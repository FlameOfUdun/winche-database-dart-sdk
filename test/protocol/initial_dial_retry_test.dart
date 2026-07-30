import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/protocol/connection.dart';

import 'fake_channel.dart';

void main() {
  // Closing while a retry's dial is IN FLIGHT AND ABOUT TO SUCCEED.
  //
  // This is the discriminating case for "closed is terminal", and it is worth
  // spelling out why the obvious version of this test is not. With a dial that
  // always fails, `_reconnectLoop` re-checks the state after its backoff and
  // returns cleanly, so nothing is exercised. The crash needs a dial that
  // *succeeds* after close(): the loop then reaches `_setState(ready)` in its
  // success branch, which has no state check of its own.
  //
  // Unguarded, that revives a closed connection — it keeps a socket nobody owns
  // and pings on it — and adds to a closed controller, throwing StateError from
  // inside a callback where nothing catches it.
  //
  // The gate Completer is what makes the race deterministic instead of hoped-for.
  test('closing during an in-flight successful dial does not revive it',
      () async {
    final gate = Completer<FakeChannel>();
    var dials = 0;

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      pingInterval: const Duration(hours: 1),
      sleeper: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      channelFactory: (_) {
        dials++;
        if (dials == 1) throw Exception('refused'); // initial dial → loop starts
        return gate.future; // the retry's dial: the test decides when it lands
      },
    ));

    await expectLater(conn.connect(), throwsA(isA<Object>()));

    // Let the loop get as far as awaiting our gated dial.
    while (dials < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // Close with that dial still outstanding.
    await conn.close();
    expect(conn.currentState, equals(ConnectionState.closed));

    // Now let it succeed. A connection that respects `closed` ignores this.
    final channel = FakeChannel()..startCapture();
    scheduleMicrotask(() =>
        channel.serverSend({'type': 'welcome', 'connectionId': 'late'}));
    gate.complete(channel);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(conn.currentState, equals(ConnectionState.closed),
        reason: 'a late successful dial must not resurrect a closed connection');
  });

  // The app started offline. Today connect() throws once and gives up, so the
  // connection never recovers even after the network returns.
  test('a failed initial dial retries and reaches ready', () async {
    var attempts = 0;
    late FakeChannel channel;

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      pingInterval: const Duration(hours: 1),
      sleeper: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      channelFactory: (_) {
        attempts++;
        if (attempts < 3) throw Exception('refused');
        channel = FakeChannel()..startCapture();
        scheduleMicrotask(() => channel
            .serverSend({'type': 'welcome', 'connectionId': 'test-conn'}));
        return channel;
      },
    ));
    addTearDown(conn.close);

    // The first dial still reports its failure to this caller.
    await expectLater(conn.connect(), throwsA(isA<Object>()));

    // ...but recovery continues in the background until it succeeds.
    final ready = Completer<void>();
    conn.states.listen((s) {
      if (s == ConnectionState.ready && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('never reached ready; attempts=$attempts'),
    );

    expect(conn.currentState, equals(ConnectionState.ready));
    expect(attempts, greaterThanOrEqualTo(3));
  });

  test('closing during backoff terminates promptly', () async {
    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      pingInterval: const Duration(hours: 1),
      // A long backoff: the test would time out if close() waited it out.
      maxBackoff: const Duration(seconds: 30),
      sleeper: (d) => Future<void>.delayed(d),
      channelFactory: (_) => throw Exception('refused'),
    ));

    await expectLater(conn.connect(), throwsA(isA<Object>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final stopwatch = Stopwatch()..start();
    await conn.close();
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)),
        reason: 'close() must not wait out the backoff delay');
  });

  test('closing while retrying does not resurrect the connection', () async {
    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      pingInterval: const Duration(hours: 1),
      sleeper: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      channelFactory: (_) => throw Exception('refused'),
    ));

    await expectLater(conn.connect(), throwsA(isA<Object>()));
    await conn.close();
    // Let any in-flight loop iteration run to completion.
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(conn.currentState, equals(ConnectionState.closed),
        reason: 'a closed connection must stay closed');
  });
}
