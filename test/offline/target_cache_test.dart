import 'package:test/test.dart';
import 'package:winche_database/src/offline/memory_local_store.dart';
import 'package:winche_database/src/offline/target_cache.dart';
import 'package:winche_database/src/protocol/query_spec.dart';

void main() {
  test('stores, returns, and persists ordered membership keyed by query',
      () async {
    final store = MemoryLocalStore();
    final tc = TargetCache(store);
    final users = QuerySpec('users');

    expect(await tc.members(users), isNull);

    await tc.setMembers(users, ['users/a', 'users/b']);
    expect(await tc.members(users), ['users/a', 'users/b']);

    // A different query is a different key.
    expect(await tc.members(QuerySpec('orders')), isNull);

    // A fresh instance over the same backing store rehydrates from disk.
    final tc2 = TargetCache(store);
    expect(await tc2.members(QuerySpec('users')), ['users/a', 'users/b']);
  });

  test('bounds entries: oldest-set query is dropped past the cap', () async {
    final store = MemoryLocalStore();
    final tc = TargetCache(store, maxEntries: 2);

    await tc.setMembers(QuerySpec('a'), ['a/1']);
    await tc.setMembers(QuerySpec('b'), ['b/1']);
    await tc.setMembers(QuerySpec('c'), ['c/1']); // evicts 'a'

    expect(await tc.members(QuerySpec('a')), isNull);
    expect(await tc.members(QuerySpec('b')), ['b/1']);
    expect(await tc.members(QuerySpec('c')), ['c/1']);
  });

  test('concurrent first-access shares one hydration and loses no write',
      () async {
    final store = MemoryLocalStore();
    final tc = TargetCache(store);

    // Two writes race the lazy load (e.g. two listeners' first snapshots).
    await Future.wait([
      tc.setMembers(QuerySpec('a'), ['a/1']),
      tc.setMembers(QuerySpec('b'), ['b/1']),
    ]);

    expect(await tc.members(QuerySpec('a')), ['a/1']);
    expect(await tc.members(QuerySpec('b')), ['b/1']);
  });
}
