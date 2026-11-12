import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  late WincheApp app;
  late ScriptedAuthService auth;
  late WincheDatabase db;

  setUp(() {
    app = WincheApp(
      'signed-out-test',
      // Refused fast: nothing here waits for a connection.
      options: WincheOptions(databaseEndpoint: Uri.parse('ws://localhost:1/ws')),
      hookTimeout: const Duration(seconds: 5),
    );
    auth = ScriptedAuthService(app);
    db = WincheDatabase(app);
  });

  tearDown(() async => app.dispose());

  test('off by default: signed out is unbound', () async {
    db.config = const WincheDatabaseConfig(inMemory: true);
    expect(db.debugSession, isNull);
    await expectLater(db.doc('public/a').get(), throwsA(isA<WincheUnboundException>()));
  });

  test('allowSignedOut binds a session with no identity on first use', () async {
    db.config = const WincheDatabaseConfig(allowSignedOut: true, inMemory: true);
    expect(db.debugSession, isNull);   // nothing until it's used

    final sub = db.collection('public').snapshots().listen((_) {}, onError: (_) {});
    await pumpEventQueue();
    final signedOut = db.debugSession;
    expect(signedOut, isNotNull);

    // Someone signs in: their session replaces the signed-out one.
    auth.announce(WincheIdentity('u1'));
    await app.settled;
    expect(db.debugSession, isNotNull);
    expect(identical(db.debugSession, signedOut), isFalse);

    // Signing out again: unbound until the next use, which is signed out again.
    auth.announce(null);
    await app.settled;
    expect(db.debugSession, isNull);
    final again = db.collection('public').snapshots().listen((_) {}, onError: (_) {});
    await pumpEventQueue();
    expect(db.debugSession, isNotNull);
    await sub.cancel();
    await again.cancel();
  });

  test("a signed-in session that can't be built doesn't leave the signed-out one bound", () async {
    // Not in memory and no directoryResolver: the signed-in store can't be made.
    db.config = const WincheDatabaseConfig(allowSignedOut: true);
    final sub = db.collection('public').snapshots().listen((_) {}, onError: (_) {});
    await pumpEventQueue();
    expect(db.debugSession, isNotNull);
    auth.announce(WincheIdentity('u1'));
    await app.settled;
    expect(db.debugSession, isNull);
    await sub.cancel();
  });

  test('works with no auth service at all', () async {
    final bare = WincheApp('no-auth', options: WincheOptions(databaseEndpoint: Uri.parse('ws://localhost:1/ws')));
    final database = WincheDatabase(bare)..config = const WincheDatabaseConfig(allowSignedOut: true);
    final sub = database.doc('public/a').snapshots().listen((_) {}, onError: (_) {});
    await pumpEventQueue();
    expect(database.debugSession, isNotNull);
    await sub.cancel();
    await bare.dispose();
  });
}
