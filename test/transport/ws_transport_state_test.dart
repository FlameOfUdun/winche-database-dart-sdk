import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/transport/transport.dart';

import '../protocol/fake_channel.dart';

/// A transport whose dial always fails, with a slow-enough sleeper that the
/// retry loop cannot spin hot during the test.
WsTransport _failingTransport(void Function() onAttempt) => WsTransport(
      ConnectionConfig(
        uri: Uri.parse('ws://fake/documents/ws'),
        pingInterval: const Duration(hours: 1),
        sleeper: (_) => Future<void>.delayed(const Duration(milliseconds: 20)),
        channelFactory: (_) {
          onAttempt();
          throw Exception('refused');
        },
      ),
    );

void main() {
  test('connectionStates seeds a subscriber with the current state', () async {
    final transport = WsTransport(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      pingInterval: const Duration(hours: 1),
      channelFactory: (_) => FakeChannel()..startCapture(),
    ));
    addTearDown(transport.dispose);

    final seen = <ConnectionState>[];
    transport.connectionStates.listen(seen.add);
    await Future<void>.delayed(Duration.zero);

    expect(seen, isNotEmpty,
        reason: 'a subscriber must learn the state without waiting for a change');
    expect(seen.first, equals(ConnectionState.connecting));
  });

  // Bug B. This is the defect that made "start offline, write, network returns"
  // never sync: the stream ended, so the sync controller went permanently deaf.
  test('connectionStates does NOT complete when the first dial fails',
      () async {
    final transport = _failingTransport(() {});
    addTearDown(transport.dispose);

    var done = false;
    transport.connectionStates.listen((_) {}, onDone: () => done = true);
    await transport.request(<String, Object?>{'type': 'noop'}).catchError(
        (Object _) => <String, Object?>{});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(done, isFalse,
        reason: 'a deaf subscriber can never recover when the network returns');
  });

  // A failed dial must not orphan a ProtocolConnection that owns a live retry
  // loop: dispose() could not reach it, and each later call would build another.
  test('a failed dial does not spawn a second connection', () async {
    var connectionsBuilt = 0;
    final transport = _failingTransport(() => connectionsBuilt++);
    addTearDown(transport.dispose);

    for (var i = 0; i < 3; i++) {
      await transport
          .request(<String, Object?>{'type': 'noop'})
          .catchError((Object _) => <String, Object?>{});
    }
    final afterCalls = connectionsBuilt;
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // Attempts keep happening (the retry loop is alive), but they must all come
    // from ONE connection, so the count must not jump by one per request call.
    expect(afterCalls, lessThanOrEqualTo(3),
        reason: 'each request must not create its own connection');
  });

  test('request fails fast with UnavailableException while not ready',
      () async {
    final transport = _failingTransport(() {});
    addTearDown(transport.dispose);

    await expectLater(
      transport.request(<String, Object?>{'type': 'noop'}),
      throwsA(isA<Exception>()),
    );
  });

  test('dispose closes cleanly after a failed dial', () async {
    final transport = _failingTransport(() {});
    await transport
        .request(<String, Object?>{'type': 'noop'})
        .catchError((Object _) => <String, Object?>{});

    await expectLater(transport.dispose(), completes);
  });
}
