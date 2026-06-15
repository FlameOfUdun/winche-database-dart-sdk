part of '../../winche_database.dart';

/// Maintains a single live server subscription for [_spec] and exposes the
/// authoritative server document set as a stream. Emits:
///   * a `List<WireDocument>` whenever a server snapshot/delta updates the set,
///   * `null` whenever the link goes down (disconnected or network disabled).
///
/// It (re)subscribes whenever the connection is ready AND network is enabled,
/// resubscribes on reconnect (carrying the last resume token — the server still
/// sends a full snapshot first), and treats connectivity/subscribe failures as
/// transient: it never closes the output stream on them. Only a permanent query
/// error (INVALID_QUERY / INVALID_ARGUMENT) is surfaced as a stream error.
final class _LiveServerLink {
  _LiveServerLink(this._db, this._spec);

  final WincheDatabase _db;
  final QuerySpec _spec;

  final StreamController<List<WireDocument>?> _out =
      StreamController<List<WireDocument>?>.broadcast();

  /// The current server-authoritative document set (server order).
  List<WireDocument> _docs = [];
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
    await _teardownServerSub(sendUnlisten: true);
    if (!_out.isClosed) await _out.close();
  }

  // --- subscription lifecycle ---

  Future<void> _subscribe({required int? resumeToken}) async {
    if (_disposed || _permanent) return;
    if (_frames != null) return; // already subscribed
    try {
      final result = await _db._transport
          .request(listenFrame('', _spec, resumeToken: resumeToken));
      if (_disposed) return;
      final subId = result['subscriptionId'] as String;
      _subscriptionId = subId;
      _frames = _db
          .listenEvents(subId)
          .listen(_onFrame, onError: _onFrameError, onDone: _goDown);
    } on InvalidQueryException catch (e) {
      _surfacePermanent(e);
    } on InvalidArgumentException catch (e) {
      _surfacePermanent(e);
    } on PermissionDeniedException catch (e) {
      _surfacePermanent(e);
    } on UnauthenticatedException catch (e) {
      _surfacePermanent(e);
    } catch (_) {
      // Transient (offline / unavailable): stay down; reconnect drives retry.
      _goDown();
    }
  }

  /// Surfaces a permanent error once and stops all future (re)subscription.
  void _surfacePermanent(WincheException e) {
    _permanent = true;
    if (!_out.isClosed) _out.addError(e);
  }

  /// Re-subscribe on a fresh socket (reconnect) or on going online.
  Future<void> _resubscribe({required bool fresh}) async {
    if (_disposed) return;
    await _teardownServerSub(
        sendUnlisten: false); // old sub is dead server-side
    await _subscribe(resumeToken: fresh ? null : _resumeToken);
  }

  Future<void> _teardownServerSub({required bool sendUnlisten}) async {
    final subId = _subscriptionId;
    _subscriptionId = null;
    await _frames?.cancel();
    _frames = null;
    if (subId != null) {
      if (sendUnlisten) {
        try {
          await _db._transport.request(unlistenFrame('', subId));
        } catch (_) {}
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

  // --- frame handling: accumulate the server doc set ---

  void _onFrame(ServerFrame frame) {
    switch (frame) {
      case ListenSnapshotFrame(:final documents, :final resumeToken):
        _resumeToken = resumeToken;
        _docs = List<WireDocument>.of(documents);
        _active = true;
        if (!_out.isClosed) _out.add(List.unmodifiable(_docs));
      case ListenDeltaFrame(:final changes, :final count, :final resumeToken):
        _resumeToken = resumeToken;
        _applyDelta(changes, count);
      default:
        break;
    }
  }

  void _onFrameError(Object error) {
    // Treat as a transient drop; the reconnect path re-establishes it.
    _goDown();
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
    _active = true;
    if (!_out.isClosed) _out.add(List.unmodifiable(_docs));
  }
}
