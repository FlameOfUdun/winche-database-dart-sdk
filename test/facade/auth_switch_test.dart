import 'dart:async';
import 'dart:io';
import '../support/wire_error.dart';

import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';
import 'package:winche_database/src/protocol/connection.dart'
    show ConnectionConfig;

import '../protocol/fake_channel.dart';
import 'facade_harness.dart';

/// A harness that mints a fresh [FakeChannel] per dial and records the URI each
/// dial used, so a test can assert which auth token went onto the wire.
class _AuthHarness {
  _AuthHarness({
    required FutureOr<String> Function() tokenProvider,
    Future<void> Function(Duration)? sleeper,
  }) {
    db = WincheDatabase(WincheApp('auth-switch'))
      ..debugBindStore(
        ConnectionConfig(
          uri: Uri.parse('ws://fake/documents/v1/ws'),
          tokenProvider: tokenProvider,
          channelFactory: _dial,
          sleeper: sleeper ?? (_) => Future<void>.value(),
          pingInterval: const Duration(hours: 1),
        ),
        MemoryLocalStore(),
      );
  }

  late final WincheDatabase db;

  final List<FakeChannel> channels = [];

  /// The `access_token` query parameter of each dial, in order.
  final List<String?> tokens = [];

  void Function(FakeChannel channel, Map<String, Object?> frame)? handler;

  /// While set, each dial is closed before the welcome (server unreachable).
  bool refuse = false;

  /// While set, each dial is answered with this error instead of the welcome.
  String? handshakeError;

  /// While set, each dial goes to this real address instead (a server that
  /// refuses the upgrade, or a port nothing listens on), so it fails with the
  /// exceptions dart:io and web_socket_channel really throw.
  Uri? realServer;

  WebSocketChannel _dial(Uri uri) {
    tokens.add(uri.queryParameters['access_token']);
    final real = realServer;
    if (real != null) return IOWebSocketChannel.connect(real)..ready.ignore();
    final channel = FakeChannel()..startCapture();
    channels.add(channel);
    final refused = refuse;
    final error = handshakeError;
    scheduleMicrotask(
      () => refused
          ? channel.serverClose()
          : error != null
              ? channel.serverSend({'type': 'error', 'error': wireError(error, 'refused')})
              : channel.serverSend({'type': 'welcome', 'connectionId': 'test'}),
    );
    channel.onClientFrame = (frame) {
      scheduleMicrotask(() => handler?.call(channel, frame));
    };
    return channel;
  }

  void respond(
    FakeChannel c,
    Map<String, Object?> frame,
    Map<String, Object?> r,
  ) => c.serverSend({'type': 'response', 'id': frame['id'], 'result': r});

  void respondError(
    FakeChannel c,
    Map<String, Object?> frame,
    String status,
    String message,
  ) => c.serverSend({
    'type': 'error',
    'id': frame['id'],
    'error': wireError(status, message),
  });

  Future<void> close() async {
    await db.dispose();
    await pump();
  }
}

