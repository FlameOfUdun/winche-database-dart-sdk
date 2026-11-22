import 'dart:async';
import 'package:winche_core/winche_core.dart';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'exceptions.dart';
import 'messages.dart';
import 'web_socket_dial.dart';

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
    this.requestTimeout = const Duration(seconds: 60),
    this.livenessTimeout,
    this.maxBackoff = const Duration(seconds: 30),
    this.maxFrameBytes = 1 << 20,
    this.channelFactory,
    this.dialer,
    this.sleeper,
    this.dialUri,
    this.dialHeaders,
    this.onDialFailed,
  });

  /// Called when a dial fails before the server's welcome (the upgrade
  /// refused, the server unreachable, the handshake timed out), with how many
  /// have failed in a row; a dial that gets its welcome starts the count over.
  /// Not called for a dial that never started (no auth token to send). The
  /// app's Integrity token is dropped from here after repeated failures, since
  /// a server that refuses it refuses the upgrade (the reconnect backoff still
  /// applies).
  final void Function(int failuresInARow)? onDialFailed;

  /// Rewrites the address on every (re)dial, after the auth token is added:
  /// in a browser, the app's Integrity token (`WincheIntegrity.withToken`),
  /// fresh each time.
  final Future<Uri> Function(Uri)? dialUri;

  /// Headers sent on every (re)dial where the platform can (not in a browser):
  /// the app's Integrity token (`WincheIntegrity.webSocketHeaders`), fresh each
  /// time.
  final Future<Map<String, String>> Function()? dialHeaders;

  /// The WebSocket URI, e.g. `ws://host/documents/ws`.
  final Uri uri;

  /// Supplies the auth token used as the `?access_token=` query parameter on
  /// every (re)dial. To rotate an expired token, return the new value here — the
  /// reconnect path re-reads it automatically.
  final FutureOr<String> Function()? tokenProvider;

  /// Interval for keep-alive pings. Defaults to 30 seconds.
  final Duration pingInterval;

  /// How long a request waits for its response before failing with
  /// a [WincheDatabaseException] with code `unavailable` (so a read falls back to the cache instead of
  /// hanging). [Duration.zero] disables it. Defaults to 60 seconds.
  final Duration requestTimeout;

  /// A ready socket that has received nothing for this long is treated as dead
  /// (e.g. after a Wi-Fi → cellular switch the OS may not notice for minutes):
  /// it is dropped and the usual reconnect loop runs. Pings keep a healthy socket
  /// talking. Defaults to two ping intervals plus 15 seconds.
  final Duration? livenessTimeout;

  Duration get effectiveLivenessTimeout => livenessTimeout ?? pingInterval * 2 + const Duration(seconds: 15);

  /// Maximum backoff between reconnect attempts.
  final Duration maxBackoff;

  /// Maximum size in bytes of a single outbound write frame. A batch whose
  /// serialized frame would exceed this is rejected at commit time (before it
  /// is queued), avoiding a server `4413` close. Default 1 MiB — match the
  /// server's `WsOptions.MaxFrameBytes` if it is configured differently.
  final int maxFrameBytes;

  /// For testing: allows injecting a custom WebSocketChannel factory.
  final FutureOr<WebSocketChannel> Function(Uri)? channelFactory;

  /// For testing: like [channelFactory], also given the dial's headers.
  final FutureOr<WebSocketChannel> Function(Uri, Map<String, String>)? dialer;

  /// For testing: allows injecting a custom sleeper for backoff delays.
  final FutureOr<void> Function(Duration)? sleeper;
}

/// WebSocket protocol connection to a Winche Database server (PROTOCOL §7).
class ProtocolConnection {
  /// The server's expand limit, from its `welcome` (null until one arrives, or from a server that doesn't send it).
  int? expandLimit;

  ProtocolConnection(this.config)
      : _channelFactory = config.dialer ??
            (config.channelFactory == null ? _defaultFactory : (uri, _) => config.channelFactory!(uri)),
        _sleeper = config.sleeper ?? _defaultSleeper;

  final ConnectionConfig config;
  final FutureOr<WebSocketChannel> Function(Uri, Map<String, String>) _channelFactory;
  final FutureOr<void> Function(Duration) _sleeper;

