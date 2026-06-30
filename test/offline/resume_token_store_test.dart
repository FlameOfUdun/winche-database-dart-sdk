import 'package:test/test.dart';
import 'package:winche_database/src/offline/memory_local_store.dart';
import 'package:winche_database/src/offline/resume_token_store.dart';

void main() {
  test('stores, returns, and clears tokens; persists across instances', () async {
    final store = MemoryLocalStore();
    final r = ResumeTokenStore(store);

    expect(await r.get('q1'), isNull);
    await r.set('q1', 42);
    await r.set('doc:users/u1', 7);
    expect(await r.get('q1'), 42);
    expect(await r.get('doc:users/u1'), 7);

    // A fresh store instance over the same backing store rehydrates.
    final r2 = ResumeTokenStore(store);
    expect(await r2.get('q1'), 42);

    await r.set('q1', null); // clear
    expect(await r.get('q1'), isNull);
  });

  test('bounds entries: oldest-set token is dropped past the cap', () async {
    final store = MemoryLocalStore();
    final r = ResumeTokenStore(store, maxEntries: 2);

    await r.set('a', 1);
    await r.set('b', 2);
    await r.set('c', 3); // evicts 'a'

    expect(await r.get('a'), isNull);
    expect(await r.get('b'), 2);
    expect(await r.get('c'), 3);
  });

  test('concurrent first-access shares one hydration and loses no write',
      () async {
    final store = MemoryLocalStore();
    final r = ResumeTokenStore(store);

    // Two writes race the lazy load (e.g. two listeners starting at once).
    await Future.wait([r.set('a', 1), r.set('b', 2)]);

    expect(await r.get('a'), 1);
    expect(await r.get('b'), 2);
  });
}
