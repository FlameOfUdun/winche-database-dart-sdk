part of 'transport.dart';

final class WsTransport implements Transport {
  WsTransport(this._config);

  final ConnectionConfig _config;

  Future<ProtocolConnection>? _connectFuture;
  ProtocolConnection? _connection;
  StreamSubscription<ConnectionState>? _stateForward;

  // Stable, transport-owned level signal: survives ProtocolConnection's in-place
  // reconnects because we never replace the connection instance, and hands every
  // subscriber the current state so nobody has to seed themselves.
  final ValueRelay<ConnectionState> _states =
      ValueRelay<ConnectionState>(ConnectionState.connecting);

  @override
  Stream<ConnectionState> get connectionStates => _states.stream;

  @override
  ConnectionState get connectionState => _states.value;

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

  /// Returns the single long-lived connection, creating it once.
  ///
  /// This resolves to the connection *object*, which may not be `ready` — a
  /// failed dial leaves it retrying rather than discarded. That is safe because
  /// [request] fails fast with [UnavailableException] on any non-ready state,
  /// so callers still see the failure immediately.
  ///
  /// The connection reconnects itself in place (PROTOCOL §7); we never
  /// close+recreate it here — doing so previously orphaned listener streams
  /// during the reconnect window.
  Future<ProtocolConnection> _ensureConnected() {
    if (_disposed) {
      return Future.error(
          const UnavailableException('Transport has been disposed.'));
    }
    final inFlight = _connectFuture;
    if (inFlight != null) return inFlight;
    final c = _connection;
    if (c != null && c.currentState != ConnectionState.closed) {
      return Future.value(c);
    }
    _connectFuture = _connect();
    return _connectFuture!;
  }

  Future<ProtocolConnection> _connect() async {
    // Own the connection BEFORE dialling. `connect()` starts a retry loop when
    // the dial fails; if we only assigned on success, that loop would be
    // orphaned — `dispose()` could not reach it, and the next call here would
    // build a second connection with a second loop, one per failed dial.
    final connection = ProtocolConnection(_config);
    _connection = connection;
    // Forward transitions, but NOT `done`: close() closes the connection's state
    // controller, and forwarding that would end the facade-lifetime stream and
    // freeze every consumer on its last value.
    _stateForward = connection.states.listen(_states.add);
    _states.add(connection.currentState);
    try {
      await connection.connect();
    } catch (_) {
      // The retry loop owns recovery from here. Deliberately swallowed: callers
      // still see the failure, because `request()` fails fast on any non-ready
      // state, and keeping the connection is what lets the loop reach `ready`.
    } finally {
      _connectFuture = null;
    }
    return connection;
  }

  @override
  Future<void> reconnect() async {
    if (_disposed) {
      throw const UnavailableException('Transport has been disposed.');
    }
    final existing = _connection;
    if (existing == null ||
        existing.currentState == ConnectionState.closed ||
        existing.currentState == ConnectionState.connecting) {
      // Never dialled yet, still dialling, or the last dial failed (which now
      // leaves the connection parked in `connecting`, not discarded): connecting
      // IS the reconnect, and it reads the current token anyway.
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
    // that was opened while dispose() was running. `_connect` absorbs dial
    // failures itself, so this cannot throw.
    await _connectFuture;
    await _stateForward?.cancel();
    await _connection?.close();
    _connection = null;
    _connectFuture = null;
    await _states.close();
  }
}