void main() {
  group('reconnect()', () {
    test('keeps a ready socket on a token rotation; the next dial reads the fresh token', () async {
      var token = 'token-a';
      final h = _AuthHarness(tokenProvider: () => token);
      h.handler = (c, f) => h.respond(c, f, {});

      await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
      await pump();
      expect(h.tokens, ['token-a']);

      token = 'token-b';
      await h.db.onTokenChanged();
      await pump();

      expect(
        h.tokens,
        ['token-a'],
        reason: 'a ready socket stays open: re-dialling on every rotation fails in-flight requests',
      );
      expect(h.db.connectionState, ConnectionState.ready);

      // The socket drops (network change, server deploy): the re-dial uses the new token.
      await h.channels.last.serverClose();
      await pump();
      await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
      await pump();

      expect(h.tokens, ['token-a', 'token-b'], reason: 'reconnect must re-read tokenProvider');
      expect(h.db.connectionState, ConnectionState.ready);

      await h.close();
    });

    test('revives a listener that died on PERMISSION_DENIED', () async {
      var token = 'expired';
      final h = _AuthHarness(tokenProvider: () => token);
      h.handler = (c, f) {
        if (f['type'] != 'doc.listen') return;
        // The first socket is unauthorised for this document; the second is not.
        if (h.channels.indexOf(c) == 0) {
          h.respondError(c, f, 'PERMISSION_DENIED', 'nope');
        } else {
          h.respond(c, f, {'subscriptionId': 's2'});
        }
      };

      final errors = <Object>[];
      final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
      final sub = h.db
          .doc('users/u1')
          .snapshots()
          .listen(snaps.add, onError: errors.add);
      await pump();

      expect(errors.single, isA<PermissionDeniedException>());

      token = 'fresh';
      await h.db.onTokenChanged();
      await pump();

      h.channels.last.serverSend({
        'type': 'listen.snapshot',
        'subscriptionId': 's2',
        'documents': [
          wireDoc('users/u1', wireFields({'name': 'Alice'})),
        ],
        'readTime': '2026-06-08T10:00:00+00:00',
      });
      await pump();

      expect(
        snaps.last.exists,
        isTrue,
        reason: 'the permanently-failed feed must resubscribe after re-auth',
      );
      expect(snaps.last.data()!['name'], 'Alice');

      await sub.cancel();
      await h.close();
    });
  });

  group('token change while the network is down', () {
    test('a refused re-dial is not reported; the connection comes back on its own', () async {
      var token = 'token-a';
      final sleeps = <Completer<void>>[];
      final h = _AuthHarness(
        tokenProvider: () => token,
        // Backoffs wait until the test releases them.
        sleeper: (_) {
          final s = Completer<void>();
          sleeps.add(s);
          return s.future;
        },
      );
      h.handler = (c, f) => h.respond(c, f, {});
      await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
      await pump();
      expect(h.db.connectionState, ConnectionState.ready);

      // The app goes to the background; the socket drops and the redial fails.
      h.refuse = true;
      await h.channels.last.serverClose();
      await pump();
      expect(h.db.connectionState, isNot(ConnectionState.ready));

      // The access token renews while the server is still out of reach.
      token = 'token-b';
      await expectLater(h.db.onTokenChanged(), completes);
      await pump();

      // The network returns: the next backoff ends and the dial gets in, with the fresh token.
      h.refuse = false;
      for (final s in sleeps) {
        if (!s.isCompleted) s.complete();
      }
      await pump(20);
      expect(h.db.connectionState, ConnectionState.ready);
      expect(h.tokens.last, 'token-b');

      await h.close();
    });

    test('a token refused at the upgrade (HTTP 401) is reported as unauthenticated', () async {
      // The real server refuses a bad access or Integrity token at the WebSocket upgrade.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..close();
      });
      var token = 'token-a';
      final h = _AuthHarness(
        tokenProvider: () => token,
        sleeper: (_) => Completer<void>().future, // the loop waits; close() ends it
      );
      h.handler = (c, f) => h.respond(c, f, {});
      await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
      await pump();

      // The socket drops and every redial now reaches the server, which refuses the token.
      h.realServer = Uri.parse('ws://127.0.0.1:${server.port}/documents/v1/ws');
      await h.channels.last.serverClose();
      await pump();
      expect(h.db.connectionState, isNot(ConnectionState.ready));

      token = 'token-b';
      await expectLater(
        h.db.onTokenChanged(),
        throwsA(isA<WincheDatabaseException>().having((e) => e.code, 'code', WincheErrorCode.unauthenticated)),
      );
      await h.close();
      await server.close(force: true);
    });

    test('a server out of reach (connection refused) is still not reported', () async {
      // A port nothing listens on: the dial fails the way a real network failure does.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      var token = 'token-a';
      final h = _AuthHarness(
        tokenProvider: () => token,
        sleeper: (_) => Completer<void>().future, // the loop waits; close() ends it
      );
      h.handler = (c, f) => h.respond(c, f, {});
      await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
      await pump();

      h.realServer = Uri.parse('ws://127.0.0.1:$port/documents/v1/ws');
      await h.channels.last.serverClose();
      await pump();

      token = 'token-b';
      await expectLater(h.db.onTokenChanged(), completes);
      await h.close();
    });

    test('a token the server refuses is still reported', () async {
      var token = 'token-a';
      final h = _AuthHarness(
        tokenProvider: () => token,
        sleeper: (_) => Completer<void>().future, // the loop waits; close() ends it
      );
      h.handler = (c, f) => h.respond(c, f, {});
      await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
      await pump();

      // The socket drops and the server refuses the token on the redial.
      h.handshakeError = 'UNAUTHENTICATED';
      await h.channels.last.serverClose();
      await pump();
      expect(h.db.connectionState, isNot(ConnectionState.ready));

      token = 'token-b';
      await expectLater(
        h.db.onTokenChanged(),
        throwsA(isA<WincheDatabaseException>().having((e) => e.code, 'code', WincheErrorCode.unauthenticated)),
      );
      await h.close();
    });
  });

  group('write rejected by the server', () {
    test(
      'UNAUTHENTICATED keeps the write queued and reports SyncPaused',
      () async {
        final h = FacadeHarness();
        h.handler = (f) {
          if (f['type'] == 'write') {
            h.respondError(f, 'UNAUTHENTICATED', 'token expired');
          } else {
            h.respond(f, {});
          }
        };

        final events = <SyncEvent>[];
        h.db.syncEvents.listen(events.add);

        await h.db.doc('users/u1').set({'name': 'Alice'});
        await pump();

        expect(
          await h.db.hasPendingWrites,
          isTrue,
          reason: 'an auth failure says nothing about the write itself',
        );
        final paused = events.whereType<SyncPaused>().single;
        expect(paused.paths, ['users/u1']);
        expect(paused.error, isA<UnauthenticatedException>());
        expect(events.whereType<WriteFailed>(), isEmpty);

        await h.close();
      },
    );

    test(
      'a repeated drain under the same dead token reports SyncPaused once',
      () async {
        final h = FacadeHarness();
        h.handler = (f) {
          if (f['type'] == 'write') {
            h.respondError(f, 'UNAUTHENTICATED', 'token expired');
          } else {
            h.respond(f, {});
          }
        };

        final events = <SyncEvent>[];
        h.db.syncEvents.listen(events.add);

        await h.db.doc('users/u1').set({'name': 'Alice'});
        await h.db.doc('users/u2').set({'name': 'Bob'});
        await pump();

        expect(events.whereType<SyncPaused>(), hasLength(1));
        await h.close();
      },
    );

    test(
      'PERMISSION_DENIED drops the write but hands back its payload',
      () async {
        final h = FacadeHarness();
        h.handler = (f) {
          if (f['type'] == 'write') {
            h.respondError(f, 'PERMISSION_DENIED', 'not your document');
          } else {
            h.respond(f, {});
          }
        };

        final events = <SyncEvent>[];
        h.db.syncEvents.listen(events.add);

        await h.db.doc('users/u1').set({'name': 'Alice'});
        await pump();

        expect(await h.db.hasPendingWrites, isFalse);
        final failed = events.whereType<WriteFailed>().single;
        expect(failed.error, isA<PermissionDeniedException>());
        expect(failed.writes, hasLength(1));
        expect(failed.writes.single.path, 'users/u1');
        expect(failed.writes.single.kind, PendingKind.set);

        await h.close();
      },
    );
  });
}
