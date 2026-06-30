part of '../../winche_database.dart';

/// A facade live listener — backs `QueryReference.snapshots()` or
/// `DocumentReference.snapshots()`. Semantics common to both:
///
///   * Always emits the EFFECTIVE view = server/cache base + pending overlay.
///   * The live [_LiveFeed] feeds the base (write-through to the confirmed
///     cache); when it is down, the base falls back to the local cache.
///   * `metadata.fromCache` is true until/unless the feed is delivering.
///
/// Subclasses supply the feed ([_createFeed]), how a server set is stored and
/// written through ([_storeServerDocs]), and how an effective snapshot is built
/// and emitted ([_emit]).
abstract class _LiveListener<TSnapshot> {
  _LiveListener(this._db);

  final WincheDatabase _db;

  StreamController<TSnapshot>? _controller;
  _LiveFeed? _feed;
  StreamSubscription<_FeedUpdate?>? _feedSub;
  StreamSubscription<void>? _changeSub;
  bool _cancelled = false;

  /// Whether the feed is currently delivering (drives `fromCache`).
  bool _serverActive = false;

  // ── Hooks ──────────────────────────────────────────────────────────────────

  /// Creates the server feed for this listener (query or single document).
  _LiveFeed _createFeed();

  /// Stores the latest server update and writes it through to the confirmed cache.
  Future<void> _storeServerDocs(_FeedUpdate update);

  /// Builds and emits the current effective snapshot to [_controller].
  Future<void> _emit();

  /// Releases any references this listener pins against eviction. Default no-op.
  void _releaseReferences() {}

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Stream<TSnapshot> stream() {
    final controller = StreamController<TSnapshot>(
      onListen: _onListen,
      onCancel: _onCancel,
    );
    _controller = controller;
    return controller.stream;
  }

  Future<void> _onListen() async {
    // Cache-first emission so the consumer gets an immediate snapshot.
    await _emit();
    if (_cancelled) return;

    // React to local cache/queue mutations (latency compensation).
    _changeSub = _db.localChanges.stream.listen((_) => _emit());
    if (_cancelled) {
      await _changeSub?.cancel();
      _changeSub = null;
      return;
    }

    // Start the live server feed and react to its updates.
    final feed = _createFeed();
    _feed = feed;
    _feedSub = feed.serverDocs.listen(_onServerDocs, onError: _onServerError);
    feed.start();
    if (_cancelled) {
      await _feedSub?.cancel();
      _feedSub = null;
      await feed.dispose();
      _feed = null;
      await _changeSub?.cancel();
      _changeSub = null;
    }
  }

  Future<void> _onCancel() async {
    _cancelled = true;
    _releaseReferences();
    await _feedSub?.cancel();
    _feedSub = null;
    await _feed?.dispose();
    _feed = null;
    await _changeSub?.cancel();
    _changeSub = null;
    await _controller?.close();
    _controller = null;
  }

  Future<void> _onServerDocs(_FeedUpdate? update) async {
    if (update == null) {
      // Feed down: fall back to cache/last-known.
      _serverActive = false;
      await _emit();
      return;
    }
    _serverActive = true;
    if (update.currentOnly) {
      // Covered resume: we are live and up to date — keep the existing base
      // (last server set, or cache/membership on a cold start) and just re-emit
      // so `fromCache` clears.
      await _emit();
      return;
    }
    if (update.tombstoneOnly) {
      // Count-mismatch resubscribe: persist the deletions to the cache without
      // emitting (transparent) so they can't resurface offline before the fresh
      // snapshot arrives.
      for (final p in update.deletedPaths) {
        await _db.cache
            .putConfirmedDeleted(p, formatMetaTimestamp(DateTime.now()));
      }
      return;
    }
    await _storeServerDocs(update);
    await _emit();
  }

  void _onServerError(Object error) => _controller?.addError(error);
}

