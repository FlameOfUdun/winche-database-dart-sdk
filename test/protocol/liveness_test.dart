import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';

import 'fake_channel.dart';

/// A socket that stops answering must not leave requests waiting forever: requests time out, a silent
/// socket is replaced, and verify() replaces one that doesn't answer a ping.
void main() {
  Future<(ProtocolConnection, List<FakeChannel>)> connect({
    Duration ping = const Duration(hours: 1),
    Duration requestTimeout = const Duration(seconds: 60),
    Duration? liveness,
  }) async {
    final channels = <FakeChannel>[];
    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/v1/ws'),
      channelFactory: (_) {
        final fake = FakeChannel()..startCapture();
        channels.add(fake);
        // Every (re)dial is welcomed.
        Future<void>.delayed(Duration.zero, () => fake.serverSend({'type': 'welcome', 'connectionId': 'c${channels.length}'}));
        return fake;
      },
      pingInterval: ping,
      requestTimeout: requestTimeout,
      livenessTimeout: liveness,
      sleeper: (_) => Future<void>.value(),
    ));
    await conn.connect();
    return (conn, channels);
  }

  test('a request with no response fails as unavailable after the timeout', () async {
    final (conn, _) = await connect(requestTimeout: const Duration(milliseconds: 100));

    await expectLater(conn.request({'type': 'doc.get', 'path': 'a/b'}), throwsA(isA<UnavailableException>()));
    await conn.close();
  });

  test('a socket that receives nothing is dropped and redialled', () async {
    final (conn, channels) = await connect(
      ping: const Duration(milliseconds: 50),
      liveness: const Duration(milliseconds: 150),
    );
    expect(channels, hasLength(1));

    // The fake server never answers pings: after the liveness timeout the client gives up on it.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(channels.length, greaterThan(1), reason: 'the silent socket should have been replaced');
    expect(conn.currentState, ConnectionState.ready);
    await conn.close();
  });

  test('a socket that keeps talking is kept', () async {
    final (conn, channels) = await connect(
      ping: const Duration(milliseconds: 50),
      liveness: const Duration(milliseconds: 150),
    );
    // Answer every ping.
    channels.single.onClientFrame = (f) {
      if (f['type'] == 'ping') channels.single.serverSend({'type': 'response', 'id': f['id'], 'result': <String, Object?>{}});
    };

    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(channels, hasLength(1));
    await conn.close();
  });

  test('verify() keeps an answering socket and replaces a silent one', () async {
    final (conn, channels) = await connect();
    channels.single.onClientFrame = (f) {
      if (f['type'] == 'ping') channels.single.serverSend({'type': 'response', 'id': f['id'], 'result': <String, Object?>{}});
    };
    expect(await conn.verify(timeout: const Duration(milliseconds: 200)), isTrue);
    expect(channels, hasLength(1));

    channels.single.onClientFrame = null; // the socket goes silent
    expect(await conn.verify(timeout: const Duration(milliseconds: 100)), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(channels.length, greaterThan(1));
    expect(conn.currentState, ConnectionState.ready);
    await conn.close();
  });
}
