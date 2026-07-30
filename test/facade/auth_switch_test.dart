import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';
import 'package:winche_database/src/protocol/connection.dart'
    show ConnectionConfig;

import '../protocol/fake_channel.dart';
import 'facade_harness.dart';

/// A harness that mints a fresh [FakeChannel] per dial and records the URI each
/// dial used, so a test can assert which auth token went onto the wire.
class _AuthHarness {
  _AuthHarness({required FutureOr<String> Function() tokenProvider}) {
    db = WincheDatabase(WincheApp('auth-switch'))
      ..debugBindStore(
        ConnectionConfig(
          uri: Uri.parse('ws://fake/documents/ws'),
          tokenProvider: tokenProvider,
          channelFactory: _dial,
          sleeper: (_) => Future<void>.value(),
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

  FakeChannel _dial(Uri uri) {
    tokens.add(uri.queryParameters['access_token']);
    final channel = FakeChannel()..startCapture();
    channels.add(channel);
    scheduleMicrotask(
      () => channel.serverSend({'type': 'welcome', 'connectionId': 'test'}),
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
    'status': status,
    'message': message,
  });

  Future<void> close() async {
    await db.dispose();
    await pump();
  }
}

void main() {
  group('reconnect()', () {
    test('re-dials with a freshly read token', () async {
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
        ['token-a', 'token-b'],
        reason: 'reconnect must re-read tokenProvider, not reuse the socket',
      );
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