/// A live query listener. Builds each emission as the effective view
/// (server/cache base + pending overlay) run through the local query engine,
/// then diffs the previous ordered list to produce `docChanges`.
/// `metadata.hasPendingWrites` is true when the overlay added un-acked local
/// writes. Backed by a [_QueryFeed].
final class _QueryListener<T> extends _LiveListener<QuerySnapshot<T>> {
  _QueryListener(super._db, this._spec, this._converter);

  final QuerySpec _spec;
  final Converter<T> _converter;

  /// Last server-authoritative set (null until the first server snapshot).
  List<WireDocument>? _serverDocs;

  /// Previous emitted ordered docs, for change diffing.
  List<DocumentSnapshot<T>> _lastDocs = [];
  bool _first = true;

  @override
  _LiveFeed _createFeed() => _QueryFeed(_db, _spec);

  @override
  Future<void> _storeServerDocs(_FeedUpdate update) async {
    _serverDocs = update.docs;
    final paths = [for (final d in update.docs) d.path];
    await _db.targets.setMembers(_spec, paths);
    _db.activeTargets.pin(this, paths);
    // Write-through so the offline fallback + one-shot reads stay warm (one
    // eviction pass for the whole batch).
    await _db.cache.putConfirmedAll(update.docs);
    // Tombstone documents the server reported deleted so they cannot reappear
    // from the cache (offline fallback, one-shot reads, a new listener).
    for (final path in update.deletedPaths) {
      await _db.cache
          .putConfirmedDeleted(path, formatMetaTimestamp(DateTime.now()));
    }
  }

  @override
  void _releaseReferences() => _db.activeTargets.unpin(this);

  @override
  Future<void> _emit() async {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;

    final base = await _baseDocs();
    final pendingByPath = await _pendingByPath();
    final view = buildEffectiveView(base, pendingByPath);
    final ordered = const LocalQueryEngine().runQuery(_spec, view.docs);
    final shaped = _spec.select == null
        ? ordered
        : [for (final d in ordered) projectFields(d, _spec.select!)];

    final metadata = SnapshotMetadata(
      fromCache: !_serverActive,
      hasPendingWrites: view.anyPending,
    );
    final newDocs = [
      for (final wire in shaped)
        DocumentSnapshot<T>._fromWire(
            _db.doc(wire.path).withConverter(_converter), wire,
            metadata: metadata),
    ];

    final changes = _first
        ? [
            for (var i = 0; i < newDocs.length; i++)
              DocumentChange<T>(
                  type: DocumentChangeType.added,
                  oldIndex: -1,
                  newIndex: i,
                  doc: newDocs[i]),
          ]
        : _diff(_lastDocs, newDocs);
    _first = false;
    _lastDocs = newDocs;

    if (controller.isClosed) return;
    controller.add(QuerySnapshot<T>(
      docs: List.unmodifiable(newDocs),
      docChanges: changes,
      readTime: DateTime.now().toUtc(),
      resumeToken: null,
      hasMore: false,
      metadata: metadata,
    ));
  }

  /// The base document set for an emission. Prefers the query's server-reported
  /// membership (the last live set, or — when this listener has not yet received a
  /// snapshot — a membership left by a prior/concurrent listener or get), resolved
  /// against the cache. Re-deriving over the whole collection is the last resort
  /// (a cold query never listened/got), because it would resurface out-of-window
  /// or stale-but-locally-matching documents.
  Future<List<WireDocument>> _baseDocs() async {
    if (_serverDocs != null) return _serverDocs!;
    final members = await _db.targets.members(_spec);
    if (members != null) return _resolveMembers(members);
    return _db.cache.confirmedInCollection(_spec.collection);
  }

  Future<List<WireDocument>> _resolveMembers(List<String> paths) async {
    final docs = <WireDocument>[];
    for (final p in paths) {
      final doc = await _db.cache.confirmed(p);
      if (doc != null) docs.add(doc);
    }
    return docs;
  }

  Future<Map<String, List<PendingWrite>>> _pendingByPath() =>
      _db.queue.byPathInCollection(_spec.collection);

