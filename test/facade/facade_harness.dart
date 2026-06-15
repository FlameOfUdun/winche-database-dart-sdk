import 'dart:async';

import 'package:winche_database/winche_database.dart';

import '../protocol/fake_channel.dart';

/// Pumps the event loop a few turns so chained futures/microtasks settle.
///
/// The [FakeChannel] dispatches synchronously (`sync: true`), but the facade
/// layers (`WsTransport` async*, `Future.whenComplete`, broadcast streams) add
/// a handful of microtask hops, so several turns are needed.
Future<void> pump([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Full-stack facade test harness.
///
/// Wires a real [WincheDatabase] → [Transport] → [ProtocolConnection] on top of
/// an in-memory [FakeChannel]. The connection dials lazily on the first
/// operation; the harness auto-answers the `hello` handshake with a `welcome`,
/// then routes each subsequent client request frame to [handler] (or, if unset,
/// replies with [defaultResult]).
class FacadeHarness {
  FacadeHarness({bool autoReconnect = false, LocalStore? store})
      : channel = FakeChannel()..startCapture() {
    db = WincheDatabase.withStore(
      ConnectionConfig(
        uri: Uri.parse('ws://fake/documents/ws'),
        channelFactory: (_) {
          // The backend sends `welcome` immediately on upgrade — there is no
          // `hello` and no in-band auth. Emit it on every (re)dial. Deferred to
          // a microtask so it lands after connect() has subscribed and armed
          // its welcome completer.
          scheduleMicrotask(() => channel
              .serverSend({'type': 'welcome', 'connectionId': 'test-conn'}));
          return channel;
        },
        pingInterval: const Duration(hours: 1), // disable keepalive pings
        autoReconnect: autoReconnect,
      ),
      store ?? MemoryLocalStore(), // null → default in-memory store (offline is always on)
    );
    channel.onClientFrame = _route;
  }

  final FakeChannel channel;
  late final WincheDatabase db;

  /// Per-request handler. Receives each client request frame (never `hello`);
  /// it must reply via [respond]/[respondError], stream listener frames, or
  /// deliberately stay silent. When null, requests are answered with
  /// [defaultResult].
  void Function(Map<String, Object?> frame)? handler;

  /// Default response result used when [handler] is null.
  Map<String, Object?> defaultResult = const <String, Object?>{};

  void _route(Map<String, Object?> frame) {
    // Defer to a microtask so responses arrive asynchronously, the way a real
    // socket behaves. The channel dispatches synchronously (`sync: true`); if we
    // replied inline, the `welcome` would land mid-`connect()` (before it awaits
    // its welcome completer) and break the handshake.
    scheduleMicrotask(() {
      final h = handler;
      if (h != null) {
        h(frame);
      } else {
        respond(frame, defaultResult);
      }
    });
  }

  /// Sends a `response` frame correlated to [frame]'s id.
  void respond(Map<String, Object?> frame, Map<String, Object?> result) {
    channel
        .serverSend({'type': 'response', 'id': frame['id'], 'result': result});
  }

  /// Sends an `error` frame correlated to [frame]'s id.
  void respondError(
    Map<String, Object?> frame,
    String status,
    String message, [
    Map<String, Object?>? details,
  ]) {
    channel.serverSend({
      'type': 'error',
      'id': frame['id'],
      'status': status,
      'message': message,
      if (details != null) 'details': details,
    });
  }

  /// Pushes a server-initiated frame (e.g. `listen.snapshot`, `listen.delta`).
  void push(Map<String, Object?> frame) => channel.serverSend(frame);

  /// All client request frames captured so far, excluding the `hello`.
  List<Map<String, Object?>> get requests =>
      channel.clientFrames.where((f) => f['type'] != 'hello').toList();

  /// The most recent client request frame (excluding `hello`).
  Map<String, Object?> get lastRequest => requests.last;

  Future<void> close() async {
    db.close();
    await pump();
  }
}

/// Encodes a native field map into wire (tagged-value) form.
Map<String, Object?> wireFields(Map<String, Object?> native) => {
      for (final e in native.entries) e.key: toValue(e.value).toJson(),
    };

/// Builds a wire `document` map (the shape inside a `doc.get`/query response).
Map<String, Object?> wireDoc(
  String path,
  Map<String, Object?> fields, {
  String collection = 'users',
  String createTime = '2026-06-08T10:00:00+00:00',
  String updateTime = '2026-06-08T10:00:00+00:00',
  int version = 1,
}) {
  final slash = path.lastIndexOf('/');
  final id = slash < 0 ? path : path.substring(slash + 1);
  final col = slash < 0 ? collection : path.substring(0, slash);
  return {
    'path': path,
    'id': id,
    'collection': col,
    'fields': fields,
    'createTime': createTime,
    'updateTime': updateTime,
    'version': version,
  };
}

/// A standard `writeResults` payload with a single result.
Map<String, Object?> writeResultsPayload({
  String updateTime = '2026-06-08T10:00:00+00:00',
  int count = 1,
}) =>
    {
      'writeResults': [
        for (var i = 0; i < count; i++) {'updateTime': updateTime},
      ],
    };
