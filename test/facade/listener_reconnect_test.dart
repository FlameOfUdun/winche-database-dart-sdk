import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import '../protocol/fake_channel.dart';
import 'facade_harness.dart' show pump, wireDoc, wireFields;

/// A facade harness that mints a fresh [FakeChannel] on every dial, so the
/// auto-reconnect loop reconnects onto a new socket (the single-channel
/// [FacadeHarness] reuses one closed channel and cannot reconnect).
///
/// Each dialed channel sends its own `welcome` on dial (as the backend does on
/// upgrade); all other frames are routed to [handler] together with the channel
/// they arrived on.
class ReconnectHarness {
  ReconnectHarness() {
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

  /// Routes a non-`hello` client frame: `(channel, frame)`.
  void Function(FakeChannel channel, Map<String, Object?> frame)? handler;

  FakeChannel _dial() {
    final channel = FakeChannel()..startCapture();
    channels.add(channel);
    // The backend sends `welcome` immediately on upgrade — there is no `hello`.
    // Fire it once per dialed channel.
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

  /// Client request frames captured on [channel], excluding `hello`.
  List<Map<String, Object?>> requestsOn(FakeChannel channel) =>
      channel.clientFrames.where((f) => f['type'] != 'hello').toList();

  Future<void> close() async {
    db.close();
    await pump();
  }
}

Map<String, Object?> snapshotFrame(
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
  test('listener re-subscribes with the last resume token after reconnect',
      () async {
    final h = ReconnectHarness();

    // Each channel's listen frame gets its own subscription id, derived from the
    // channel index so we can route pushed frames to the right subscription.
    String subIdFor(FakeChannel c) => 'sub-${h.channels.indexOf(c)}';
    final listenFrames = <FakeChannel, Map<String, Object?>>{};

    h.handler = (c, f) {
      switch (f['type']) {
        case 'listen':
          listenFrames[c] = f;
          h.respond(c, f, {'subscriptionId': subIdFor(c)});
        case 'unlisten':
          h.respond(c, f, const {});
        default:
          h.respond(c, f, const {});
      }
    };

    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('users').snapshots().listen(events.add);
    await pump();

    // Initial subscription on channel 0, no resume token.
    expect(h.channels, hasLength(1));
    expect(listenFrames[h.channels[0]]!.containsKey('resumeToken'), isFalse);

    // First snapshot establishes resume token 42.
    h.channels[0].serverSend(snapshotFrame(
      'sub-0',
      [
        wireDoc('users/u1', wireFields({'n': 1}))
      ],
      resumeToken: 42,
    ));
    await pump();
    // Cache-first (empty) emit + the server snapshot.
    expect(events.last.docs.map((d) => d.id), ['u1']);

    // The socket drops → the connection auto-reconnects onto a fresh channel.
    await h.channels[0].serverClose();
    await pump(12);

    // A new channel was dialed and the listener re-subscribed on it, carrying
    // the last resume token.
    expect(h.channels.length, greaterThanOrEqualTo(2));
    final ch1 = h.channels[1];
    expect(listenFrames[ch1], isNotNull,
        reason: 'listener should re-subscribe on the new channel');
    expect(listenFrames[ch1]!['resumeToken'], 42);

    // Resumed stream keeps delivering on the new subscription.
    ch1.serverSend(snapshotFrame(
      'sub-1',
      [
        wireDoc('users/u1', wireFields({'n': 1})),
        wireDoc('users/u2', wireFields({'n': 2})),
      ],
      resumeToken: 43,
      readTime: '2026-06-08T12:05:00+00:00',
    ));
    await pump();

    expect(events.length, greaterThanOrEqualTo(2));
    expect(events.last.docs.map((d) => d.id), ['u1', 'u2']);

    await sub.cancel();
    await h.close();
  });

  test(
      'reconnect emits on the reconnects stream and resubscribe is local '
      '(no unlisten to the dead socket)', () async {
    final h = ReconnectHarness();
    String subIdFor(FakeChannel c) => 'sub-${h.channels.indexOf(c)}';

    h.handler = (c, f) {
      switch (f['type']) {
        case 'listen':
          h.respond(c, f, {'subscriptionId': subIdFor(c)});
        case 'unlisten':
          h.respond(c, f, const {});
        default:
          h.respond(c, f, const {});
      }
    };

    final sub = h.db.collection('users').snapshots().listen((_) {});
    await pump();
    h.channels[0].serverSend(snapshotFrame('sub-0', const [], resumeToken: 1));
    await pump();

    await h.channels[0].serverClose();
    await pump(12);

    // The dead channel 0 must NOT have received an unlisten (the subscription is
    // released locally because the connection is gone).
    final unlistensOnCh0 =
        h.requestsOn(h.channels[0]).where((f) => f['type'] == 'unlisten');
    expect(unlistensOnCh0, isEmpty);

    // The new channel carries the re-subscribe.
    expect(
        h.requestsOn(h.channels[1]).any((f) => f['type'] == 'listen'), isTrue);

    await sub.cancel();
    await h.close();
  });
}
