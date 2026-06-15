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
  void dispose() {
    unawaited(Future(() async {
      await _stateForward?.cancel();
      await _connection?.close();
      _connection = null;
      if (!_states.isClosed) await _states.close();
    }));
  }
}
