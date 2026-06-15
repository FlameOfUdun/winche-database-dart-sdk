part of '../../winche_database.dart';

/// One live query (used by both `QueryReference.snapshots()` and
/// `doc.snapshots()`), with these semantics:
///
///   * Always emits the EFFECTIVE view = base + pending overlay.
///   * The live server stream feeds the base (write-through to the confirmed
///     cache); when there is no server link it falls back to the cache (or, with
///     no cache configured, the last-known server set).
///   * `docChanges` come from diffing the previous emitted ordered list against
///     the new one. `metadata.fromCache` is true until/unless the server link is
///     delivering; `metadata.hasPendingWrites` is true when the overlay added
///     un-acked local writes.
final class _LiveQuery<T> {
  _LiveQuery(this._db, this._spec, this._converter);

  final WincheDatabase _db;
  final QuerySpec _spec;
  final Converter<T> _converter;

  StreamController<QuerySnapshot<T>>? _controller;
  _LiveServerLink? _link;
  StreamSubscription<List<WireDocument>?>? _linkSub;
  StreamSubscription<void>? _changeSub;
  bool _cancelled = false;

  /// Last server-authoritative set (null until the first server snapshot).
  List<WireDocument>? _serverDocs;

  /// Whether the server link is currently delivering (drives `fromCache`).
  bool _serverActive = false;

  /// Previous emitted ordered docs, for change diffing.
  List<DocumentSnapshot<T>> _lastDocs = [];
  bool _first = true;

  Stream<QuerySnapshot<T>> stream() {
    final controller = StreamController<QuerySnapshot<T>>(
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

    // Start the live server link and react to its updates.
    final link = _LiveServerLink(_db, _spec);
    _link = link;
    _linkSub = link.serverDocs.listen(_onServerDocs, onError: _onServerError);
    link.start();
    if (_cancelled) {
      await _linkSub?.cancel();
      _linkSub = null;
      await link.dispose();
      _link = null;
      await _changeSub?.cancel();
      _changeSub = null;
    }
  }

  Future<void> _onCancel() async {
    _cancelled = true;
    await _linkSub?.cancel();
    _linkSub = null;
    await _link?.dispose();
    _link = null;
    await _changeSub?.cancel();
    _changeSub = null;
    await _controller?.close();
    _controller = null;
  }

  Future<void> _onServerDocs(List<WireDocument>? docs) async {
    if (docs == null) {
      // Link down: fall back to cache/last-known.
      _serverActive = false;
      await _emit();
      return;
    }
    _serverActive = true;
    _serverDocs = docs;
    // Write-through so the offline fallback + one-shot reads stay warm.
    for (final d in docs) {
      await _db.cache.putConfirmed(d);
    }
    await _emit();
  }

  void _onServerError(Object error) {
    // Permanent query error surfaced by the link: forward once.
    _controller?.addError(error);
  }

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

  /// The base document set: the live server set when active, else the local
  /// confirmed cache.
  Future<List<WireDocument>> _baseDocs() async {
    if (_serverActive && _serverDocs != null) return _serverDocs!;
    return _db.cache.confirmedInCollection(_spec.collection);
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
