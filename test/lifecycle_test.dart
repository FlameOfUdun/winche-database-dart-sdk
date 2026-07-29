import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  group('WincheUnboundException', () {
    test('is an Exception and explains how to recover', () {
      final error = WincheUnboundException();
      expect(error, isA<Exception>());
      expect(error.toString(), contains('sign in'));
    });

    test('is not a StateError, which means terminal', () {
      expect(WincheUnboundException(), isNot(isA<StateError>()));
    });
  });

  group('lifecycle', () {
    late WincheApp app;
    late ScriptedAuthService auth;
    late WincheDatabase db;

    setUp(() {
      app = WincheApp(
        'lifecycle-test',
        // A refused-fast address: onSessionChanged requires an endpoint, but
        // nothing in this group ever awaits a successful connection.
        options: WincheOptions(databaseEndpoint: Uri.parse('ws://localhost:1/ws')),
        hookTimeout: const Duration(seconds: 5),
      );
      auth = ScriptedAuthService(app);
      // inMemory so no filesystem is touched; set immediately after
      // construction, while the facade is still unbound (`_started` is false).
      db = WincheDatabase(app)..config = const WincheDatabaseConfig(inMemory: true);
    });

    tearDown(() async {
      await app.dispose();
    });

    test('throws while unbound', () async {
      // `doc()`/`batch()` are lazy factories — they never touch `_require()`
      // themselves (only the session-backed getters do), so building the
      // reference/batch does not throw. The exception surfaces on first real
      // use, same as every other facade member.
      await expectLater(
        db.doc('a/b').get(),
        throwsA(isA<WincheUnboundException>()),
      );
      await expectLater(
        db.batch().commit(),
        throwsA(isA<WincheUnboundException>()),
      );

      // snapshots() builds a listener eagerly, so unlike doc()/batch() it
      // throws at call time. It must still be the documented exception: this
      // used to surface as a raw "Null check operator used on a null value"
      // from inside the SDK, which tells an app author nothing.
      expect(
        () => db.doc('a/b').snapshots(),
        throwsA(isA<WincheUnboundException>()),
      );
      expect(
        () => db.collection('a').snapshots(),
        throwsA(isA<WincheUnboundException>()),
      );
    });

    test('binds on sign-in, unbinds on sign-out', () async {
      expect(db.debugSession, isNull);

      auth.announce(WincheIdentity('alice'));
      await app.settled;
      expect(db.debugSession, isNotNull);

      auth.announce(null);
      await app.settled;
      expect(db.debugSession, isNull);
    });

    test('a user switch replaces the session', () async {
      auth.announce(WincheIdentity('alice'));
      await app.settled;
      final alice = db.debugSession;

      auth.announce(WincheIdentity('bob'));
      await app.settled;
      final bob = db.debugSession;

      expect(alice, isNotNull);
      expect(bob, isNotNull);
      expect(bob, isNot(same(alice)),
          reason: 'a user switch must tear down the previous identity\'s '
              'session and build a fresh one, or bob would read alice\'s '
              'cache and write queue');
    });

    test('a token rotation does NOT replace it', () async {
      auth.announce(WincheIdentity('alice'));
      await app.settled;
      final before = db.debugSession;

      auth.rotate();
      await app.settled;
      final after = db.debugSession;

      expect(
        after,
        same(before),
        reason: 'onTokenChanged must nudge the existing session, not rebuild '
            'it — rebuilding would tear down and reopen the store and socket '
            'on every token refresh instead of just re-dialling with a fresh '
            'token',
      );
    });

    test('status streams survive a user switch', () async {
      auth.announce(WincheIdentity('alice'));
      await app.settled;

      var done = false;
      final sub = db.connectionStates.listen((_) {}, onDone: () => done = true);

      auth.announce(WincheIdentity('bob'));
      await app.settled;

      expect(
        done,
        isFalse,
        reason: '`done` is terminal on a broadcast stream, so a connection '
            'banner subscribed here would never update again once the '
            'stream ended — a user switch must not end it',
      );

      await sub.cancel();
    });

    test('config is settable before first use and throws after', () async {
      auth.announce(WincheIdentity('alice'));
      await app.settled;

      // Bound but unused: `_started` is still false, so this must succeed.
      db.config = const WincheDatabaseConfig(inMemory: true);

      // Any public member funnels through `_require()`, marking `_started`.
      db.connectionState;

      expect(
        () => db.config = const WincheDatabaseConfig(inMemory: true),
        throwsA(isA<StateError>()),
      );
    });

    test('onTokenChanged while unbound is a no-op', () async {
      // Replaces a retired test that asserted the old reconnect() threw after
      // close. Core may call onTokenChanged after a token rotation while
      // signed out (e.g. a rotation racing a sign-out), so this must complete
      // quietly rather than throw.
      await expectLater(db.onTokenChanged(), completes);
    });
  });
}
