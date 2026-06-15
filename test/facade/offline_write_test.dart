import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import '../offline/fake_local_store.dart';

void main() {
  WincheDatabase offlineDb(LocalStore store) => WincheDatabase(
        ConnectionConfig(
            uri: Uri.parse('ws://localhost:1/documents/ws'),
            autoReconnect: false),
        store: store,
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
    db.close();
  });

  test('offline update then cache read reflects the change', () async {
    final db = offlineDb(FakeLocalStore());
    await db.doc('users/u1').set({'a': 1, 'b': 2});
    await db.doc('users/u1').update({'a': 9});
    final snap =
        await db.doc('users/u1').get(const GetOptions(source: Source.cache));
    expect(snap.data(), {'a': 9, 'b': 2});
    db.close();
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
    db.close();
  });
}
