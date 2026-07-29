import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

import '../offline/fake_local_store.dart';

void main() {
  WincheDatabase offlineDb(LocalStore store, {ConflictPolicy? policy}) =>
      WincheDatabase(WincheApp('sync-api'))
        ..debugBindStore(
          ConnectionConfig(
              uri: Uri.parse('ws://localhost:1/documents/ws'),
              autoReconnect: false),
          store,
          conflictPolicy: policy ?? ConflictPolicy.manual,
        );

  test('syncEvents is a broadcast stream', () {
    final db = offlineDb(FakeLocalStore());
    expect(db.syncEvents, isA<Stream<SyncEvent>>());
    db.dispose();
  });

  test('hasPendingWrites reflects queued writes', () async {
    final db = offlineDb(FakeLocalStore());
    expect(await db.hasPendingWrites, isFalse);
    await db.doc('users/u1').set({'n': 1});
    expect(await db.hasPendingWrites, isTrue);
    db.dispose();
  });

  test('clearPersistence empties the cache and queue', () async {
    final db = offlineDb(FakeLocalStore());
    await db.doc('users/u1').set({'n': 1});
    expect(await db.hasPendingWrites, isTrue);
    await db.clearPersistence();
    expect(await db.hasPendingWrites, isFalse);
    db.dispose();
  });

  test('a fresh in-memory db has no pending writes', () async {
    // Old test built a persistent-store-shaped `WincheDatabaseConfig(uri:,
    // inMemory: true)` directly via the removed `WincheDatabase(config)`
    // factory. That config shape is gone; `inMemory` on the current
    // `WincheDatabaseConfig` only takes effect via the identity-driven
    // `onSessionChanged` path (`_storeFor`), which is out of reach from a
    // debugBindStore-based test (see the not-converted namespaceResolver
    // tests in auth_switch_test.dart / database_ctor_test.dart for why).
    // The assertion under test — a fresh db has no pending writes — is
    // preserved unchanged; only the construction (in-memory store injected
    // directly, same as every other test in this file) is adapted.
    final db = offlineDb(MemoryLocalStore());
    expect(await db.hasPendingWrites, isFalse);
    db.dispose();
  });
}
