import 'package:test/test.dart';
import 'package:winche_database/src/offline/memory_local_store.dart';
import 'fake_local_store.dart';

void main() {
  late FakeLocalStore store;
  setUp(() => store = FakeLocalStore());

  test('documents: put/get/remove and collection scan', () async {
    await store.putDocument('users/u1', {'path': 'users/u1', 'n': 1});
    await store.putDocument('users/u2', {'path': 'users/u2', 'n': 2});
    await store.putDocument('users/u1/posts/p1', {'path': 'users/u1/posts/p1'});

    expect(await store.getDocument('users/u1'), {'path': 'users/u1', 'n': 1});

    final inUsers = await store.documentsInCollection('users');
    expect(inUsers.map((d) => d['path']).toSet(), {'users/u1', 'users/u2'});

    await store.removeDocument('users/u1');
    expect(await store.getDocument('users/u1'), isNull);
  });

  test('pending queue: monotonic seq, ordered scan, remove', () async {
    final s1 = await store.nextPendingSeq();
    final s2 = await store.nextPendingSeq();
    expect(s2, greaterThan(s1));

    await store.putPending(s2, {'seq': s2});
    await store.putPending(s1, {'seq': s1});
    expect((await store.allPending()).map((e) => e['seq']), [s1, s2]);

    await store.removePending(s1);
    expect((await store.allPending()).map((e) => e['seq']), [s2]);
  });

  test('meta: put/get and clear wipes everything', () async {
    await store.putMeta('lastSync', 'X');
    expect(await store.getMeta('lastSync'), 'X');
    await store.putDocument('a/b', {'path': 'a/b'});
    await store.clear();
    expect(await store.getMeta('lastSync'), isNull);
    expect(await store.getDocument('a/b'), isNull);
  });

  test('reopen preserves data (simulated restart)', () async {
    await store.putDocument('a/b', {'path': 'a/b'});
    final seq = await store.nextPendingSeq();
    await store.putPending(seq, {'seq': seq});
    final reopened = store.reopen();
    expect(await reopened.getDocument('a/b'), {'path': 'a/b'});
    expect((await reopened.allPending()).single['seq'], seq);
    expect(await reopened.nextPendingSeq(), greaterThan(seq));
  });

  test('allDocuments returns every stored document record', () async {
    final store = MemoryLocalStore();
    await store.putDocument('c/a', {'path': 'c/a', 'n': 1});
    await store.putDocument('c/b', {'path': 'c/b', 'n': 2});
    await store.putDocument('d/x', {'path': 'd/x', 'n': 3});

    final all = await store.allDocuments();
    expect(all.length, 3);
    expect({for (final r in all) r['path']}, {'c/a', 'c/b', 'd/x'});
  });
}
