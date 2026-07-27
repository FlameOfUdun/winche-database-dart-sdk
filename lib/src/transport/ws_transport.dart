part of 'transport.dart';

final class WsTransport implements Transport {
  WsTransport(this._config);

  final ConnectionConfig _config;

  Future<ProtocolConnection>? _connectFuture;
  ProtocolConnection? _connection;
  StreamSubscription<ConnectionState>? _stateForward;

  // Stable, transport-owned state stream: survives ProtocolConnection's
  // in-place reconnects because we never replace the connection instance.
  final StreamController<ConnectionState> _states =
      StreamController<ConnectionState>.broadcast();

  @override
  Stream<ConnectionState> get connectionStates => _states.stream;

  @override
  Stream<ServerFrame> listenEvents(String subscriptionId) async* {
    final connection = await _ensureConnected();
    yield* connection.listenEvents(subscriptionId);
  }

  @override
  Stream<void> get reconnects async* {
    final ProtocolConnection connection;
    try {
      connection = await _ensureConnected();
    } catch (_) {
      return;
    }
    yield* connection.reconnects;
  }

  @override
  void releaseSubscription(String subscriptionId) {
    _connection?.releaseSubscription(subscriptionId);
  }

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    final connection = await _ensureConnected();
    return connection.request(frame);
  }

  /// Returns the single long-lived connection, creating it once. The connection
  /// reconnects itself in place (PROTOCOL §7); we never close+recreate it here
  /// — doing so previously orphaned listener streams during the reconnect window.
  Future<ProtocolConnection> _ensureConnected() {
    if (_disposed) {
      return Future.error(
          const UnavailableException('Transport has been disposed.'));
    }
    final c = _connection;
    if (c != null && c.currentState != ConnectionState.closed) {
      return Future.value(c);
    }
    _connectFuture ??= _connect();
    return _connectFuture!;
  }

  Future<ProtocolConnection> _connect() async {
    final connection = ProtocolConnection(_config);
    try {
      await connection.connect();
    } catch (e) {
      _connectFuture = null; // allow a fresh attempt on the next call
      rethrow;
    }
    _connection = connection;
    _connectFuture = null;
    // Forward this connection's state transitions onto the stable stream.
    _stateForward = connection.states.listen((s) {
      if (!_states.isClosed) _states.add(s);
    });
    if (!_states.isClosed) _states.add(connection.currentState);
    return connection;
  }

  @override
  ConnectionState get connectionState =>
      _connection?.currentState ?? ConnectionState.connecting;

  @override
  Future<void> reconnect() async {
    if (_disposed) {
      throw const UnavailableException('Transport has been disposed.');
    }
    final existing = _connection;
    if (existing == null || existing.currentState == ConnectionState.closed) {
      // Never dialled yet (or the last dial failed): connecting IS the
      // reconnect, and it reads the current token anyway.
      await _ensureConnected();
      return;
    }
    await existing.reconnect();
  }

  /// Set before the connection is torn down so no caller can re-dial a fresh
  /// socket through [_ensureConnected] after disposal.
  bool _disposed = false;
  Future<void>? _disposal;

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    // Let an in-flight dial finish before closing it, so we never leak a socket
    // that was opened while dispose() was running.
    try {
      await _connectFuture;
    } catch (_) {
      // A failed dial has nothing to close.
    }
    await _stateForward?.cancel();
    await _connection?.close();
    _connection = null;
    _connectFuture = null;
    if (!_states.isClosed) await _states.close();
  }
}
