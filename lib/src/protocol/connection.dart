import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'exceptions.dart';
import 'messages.dart';

/// Connection lifecycle state.
enum ConnectionState {
  /// Initial / dialing.
  connecting,

  /// Handshake complete; fully operational.
  ready,

  /// Socket closed unexpectedly; pending requests have failed.
  disconnected,

  /// Auto-reconnect is in progress (dialing / waiting for welcome).
  reconnecting,

  /// [ProtocolConnection.close] has been called.
  closed,
}

final class ConnectionConfig {
  const ConnectionConfig({
    required this.uri,
    this.tokenProvider,
    this.pingInterval = const Duration(seconds: 30),
    this.autoReconnect = true,
    this.maxBackoff = const Duration(seconds: 30),
    this.maxFrameBytes = 1 << 20,
    this.channelFactory,
    this.sleeper,
  });

  /// The WebSocket URI, e.g. `ws://host/documents/ws`.
  final Uri uri;

  /// Supplies the auth token used as the `?access_token=` query parameter on
  /// every (re)dial. To rotate an expired token, return the new value here — the
  /// reconnect path re-reads it automatically.
  final String Function()? tokenProvider;

  /// Interval for keep-alive pings. Defaults to 30 seconds.
  final Duration pingInterval;

  /// Whether to automatically reconnect on unexpected disconnect.
  final bool autoReconnect;

  /// Maximum backoff between reconnect attempts.
  final Duration maxBackoff;

  /// Maximum size in bytes of a single outbound write frame. A batch whose
  /// serialized frame would exceed this is rejected at commit time (before it
  /// is queued), avoiding a server `4413` close. Default 1 MiB — match the
  /// server's `WsOptions.MaxFrameBytes` if it is configured differently.
  final int maxFrameBytes;

  /// For testing: allows injecting a custom WebSocketChannel factory.
  final FutureOr<WebSocketChannel> Function(Uri)? channelFactory;

  /// For testing: allows injecting a custom sleeper for backoff delays.
  final Future<void> Function(Duration)? sleeper;
}

/// WebSocket protocol connection to a Winche Database server (PROTOCOL §7).
class ProtocolConnection {
  ProtocolConnection(this.config)
      : _channelFactory = config.channelFactory ?? _defaultFactory,
        _sleeper = config.sleeper ?? _defaultSleeper;

  final ConnectionConfig config;
  final FutureOr<WebSocketChannel> Function(Uri) _channelFactory;
  final Future<void> Function(Duration) _sleeper;

  static Future<WebSocketChannel> _defaultFactory(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    // Suppress unhandled errors on the `ready` future.  If the connection
    // fails, the error surfaces both here and via the channel stream (where our
    // listener handles it with `_onError` / `_onDone`).  Without this ignore
    // the `ready` error leaks to the ambient zone and fails tests.
    channel.ready.ignore();
    return channel;
  }

  static Future<void> _defaultSleeper(Duration d) {
    return Future<void>.delayed(d);
  }

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  ConnectionState _state = ConnectionState.connecting;
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();

  Stream<ConnectionState> get states => _stateController.stream;
  ConnectionState get currentState => _state;

  void _setState(ConnectionState s) {
    _state = s;
    _stateController.add(s);
  }

  /// Emits a void event each time a reconnect succeeds.
  Stream<void> get reconnects => _reconnectController.stream;
  final StreamController<void> _reconnectController =
      StreamController<void>.broadcast();

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _sub;

  /// Correlation map: request id → Completer.
  final Map<String, Completer<Map<String, Object?>>> _pending = {};

  /// Per-subscription listener streams.
  final Map<String, StreamController<ServerFrame>> _listeners = {};

  /// Sequential send queue — ensures frames are sent in order.
  final List<Map<String, Object?>> _sendQueue = [];
  bool _sending = false;

  /// Auto-incrementing request counter.
  int _idCounter = 0;

