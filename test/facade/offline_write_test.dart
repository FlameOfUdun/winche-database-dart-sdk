import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

import '../offline/fake_local_store.dart';
import 'facade_harness.dart';

void main() {
  test('a write returns without waiting for the server round-trip', () async {
    final h = FacadeHarness();
    // Answer everything except the write, so the drain parks on the wire.
    h.handler = (f) {
      if (f['type'] != 'write') h.respond(f, {});
    };

    // If `set` awaited the drain this never completes.
    await h.db
        .doc('users/u1')
        .set({'name': 'Alice'}).timeout(const Duration(seconds: 2));

    expect(await h.db.hasPendingWrites, isTrue,
        reason: 'the write is queued and still draining in the background');
    await h.close();
  });

  WincheDatabase offlineDb(LocalStore store) =>
      WincheDatabase(WincheApp('offline-write'))
        ..debugBindStore(
          ConnectionConfig(
            uri: Uri.parse('ws://localhost:1/documents/ws'),
            // Reconnection is unconditional; without a small real backoff the
            // always-failing dial would retry on the default (up-to-30s) delay.
            sleeper: (_) =>
                Future<void>.delayed(const Duration(milliseconds: 5)),
          ),
          store,
        );

  test('offline set acks locally and is visible to get (hasPendingWrites)',
      () async {
    final db = offlineDb(FakeLocalStore());
    final wr = await db.doc('users/u1').set({'name': 'Alice'});
    expect(wr.updateTime, isA<DateTime>());

    final snap =
        await db.doc('users/u1').get(const GetOptions(source: Source.cache));
    expect(snap.exists, isTrue);
    expect(snap.data(), {'name': 'Alice'});
    expect(snap.metadata.hasPendingWrites, isTrue);
    db.dispose();
  });

  test('offline update then cache read reflects the change', () async {
    final db = offlineDb(FakeLocalStore());
    await db.doc('users/u1').set({'a': 1, 'b': 2});
    await db.doc('users/u1').update({'a': 9});
    final snap =
        await db.doc('users/u1').get(const GetOptions(source: Source.cache));
    expect(snap.data(), {'a': 9, 'b': 2});
    db.dispose();
  });

  test('offline batch commit enqueues all writes, visible via cache query',
      () async {
    final db = offlineDb(FakeLocalStore());
    await (db.batch()
          ..set(db.doc('users/a'), {'age': 1})
          ..set(db.doc('users/b'), {'age': 2}))
        .commit();
    final qs = await db
        .collection('users')
        .get(const GetOptions(source: Source.cache));
    expect(qs.docs.map((d) => d.id).toSet(), {'a', 'b'});
    expect(qs.metadata.hasPendingWrites, isTrue);
    db.dispose();
  });
}
