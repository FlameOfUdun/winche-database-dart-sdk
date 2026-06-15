import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import '../offline/fake_local_store.dart';

void main() {
  WincheDatabase offlineDb(LocalStore store, {ConflictPolicy? policy}) =>
      WincheDatabase.withStore(
        ConnectionConfig(
            uri: Uri.parse('ws://localhost:1/documents/ws'),
            autoReconnect: false),
        store,
        conflictPolicy: policy ?? ConflictPolicy.manual,
      );

  test('syncEvents is a broadcast stream', () {
    final db = offlineDb(FakeLocalStore());
    expect(db.syncEvents, isA<Stream<SyncEvent>>());
    db.close();
  });

  test('hasPendingWrites reflects queued writes', () async {
    final db = offlineDb(FakeLocalStore());
    expect(await db.hasPendingWrites, isFalse);
    await db.doc('users/u1').set({'n': 1});
    expect(await db.hasPendingWrites, isTrue);
    db.close();
  });

  test('clearPersistence empties the cache and queue', () async {
    final db = offlineDb(FakeLocalStore());
    await db.doc('users/u1').set({'n': 1});
    expect(await db.hasPendingWrites, isTrue);
    await db.clearPersistence();
    expect(await db.hasPendingWrites, isFalse);
    db.close();
  });

  test('a fresh in-memory db has no pending writes', () async {
    final db = WincheDatabase(WincheDatabaseConfig(
        uri: Uri.parse('ws://localhost:1/documents/ws'), inMemory: true));
    expect(await db.hasPendingWrites, isFalse);
    db.close();
  });
}
