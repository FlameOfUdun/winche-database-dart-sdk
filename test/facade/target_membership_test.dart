import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';
import 'package:winche_database/src/protocol/messages.dart' show WireDocument;

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  test('offline fallback serves query membership, not a whole-collection re-derive',
      () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db
        .collection('users')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen(snaps.add);
    await pump();

    // Server result: a and b both match.
    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('users/a', wireFields({'active': true})),
        wireDoc('users/b', wireFields({'active': true})),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();
    expect(snaps.last.docs.map((d) => d.id), ['a', 'b']);

    // b changes server-side so it no longer matches → 'removed' (still exists,
    // stays cached with its stale active:true fields).
    h.push({
      'type': 'listen.delta',
      'subscriptionId': 's',
      'changes': [
        {
          'kind': 'removed',
          'document': wireDoc('users/b', wireFields({'active': true})),
          'oldIndex': 1,
          'newIndex': -1,
        }
      ],
      'count': 1,
      'readTime': '2026-06-30T10:00:01+00:00',
    });
    await pump();
    expect(snaps.last.docs.map((d) => d.id), ['a']);

    // Feed goes down. Stale b is still cached and still matches the filter locally;
    // the old whole-collection fallback would resurrect it.
    await h.channel.serverClose();
    await pump();

    expect(snaps.last.metadata.fromCache, isTrue);
    expect(snaps.last.docs.map((d) => d.id), ['a'],
        reason: 'offline fallback must serve membership, not re-derive over the cache');

    await sub.cancel();
  });

  test('server query.get returns the server result, not a whole-collection re-derive',
      () async {
    // Pre-seed a stale doc that matches the filter but is not in the server result.
    await h.db.cache.putConfirmed(
        WireDocument.fromJson(wireDoc('users/b', wireFields({'active': true}))));

    h.handler = (f) {
      if (f['type'] == 'query') {
        h.respond(f, {
          'documents': [wireDoc('users/a', wireFields({'active': true}))],
          'hasMore': false,
        });
      }
    };

    final snap = await h.db
        .collection('users')
        .where('active', isEqualTo: true)
        .get();

    expect(snap.docs.map((d) => d.id), ['a']);
  });

  test('cache query.get reuses membership learned from a prior server get',
      () async {
    await h.db.cache.putConfirmed(
        WireDocument.fromJson(wireDoc('users/b', wireFields({'active': true}))));

    h.handler = (f) {
      if (f['type'] == 'query') {
        h.respond(f, {
          'documents': [wireDoc('users/a', wireFields({'active': true}))],
          'hasMore': false,
        });
      }
    };

    // Prime membership via a server-backed get.
    await h.db
        .collection('users')
        .where('active', isEqualTo: true)
        .get(const GetOptions(source: Source.server));

    // A cache-only get must serve that membership, not the whole collection.
    final snap = await h.db
        .collection('users')
        .where('active', isEqualTo: true)
        .get(const GetOptions(source: Source.cache));

    expect(snap.docs.map((d) => d.id), ['a']);
  });

  test('a fresh (reset) snapshot replaces membership; dropped doc not served offline',
      () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('users').snapshots().listen(snaps.add);
    await pump();

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('users/a', wireFields({'n': 1})),
        wireDoc('users/b', wireFields({'n': 2})),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();
    expect(snaps.last.docs.map((d) => d.id), ['a', 'b']);

    // Reset snapshot (server resync) now omits b — b still exists in the cache.
    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [wireDoc('users/a', wireFields({'n': 1}))],
      'readTime': '2026-06-30T10:00:02+00:00',
    });
    await pump();
    expect(snaps.last.docs.map((d) => d.id), ['a']);

    // Offline: membership (now just [a]) is what's served, not the cache's [a, b].
    await h.channel.serverClose();
    await pump();
    expect(snaps.last.docs.map((d) => d.id), ['a']);

    await sub.cancel();
  });

  test('cold-start cache query.get serves persisted membership, not the collection',
      () async {
    final store = MemoryLocalStore();

    // Session 1: a server query records membership [a]; a stale matching doc b
    // also lands in the (durable) cache.
    final h1 = FacadeHarness(store: store);
    await h1.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('users/b', wireFields({'active': true}))));
    h1.handler = (f) {
      if (f['type'] == 'query') {
        h1.respond(f, {
          'documents': [wireDoc('users/a', wireFields({'active': true}))],
          'hasMore': false,
        });
      }
    };
    await h1.db
        .collection('users')
        .where('active', isEqualTo: true)
        .get(const GetOptions(source: Source.server));
    await h1.close();

    // Session 2 over the same store, offline: cache get must serve membership [a].
    final h2 = FacadeHarness(store: store);
    final snap = await h2.db
        .collection('users')
        .where('active', isEqualTo: true)
        .get(const GetOptions(source: Source.cache));
    expect(snap.docs.map((d) => d.id), ['a']);
    await h2.close();
  });

  test("cold-start listener's first emission serves persisted membership",
      () async {
    final store = MemoryLocalStore();

    final h1 = FacadeHarness(store: store);
    await h1.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('users/b', wireFields({'active': true}))));
    h1.handler = (f) {
      if (f['type'] == 'query') {
        h1.respond(f, {
          'documents': [wireDoc('users/a', wireFields({'active': true}))],
          'hasMore': false,
        });
      }
    };
    await h1.db
        .collection('users')
        .where('active', isEqualTo: true)
        .get(const GetOptions(source: Source.server));
    await h1.close();

    // Session 2: the listener's cache-first emission (no server response yet)
    // must reflect membership [a], not the cache's [a, b].
    final h2 = FacadeHarness(store: store);
    h2.handler = (f) {/* never answer listen → stay on the cache-first emission */};
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h2.db
        .collection('users')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen(snaps.add);
    await pump();

    expect(snaps.first.metadata.fromCache, isTrue);
    expect(snaps.first.docs.map((d) => d.id), ['a']);

    await sub.cancel();
    await h2.close();
  });
}