  static Future<WebSocketChannel> _defaultFactory(Uri uri, Map<String, String> headers) async {
    final channel = connectWebSocket(uri, headers);
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


  ConnectionState _state = ConnectionState.connecting;
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();

  Stream<ConnectionState> get states => _stateController.stream;
  ConnectionState get currentState => _state;

  void _setState(ConnectionState s) {
    // `closed` is terminal. A retry loop scheduled just before close() must not
    // be able to reopen a connection whose socket and controllers are gone.
    if (_state == ConnectionState.closed && s != ConnectionState.closed) return;
    // Connected, by whichever path (the loop, reconnect(), connect()): any loop
    // still running is stale, and the next drop must be free to start a new one.
    if (s == ConnectionState.ready) _reconnecting = null;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }


  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _sub;

  /// Correlation map: request id → Completer.
  final Map<String, Completer<Map<String, Object?>>> _pending = {};

  /// Per-subscription listener streams.
  final Map<String, StreamController<ServerFrame>> _listeners = {};

  /// Listener frames that arrived before their subscription was registered.
  ///
  /// A client learns its `subscriptionId` from the subscribe *response*, so it
  /// can only call [listenEvents] after that response lands — but the server is
  /// free to push the first `listen.snapshot` before it. Without this buffer
  /// that snapshot has nowhere to go and is dropped, and the listener then waits
  /// forever for a delta (PROTOCOL §7.6 guarantees the snapshot, not its
  /// ordering against the response).
  ///
  /// Insertion-ordered, so trimming evicts the oldest subscription first.
  final Map<String, List<ServerFrame>> _earlyFrames = {};

  /// Cap on total buffered frames, so a server pushing frames for subscription
  /// ids the client never claims cannot grow this without bound.
  static const _maxEarlyFrames = 128;

  /// Sequential send queue — ensures frames are sent in order.
  final List<Map<String, Object?>> _sendQueue = [];
  bool _sending = false;

  /// Auto-incrementing request counter.
  int _idCounter = 0;

  String _nextId() => (_idCounter++).toString();

  /// Completer that resolves when the welcome frame is received.
  Completer<void>? _welcomeCompleter;

  Timer? _pingTimer;

  /// When the last frame arrived from the server; see [ConnectionConfig.livenessTimeout].
  DateTime _lastInbound = DateTime.now();


  /// Returns the dial URI with the current auth token (if any) added as the
  /// `access_token` query parameter (auth is at the WS upgrade — there is no
  /// in-band hello/auth message).
  FutureOr<Uri> _dialUri() async {
    final token = await config.tokenProvider?.call();
    final uri = token == null
        ? config.uri
        : config.uri.replace(queryParameters: {
            ...config.uri.queryParameters,
            'access_token': token,
          });
    return config.dialUri == null ? uri : await config.dialUri!(uri);
  }

  int _failedDials = 0;

  /// Runs one dial + handshake ([body], given the dial to make), counting the
  /// dials that fail before the welcome for [ConnectionConfig.onDialFailed].
  Future<void> _attempt(Future<void> Function(Future<WebSocketChannel> Function() dial) body) async {
    var started = false;
    try {
      await body(() async {
        final uri = await _dialUri();
        final headers = await config.dialHeaders?.call() ?? const <String, String>{};
        started = true;
        return _channelFactory(uri, headers);
      });
      _failedDials = 0;
    } catch (e) {
      // A dial another path superseded is not this connection failing.
      if (e is! _SupersededDial && started && _state != ConnectionState.closed) {
        config.onDialFailed?.call(++_failedDials);
      }
      rethrow;
    }
  }

  /// The error for a dial the server refused at the WebSocket upgrade: HTTP 401
  /// (a bad access or Integrity token) is `unauthenticated` and 403
  /// `permissionDenied`, so the app hears it instead of a retryable
  /// `unavailable`. Null for any other failure (and always in a browser, which
  /// does not say why a WebSocket failed to open).
  static WincheDatabaseException? _refusedUpgrade(Object error) => switch (refusedUpgradeStatus(error)) {
        401 => WincheDatabaseException.of(
            WincheErrorCode.unauthenticated, 'The server refused the connection (HTTP 401)'),
        403 => WincheDatabaseException.of(
            WincheErrorCode.permissionDenied, 'The server refused the connection (HTTP 403)'),
        _ => null,
      };

  /// [error] as text with the query taken off any address in it: a failed
  /// dial's message (dart:io's "Connection to '…' was not upgraded") would
  /// otherwise carry the access and Integrity tokens into logs.
  static String redacted(Object error) =>
      error.toString().replaceAllMapped(RegExp(r'''((?:wss?|https?)://[^\s'"?#]*)[?#][^\s'"]*'''), (m) => m[1]!);

  /// Dials and completes the handshake.
  ///
  /// Rethrows the failure to its caller — `request()` depends on that to surface
  /// a [WincheDatabaseException] with code `unavailable` — *and* hands recovery to the auto-reconnect loop, so
  /// a connection that starts while the network is down is not dead forever. The
  /// two are not in conflict: the caller learns this attempt failed, while the
  /// loop keeps working in the background.
  Future<void> connect({
    Duration welcomeTimeout = const Duration(seconds: 15),
  }) async {
    _setState(ConnectionState.connecting);
    try {
      await _initialDial(welcomeTimeout);
    } catch (_) {
      if (_state != ConnectionState.closed) unawaited(_reconnectLoop());
      rethrow;
    }
    _setState(ConnectionState.ready);
    _startPing();
  }

  /// The first dial + handshake. Leaves state transitions to [connect].
  Future<void> _initialDial(Duration welcomeTimeout) => _attempt((dial) async {
    try {
      _channel = await dial();
    } catch (e) {
      // Channel factory threw (e.g. WebSocketChannelException on Windows when
      // the remote port is refused before the stream is even subscribed to).
      // Normalise to `unavailable` so callers don't need to know about
      // transport-layer exception types.
      throw _refusedUpgrade(e) ??
          WincheDatabaseException.of(WincheErrorCode.unavailable, 'Failed to open WebSocket channel: ${redacted(e)}');
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
          throw WincheDatabaseException.of(WincheErrorCode.unavailable, 
            'Handshake timed out: no welcome frame received',
          );
        },
      );
    } catch (_) {
      _sub?.cancel();
      rethrow;
    }
  });

  /// Sends a client frame and waits for the server's response or error.
  ///
  /// Automatically assigns a unique `id` to the frame.
  /// The caller should not set an `id` in the frame — it will be overwritten.
  ///
  /// Throws a [WincheDatabaseException] with code `unavailable` immediately if the connection is not ready
  /// (including while reconnecting).
  Future<Map<String, Object?>> request(Map<String, Object?> frame) {
    if (_state != ConnectionState.ready) {
      return Future.error(
        WincheDatabaseException.of(WincheErrorCode.unavailable, 
          'Cannot send request: connection is $_state',
        ),
      );
    }
    final id = _nextId();
    final tagged = Map<String, Object?>.of(frame)..['id'] = id;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _enqueueSend(tagged);
    var future = completer.future;
    final timeout = config.requestTimeout;
    if (timeout > Duration.zero) {
      future = future.timeout(timeout, onTimeout: () {
        _pending.remove(id);
        throw WincheDatabaseException.of(WincheErrorCode.unavailable, 'No response within ${timeout.inSeconds}s');
      });
    }
    return future;
  }

  /// Checks that the socket still answers: sends a ping and, if no reply comes
  /// within [timeout], drops the socket so the reconnect loop takes over. Call it
  /// when the app returns to the foreground, where a silently dead socket is
  /// most likely. Returns whether the connection answered.
  Future<bool> verify({Duration timeout = const Duration(seconds: 5)}) async {
    if (_state != ConnectionState.ready) return false;
    final id = _nextId();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _enqueueSend(pingFrame(id));
    try {
      await completer.future.timeout(timeout);
      return true;
    } catch (_) {
      _pending.remove(id);
      if (_state == ConnectionState.ready) _dropDeadSocket('ping unanswered for ${timeout.inSeconds}s');
      return false;
    }
  }

  /// Takes down a socket that stopped answering and lets [_onDone] fail pending
  /// requests and start the reconnect loop, as for any drop.
  void _dropDeadSocket(String reason) {
    final channel = _channel;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    unawaited(Future(() async {
      try {
        await channel?.sink.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }));
    _onDone();
  }

  /// Returns a broadcast stream of listener frames for [subscriptionId].
  ///
  /// The stream receives [ListenSnapshotFrame] and [ListenDeltaFrame] events.
  /// On disconnect, the stream goes quiet (no error, no close).
  /// On graceful [close], the stream completes with done.
  Stream<ServerFrame> listenEvents(String subscriptionId) {
    final controller = _listeners.putIfAbsent(
      subscriptionId,
      () => StreamController<ServerFrame>.broadcast(
          onListen: () => _flushEarlyFrames(subscriptionId)),
    );
    return controller.stream;
  }

  /// Closes and removes the listener stream for [subscriptionId].
  ///
  /// Call this after sending an unlisten frame so the entry doesn't accumulate
  /// in the internal listeners map. Idempotent — no-op if not found.
  void releaseSubscription(String id) {
    _earlyFrames.remove(id);
    final ctrl = _listeners.remove(id);
    if (ctrl != null && !ctrl.isClosed) ctrl.close();
  }

  /// Routes one listener frame to its subscription, buffering it when the
  /// subscribe response has not landed yet.
  ///
  /// Checks the buffer before the controller so that a frame arriving in the gap
  /// between [_flushEarlyFrames] scheduling its drain and running it queues
  /// behind the buffered ones instead of overtaking them.
  void _routeListenerFrame(String subscriptionId, ServerFrame frame) {
    final buffered = _earlyFrames[subscriptionId];
    if (buffered != null) {
      buffered.add(frame);
      _trimEarlyFrames();
      return;
    }
    final ctrl = _listeners[subscriptionId];
    if (ctrl != null) {
      if (!ctrl.isClosed) ctrl.add(frame);
      return;
    }
    _earlyFrames[subscriptionId] = [frame];
    _trimEarlyFrames();
  }

  /// Delivers any frames buffered for [subscriptionId] to its now-listening
  /// controller. Drained in a microtask because this runs from `onListen`, i.e.
  /// while the subscription is still being wired up.
  void _flushEarlyFrames(String subscriptionId) {
    if (!_earlyFrames.containsKey(subscriptionId)) return;
    scheduleMicrotask(() {
      final pending = _earlyFrames.remove(subscriptionId);
      final ctrl = _listeners[subscriptionId];
      if (pending == null || ctrl == null || ctrl.isClosed) return;
      for (final frame in pending) {
        ctrl.add(frame);
      }
    });
  }

  void _trimEarlyFrames() {
    var total = 0;
    for (final frames in _earlyFrames.values) {
      total += frames.length;
    }
    while (total > _maxEarlyFrames && _earlyFrames.isNotEmpty) {
      total -= _earlyFrames.remove(_earlyFrames.keys.first)!.length;
    }
  }

  /// Drops the current socket and re-dials once, re-reading `tokenProvider`.
  ///
  /// This is the only way to push a rotated auth token onto a live connection:
  /// the token is a query parameter on the WebSocket upgrade, so it is fixed for
  /// the lifetime of a socket. Listener streams and the state stream are
  /// preserved, so subscriptions resume in place exactly as after a network
  /// drop, and the state returns to `ready` on success.
  ///
  /// Throws if the re-dial fails — `unauthenticated` when the server
  /// rejects the new token, a [WincheDatabaseException] with code `unavailable` when it is unreachable. In
  /// that case the connection falls back to its normal post-drop behaviour:
  /// the auto-reconnect loop.
  Future<void> reconnect() async {
    if (_state == ConnectionState.closed) {
      throw StateError('Cannot reconnect: connection is closed.');
    }
    _pingTimer?.cancel();
    // This dial takes over from any reconnect loop, whether it is backing off or
    // mid-dial: that loop stops when it wakes, leaving the socket to this path,
    // and a failure here starts a fresh one.
    _reconnecting = null;
    final staleWelcome = _welcomeCompleter;
    _welcomeCompleter = null;
    if (staleWelcome != null && !staleWelcome.isCompleted) {
      staleWelcome.completeError(
        WincheDatabaseException.of(WincheErrorCode.unavailable, 'Reconnecting to apply a new auth token'),
      );
    }
    // Take the old socket down first: `disconnected` is what tells live feeds to
    // stop treating their subscriptions as delivering.
    final old = _channel;
    _channel = null;
    await _sub?.cancel();
    _sub = null;
    _failAllPending('Reconnecting to apply a new auth token');
    try {
      await old?.sink.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Ignore errors from closing a socket we are discarding anyway.
    }
    if (_state == ConnectionState.closed) return;

    _setState(ConnectionState.reconnecting);
    try {
      await _dialOnce();
    } on _SupersededDial {
      return; // a newer reconnect() owns the socket now
    } catch (e) {
      if (_state == ConnectionState.closed) return;
      unawaited(_reconnectLoop());
      rethrow;
    }
    _setState(ConnectionState.ready);
    _startPing();
  }

  /// One dial + handshake on the reconnect path (shared by [reconnect] and
  /// [_reconnectLoop]). Leaves the state alone — callers own the transitions.
  ///
  /// The dial works on its own channel and takes over the shared socket only
  /// while it is still the newest attempt (and, for a loop's dial, while
  /// [current] holds). An attempt that was superseded — [reconnect] started
  /// while it was dialling — closes its own channel, touches nothing shared and
  /// throws [_SupersededDial], which is not counted as a failed dial.
  Future<void> _dialOnce({
    Duration welcomeTimeout = const Duration(seconds: 15),
    bool Function()? current,
  }) {
    final attempt = ++_dialAttempt;
    bool live() =>
        attempt == _dialAttempt && _state != ConnectionState.closed && (current?.call() ?? true);
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    return _attempt((dial) async {
      try {
        try {
          channel = await dial();
        } on WincheDatabaseException {
          rethrow; // a tokenProvider that itself reports an auth failure
        } catch (e) {
          throw _refusedUpgrade(e) ??
              WincheDatabaseException.of(
                  WincheErrorCode.unavailable, 'Failed to open WebSocket channel: ${redacted(e)}');
        }
        if (!live()) throw const _SupersededDial();
        final ch = channel!;
        final welcome = Completer<void>();
        _channel = ch;
        _welcomeCompleter = welcome;
        // Frames from a socket that is no longer the connection's are dropped.
        sub = _sub = ch.stream.listen(
          (Object? data) {
            if (identical(_channel, ch)) _onFrame(data);
          },
          onError: (Object e) {
            if (identical(_channel, ch)) _onError(e);
          },
          onDone: () {
            if (identical(_channel, ch)) _onDoneReconnect();
          },
        );
        try {
          await welcome.future.timeout(
            welcomeTimeout,
            onTimeout: () =>
                throw WincheDatabaseException.of(WincheErrorCode.unavailable, 'Reconnect handshake timed out'),
          );
        } finally {
          if (identical(_welcomeCompleter, welcome)) _welcomeCompleter = null;
        }
        if (!live()) throw const _SupersededDial();
      } catch (e) {
        final ch = channel;
        if (live()) {
          rethrow; // the caller cleans up its own socket, as before
        }
        // Superseded: close our own socket and leave the shared one alone.
        if (identical(_channel, ch) && ch != null) {
          _channel = null;
          _sub = null;
        }
        unawaited(sub?.cancel());
        if (ch != null) {
          unawaited(Future(() async {
            try {
              await ch.sink.close().timeout(const Duration(seconds: 1));
            } catch (_) {}
          }));
        }
        if (e is _SupersededDial) rethrow;
        throw const _SupersededDial();
      }
    });
  }

  /// Bumped by every [_dialOnce]: only the newest attempt may own the socket.
  int _dialAttempt = 0;

  /// Sends a graceful close.
  Future<void> close() async {
    _setState(ConnectionState.closed);
    if (!_closed.isCompleted) _closed.complete();
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
    await _stateController.close();
  }


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
          completer.completeError(WincheDatabaseException.of(WincheErrorCode.unavailable, 'Send failed: $e'));
        }
      }
    }
    // Continue draining synchronously — frames are queued but sent in order.
    _drainQueue();
  }


  void _onFrame(Object? data) {
    _lastInbound = DateTime.now();
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
            WincheDatabaseException.of(WincheErrorCode.internal, 'Malformed server frame for id $rawId'),
          );
        }
      }
      return;
    }

    switch (frame) {
      case WelcomeFrame(:final expandLimit):
        if (expandLimit != null) this.expandLimit = expandLimit;
        _welcomeCompleter?.complete();
        _welcomeCompleter = null;

      case ResponseFrame(:final id, :final result):
        final completer = _pending.remove(id);
        completer?.complete(result);

      case ErrorFrame(:final id):
        if (id != null) {
          final completer = _pending.remove(id);
          completer?.completeError(frame.toException());
        } else {
          // Pre-welcome error (e.g. 4401 authentication failure).
          _welcomeCompleter?.completeError(frame.toException());
          _welcomeCompleter = null;
        }

      case ListenSnapshotFrame(:final subscriptionId):
        _routeListenerFrame(subscriptionId, frame);

      case ListenDeltaFrame(:final subscriptionId):
        _routeListenerFrame(subscriptionId, frame);

      case ListenCurrentFrame(:final subscriptionId):
        _routeListenerFrame(subscriptionId, frame);

      case UnknownFrame():
        // Log-and-ignore: future server capabilities.
        break;
    }
  }

  void _onError(Object error) {
    // A refused upgrade fails the handshake with its own code (see
    // [_refusedUpgrade]) before the close that follows reports `unavailable`.
    final refused = _refusedUpgrade(error);
    final welcome = _welcomeCompleter;
    if (refused != null && welcome != null && !welcome.isCompleted) {
      _welcomeCompleter = null;
      welcome.completeError(refused);
    }
    _failAllPending('WebSocket error: ${redacted(error)}');
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
        WincheDatabaseException.of(WincheErrorCode.unavailable, 'Connection closed during handshake'),
      );
      _welcomeCompleter = null;
    }
    // Always recover: reconnection is not configurable, so a drop is always
    // followed by an attempt to come back.
    _reconnectLoop();
  }


  /// The generation of the [_reconnectLoop] that is running, if one is: a drop
  /// during the first dial starts it from [_onDone] and again from [connect],
  /// and two loops would dial twice as often.
  ///
  /// Cleared whenever the connection becomes ready, by any path, and when
  /// [reconnect] dials, so a drop right after starts a new loop. A loop that
  /// finds it is no longer the current one (after a backoff or a dial) stops:
  /// it would otherwise act on a state that belongs to another path.
  int? _reconnecting;
  int _loopGeneration = 0;

  /// Exponential backoff reconnect loop. Runs until ready or closed.
  Future<void> _reconnectLoop() async {
    if (_state == ConnectionState.closed || _reconnecting != null) return;
    final loop = _reconnecting = ++_loopGeneration;
    try {
      await _runReconnectLoop(loop);
    } finally {
      if (_reconnecting == loop) _reconnecting = null;
    }
  }

  Future<void> _runReconnectLoop(int loop) async {
    _setState(ConnectionState.reconnecting);
    var attempt = 0;
    const baseMs = 250;
    bool current() => _reconnecting == loop;

    while (current() && _state == ConnectionState.reconnecting) {
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
        // Race the backoff against close(), so teardown is not stuck waiting out
        // a delay of up to maxBackoff (30s by default).
        await Future.any<void>([
          Future<void>.value(_sleeper(delay)),
          _closed.future,
        ]);
        if (!current() || _state != ConnectionState.reconnecting) return;
      }
      attempt++;

      // Try to establish a new connection.
      try {
        await _dialOnce(current: current);
        if (!current()) return;

        // Connected! (`ready` clears the guard.)
        _setState(ConnectionState.ready);
        _startPing();
        return;
      } catch (e) {
        // Another path owns the socket now: leave it alone.
        if (e is _SupersededDial || !current()) return;
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
          WincheDatabaseException.of(WincheErrorCode.unavailable, 'Channel closed during reconnect'),
        );
        _welcomeCompleter = null;
      }
      return;
    }
    // Already reconnected but new channel closed — treat as fresh disconnect.
    _onDone();
  }

  int _jitterSeed = 0;

  /// Completed by [close] so a pending backoff wait gives up immediately
  /// instead of running to term.
  final Completer<void> _closed = Completer<void>();

  void _failAllPending(String reason) {
    final ex = WincheDatabaseException.of(WincheErrorCode.unavailable, reason);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(ex);
    }
    _pending.clear();
  }

  /// Closes all listener stream controllers cleanly (no error).
  /// Called only from [close] — on disconnect, listeners go quiet per PROTOCOL.
  void _completeAllListeners() {
    _earlyFrames.clear();
    for (final ctrl in _listeners.values) {
      if (!ctrl.isClosed) ctrl.close();
    }
    _listeners.clear();
  }


  void _startPing() {
    _pingTimer?.cancel();
    _lastInbound = DateTime.now();
    _pingTimer = Timer.periodic(config.pingInterval, (_) {
      if (_state != ConnectionState.ready) return;
      if (DateTime.now().difference(_lastInbound) > config.effectiveLivenessTimeout) {
        _dropDeadSocket('nothing received for ${config.effectiveLivenessTimeout.inSeconds}s');
        return;
      }
      // Pinged even while requests are in flight: a request waiting on a dead
      // socket is exactly when liveness matters.
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

/// Thrown by a dial that another path superseded; never reaches the app.
class _SupersededDial implements Exception {
  const _SupersededDial();
}
