import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';
import 'package:winche_database/src/protocol/messages.dart' show WireDocument;

import 'facade_harness.dart';

/// Builds an offline-only [WincheDatabase] (unreachable server) with an
/// in-memory store and the given [maxCachedDocuments] cap. Writes are enqueued
/// and stay pending because the connection always fails with
/// [UnavailableException], which [SyncController.drain] treats as "offline –
/// keep the queue" and returns immediately.
WincheDatabase _offlineDb({required int maxCachedDocuments}) =>
    WincheDatabase.withStore(
      ConnectionConfig(
        uri: Uri.parse('ws://localhost:1/documents/ws'),
        autoReconnect: false,
      ),
      MemoryLocalStore(),
      maxCachedDocuments: maxCachedDocuments,
    );

void main() {
  test('a document with a pending write is pinned and survives eviction',
      () async {
    final db = _offlineDb(maxCachedDocuments: 1);
    // Queue an offline write for c/keep → it stays pending (connection fails).
    await db.doc('c/keep').set({'n': 1});

    // Now warm two more confirmed docs through the cache; cap is 1, so eviction
    // must drop the unpinned ones, never the pending-write doc.
    await db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/keep', wireFields({'n': 1}), collection: 'c')));
    await db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/drop1', wireFields({'n': 2}), collection: 'c')));
    await db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/drop2', wireFields({'n': 3}), collection: 'c')));

    expect(await db.cache.confirmed('c/keep'), isNotNull,
        reason: 'pending-write doc must be pinned');
    // At least one unpinned doc was evicted to honour the cap.
    final drop1 = await db.cache.confirmed('c/drop1');
    final drop2 = await db.cache.confirmed('c/drop2');
    expect(drop1 == null || drop2 == null, isTrue);

    db.close();
  });

  test('an active listener pins its members; an unrelated doc is evicted',
      () async {
    final h = FacadeHarness(maxCachedDocuments: 1);
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final sub = h.db.collection('c').snapshots().listen((_) {});
    await pump();

    // Server result has two members → both must be pinned despite cap == 1.
    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('c/m1', wireFields({'n': 1}), collection: 'c'),
        wireDoc('c/m2', wireFields({'n': 2}), collection: 'c'),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();

    // Warm an unrelated, unpinned doc → it (not the members) must be evicted.
    await h.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/loose', wireFields({'n': 9}), collection: 'c')));

    expect(await h.db.cache.confirmed('c/m1'), isNotNull, reason: 'member pinned');
    expect(await h.db.cache.confirmed('c/m2'), isNotNull, reason: 'member pinned');
    expect(await h.db.cache.confirmed('c/loose'), isNull,
        reason: 'unpinned → evicted');

    await sub.cancel();

    // After cancel the members are unpinned and become eligible for eviction.
    await h.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/after1', wireFields({'n': 1}), collection: 'c')));
    await h.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/after2', wireFields({'n': 2}), collection: 'c')));
    expect(await h.db.cache.confirmed('c/m1'), isNull,
        reason: 'cancelled listener no longer pins its old members');

    await h.close();
  });

  test('server query.get returns the full result even when it exceeds the cap',
      () async {
    final h = FacadeHarness(maxCachedDocuments: 2);
    h.handler = (f) {
      if (f['type'] == 'query') {
        h.respond(f, {
          'documents': [
            for (var i = 1; i <= 5; i++)
              wireDoc('c/d$i', wireFields({'n': i}), collection: 'c'),
          ],
          'hasMore': false,
        });
      }
    };

    final snap = await h.db.collection('c').get();

    // The fetched result (5) must come back whole even though the cache cap is 2
    // and the write-through evicted the earliest-cached docs.
    expect(snap.docs.length, 5);
    expect(snap.docs.map((d) => d.id).toSet(),
        {'d1', 'd2', 'd3', 'd4', 'd5'});

    await h.close();
  });

  test('server getAll returns all fetched docs even when over the cap',
      () async {
    final h = FacadeHarness(maxCachedDocuments: 1);
    h.handler = (f) {
      if (f['type'] == 'doc.getAll') {
        h.respond(f, {
          'documents': [
            wireDoc('c/a', wireFields({'n': 1}), collection: 'c'),
            wireDoc('c/b', wireFields({'n': 2}), collection: 'c'),
            wireDoc('c/c', wireFields({'n': 3}), collection: 'c'),
          ],
        });
      }
    };

    final snaps = await h.db
        .getAll([h.db.doc('c/a'), h.db.doc('c/b'), h.db.doc('c/c')]);

    expect(snaps.map((s) => s.exists).toList(), [true, true, true]);

    await h.close();
  });

  test('byte cap evicts unpinned docs over the limit', () async {
    // ~120 bytes/doc serialized; cap 300 keeps ~2.
    final h = FacadeHarness(cacheSizeBytes: 300);
    for (var i = 0; i < 6; i++) {
      await h.db.cache.putConfirmed(WireDocument.fromJson(wireDoc(
          'c/d$i', wireFields({'label': 'value-$i'}), collection: 'c')));
    }
    var live = 0;
    for (var i = 0; i < 6; i++) {
      if (await h.db.cache.confirmed('c/d$i') != null) live++;
    }
    expect(live, lessThan(6), reason: 'byte cap must evict some docs');
    await h.close();
  });

  test('startup enforces the byte cap against already-persisted documents',
      () async {
    final store = MemoryLocalStore();

    // Session 1: persist several docs with no cap.
    final h1 = FacadeHarness(store: store);
    for (var i = 0; i < 6; i++) {
      await h1.db.cache.putConfirmed(WireDocument.fromJson(wireDoc(
          'c/p$i', wireFields({'label': 'value-$i'}), collection: 'c')));
    }
    await h1.close();

    // Session 2: small byte cap. The first cache write primes from the durable
    // store and evicts the over-cap persisted docs.
    final h2 = FacadeHarness(store: store, cacheSizeBytes: 300);
    await h2.db.cache.putConfirmed(WireDocument.fromJson(
        wireDoc('c/new', wireFields({'label': 'fresh'}), collection: 'c')));
    var live = 0;
    for (var i = 0; i < 6; i++) {
      if (await h2.db.cache.confirmed('c/p$i') != null) live++;
    }
    expect(live, lessThan(6),
        reason: 'startup priming must enforce the cap against persisted docs');
    await h2.close();
  });
}