  /// Ordered-list diff by path + updateTimeRaw (added/modified/removed change set).
  static List<DocumentChange<T>> _diff<T>(
    List<DocumentSnapshot<T>> oldDocs,
    List<DocumentSnapshot<T>> newDocs,
  ) {
    final oldByPath = <String, int>{};
    for (var i = 0; i < oldDocs.length; i++) {
      oldByPath[oldDocs[i].path] = i;
    }
    final newByPath = <String, int>{};
    for (var j = 0; j < newDocs.length; j++) {
      newByPath[newDocs[j].path] = j;
    }
    final removed = <DocumentChange<T>>[];
    final added = <DocumentChange<T>>[];
    final modified = <DocumentChange<T>>[];
    for (var i = 0; i < oldDocs.length; i++) {
      if (!newByPath.containsKey(oldDocs[i].path)) {
        removed.add(DocumentChange<T>(
            type: DocumentChangeType.removed,
            oldIndex: i,
            newIndex: -1,
            doc: oldDocs[i]));
      }
    }
    for (var j = 0; j < newDocs.length; j++) {
      final oldIdx = oldByPath[newDocs[j].path];
      if (oldIdx == null) {
        added.add(DocumentChange<T>(
            type: DocumentChangeType.added,
            oldIndex: -1,
            newIndex: j,
            doc: newDocs[j]));
      } else if (oldDocs[oldIdx].updateTimeRaw != newDocs[j].updateTimeRaw) {
        modified.add(DocumentChange<T>(
            type: DocumentChangeType.modified,
            oldIndex: oldIdx,
            newIndex: j,
            doc: newDocs[j]));
      }
    }
    return [...removed, ...added, ...modified];
  }
}

/// A live single-document listener. Backed by the dedicated `doc.listen` server
/// frame (a [_DocumentFeed]) and overlaying pending local writes for latency
/// compensation; emits a non-existent snapshot when the document is absent. The
/// query-vs-document split mirrors the server: `doc.listen` is authorized as
/// `get` (not the collection `list`).
final class _DocumentListener<T> extends _LiveListener<DocumentSnapshot<T>> {
  _DocumentListener(super._db, this._ref);

  final DocumentReference<T> _ref;

  String get _path => _ref.path;

  /// Last server-authoritative document (null = absent or no server data yet).
  WireDocument? _serverDoc;

  @override
  _LiveFeed _createFeed() => _DocumentFeed(_db, _path);

  @override
  Future<void> _storeServerDocs(_FeedUpdate update) async {
    _serverDoc = update.docs.isEmpty ? null : update.docs.first;
    if (_serverDoc != null) {
      _db.activeTargets.pin(this, [_path]);
      await _db.cache.putConfirmed(_serverDoc!);
    } else {
      _db.activeTargets.unpin(this);
      if (update.deletedPaths.contains(_path)) {
        await _db.cache
            .putConfirmedDeleted(_path, formatMetaTimestamp(DateTime.now()));
      }
    }
  }

  @override
  void _releaseReferences() => _db.activeTargets.unpin(this);

  @override
  Future<void> _emit() async {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    // A covered-resume (listen.current) marks us active without delivering a
    // document, so _serverDoc stays null even though the doc may be live in the
    // cache; fall back to the cache rather than emitting a false "missing".
    final base = (_serverActive && _serverDoc != null)
        ? _serverDoc
        : await _db.cache.confirmed(_path);
    final pending = await _db.queue.forPath(_path);
    final eff = applyOverlay(base, pending);
    final metadata = SnapshotMetadata(
      fromCache: !_serverActive,
      hasPendingWrites: eff.hasPendingWrites,
    );
    if (controller.isClosed) return;
    controller.add(eff.document == null
        ? DocumentSnapshot<T>._missing(_ref, metadata: metadata)
        : DocumentSnapshot<T>._fromWire(_ref, eff.document!,
            metadata: metadata));
  }
}
