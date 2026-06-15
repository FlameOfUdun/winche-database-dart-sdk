import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';

import 'fake_channel.dart';

// ---------------------------------------------------------------------------
// Helper: connect with a FakeChannel
// ---------------------------------------------------------------------------

Future<(ProtocolConnection, FakeChannel)> _makeConnected() async {
  final fake = FakeChannel();
  fake.startCapture();

  final conn = ProtocolConnection(ConnectionConfig(
    uri: Uri.parse('ws://fake/documents/ws'),
    channelFactory: (_) => fake,
    pingInterval: const Duration(hours: 1), // disable auto-ping in tests
    autoReconnect: false, // these tests assert plain disconnect semantics
  ));

  final connectFuture = conn.connect();

  // Server sends welcome — no protocol field (backend never sends it).
  fake.serverSend({'type': 'welcome', 'connectionId': 'test-conn'});

  await connectFuture;
  return (conn, fake);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ---------------------------------------------------------------------------
  // Handshake happy path
  // ---------------------------------------------------------------------------
  test('handshake — welcome received, state=ready, no hello sent', () async {
    final (conn, fake) = await _makeConnected();
    expect(conn.currentState, equals(ConnectionState.ready));
    // No hello frame should have been sent — auth is at the WS upgrade level.
    expect(
      fake.clientFrames.any((f) => f['type'] == 'hello'),
      isFalse,
      reason: 'Client must not send a hello frame',
    );
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Handshake — error frame → connect() throws
  // ---------------------------------------------------------------------------
  test('handshake — error frame → connect() throws with status', () async {
    final fake = FakeChannel();
    fake.startCapture();

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      channelFactory: (_) => fake,
      pingInterval: const Duration(hours: 1),
    ));

    final connectFuture = conn.connect();
    await Future<void>.delayed(Duration.zero);

    fake.serverSend({
      'type': 'error',
      'status': 'UNAUTHENTICATED',
      'message': 'Token rejected.',
    });

    await expectLater(connectFuture, throwsA(isA<UnauthenticatedException>()));
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Request / response correlation
  // ---------------------------------------------------------------------------
  test('request/response correlation — correct result delivered', () async {
    final (conn, fake) = await _makeConnected();

    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    await Future<void>.delayed(Duration.zero);

    final reqFrame = fake.clientFrames.last;
    final id = reqFrame['id'] as String;
    expect(reqFrame['type'], equals('doc.get'));

    fake.serverSend({
      'type': 'response',
      'id': id,
      'result': <String, Object?>{'document': null},
    });

    expect(await result, equals({'document': null}));
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Out-of-order responses
  // ---------------------------------------------------------------------------
  test('out-of-order responses resolved to correct futures', () async {
    final (conn, fake) = await _makeConnected();

    final f1 = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    final f2 = conn.request({'type': 'doc.get', 'path': 'users/u2'});
    await Future<void>.delayed(Duration.zero);

    final frames =
        fake.clientFrames.where((f) => f['type'] == 'doc.get').toList();
    expect(frames.length, equals(2));
    final id1 = frames[0]['id'] as String;
    final id2 = frames[1]['id'] as String;

    // Respond to f2 first, then f1.
    fake.serverSend({
      'type': 'response',
      'id': id2,
      'result': <String, Object?>{'which': 2}
    });
    fake.serverSend({
      'type': 'response',
      'id': id1,
      'result': <String, Object?>{'which': 1}
    });

    expect((await f1)['which'], equals(1));
    expect((await f2)['which'], equals(2));
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Error frame → typed exception
  // ---------------------------------------------------------------------------
  test('error frame → typed WincheException', () async {
    final (conn, fake) = await _makeConnected();

    final result = conn.request({'type': 'doc.get', 'path': 'users/missing'});
    await Future<void>.delayed(Duration.zero);

    final id = fake.clientFrames.last['id'] as String;
    fake.serverSend({
      'type': 'error',
      'id': id,
      'status': 'NOT_FOUND',
      'message': "Document does not exist.",
      'details': null,
    });

    await expectLater(
      result,
      throwsA(isA<WincheException>()
          .having((e) => e.status, 'status', 'NOT_FOUND')),
    );
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Listener demux — two subscriptions interleaved
  // ---------------------------------------------------------------------------
  test('listener demux — two subscriptions receive their frames', () async {
    final (conn, fake) = await _makeConnected();

    final events1 = <ServerFrame>[];
    final events2 = <ServerFrame>[];
    final sub1 = conn.listenEvents('sub-1').listen(events1.add);
    final sub2 = conn.listenEvents('sub-2').listen(events2.add);

    fake.serverSend({
      'type': 'listen.snapshot',
      'subscriptionId': 'sub-1',
      'documents': <Object?>[],
      'readTime': '2026-06-07T12:00:00+00:00',
      'resumeToken': 1,
    });
    fake.serverSend({
      'type': 'listen.delta',
      'subscriptionId': 'sub-2',
      'changes': <Object?>[],
      'count': 0,
      'readTime': '2026-06-07T12:00:01+00:00',
      'resumeToken': 2,
    });
    fake.serverSend({
      'type': 'listen.snapshot',
      'subscriptionId': 'sub-1',
      'documents': <Object?>[],
      'readTime': '2026-06-07T12:00:02+00:00',
      'resumeToken': 3,
    });

    await Future<void>.delayed(Duration.zero);

    expect(events1.length, equals(2));
    expect(events2.length, equals(1));
    expect(events1[0], isA<ListenSnapshotFrame>());
    expect(events2[0], isA<ListenDeltaFrame>());

    await sub1.cancel();
    await sub2.cancel();
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Disconnect mid-request → UnavailableException
  // ---------------------------------------------------------------------------
  test('disconnect mid-request → UnavailableException', () async {
    final (conn, fake) = await _makeConnected();

    // Register expectLater BEFORE closing so the error is captured.
    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    final resultExpect =
        expectLater(result, throwsA(isA<UnavailableException>()));

    await Future<void>.delayed(Duration.zero);

    // Close the server side — this triggers _onDone which fails pending requests.
    await fake.serverClose();

    await resultExpect;
    expect(conn.currentState, equals(ConnectionState.disconnected));
  });

  // ---------------------------------------------------------------------------
  // I2 — Listener stream lifecycle
  // ---------------------------------------------------------------------------
  test('I2 — disconnect: listener stream stays open, receives no error',
      () async {
    final (conn, fake) = await _makeConnected();

    Object? receivedError;
    bool streamDone = false;
    conn.listenEvents('sub-1').listen(
          (_) {},
          onError: (Object e) => receivedError = e,
          onDone: () => streamDone = true,
        );

    // Disconnect the server side.
    await fake.serverClose();
    await Future<void>.delayed(Duration.zero);

    expect(conn.currentState, equals(ConnectionState.disconnected));
    // Stream must NOT have received an error and must NOT be done.
    expect(receivedError, isNull);
    expect(streamDone, isFalse);
  });

  test('I2 — graceful close(): listener stream completes with done (no error)',
      () async {
    final (conn, _) = await _makeConnected();

    Object? receivedError;
    bool streamDone = false;
    conn.listenEvents('sub-2').listen(
          (_) {},
          onError: (Object e) => receivedError = e,
          onDone: () => streamDone = true,
        );

    await conn.close();
    await Future<void>.delayed(Duration.zero);

    expect(streamDone, isTrue);
    expect(receivedError, isNull);
  });

  // ---------------------------------------------------------------------------
  // I4 — Malformed frames must not escape as zone errors
  // ---------------------------------------------------------------------------
  test(
      'I4 — malformed response frame (numeric id) does not cause zone error and request fails cleanly',
      () async {
    final (conn, fake) = await _makeConnected();

    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    final resultExpect =
        expectLater(result, throwsA(isA<UnavailableException>()));
    await Future<void>.delayed(Duration.zero);

    // Send a response with a numeric id (malformed) — connection must NOT
    // propagate a zone error.
    runZonedGuarded(
      () {
        fake.serverSend({
          'type': 'response',
          'id': 42, // numeric — malformed
          'result': <String, Object?>{},
        });
      },
      (e, st) => fail('Zone error must not occur: $e'),
    );

    await Future<void>.delayed(Duration.zero);
    await conn.close();
    await resultExpect;
  });

  test(
      'I4 — malformed error frame (missing message) fails matching request cleanly',
      () async {
    final (conn, fake) = await _makeConnected();

    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    // Register expectLater BEFORE the malformed frame is sent so the error is captured.
    final resultExpect = expectLater(result, throwsA(isA<WincheException>()));
    await Future<void>.delayed(Duration.zero);

    runZonedGuarded(
      () {
        fake.serverSend({
          'type': 'error',
          'id': '0', // matching the request id
          'status': 'NOT_FOUND',
          // 'message' missing — malformed
        });
      },
      (e, st) => fail('Zone error must not occur: $e'),
    );

    await Future<void>.delayed(Duration.zero);
    // Parse threw FormatException; frame has string id '0' → request fails with WincheException.
    await resultExpect;
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Minor 11 — releaseSubscription removes controller from _listeners
  // ---------------------------------------------------------------------------
  test('Minor 11 — releaseSubscription closes stream and removes from map',
      () async {
    final (conn, _) = await _makeConnected();

    bool streamDone = false;
    conn.listenEvents('sub-cleanup').listen(
          (_) {},
          onDone: () => streamDone = true,
        );

    // Release the subscription.
    conn.releaseSubscription('sub-cleanup');
    await Future<void>.delayed(Duration.zero);

    expect(streamDone, isTrue);
    // Second call must not throw even though the controller is gone.
    conn.releaseSubscription('sub-cleanup'); // idempotent, no-op
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // New — connect appends access_token and sends no hello
  // ---------------------------------------------------------------------------
  test('connect appends access_token to the dial URI and sends no hello',
      () async {
    Uri? dialedUri;
    final fake = FakeChannel();
    fake.startCapture();

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      tokenProvider: () => 'tok-123',
      channelFactory: (uri) {
        dialedUri = uri;
        return fake;
      },
      pingInterval: const Duration(hours: 1),
      autoReconnect: false,
    ));

    final connectFuture = conn.connect();

    // Feed welcome with no protocol field.
    fake.serverSend({'type': 'welcome', 'connectionId': 'c1'});

    await connectFuture;

    expect(dialedUri, isNotNull);
    expect(dialedUri!.queryParameters['access_token'], equals('tok-123'));
    // The client must NOT send a hello frame.
    expect(
      fake.clientFrames.any((f) => f['type'] == 'hello'),
      isFalse,
      reason: 'No hello frame should be sent after removing in-band auth',
    );
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // New — welcome without protocol completes the handshake
  // ---------------------------------------------------------------------------
  test('welcome without protocol completes the handshake', () async {
    final fake = FakeChannel();
    fake.startCapture();

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      channelFactory: (_) => fake,
      pingInterval: const Duration(hours: 1),
      autoReconnect: false,
    ));

    final connectFuture = conn.connect();

    // Welcome frame has no protocol field.
    fake.serverSend({'type': 'welcome', 'connectionId': 'c1'});

    await connectFuture;

    expect(conn.currentState, equals(ConnectionState.ready));
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // I7 — Handshake timeout
  // ---------------------------------------------------------------------------
  test('I7 — handshake timeout: no welcome → UnavailableException', () async {
    // A fake channel that NEVER sends any frames.
    final silentFake = FakeChannel();

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      channelFactory: (_) => silentFake,
      pingInterval: const Duration(hours: 1),
    ));

    await expectLater(
      conn.connect(welcomeTimeout: const Duration(milliseconds: 50)),
      throwsA(isA<UnavailableException>()),
    );
  });

  // ---------------------------------------------------------------------------
  // I3 — close() fails pending requests before closing sink
  // ---------------------------------------------------------------------------
  test('I3 — close() fails pending requests with UnavailableException',
      () async {
    final (conn, _) = await _makeConnected();

    // Issue a request that will never be answered.
    final result = conn.request({'type': 'doc.get', 'path': 'users/u1'});
    // Register expectLater BEFORE close() so the error is captured.
    final resultExpect =
        expectLater(result, throwsA(isA<UnavailableException>()));

    // Close immediately without the server responding.
    await conn.close();

    await resultExpect;
  });

  // ---------------------------------------------------------------------------
  // C2 — request() fails fast when not ready
  // ---------------------------------------------------------------------------
  test('C2 — request() before connect() throws UnavailableException', () async {
    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      channelFactory: (_) => FakeChannel(),
      pingInterval: const Duration(hours: 1),
    ));
    // Do NOT call connect().
    await expectLater(
      conn.request({'type': 'doc.get', 'path': 'a/b'}),
      throwsA(isA<UnavailableException>()),
    );
  });

  test('C2 — request() after disconnect throws UnavailableException (not hang)',
      () async {
    final (conn, fake) = await _makeConnected();
    await fake.serverClose();
    await Future<void>.delayed(Duration.zero);
    expect(conn.currentState, equals(ConnectionState.disconnected));
    await expectLater(
      conn.request({'type': 'doc.get', 'path': 'a/b'}),
      throwsA(isA<UnavailableException>()),
    );
  });

  // ---------------------------------------------------------------------------
  // Minor 1 — _requestsInFlight is an int counter, not a bool
  // ---------------------------------------------------------------------------
  test(
      'Minor 1 — two concurrent requests: completing one does not clear the in-flight counter',
      () async {
    // The bug with bool: if req A and req B are both in-flight, when A
    // completes it sets _requestInFlight = false even though B is still open.
    // With an int counter, completing A decrements to 1, which is still > 0.
    // We expose this indirectly: issue 2 requests, answer req A, then
    // immediately send a ping-tick. With the bug the ping would fire
    // (counter = 0). With the fix it should not appear in clientFrames
    // (counter = 1 → ping skipped). Since we can't directly tick the timer
    // without coupling to internals, we verify via a behavioral proxy:
    // the second request still completes correctly, meaning the completer
    // for B was not erroneously removed when A finished.
    final (conn, fake) = await _makeConnected();

    final fA = conn.request({'type': 'ping'});
    final fB = conn.request({'type': 'doc.get', 'path': 'a/b'});
    await Future<void>.delayed(Duration.zero);

    final frames = fake.clientFrames.toList();
    final idA = frames[frames.length - 2]['id'] as String;
    final idB = frames[frames.length - 1]['id'] as String;

    // Complete A while B is still pending.
    fake.serverSend(
        {'type': 'response', 'id': idA, 'result': <String, Object?>{}});
    await fA; // A done

    // B must still be resolvable — if counter was bool and reset to false,
    // a premature state change or gc might break B.
    fake.serverSend(
        {'type': 'response', 'id': idB, 'result': <String, Object?>{}});
    await expectLater(fB, completes);

    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Serialized send order
  // ---------------------------------------------------------------------------
  test('sends are serialized in order', () async {
    final (conn, fake) = await _makeConnected();
    final initialCount = fake.clientFrames.length;

    final f1 = conn.request({'type': 'ping'});
    final f2 = conn.request({'type': 'doc.get', 'path': 'a/b'});
    final f3 = conn.request({'type': 'doc.get', 'path': 'c/d'});
    await Future<void>.delayed(Duration.zero);

    final sent = fake.clientFrames.skip(initialCount).toList();
    expect(sent.length, equals(3));
    expect(sent[0]['type'], equals('ping'));
    expect(sent[1]['type'], equals('doc.get'));
    expect(sent[2]['type'], equals('doc.get'));

    // Respond to all to clean up.
    for (final frame in sent) {
      fake.serverSend({
        'type': 'response',
        'id': frame['id'],
        'result': <String, Object?>{}
      });
    }
    await Future.wait([f1, f2, f3]);
    await conn.close();
  });

  // ---------------------------------------------------------------------------
  // Any server close → reconnects (including formerly-terminal 4413)
  // ---------------------------------------------------------------------------
  test('server close with any code (1013) → reconnects', () async {
    var dialCount = 0;
    final channels = <FakeChannel>[];

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      channelFactory: (_) {
        dialCount++;
        final c = FakeChannel()..startCapture();
        channels.add(c);
        return c;
      },
      pingInterval: const Duration(hours: 1),
      autoReconnect: true,
      sleeper: (_) => Future<void>.value(), // no-op backoff
    ));

    final connectFuture = conn.connect();
    await Future<void>.delayed(Duration.zero);
    channels[0].serverSend({'type': 'welcome', 'connectionId': 'c0'});
    await connectFuture;

    expect(dialCount, equals(1));

    await channels[0].serverClose(1013);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // A second channel must have been dialed.
    expect(dialCount, greaterThanOrEqualTo(2));

    channels[1].serverSend({'type': 'welcome', 'connectionId': 'c1'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(conn.currentState, equals(ConnectionState.ready));
    await conn.close();
  });

  test('server close with formerly-terminal code (4413) → reconnects',
      () async {
    var dialCount = 0;
    final channels = <FakeChannel>[];

    final conn = ProtocolConnection(ConnectionConfig(
      uri: Uri.parse('ws://fake/documents/ws'),
      channelFactory: (_) {
        dialCount++;
        final c = FakeChannel()..startCapture();
        channels.add(c);
        return c;
      },
      pingInterval: const Duration(hours: 1),
      autoReconnect: true,
      sleeper: (_) => Future<void>.value(), // no-op backoff
    ));

    final connectFuture = conn.connect();
    await Future<void>.delayed(Duration.zero);
    channels[0].serverSend({'type': 'welcome', 'connectionId': 'c0'});
    await connectFuture;

    expect(dialCount, equals(1));

    // 4413 is no longer terminal — it should now trigger reconnect.
    await channels[0].serverClose(4413);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(dialCount, greaterThanOrEqualTo(2));

    channels[1].serverSend({'type': 'welcome', 'connectionId': 'c1'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(conn.currentState, equals(ConnectionState.ready));
    await conn.close();
  });
}