  String _nextId() => (_idCounter++).toString();

  /// Completer that resolves when the welcome frame is received.
  Completer<void>? _welcomeCompleter;

  Timer? _pingTimer;
  int _requestsInFlight = 0;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns the dial URI with the current auth token (if any) added as the
  /// `access_token` query parameter (auth is at the WS upgrade — there is no
  /// in-band hello/auth message).
  Uri _dialUri() {
    final token = config.tokenProvider?.call();
    if (token == null) return config.uri;
    return config.uri.replace(queryParameters: {
      ...config.uri.queryParameters,
      'access_token': token,
    });
  }

  /// Dials the server and waits for the welcome frame.
  ///
  /// Authentication is performed at the WebSocket upgrade level via the
  /// `?access_token=` query parameter — no in-band hello message is sent.
  ///
  /// [welcomeTimeout] caps how long to wait for the welcome frame; defaults to
  /// 15 seconds. Throws [UnavailableException] if the timeout elapses.
  /// Throws [UnauthenticatedException] if the server returns close code 4401.
  /// Throws [WincheException] if the server sends an error frame before welcome.
  /// Throws [UnavailableException] if the connection closes before welcome or
  /// if the channel factory throws a transport-level exception (e.g. on a
  /// refused connection).
  Future<void> connect({
    Duration welcomeTimeout = const Duration(seconds: 15),
  }) async {
    _setState(ConnectionState.connecting);
    try {
      _channel = await _channelFactory(_dialUri());
    } catch (e) {
      // Channel factory threw (e.g. WebSocketChannelException on Windows when
      // the remote port is refused before the stream is even subscribed to).
      // Normalise to UnavailableException so callers don't need to know about
      // transport-layer exception types.
      throw UnavailableException('Failed to open WebSocket channel: $e');
    }
    _sub = _channel!.stream.listen(
      _onFrame,
      onError: _onError,
      onDone: _onDone,
    );

    _welcomeCompleter = Completer<void>();

    try {
      await _welcomeCompleter!.future.timeout(
        welcomeTimeout,
        onTimeout: () {
          _welcomeCompleter = null;
          throw const UnavailableException(
            'Handshake timed out: no welcome frame received',
          );
        },
      );
    } catch (_) {
      _sub?.cancel();
      rethrow;
    }
    _setState(ConnectionState.ready);
    _startPing();
  }

  /// Sends a client frame and waits for the server's response or error.
  ///
  /// Automatically assigns a unique `id` to the frame.
  /// The caller should not set an `id` in the frame — it will be overwritten.
  ///
  /// Throws [UnavailableException] immediately if the connection is not ready
  /// (including while reconnecting).
  Future<Map<String, Object?>> request(Map<String, Object?> frame) {
    if (_state != ConnectionState.ready) {
      return Future.error(
        UnavailableException(
          'Cannot send request: connection is $_state',
        ),
      );
    }
    final id = _nextId();
    final tagged = Map<String, Object?>.of(frame)..['id'] = id;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _requestsInFlight++;
    _enqueueSend(tagged);
    return completer.future.whenComplete(() {
      _requestsInFlight--;
    });
  }

  /// Returns a broadcast stream of listener frames for [subscriptionId].
  ///
  /// The stream receives [ListenSnapshotFrame] and [ListenDeltaFrame] events.
  /// On disconnect, the stream goes quiet (no error, no close).
  /// On graceful [close], the stream completes with done.
  Stream<ServerFrame> listenEvents(String subscriptionId) {
    final controller = _listeners.putIfAbsent(
      subscriptionId,
      () => StreamController<ServerFrame>.broadcast(),
    );
    return controller.stream;
  }

  /// Closes and removes the listener stream for [subscriptionId].
  ///
  /// Call this after sending an unlisten frame so the entry doesn't accumulate
  /// in the internal listeners map. Idempotent — no-op if not found.
  void releaseSubscription(String id) {
    final ctrl = _listeners.remove(id);
    if (ctrl != null && !ctrl.isClosed) ctrl.close();
  }

