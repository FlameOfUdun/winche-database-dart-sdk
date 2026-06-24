part of '../../winche_database.dart';

/// Maintains a live subscription for a single document via the dedicated
/// `doc.listen` server frame, overlaying pending local writes for latency
/// compensation. Mirrors [_LiveQuery] but for exactly one document.
final class _LiveDocument<T> {
  _LiveDocument(this._db, this._ref);

  final WincheDatabase _db;
  final DocumentReference<T> _ref;

  String get _path => _ref.path;

  StreamController<DocumentSnapshot<T>>? _controller;
  _LiveDocumentServerLink? _link;
  StreamSubscription<List<WireDocument>?>? _linkSub;
  StreamSubscription<void>? _changeSub;
  bool _cancelled = false;

  WireDocument? _serverDoc;
  bool _serverActive = false;

  Stream<DocumentSnapshot<T>> stream() {
    final controller = StreamController<DocumentSnapshot<T>>(
      onListen: _onListen,
      onCancel: _onCancel,
    );
    _controller = controller;
    return controller.stream;
  }

  Future<void> _onListen() async {
    await _emit();
    if (_cancelled) return;

    _changeSub = _db.localChanges.stream.listen((_) => _emit());
    if (_cancelled) {
      await _changeSub?.cancel();
      _changeSub = null;
      return;
    }

    final link = _LiveDocumentServerLink(_db, _path);
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
      _serverActive = false;
      await _emit();
      return;
    }
    _serverActive = true;
    _serverDoc = docs.isEmpty ? null : docs.first;
    if (_serverDoc != null) await _db.cache.putConfirmed(_serverDoc!);
    await _emit();
  }

  void _onServerError(Object error) => _controller?.addError(error);

  Future<void> _emit() async {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    final base = _serverActive ? _serverDoc : await _db.cache.confirmed(_path);
    final pending = await _db.queue.forPath(_path);
    final eff = applyOverlay(base, pending);
    final metadata = SnapshotMetadata(
      fromCache: !_serverActive,
      hasPendingWrites: eff.hasPendingWrites,
    );
    if (controller.isClosed) return;
    controller.add(eff.document == null
        ? DocumentSnapshot<T>._missing(_ref, metadata: metadata)
        : DocumentSnapshot<T>._fromWire(_ref, eff.document!, metadata: metadata));
  }
}

/// Maintains a single live `doc.listen` server subscription, exposing the
/// authoritative server document as a 0-or-1-element list stream. Emits `null`
/// when the link goes down. Mirrors [_LiveServerLink]'s lifecycle (reconnect,
/// permanent-error, unlisten teardown) but for one document — no ordering,
/// index math, or count-mismatch resubscription is needed.
final class _LiveDocumentServerLink {
  _LiveDocumentServerLink(this._db, this._path);

  final WincheDatabase _db;
  final String _path;

  final StreamController<List<WireDocument>?> _out =
      StreamController<List<WireDocument>?>.broadcast();

  WireDocument? _doc;
  bool _active = false;
  int? _resumeToken;
  String? _subscriptionId;
  StreamSubscription<ServerFrame>? _frames;
  StreamSubscription<void>? _reconnectSub;
  StreamSubscription<ConnectionState>? _stateSub;
  bool _disposed = false;
  bool _permanent = false;

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
    await _teardown(sendUnlisten: true);
    if (!_out.isClosed) await _out.close();
  }

  Future<void> _subscribe({required int? resumeToken}) async {
    if (_disposed || _permanent) return;
    if (_frames != null) return;
    try {
      final result = await _db._transport
          .request(docListenFrame('', _path, resumeToken: resumeToken));
      if (_disposed) return;
      final subId = result['subscriptionId'] as String;
      _subscriptionId = subId;
      _frames = _db
          .listenEvents(subId)
          .listen(_onFrame, onError: (_) => _goDown(), onDone: _goDown);
    } on InvalidArgumentException catch (e) {
      _surfacePermanent(e);
    } on PermissionDeniedException catch (e) {
      _surfacePermanent(e);
    } on UnauthenticatedException catch (e) {
      _surfacePermanent(e);
    } catch (_) {
      _goDown();
    }
  }

  void _surfacePermanent(WincheException e) {
    _permanent = true;
    if (!_out.isClosed) _out.addError(e);
  }

  Future<void> _resubscribe({required bool fresh}) async {
    if (_disposed) return;
    await _teardown(sendUnlisten: false);
    await _subscribe(resumeToken: fresh ? null : _resumeToken);
  }

  Future<void> _teardown({required bool sendUnlisten}) async {
    final subId = _subscriptionId;
    _subscriptionId = null;
    await _frames?.cancel();
    _frames = null;
    if (subId != null) {
      if (sendUnlisten) {
        // Fire-and-forget: we do not wait for the server ack so that teardown
        // never hangs when the server is unreachable or slow to respond.
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

  void _onFrame(ServerFrame frame) {
    switch (frame) {
      case ListenSnapshotFrame(:final documents, :final resumeToken):
        _resumeToken = resumeToken;
        _doc = documents.isEmpty ? null : documents.first;
        _publish();
      case ListenDeltaFrame(:final changes, :final resumeToken):
        _resumeToken = resumeToken;
        for (final c in changes) {
          _doc = c.kind == ChangeKind.removed ? null : c.document;
        }
        _publish();
      default:
        break;
    }
  }

  void _publish() {
    _active = true;
    if (!_out.isClosed) {
      _out.add(_doc == null ? const <WireDocument>[] : [_doc!]);
    }
  }
}
