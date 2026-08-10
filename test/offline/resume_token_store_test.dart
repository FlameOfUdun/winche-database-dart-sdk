import 'package:test/test.dart';
import 'package:winche_database/src/offline/memory_local_store.dart';
import 'package:winche_database/src/offline/resume_token_store.dart';

void main() {
  test('stores, returns, and clears tokens; persists across instances', () async {
    final store = MemoryLocalStore();
    final r = ResumeTokenStore(store);

    expect(await r.get('q1'), isNull);
    await r.set('q1', '42:0');
    await r.set('doc:users/u1', '7:0');
    expect(await r.get('q1'), '42:0');
    expect(await r.get('doc:users/u1'), '7:0');

    // A fresh store instance over the same backing store rehydrates.
    final r2 = ResumeTokenStore(store);
    expect(await r2.get('q1'), '42:0');

    await r.set('q1', null); // clear
    expect(await r.get('q1'), isNull);
  });

  test('bounds entries: oldest-set token is dropped past the cap', () async {
    final store = MemoryLocalStore();
    final r = ResumeTokenStore(store, maxEntries: 2);

    await r.set('a', '1:0');
    await r.set('b', '2:0');
    await r.set('c', '3:0'); // evicts 'a'

    expect(await r.get('a'), isNull);
    expect(await r.get('b'), '2:0');
    expect(await r.get('c'), '3:0');
  });

  test('concurrent first-access shares one hydration and loses no write',
      () async {
    final store = MemoryLocalStore();
    final r = ResumeTokenStore(store);

    // Two writes race the lazy load (e.g. two listeners starting at once).
    await Future.wait([r.set('a', '1:0'), r.set('b', '2:0')]);

    expect(await r.get('a'), '1:0');
    expect(await r.get('b'), '2:0');
  });

  test('a legacy int-valued blob (pre-8.0 numeric resume tokens) is dropped, '
      'not thrown or returned', () async {
    final store = MemoryLocalStore();
    // Simulate a pre-upgrade metadata blob: int-valued tokens under the old
    // numeric resume-token protocol, written directly to bypass ResumeTokenStore
    // (which would only ever write strings post-upgrade).
    await store.putMeta('resumeTokens', <String, Object?>{
      'q1': 42, // legacy int — meaningless under the new cursor, must be dropped
      'doc:users/u1': 7,
    });

    final r = ResumeTokenStore(store);

    // Must not throw, and must not resurface the legacy value in any form.
    expect(await r.get('q1'), isNull);
    expect(await r.get('doc:users/u1'), isNull);

    // The store is still usable afterwards — a fresh (string) token can be set.
    await r.set('q1', '99:0');
    expect(await r.get('q1'), '99:0');
  });

  test('a mixed blob keeps valid string entries and drops only the legacy '
      'int ones', () async {
    final store = MemoryLocalStore();
    await store.putMeta('resumeTokens', <String, Object?>{
      'legacy': 1, // dropped
      'current': '5:0', // kept
    });

    final r = ResumeTokenStore(store);
    expect(await r.get('legacy'), isNull);
    expect(await r.get('current'), '5:0');
  });
}
