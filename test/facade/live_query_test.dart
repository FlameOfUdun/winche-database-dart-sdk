import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import '../offline/fake_local_store.dart';
import 'facade_harness.dart';

Map<String, Object?> snapshotFrame(
  String subId,
  List<Map<String, Object?>> documents, {
  int resumeToken = 1,
}) =>
    {
      'type': 'listen.snapshot',
      'subscriptionId': subId,
      'documents': documents,
      'readTime': '2026-06-08T12:00:00+00:00',
      'resumeToken': resumeToken,
    };

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  test('serves cache-first, then the server snapshot clears fromCache',
      () async {
    final h = FacadeHarness(store: FakeLocalStore());
    h.handler = (f) {
      switch (f['type']) {
        case 'listen':
          h.respond(f, {'subscriptionId': 'sub0'});
        default:
          h.respond(f, const {});
      }
    };
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('users').snapshots().listen(snaps.add);
    await pump();

    // First emission is cache-first (empty cache) and flagged fromCache.
    expect(snaps.first.metadata.fromCache, isTrue);
    expect(snaps.first.docs, isEmpty);

    h.push(snapshotFrame('sub0', [
      wireDoc('users/u1', wireFields({'n': 1}))
    ]));
    await pump();

    expect(snaps.last.metadata.fromCache, isFalse);
    expect(snaps.last.docs.map((d) => d.id), ['u1']);

    await sub.cancel();
    await h.close();
  });

  test('a local write shows optimistically with hasPendingWrites', () async {
    final h = FacadeHarness(store: FakeLocalStore());
    h.handler = (f) {
      switch (f['type']) {
        case 'listen':
          h.respond(f, {'subscriptionId': 'sub0'});
        case 'write':
          h.respond(f, writeResultsPayload());
        default:
          h.respond(f, const {});
      }
    };
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('users').snapshots().listen(snaps.add);
    await pump();
    h.push(snapshotFrame('sub0', [
      wireDoc('users/u1', wireFields({'n': 1}))
    ]));
    await pump();

    await h.db.doc('users/u2').set({'n': 2});
    await pump(12);

    // The optimistic overlay surfaced the queued write (with hasPendingWrites)
    // before the server acked it.
    expect(
      snaps.any((s) =>
          s.metadata.hasPendingWrites &&
          s.docs.map((d) => d.id).contains('u2')),
      isTrue,
    );

    await sub.cancel();
    await h.close();
  });

  test('a deleted delta tombstones the doc so it cannot reappear from cache',
      () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final sub = h.db.collection('users').snapshots().listen((_) {});
    await pump();

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('users/u1', wireFields({'name': 'Alice'})),
        wireDoc('users/u2', wireFields({'name': 'Bob'})),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();

    h.push({
      'type': 'listen.delta',
      'subscriptionId': 's',
      'changes': [
        {
          'kind': 'deleted',
          'document': wireDoc('users/u2', wireFields({'name': 'Bob'})),
          'oldIndex': 1,
          'newIndex': -1,
        }
      ],
      'count': 1,
      'readTime': '2026-06-30T10:00:01+00:00',
    });
    await pump();

    await sub.cancel();

    expect(await h.db.cache.confirmed('users/u2'), isNull);
    expect(await h.db.cache.isKnownAbsent('users/u2'), isTrue);
    // The surviving doc is untouched.
    expect(await h.db.cache.confirmed('users/u1'), isNotNull);
  });

  test('a removed change (not deleted) does NOT tombstone the doc', () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final sub = h.db.collection('users').snapshots().listen((_) {});
    await pump();

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('users/u1', wireFields({'name': 'Alice'})),
        wireDoc('users/u2', wireFields({'name': 'Bob'})),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();

    // u2 leaves THIS query's window/filter but still exists → kind 'removed'.
    h.push({
      'type': 'listen.delta',
      'subscriptionId': 's',
      'changes': [
        {
          'kind': 'removed',
          'document': wireDoc('users/u2', wireFields({'name': 'Bob'})),
          'oldIndex': 1,
          'newIndex': -1,
        }
      ],
      'count': 1,
      'readTime': '2026-06-30T10:00:01+00:00',
    });
    await pump();

    await sub.cancel();

    // 'removed' (unlike 'deleted') must leave the doc cached — it still exists.
    expect(await h.db.cache.isKnownAbsent('users/u2'), isFalse);
    expect(await h.db.cache.confirmed('users/u2'), isNotNull);
  });

  test('after a deletion, a cache-source read does not resurrect the doc',
      () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final sub = h.db.collection('users').snapshots().listen((_) {});
    await pump();

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('users/u1', wireFields({'name': 'Alice'})),
        wireDoc('users/u2', wireFields({'name': 'Bob'})),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();

    h.push({
      'type': 'listen.delta',
      'subscriptionId': 's',
      'changes': [
        {
          'kind': 'deleted',
          'document': wireDoc('users/u2', wireFields({'name': 'Bob'})),
          'oldIndex': 1,
          'newIndex': -1,
        }
      ],
      'count': 1,
      'readTime': '2026-06-30T10:00:01+00:00',
    });
    await pump();

    // The cache is the exact source the feed-down fallback reads from; it must
    // exclude the deleted doc — the original resurrection bug.
    final cached = await h.db
        .collection('users')
        .get(const GetOptions(source: Source.cache));
    expect(cached.docs.map((d) => d.id), ['u1']);

    await sub.cancel();
  });

  test('a deleted change is tombstoned even when the delta count mismatches',
      () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
    };
    final sub = h.db.collection('users').snapshots().listen((_) {});
    await pump();

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [
        wireDoc('users/u1', wireFields({'n': 1})),
        wireDoc('users/u2', wireFields({'n': 2})),
      ],
      'readTime': '2026-06-30T10:00:00+00:00',
    });
    await pump();

    // Delta deletes u2 but reports a WRONG count (3, not 1) → the count-mismatch
    // resubscribe path. The deletion must still be tombstoned.
    h.push({
      'type': 'listen.delta',
      'subscriptionId': 's',
      'changes': [
        {
          'kind': 'deleted',
          'document': wireDoc('users/u2', wireFields({'n': 2})),
          'oldIndex': 1,
          'newIndex': -1,
        }
      ],
      'count': 3,
      'readTime': '2026-06-30T10:00:01+00:00',
    });
    await pump();

    await sub.cancel();

    expect(await h.db.cache.isKnownAbsent('users/u2'), isTrue,
        reason: 'deleted doc must be tombstoned even on a count mismatch');
    expect(await h.db.cache.confirmed('users/u2'), isNull);
  });
}
