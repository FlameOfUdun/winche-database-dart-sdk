import 'package:test/test.dart';
import 'package:winche_database/src/offline/eviction_manager.dart';

void main() {
  test('evicts oldest unpinned documents over the cap; keeps pinned + recent', () async {
    final removed = <String>[];
    final em = EvictionManager(maxDocuments: 2)
      ..pinnedPaths = (() async => {'c/pinned'})
      ..removeDocument = (p) async => removed.add(p);

    em.recordAccess('c/old', 1);     // oldest
    em.recordAccess('c/pinned', 1);  // pinned → never evicted
    em.recordAccess('c/new', 1);     // newest
    expect(em.trackedCount, 3);

    await em.evictIfNeeded(); // over cap by 1 → evict oldest unpinned ('c/old')

    expect(removed, ['c/old']);
    expect(em.trackedCount, 2);
  });

  test('recordAccess moves an existing path to most-recently-used', () async {
    final removed = <String>[];
    final em = EvictionManager(maxDocuments: 1)
      ..pinnedPaths = (() async => const <String>{})
      ..removeDocument = (p) async => removed.add(p);

    em.recordAccess('a', 1);
    em.recordAccess('b', 1);
    em.recordAccess('a', 1); // a is now MRU; b is oldest

    await em.evictIfNeeded(); // cap 1, two tracked → evict oldest ('b')

    expect(removed, ['b']);
  });

  test('no-op when at or under the cap', () async {
    var calls = 0;
    final em = EvictionManager(maxDocuments: 5)
      ..pinnedPaths = () async { calls++; return const <String>{}; }
      ..removeDocument = (_) async {};
    em.recordAccess('a', 1);
    await em.evictIfNeeded();
    expect(calls, 0); // didn't even compute the pinned set
  });

  test('forget drops a path from tracking', () {
    final em = EvictionManager(maxDocuments: 10);
    em.recordAccess('a', 1);
    em.forget('a');
    expect(em.trackedCount, 0);
  });

  test('evicts by byte cap, keeping pinned + recent', () async {
    final removed = <String>[];
    final em = EvictionManager(maxBytes: 250)
      ..pinnedPaths = (() async => const <String>{})
      ..removeDocument = (p) async => removed.add(p);

    em.recordAccess('a', 100); // total 100
    em.recordAccess('b', 100); // total 200
    em.recordAccess('c', 100); // total 300 > 250

    await em.evictIfNeeded(); // evict oldest unpinned until <= 250 → drop 'a'

    expect(removed, ['a']);
  });

  test('a re-access updates a path size and total', () async {
    final removed = <String>[];
    final em = EvictionManager(maxBytes: 150)
      ..pinnedPaths = (() async => const <String>{})
      ..removeDocument = (p) async => removed.add(p);
    em.recordAccess('a', 100);
    em.recordAccess('a', 200); // replaces size: total is 200, not 300
    await em.evictIfNeeded(); // 200 > 150, only 'a' tracked & unpinned → evicts 'a'
    expect(removed, ['a']);
  });
}
