import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

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
          autoReconnect: false,
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
        () => channel.serverSend({'type': 'welcome', 'connectionId': 'test'}));
    channel.onClientFrame = (frame) {
      scheduleMicrotask(() => handler?.call(channel, frame));
    };
    return channel;
  }

  void respond(
          FakeChannel c, Map<String, Object?> frame, Map<String, Object?> r) =>
      c.serverSend({'type': 'response', 'id': frame['id'], 'result': r});

  void respondError(FakeChannel c, Map<String, Object?> frame, String status,
          String message) =>
      c.serverSend({
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
  // NOT CONVERTED — reported to the task owner rather than guessed at.
  //
  // This whole group exercised `WincheDatabaseConfig(uri:, namespaceResolver:,
  // directoryResolver:)` validation that lived on the old `WincheDatabase`
  // factory constructor. None of those fields exist on the current
  // `WincheDatabaseConfig` (it only carries pingInterval/autoReconnect/
  // maxBackoff/maxFrameBytes/inMemory/conflictPolicy/maxCachedDocuments/
  // cacheSizeBytes — see lib/src/facade/database.dart), so there is no
  // mechanical rename that makes this compile.
  //
  // The behaviour itself moved, not just the API surface: namespace/id
  // validation now happens eagerly in `WincheIdentity`'s constructor (see
  // ../../../winche_core/lib/src/models/winche_identity.dart), throwing
  // `ArgumentError` for a bad `id` at identity-creation time — not lazily on
  // first store access, and not configurable via a user-supplied
  // `namespaceResolver` (there isn't one any more; the facade always derives
  // the store namespace from the signed-in identity's `storageKey`). The
  // `directoryResolver`-required-on-native check still exists, but it now
  // lives on `WincheOptions` and is checked inside the facade's private
  // `_storeFor`, driven only by a real `onSessionChanged` dispatch — which
  // requires a signed-in identity via a `WincheAuthService`. The test-only
  // seam this task added (`debugBindStore`) deliberately bypasses identity
  // and `_storeFor` entirely, so it cannot exercise this path either, and
  // introducing a fake auth service here would be new test infrastructure
  // beyond this task's construction/teardown-only mandate.
  //
  // Net: this coverage has no home left in winche_database as written. The
  // namespace-validation half belongs in winche_core's WincheIdentity tests;
  // the directoryResolver-required half would need a winche_database test
  // driven through a real signed-in session. Left un-converted rather than
  // silently deleted or given a different assertion — flagged for a decision.
  // Original group, preserved verbatim as a comment (not deleted) so the
  // exact prior assertions stay visible for whoever picks this up:
  //
  // group('namespaceResolver', () {
  //   WincheDatabase dbWith(FutureOr<String> Function() resolver) =>
  //       WincheDatabase(WincheDatabaseConfig(
  //         uri: Uri.parse('ws://x/ws'),
  //         namespaceResolver: resolver,
  //         directoryResolver: () async => '/tmp',
  //       ));
  //
  //   test('rejects a resolved value that is not a safe file-name component',
  //       () async {
  //     for (final bad in ['a/b', '../evil', '.', '..', '', 'a b']) {
  //       final db = dbWith(() => bad);
  //       // Resolved lazily, so the rejection surfaces on first store access.
  //       await expectLater(
  //         db.doc('users/u1').get(const GetOptions(source: Source.cache)),
  //         throwsA(isA<ArgumentError>()),
  //         reason: 'namespace "$bad" must be rejected',
  //       );
  //     }
  //   });
  //
  //   test('is required for a persistent store', () {
  //     expect(
  //       () => WincheDatabase(WincheDatabaseConfig(
  //         uri: Uri.parse('ws://x/ws'),
  //         directoryResolver: () async => '/tmp',
  //       )),
  //       throwsA(isA<ArgumentError>()),
  //     );
  //   });
  //
  //   test('is rejected alongside inMemory', () {
  //     expect(
  //       () => WincheDatabase(WincheDatabaseConfig(
  //         uri: Uri.parse('ws://x/ws'),
  //         inMemory: true,
  //         namespaceResolver: () => 'user-123',
  //       )),
  //       throwsA(isA<ArgumentError>()),
  //     );
  //   });
  //
  //   test('an in-memory store needs no namespace', () {
  //     expect(
  //       () => WincheDatabase(WincheDatabaseConfig(
  //         uri: Uri.parse('ws://x/ws'),
  //         inMemory: true,
  //       )),
  //       returnsNormally,
  //     );
  //   });
  // });

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

      expect(h.tokens, ['token-a', 'token-b'],
          reason: 'reconnect must re-read tokenProvider, not reuse the socket');
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
        'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
        'readTime': '2026-06-08T10:00:00+00:00',
      });
      await pump();

      expect(snaps.last.exists, isTrue,
          reason: 'the permanently-failed feed must resubscribe after re-auth');
      expect(snaps.last.data()!['name'], 'Alice');

      await sub.cancel();
      await h.close();
    });

    // Original test, preserved verbatim as a comment (not deleted):
    //
    // test('throws after close()', () async {
    //   final h = FacadeHarness();
    //   await h.db.close();
    //   expect(h.db.reconnect(), throwsA(isA<StateError>()));
    // });
    //
    // Not convertible by rename alone: the mapping table (db.reconnect() ->
    // db.onTokenChanged()) changes the *contract*, not just the name.
    // `onTokenChanged` (lib/src/facade/database.dart) reads:
    //   Future<void> onTokenChanged() async {
    //     final session = _session;
    //     if (session == null) return;
    //     ...
    //   }
    // It no-ops when there is no session — by design, since it is a
    // WincheNonAuthService hook core may call after a token rotation while
    // signed out, and must not throw for that. After `dispose()`, `_session`
    // is null, so `onTokenChanged()` returns normally instead of throwing
    // StateError. That is a real behavioural difference from the old
    // `reconnect()`, not a naming difference, so changing this assertion to
    // "returns normally" would be silently rewriting behaviour under test.
    // Flagged rather than guessed at.
  });

  group('write rejected by the server', () {
    test('UNAUTHENTICATED keeps the write queued and reports SyncPaused',
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

      expect(await h.db.hasPendingWrites, isTrue,
          reason: 'an auth failure says nothing about the write itself');
      final paused = events.whereType<SyncPaused>().single;
      expect(paused.paths, ['users/u1']);
      expect(paused.error, isA<UnauthenticatedException>());
      expect(events.whereType<WriteFailed>(), isEmpty);

      await h.close();
    });

    test('a repeated drain under the same dead token reports SyncPaused once',
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
    });

    test('PERMISSION_DENIED drops the write but hands back its payload',
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
    });
  });
}
