import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import '../protocol/fake_channel.dart';
import 'facade_harness.dart' show pump, wireDoc, wireFields;

/// A reconnect harness for doc.snapshots() tests, mirroring [ReconnectHarness]
/// from listener_reconnect_test.dart. Mints a fresh [FakeChannel] on every dial
/// so the auto-reconnect loop reconnects onto a new socket.
class DocReconnectHarness {
  DocReconnectHarness() {
    db = WincheDatabase.withStore(
      ConnectionConfig(
        uri: Uri.parse('ws://fake/documents/ws'),
        channelFactory: (_) => _dial(),
        sleeper: (d) {
          sleeps.add(d);
          return Future<void>.value();
        },
        pingInterval: const Duration(hours: 1),
        autoReconnect: true,
      ),
      MemoryLocalStore(),
    );
  }

  late final WincheDatabase db;

  /// Every channel dialed, in order. `channels[0]` is the initial connection.
  final List<FakeChannel> channels = [];

  /// Backoff durations requested by the reconnect loop.
  final List<Duration> sleeps = [];

  /// Routes a non-`welcome` server frame: `(channel, frame)`.
  void Function(FakeChannel channel, Map<String, Object?> frame)? handler;

  FakeChannel _dial() {
    final channel = FakeChannel()..startCapture();
    channels.add(channel);
    // The backend sends `welcome` immediately on upgrade — mirrors the real backend.
    scheduleMicrotask(
        () => channel.serverSend({'type': 'welcome', 'connectionId': 'test'}));
    channel.onClientFrame = (frame) {
      scheduleMicrotask(() => handler?.call(channel, frame));
    };
    return channel;
  }

  void respond(
          FakeChannel c, Map<String, Object?> frame, Map<String, Object?> r) =>
      c.serverSend({'type': 'response', 'id': frame['id'], 'result': r});

  void respondError(
    FakeChannel c,
    Map<String, Object?> frame,
    String status,
    String message,
  ) =>
      c.serverSend({
        'type': 'error',
        'id': frame['id'],
        'status': status,
        'message': message,
      });

  /// Client request frames captured on [channel], excluding `hello`.
  List<Map<String, Object?>> requestsOn(FakeChannel channel) =>
      channel.clientFrames.where((f) => f['type'] != 'hello').toList();

  Future<void> close() async {
    db.close();
    await pump();
  }
}

Map<String, Object?> docSnapshotFrame(
  String subId,
  List<Map<String, Object?>> documents, {
  required int resumeToken,
  String readTime = '2026-06-08T12:00:00+00:00',
}) =>
    {
      'type': 'listen.snapshot',
      'subscriptionId': subId,
      'documents': documents,
      'readTime': readTime,
      'resumeToken': resumeToken,
    };

void main() {
  test(
      'link-down emits a cache-backed (fromCache) snapshot after connection drops',
      () async {
    final h = DocReconnectHarness();

    String subIdFor(FakeChannel c) => 'dsub-${h.channels.indexOf(c)}';

    h.handler = (c, f) {
      switch (f['type']) {
        case 'doc.listen':
          h.respond(c, f, {'subscriptionId': subIdFor(c)});
        default:
          h.respond(c, f, const {});
      }
    };

    final events = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(events.add);
    await pump();

    // The initial emit (before server data) is already fromCache.
    // Now deliver a live server snapshot so _serverActive = true.
    h.channels[0].serverSend(docSnapshotFrame(
      'dsub-0',
      [wireDoc('users/u1', wireFields({'n': 1}))],
      resumeToken: 10,
    ));
    await pump();

    // Confirm the server snapshot arrived as a live (not cache) event.
    expect(events.last.metadata.fromCache, isFalse,
        reason: 'server snapshot should be live');
    expect(events.last.data()!['n'], 1);

    final liveEventCount = events.length;

    // Drop the socket — this triggers _goDown → _LiveDocument._onServerDocs(null)
    // → _serverActive = false → _emit() → fromCache = true.
    await h.channels[0].serverClose();
    await pump(12);

    // A new cache-backed snapshot must have been emitted after the drop.
    expect(events.length, greaterThan(liveEventCount),
        reason: 'a fromCache snapshot should be emitted when the link goes down');
    expect(events.last.metadata.fromCache, isTrue,
        reason: '_goDown path must surface a fromCache snapshot');

    await sub.cancel();
    await h.close();
  });

  test('reconnect re-subscribes carrying the last resume token', () async {
    final h = DocReconnectHarness();

    String subIdFor(FakeChannel c) => 'dsub-${h.channels.indexOf(c)}';
    final docListenFrames = <FakeChannel, Map<String, Object?>>{};

    h.handler = (c, f) {
      switch (f['type']) {
        case 'doc.listen':
          docListenFrames[c] = f;
          h.respond(c, f, {'subscriptionId': subIdFor(c)});
        case 'unlisten':
          h.respond(c, f, const {});
        default:
          h.respond(c, f, const {});
      }
    };

    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();

    // First subscription — no resume token.
    expect(h.channels, hasLength(1));
    expect(docListenFrames[h.channels[0]]!.containsKey('resumeToken'), isFalse,
        reason: 'initial doc.listen must not carry a resumeToken');

    // Deliver a server snapshot carrying resume token 77.
    h.channels[0].serverSend(docSnapshotFrame(
      'dsub-0',
      [wireDoc('users/u1', wireFields({'n': 42}))],
      resumeToken: 77,
    ));
    await pump();

    // Drop the socket → auto-reconnect dials a new channel.
    await h.channels[0].serverClose();
    await pump(12);

    // A second channel must have been dialed and the listener re-subscribed.
    expect(h.channels.length, greaterThanOrEqualTo(2));
    final ch1 = h.channels[1];
    expect(docListenFrames[ch1], isNotNull,
        reason: 'doc.listen should be re-sent on the new channel');
    expect(docListenFrames[ch1]!['resumeToken'], 77,
        reason: 'reconnect must carry the last resume token');

    // The stream keeps delivering on the new subscription.
    ch1.serverSend(docSnapshotFrame(
      'dsub-1',
      [wireDoc('users/u1', wireFields({'n': 99}))],
      resumeToken: 78,
    ));
    await pump();

    await sub.cancel();
    await h.close();
  });

  test(
      'permanent error (PERMISSION_DENIED) surfaces on the stream and stops '
      'resubscription after a subsequent reconnect', () async {
    final h = DocReconnectHarness();

    int docListenCount = 0;

    h.handler = (c, f) {
      switch (f['type']) {
        case 'doc.listen':
          docListenCount++;
          // Always return a permanent error.
          h.respondError(
              c, f, 'PERMISSION_DENIED', 'read access denied for users/u1');
        default:
          h.respond(c, f, const {});
      }
    };

    final errors = <Object>[];
    final sub = h.db.doc('users/u1').snapshots().listen(
          (_) {},
          onError: errors.add,
          cancelOnError: false,
        );
    await pump();

    // The PERMISSION_DENIED response must surface as a PermissionDeniedException.
    expect(errors, hasLength(1));
    expect(errors.first, isA<PermissionDeniedException>());

    final countAfterError = docListenCount;

    // Drop and re-establish the connection — a permanent error must NOT trigger
    // any further doc.listen frames.
    await h.channels[0].serverClose();
    await pump(12);

    expect(docListenCount, equals(countAfterError),
        reason:
            'after a permanent error, no further doc.listen should be sent '
            'even after reconnect');

    await sub.cancel();
    await h.close();
  });
}
