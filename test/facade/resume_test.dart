import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';
import 'package:winche_database/src/protocol/messages.dart' show WireDocument;

import 'facade_harness.dart';

void main() {
  test('a feed subscribes with the persisted resume token and persists updates',
      () async {
    final store = MemoryLocalStore();

    // First session: listen, receive a snapshot carrying resumeToken 99.
    final h1 = FacadeHarness(store: store);
    h1.handler = (f) {
      if (f['type'] == 'listen') h1.respond(f, {'subscriptionId': 's'});
    };
    final sub1 = h1.db.collection('users').snapshots().listen((_) {});
    await pump();
    h1.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [wireDoc('users/a', wireFields({'n': 1}))],
      'readTime': '2026-06-30T10:00:00+00:00',
      'resumeToken': 99,
    });
    await pump();
    await sub1.cancel();
    await h1.close();

    // Second session over the same store: the listen frame must carry token 99.
    final h2 = FacadeHarness(store: store);
    h2.handler = (f) {
      if (f['type'] == 'listen') h2.respond(f, {'subscriptionId': 's2'});
    };
    final sub2 = h2.db.collection('users').snapshots().listen((_) {});
    await pump();

    final listen = h2.requests.firstWhere((f) => f['type'] == 'listen');
    expect(listen['resumeToken'], 99);

    await sub2.cancel();
    await h2.close();
  });

  test('listen.current marks the listener live without wiping its cached view',
      () async {
    final store = MemoryLocalStore();

    // Seed the cache with a confirmed doc (as a prior session would have).
    final seed = FacadeHarness(store: store);
    await seed.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('users/a', wireFields({'n': 1}))));
    await seed.close();

    final h = FacadeHarness(store: store);
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('users').snapshots().listen(snaps.add);
    await pump();

    // Cache-first emission: present but flagged fromCache.
    expect(snaps.last.docs.map((d) => d.id), ['a']);
    expect(snaps.last.metadata.fromCache, isTrue);

    // Server says "you're current" — no documents in the frame.
    h.push({
      'type': 'listen.current',
      'subscriptionId': 's',
      'resumeToken': 100,
    });
    await pump();

    // The view is unchanged but now authoritative.
    expect(snaps.last.docs.map((d) => d.id), ['a'],
        reason: 'current marker must not wipe the cached view');
    expect(snaps.last.metadata.fromCache, isFalse,
        reason: 'current marker clears fromCache');

    await sub.cancel();
    await h.close();
  });

  test('doc.listen: listen.current shows the cached doc, not missing', () async {
    final store = MemoryLocalStore();

    // Seed a confirmed doc as a prior session would have.
    final seed = FacadeHarness(store: store);
    await seed.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('users/u1', wireFields({'name': 'Alice'}))));
    await seed.close();

    final h = FacadeHarness(store: store);
    h.handler = (f) {
      if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(snaps.add);
    await pump();

    // Cache-first emission: present, flagged fromCache.
    expect(snaps.last.exists, isTrue);
    expect(snaps.last.metadata.fromCache, isTrue);

    // Covered resume: server says "current" with no document.
    h.push({'type': 'listen.current', 'subscriptionId': 's', 'resumeToken': 50});
    await pump();

    expect(snaps.last.exists, isTrue,
        reason: 'covered resume must not report a live doc as missing');
    expect(snaps.last.metadata.fromCache, isFalse);
    expect(snaps.last.data()!['name'], 'Alice');

    await sub.cancel();
    await h.close();
  });
}
