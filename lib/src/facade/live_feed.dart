part of '../../winche_database.dart';

/// A live server subscription feed — query (`listen`) or single document
/// (`doc.listen`). Exposes the authoritative server document set as a stream
/// that emits a `List<WireDocument>` on each server snapshot/delta and `null`
/// whenever the link goes down (disconnected or network disabled).
///
/// It (re)subscribes whenever the connection is ready, resubscribes on reconnect
/// carrying the last resume token (the server still sends a full snapshot
/// first), and treats connectivity/subscribe failures as transient — it never
/// closes the output stream on them. Only a permanent error (see
/// [_permanentStatuses]) is surfaced as a stream error and stops resubscription.
///
/// Subclasses supply just the subscribe frame ([_subscribeFrame]) and the
/// per-type frame handling ([_handleFrame], publishing via [_publish]).
/// Consumed by the matching [_LiveListener].
abstract class _LiveFeed {
  _LiveFeed(this._db);

  final WincheDatabase _db;

  final StreamController<List<WireDocument>?> _out =
      StreamController<List<WireDocument>?>.broadcast();

  bool _active = false; // a subscription is established and delivering
  int? _resumeToken;
  String? _subscriptionId;
  StreamSubscription<ServerFrame>? _frames;
  StreamSubscription<void>? _reconnectSub;
  StreamSubscription<ConnectionState>? _stateSub;
  bool _disposed = false;
  bool _permanent = false;

  /// `null` = link is down; a list = current server set.
  Stream<List<WireDocument>?> get serverDocs => _out.stream;

  /// Error statuses that stop all future (re)subscription and surface once on
  /// the stream. Both variants share the set: a `doc.listen` never produces
  /// `INVALID_QUERY`, so including it is harmless.
  static const _permanentStatuses = {
    'INVALID_QUERY',
    'INVALID_ARGUMENT',
    'PERMISSION_DENIED',
    'UNAUTHENTICATED',
  };

  // ── Hooks ──────────────────────────────────────────────────────────────────

  /// The subscribe frame (`listen` / `doc.listen`) for [resumeToken].
  Map<String, Object?> _subscribeFrame(int? resumeToken);

  /// Handles one server frame (snapshot/delta), updating local state and
  /// publishing the new set via [_publish]. Updates [_resumeToken].
  void _handleFrame(ServerFrame frame);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Publishes the current document set, marking the feed active.
  void _publish(List<WireDocument> docs) {
    _active = true;
    if (!_out.isClosed) _out.add(List.unmodifiable(docs));
  }

  void start() {
    _reconnectSub = _db.reconnects.listen((_) => _resubscribe(fresh: false));
    _stateSub = _db.connectionStates.listen((s) {
      if (s == ConnectionState.disconnected ||
          s == ConnectionState.reconnecting ||
          s == ConnectionState.closed) {
        _goDown();
      }
    });
    _subscribe(resumeToken: null);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _reconnectSub?.cancel();
    await _stateSub?.cancel();
    await _teardown(sendUnlisten: true);
    if (!_out.isClosed) await _out.close();
  }

  Future<void> _subscribe({required int? resumeToken}) async {
    if (_disposed || _permanent) return;
    if (_frames != null) return; // already subscribed
    try {
      final result =
          await _db._transport.request(_subscribeFrame(resumeToken));
      if (_disposed) return;
      final subId = result['subscriptionId'] as String;
      _subscriptionId = subId;
      _frames = _db
          .listenEvents(subId)
          .listen(_handleFrame, onError: (_) => _goDown(), onDone: _goDown);
    } on WincheException catch (e) {
      if (_permanentStatuses.contains(e.status)) {
        _permanent = true;
        if (!_out.isClosed) _out.addError(e);
      } else {
        // Transient (offline / unavailable): stay down; reconnect drives retry.
        _goDown();
      }
    } catch (_) {
      _goDown();
    }
  }

  /// Re-subscribe on a fresh socket (reconnect) or on going online.
  Future<void> _resubscribe({required bool fresh}) async {
    if (_disposed) return;
    await _teardown(sendUnlisten: false); // old sub is dead server-side
    await _subscribe(resumeToken: fresh ? null : _resumeToken);
  }

