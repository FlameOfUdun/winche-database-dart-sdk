import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ---------------------------------------------------------------------------
// FakeWebSocketSink — delegates to an underlying StreamSink
// ---------------------------------------------------------------------------

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._inner);
  final StreamSink<Object?> _inner;

  @override
  void add(Object? data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<Object?> stream) => _inner.addStream(stream);

  @override
  Future<dynamic> get done => _inner.done;

  @override
  Future<dynamic> close([int? closeCode, String? closeReason]) =>
      _inner.close();
}

// ---------------------------------------------------------------------------
// FakeChannel — in-memory WebSocketChannel using StreamChannelController
// ---------------------------------------------------------------------------

/// An in-memory [WebSocketChannel] for unit tests.
///
/// The "server" side is [local] (a [StreamChannel]); use [serverSend] to
/// inject server frames and [serverClose] to close the connection.
/// The "client" side is what `ProtocolConnection` sees.
class FakeChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  FakeChannel() {
    // sync: true makes events dispatch immediately without event-loop delay.
    _ctrl = StreamChannelController<Object?>(sync: true);
    sink = _FakeWebSocketSink(_ctrl.foreign.sink);
  }

  late final StreamChannelController<Object?> _ctrl;

  // Frames sent by the client side (captured from the local stream).
  final List<Map<String, Object?>> clientFrames = [];
  StreamSubscription<Object?>? _captureSub;

  /// Optional hook invoked for each decoded client frame as it is captured.
  ///
  /// Lets a harness auto-respond (e.g. reply to `hello` with `welcome`, or
  /// answer requests by id). Invoked synchronously when the channel is created
  /// with `sync: true`.
  void Function(Map<String, Object?> frame)? onClientFrame;

  /// Starts capturing client frames for assertions.
  void startCapture() {
    _captureSub = _ctrl.local.stream.listen((data) {
      if (data is String) {
        final frame = (json.decode(data) as Map).cast<String, Object?>();
        clientFrames.add(frame);
        onClientFrame?.call(frame);
      }
    });
  }

  Future<void> stopCapture() async => _captureSub?.cancel();

  /// Sends a frame FROM the server TO the connection (the channel's stream side).
  void serverSend(Map<String, Object?> frame) {
    _ctrl.local.sink.add(json.encode(frame));
  }

  int? _closeCode;

  /// Closes the server side so the connection's stream closes. [code] becomes
  /// the channel's [closeCode].
  Future<void> serverClose([int? code]) async {
    _closeCode = code;
    await _ctrl.local.sink.close();
  }

  // ---- WebSocketChannel / StreamChannel interface ----

  @override
  Stream<Object?> get stream => _ctrl.foreign.stream;

  @override
  late final WebSocketSink sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future<void>.value();
}