  /// Sends a graceful close.
  Future<void> close() async {
    _setState(ConnectionState.closed);
    _pingTimer?.cancel();
    // 1. Fail all pending requests FIRST so callers aren't stuck waiting
    //    for a sink close that may block on a dead network.
    _failAllPending('Connection closed');
    // 2. Complete all listener streams cleanly (done, no error).
    _completeAllListeners();
    _sub?.cancel();
    // 3. Attempt sink close with a short timeout so a dead network can't stall.
    try {
      await _channel?.sink.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Ignore errors from closing a dead socket.
    }
    if (!_reconnectController.isClosed) await _reconnectController.close();
    await _stateController.close();
  }

  // ---------------------------------------------------------------------------
  // Send queue
  // ---------------------------------------------------------------------------

  void _enqueueSend(Map<String, Object?> frame) {
    _sendQueue.add(frame);
    if (!_sending) _drainQueue();
  }

  void _drainQueue() {
    if (_sendQueue.isEmpty) {
      _sending = false;
      return;
    }
    _sending = true;
    final frame = _sendQueue.removeAt(0);
    final id = frame['id'] as String?;
    try {
      _channel!.sink.add(json.encode(frame));
    } catch (e) {
      // Channel closed; fail the matching pending request if any.
      if (id != null) {
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(UnavailableException('Send failed: $e'));
        }
      }
    }
    // Continue draining synchronously — frames are queued but sent in order.
    _drainQueue();
  }

  // ---------------------------------------------------------------------------
  // Incoming frame handling
  // ---------------------------------------------------------------------------

  void _onFrame(Object? data) {
    if (data is! String) {
      // Binary frames should not arrive but if they do, ignore.
      return;
    }
    final Map<String, Object?> raw;
    try {
      raw = (json.decode(data) as Map).cast<String, Object?>();
    } catch (_) {
      // Malformed JSON — log-and-ignore.
      return;
    }

    final ServerFrame frame;
    try {
      frame = ServerFrame.parse(raw);
    } on FormatException {
      // Malformed known-type frame: if it has a string 'id', fail the matching
      // pending request so the caller gets a clean error rather than a hang.
      final rawId = raw['id'];
      if (rawId is String) {
        final completer = _pending.remove(rawId);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            WincheException('INTERNAL', 'Malformed server frame for id $rawId'),
          );
        }
      }
      return;
    }

    switch (frame) {
      case WelcomeFrame():
        _welcomeCompleter?.complete();
        _welcomeCompleter = null;

      case ResponseFrame(:final id, :final result):
        final completer = _pending.remove(id);
        completer?.complete(result);

      case ErrorFrame(:final id, :final status, :final message, :final details):
        if (id != null) {
          final completer = _pending.remove(id);
          completer?.completeError(
              WincheException.fromError(status, message, details));
        } else {
          // Pre-welcome error (e.g. 4401 authentication failure).
          _welcomeCompleter?.completeError(
            WincheException.fromError(status, message, details),
          );
          _welcomeCompleter = null;
        }

      case ListenSnapshotFrame(:final subscriptionId):
        _listeners[subscriptionId]?.add(frame);

      case ListenDeltaFrame(:final subscriptionId):
        _listeners[subscriptionId]?.add(frame);

      case UnknownFrame():
        // Log-and-ignore: future server capabilities.
        break;
    }
  }

  void _onError(Object error) {
    _failAllPending('WebSocket error: $error');
  }

  void _onDone() {
    if (_state == ConnectionState.closed) return;
    _pingTimer?.cancel();
    _setState(ConnectionState.disconnected);
    _failAllPending('WebSocket disconnected');
    // Listener streams go quiet on disconnect. Do NOT addError or close them.
    // Also fail the welcome completer if we're still connecting.
    if (_welcomeCompleter != null && !_welcomeCompleter!.isCompleted) {
      _welcomeCompleter!.completeError(
        const UnavailableException('Connection closed during handshake'),
      );
      _welcomeCompleter = null;
    }
    // Start auto-reconnect loop if enabled.
    if (config.autoReconnect) {
      _reconnectLoop();
    }
  }

  // ---------------------------------------------------------------------------
  // Reconnect loop
  // ---------------------------------------------------------------------------

  /// Exponential backoff reconnect loop. Runs until ready or closed.
  Future<void> _reconnectLoop() async {
    _setState(ConnectionState.reconnecting);
    var attempt = 0;
    const baseMs = 250;

    while (_state == ConnectionState.reconnecting) {
      // Backoff before attempt (skip on first immediate retry).
      if (attempt > 0) {
        final raw = baseMs * (1 << (attempt - 1));
        final capped = raw.clamp(0, config.maxBackoff.inMilliseconds).toInt();
        // ±25% jitter.
        final jitterMs =
            (capped * 0.25 * ((_jitterSeed++ % 100) / 100.0 - 0.5) * 2)
                .toInt()
                .abs();
        final delay = Duration(milliseconds: capped + jitterMs);
        await _sleeper(delay);
        if (_state != ConnectionState.reconnecting) return;
      }
      attempt++;

      // Try to establish a new connection.
      try {
        _channel = await _channelFactory(_dialUri());
        _sub = _channel!.stream.listen(
          _onFrame,
          onError: _onError,
          onDone: _onDoneReconnect,
        );

        _welcomeCompleter = Completer<void>();

        await _welcomeCompleter!.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            _welcomeCompleter = null;
            throw const UnavailableException('Reconnect handshake timed out');
          },
        );

        // Connected!
        _setState(ConnectionState.ready);
        _startPing();
        if (!_reconnectController.isClosed) {
          _reconnectController.add(null);
        }
        return;
      } catch (_) {
        // Attempt failed — loop again if still reconnecting.
        _sub?.cancel();
        try {
          await _channel?.sink.close().timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }
  }

  /// Separate _onDone handler used during reconnect-phase channels.
  /// If a reconnect-attempt channel disconnects, the loop handles it.
  void _onDoneReconnect() {
    if (_state == ConnectionState.closed) return;
    if (_state == ConnectionState.reconnecting) {
      // Welcome completer fails → loop picks it up.
      if (_welcomeCompleter != null && !_welcomeCompleter!.isCompleted) {
        _welcomeCompleter!.completeError(
          const UnavailableException('Channel closed during reconnect'),
        );
        _welcomeCompleter = null;
      }
      return;
    }
    // Already reconnected but new channel closed — treat as fresh disconnect.
    _onDone();
  }

  int _jitterSeed = 0;

  void _failAllPending(String reason) {
    final ex = UnavailableException(reason);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(ex);
    }
    _pending.clear();
  }

  /// Closes all listener stream controllers cleanly (no error).
  /// Called only from [close] — on disconnect, listeners go quiet per PROTOCOL.
  void _completeAllListeners() {
    for (final ctrl in _listeners.values) {
      if (!ctrl.isClosed) ctrl.close();
    }
    _listeners.clear();
  }

  // ---------------------------------------------------------------------------
  // Ping
  // ---------------------------------------------------------------------------

  void _startPing() {
    _pingTimer = Timer.periodic(config.pingInterval, (_) {
      if (_state != ConnectionState.ready) return;
      if (_requestsInFlight > 0) return; // skip ping while request in flight
      final id = _nextId();
      _enqueueSend(pingFrame(id));
      // We don't await the ping response — it's fire-and-forget for keepalive.
      // (The response will complete the pending completer normally.)
      final completer = Completer<Map<String, Object?>>();
      _pending[id] = completer;
      // Ignore the result.
      completer.future.ignore();
    });
  }
}