  Future<void> _teardown({required bool sendUnlisten}) async {
    final subId = _subscriptionId;
    _subscriptionId = null;
    await _frames?.cancel();
    _frames = null;
    if (subId != null) {
      if (sendUnlisten) {
        // Fire-and-forget: never wait for the ack so teardown can't hang when
        // the server is unreachable or slow to respond.
        _db._transport.request(unlistenFrame('', subId)).ignore();
      }
      _db.releaseSubscription(subId);
    }
  }

  void _goDown() {
    if (_disposed) return;
    if (_active) {
      _active = false;
      if (!_out.isClosed) _out.add(null);
    }
  }
}

/// Query feed (`listen`). Accumulates the server-authoritative document set in
/// server order, applying snapshots and deltas (with index math and a
/// count-mismatch checksum that triggers a fresh resubscribe).
final class _QueryFeed extends _LiveFeed {
  _QueryFeed(super._db, this._spec);

  final QuerySpec _spec;

  /// The current server-authoritative document set (server order).
  List<WireDocument> _docs = [];

  @override
  Map<String, Object?> _subscribeFrame(int? resumeToken) =>
      listenFrame('', _spec, resumeToken: resumeToken);

  @override
  void _handleFrame(ServerFrame frame) {
    switch (frame) {
      case ListenSnapshotFrame(:final documents, :final resumeToken):
        _resumeToken = resumeToken;
        _docs = List<WireDocument>.of(documents);
        _publish(_docs);
      case ListenDeltaFrame(:final changes, :final count, :final resumeToken):
        _resumeToken = resumeToken;
        _applyDelta(changes, count);
      default:
        break;
    }
  }

  void _applyDelta(List<WireChange> changes, int count) {
    final docs = List<WireDocument>.of(_docs);
    // Removals (descending oldIndex so earlier indices stay valid).
    final removals = changes.where((c) => c.kind == ChangeKind.removed).toList()
      ..sort((a, b) => b.oldIndex.compareTo(a.oldIndex));
    for (final c in removals) {
      if (c.oldIndex >= 0 && c.oldIndex < docs.length) {
        docs.removeAt(c.oldIndex);
      }
    }
    // Modified: remove old position by path.
    final mods = changes.where((c) => c.kind == ChangeKind.modified).toList();
    for (final c in mods) {
      final i = docs.indexWhere((d) => d.path == c.document.path);
      if (i >= 0) docs.removeAt(i);
    }
    // Inserts (added + modified) in ascending newIndex.
    final inserts = [
      ...changes.where((c) => c.kind == ChangeKind.added),
      ...mods,
    ]..sort((a, b) => a.newIndex.compareTo(b.newIndex));
    for (final c in inserts) {
      docs.insert(c.newIndex.clamp(0, docs.length), c.document);
    }
    if (docs.length != count) {
      // Count mismatch (PROTOCOL §7.6): re-subscribe fresh (full snapshot).
      _resubscribe(fresh: true);
      return;
    }
    _docs = docs;
    _publish(_docs);
  }
}

/// Single-document feed (`doc.listen`). Exposes the authoritative server
/// document as a 0-or-1-element list — a snapshot/delta simply sets the document
/// (or clears it on removal); no ordering, index math, or count-mismatch
/// resubscription is needed.
final class _DocumentFeed extends _LiveFeed {
  _DocumentFeed(super._db, this._path);

  final String _path;

  WireDocument? _doc;

  @override
  Map<String, Object?> _subscribeFrame(int? resumeToken) =>
      docListenFrame('', _path, resumeToken: resumeToken);

  @override
  void _handleFrame(ServerFrame frame) {
    switch (frame) {
      case ListenSnapshotFrame(:final documents, :final resumeToken):
        _resumeToken = resumeToken;
        _doc = documents.isEmpty ? null : documents.first;
        _publishDoc();
      case ListenDeltaFrame(:final changes, :final resumeToken):
        _resumeToken = resumeToken;
        for (final c in changes) {
          _doc = c.kind == ChangeKind.removed ? null : c.document;
        }
        _publishDoc();
      default:
        break;
    }
  }

  void _publishDoc() => _publish(_doc == null ? const [] : [_doc!]);
}
