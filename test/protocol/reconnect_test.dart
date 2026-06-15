import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';

import 'fake_channel.dart';

// ---------------------------------------------------------------------------
// Harness — channel factory minting a new FakeChannel per dial, plus a
// recording sleeper so backoff delays are observable and instant.
// ---------------------------------------------------------------------------

class _Harness {
  /// Every channel dialed, in order. `channels[0]` is the initial connection;
  /// each reconnect attempt appends one more.
  final List<FakeChannel> channels = [];

  /// URIs passed to the channel factory, in dial order.
  final List<Uri> dialedUris = [];

  /// Backoff durations passed to the sleeper, in order.
  final List<Duration> sleeps = [];

  /// When non-null, the sleeper parks on this gate instead of returning
  /// immediately — lets a test freeze the loop mid-backoff.
  Completer<void>? sleepGate;

  FakeChannel dial(Uri uri) {
    dialedUris.add(uri);
    final c = FakeChannel()..startCapture();
    channels.add(c);
    return c;
  }

  Future<void> sleeper(Duration d) {
    sleeps.add(d);
    return sleepGate?.future ?? Future<void>.value();
  }
}

/// Pumps the event loop a few turns so chained futures/microtasks settle.
Future<void> _pump([int times = 4]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> _welcome(String connectionId) =>
    {'type': 'welcome', 'connectionId': connectionId};

Future<(ProtocolConnection, _Harness)> _connect({
  Duration maxBackoff = const Duration(seconds: 30),
  String Function()? tokenProvider,
}) async {
  final h = _Harness();
  final conn = ProtocolConnection(ConnectionConfig(
    uri: Uri.parse('ws://fake/documents/ws'),
    channelFactory: h.dial,
    sleeper: h.sleeper,
    pingInterval: const Duration(hours: 1), // disable auto-ping in tests
    maxBackoff: maxBackoff,
    tokenProvider: tokenProvider,
  ));

  final connectFuture = conn.connect();
  await _pump();
  h.channels[0].serverSend(_welcome('c0'));
  await connectFuture;
  return (conn, h);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test(
      'disconnect → reconnect: new channel dialed, no hello sent, welcome → ready',
      () async {
    final (conn, h) = await _connect();
    var reconnectCount = 0;
    conn.reconnects.listen((_) => reconnectCount++);

    await h.channels[0].serverClose();
    await _pump();

    // First attempt is immediate (no backoff) on a freshly dialed channel.
    expect(conn.currentState, equals(ConnectionState.reconnecting));
    expect(h.channels.length, equals(2));
    expect(h.sleeps, isEmpty);
    // No hello frame should be sent on reconnect — auth is via query parameter.
    expect(
      h.channels[1].clientFrames.any((f) => f['type'] == 'hello'),
      isFalse,
      reason: 'No hello frame should be sent on reconnect',
    );

    h.channels[1].serverSend(_welcome('c1'));
    await _pump();

    expect(conn.currentState, equals(ConnectionState.ready));
    expect(reconnectCount, equals(1));

    // Requests flow over the new channel.
    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    await _pump();
    final req = h.channels[1].clientFrames.last;
    expect(req['type'], equals('doc.get'));
    h.channels[1].serverSend({
      'type': 'response',
      'id': req['id'],
      'result': <String, Object?>{'document': null},
    });
    expect(await result, equals({'document': null}));

    await conn.close();
  });

  test('state sequence on disconnect: disconnected → reconnecting → ready',
      () async {
    final (conn, h) = await _connect();
    final states = <ConnectionState>[];
    conn.states.listen(states.add);

    await h.channels[0].serverClose();
    await _pump();
    h.channels[1].serverSend(_welcome('c1'));
    await _pump();

    expect(
      states,
      equals([
        ConnectionState.disconnected,
        ConnectionState.reconnecting,
        ConnectionState.ready,
      ]),
    );
    await conn.close();
  });

  test('failed attempts back off exponentially and respect maxBackoff',
      () async {
    final (conn, h) =
        await _connect(maxBackoff: const Duration(milliseconds: 600));

    await h.channels[0].serverClose();
    await _pump();

    // Attempt 1 (immediate): fail it by closing the new channel pre-welcome.
    expect(h.channels.length, equals(2));
    await h.channels[1].serverClose();
    await _pump();

    // Attempt 2 after ~250ms backoff: fail it too.
    expect(h.channels.length, equals(3));
    await h.channels[2].serverClose();
    await _pump();

    // Attempt 3 after ~500ms: fail it too.
    expect(h.channels.length, equals(4));
    await h.channels[3].serverClose();
    await _pump();

    // Attempt 4 after raw 1000ms → capped to 600ms: let it succeed.
    expect(h.channels.length, equals(5));
    h.channels[4].serverSend(_welcome('c4'));
    await _pump();
    expect(conn.currentState, equals(ConnectionState.ready));

    // Backoffs: base 250ms doubling, +0–25% jitter, capped at maxBackoff.
    expect(h.sleeps.length, equals(3));
    void expectBackoff(Duration d, int cappedMs) {
      expect(d.inMilliseconds, greaterThanOrEqualTo(cappedMs));
      expect(d.inMilliseconds, lessThanOrEqualTo((cappedMs * 1.25).ceil()));
    }

    expectBackoff(h.sleeps[0], 250);
    expectBackoff(h.sleeps[1], 500);
    expectBackoff(h.sleeps[2], 600); // raw 1000ms capped by maxBackoff

    await conn.close();
  });

  test('request() while reconnecting throws UnavailableException', () async {
    final (conn, h) = await _connect();

    await h.channels[0].serverClose();
    await _pump();
    expect(conn.currentState, equals(ConnectionState.reconnecting));

    await expectLater(
      conn.request({'type': 'doc.get', 'path': 'a/b'}),
      throwsA(isA<UnavailableException>()),
    );

    // Complete the reconnect so the handshake timeout timer is cancelled.
    h.channels[1].serverSend(_welcome('c1'));
    await _pump();
    expect(conn.currentState, equals(ConnectionState.ready));
    await conn.close();
  });

  test('pending request fails when disconnect starts a reconnect', () async {
    final (conn, h) = await _connect();

    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    final resultExpect =
        expectLater(result, throwsA(isA<UnavailableException>()));
    await _pump();

    await h.channels[0].serverClose();
    await resultExpect;

    // Finish the reconnect to clean up.
    await _pump();
    h.channels[1].serverSend(_welcome('c1'));
    await _pump();
    await conn.close();
  });

  test('close() during backoff aborts the reconnect loop', () async {
    final (conn, h) = await _connect();

    await h.channels[0].serverClose();
    await _pump();

    // Fail the immediate attempt; gate the backoff sleep so the loop parks.
    h.sleepGate = Completer<void>();
    await h.channels[1].serverClose();
    await _pump();
    expect(h.sleeps.length, equals(1)); // loop is waiting in backoff

    await conn.close();
    expect(conn.currentState, equals(ConnectionState.closed));

    // Release the gate — the loop must exit without dialing again.
    h.sleepGate!.complete();
    await _pump();
    expect(h.channels.length, equals(2));
  });

  test('listener stream survives reconnect and receives frames on new channel',
      () async {
    final (conn, h) = await _connect();

    final events = <ServerFrame>[];
    Object? receivedError;
    var streamDone = false;
    conn.listenEvents('sub-1').listen(
          events.add,
          onError: (Object e) => receivedError = e,
          onDone: () => streamDone = true,
        );

    await h.channels[0].serverClose();
    await _pump();
    h.channels[1].serverSend(_welcome('c1'));
    await _pump();

    h.channels[1].serverSend({
      'type': 'listen.snapshot',
      'subscriptionId': 'sub-1',
      'documents': <Object?>[],
      'readTime': '2026-06-08T12:00:00+00:00',
      'resumeToken': 1,
    });
    await _pump();

    expect(events.length, equals(1));
    expect(events.single, isA<ListenSnapshotFrame>());
    expect(receivedError, isNull);
    expect(streamDone, isFalse);

    await conn.close();
  });

  test('disconnect after a successful reconnect triggers another reconnect',
      () async {
    final (conn, h) = await _connect();
    var reconnectCount = 0;
    conn.reconnects.listen((_) => reconnectCount++);

    // First disconnect → reconnect via channels[1].
    await h.channels[0].serverClose();
    await _pump();
    h.channels[1].serverSend(_welcome('c1'));
    await _pump();
    expect(conn.currentState, equals(ConnectionState.ready));

    // The replacement channel dies → fresh reconnect via channels[2].
    await h.channels[1].serverClose();
    await _pump();
    expect(conn.currentState, equals(ConnectionState.reconnecting));
    expect(h.channels.length, equals(3));
    h.channels[2].serverSend(_welcome('c2'));
    await _pump();

    expect(conn.currentState, equals(ConnectionState.ready));
    expect(reconnectCount, equals(2));
    await conn.close();
  });

  test('reconnect dials with a freshly fetched token in the URI', () async {
    var tokenN = 0;
    final (conn, h) = await _connect(tokenProvider: () => 'tok-${++tokenN}');

    // Initial dial must have used tok-1.
    expect(
      h.dialedUris[0].queryParameters['access_token'],
      equals('tok-1'),
    );

    await h.channels[0].serverClose();
    await _pump();

    // Reconnect dial must read a fresh token (tok-2).
    expect(h.dialedUris.length, equals(2));
    expect(
      h.dialedUris[1].queryParameters['access_token'],
      equals('tok-2'),
    );

    h.channels[1].serverSend(_welcome('c1'));
    await _pump();
    await conn.close();
  });
}
