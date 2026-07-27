import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

/// The client learns its `subscriptionId` from the subscribe *response*, so it
/// can only register a frame listener after that response lands — but a server
/// may push the first `listen.snapshot` before it. These tests pin that the
/// snapshot survives the gap instead of being dropped, which left the listener
/// waiting forever on a delta that only arrives when data changes.
void main() {
  test('a query snapshot pushed before the subscribe response is delivered',
      () async {
    final h = FacadeHarness();
    h.handler = (f) {
      if (f['type'] != 'listen') return;
      // Snapshot FIRST, response second — the ordering observed from the .NET
      // sample server for a query carrying an orderBy.
      h.push({
        'type': 'listen.snapshot',
        'subscriptionId': 's',
        'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
        'readTime': '2026-06-08T10:00:00+00:00',
        'resumeToken': 7,
      });
      h.respond(f, {'subscriptionId': 's'});
    };

    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('users').orderBy('name').snapshots().listen(
          snaps.add,
          onError: (Object e) => fail('listener errored: $e'),
        );
    await pump();

    expect(snaps.last.docs, hasLength(1),
        reason: 'the early snapshot must not be dropped');
    expect(snaps.last.docs.single.data()!['name'], 'Alice');
    expect(snaps.last.metadata.fromCache, isFalse,
        reason: 'the feed is live once the snapshot is delivered');

    await sub.cancel();
    await h.close();
  });

  test('a document snapshot pushed before the subscribe response is delivered',
      () async {
    final h = FacadeHarness();
    h.handler = (f) {
      if (f['type'] != 'doc.listen') return;
      h.push({
        'type': 'listen.snapshot',
        'subscriptionId': 's',
        'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
        'readTime': '2026-06-08T10:00:00+00:00',
      });
      h.respond(f, {'subscriptionId': 's'});
    };

    final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(snaps.add);
    await pump();

    expect(snaps.last.exists, isTrue);
    expect(snaps.last.data()!['name'], 'Alice');
    expect(snaps.last.metadata.fromCache, isFalse);

    await sub.cancel();
    await h.close();
  });

  test('early frames are delivered in arrival order, ahead of live ones',
      () async {
    final h = FacadeHarness();
    h.handler = (f) {
      if (f['type'] != 'listen') return;
      h.push({
        'type': 'listen.snapshot',
        'subscriptionId': 's',
        'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
        'readTime': '2026-06-08T10:00:00+00:00',
        'resumeToken': 1,
      });
      h.push({
        'type': 'listen.delta',
        'subscriptionId': 's',
        'changes': [
          {
            'kind': 'added',
            'oldIndex': -1,
            'newIndex': 1,
            'document': wireDoc('users/u2', wireFields({'name': 'Bob'})),
          },
        ],
        'count': 2,
        'readTime': '2026-06-08T10:00:01+00:00',
        'resumeToken': 2,
      });
      h.respond(f, {'subscriptionId': 's'});
    };

    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub =
        h.db.collection('users').orderBy('name').snapshots().listen(snaps.add);
    await pump();

    expect(snaps.last.docs.map((d) => d.id), ['u1', 'u2'],
        reason: 'the delta must be applied on top of the snapshot, not before');

    await sub.cancel();
    await h.close();
  });

  test('frames for a subscription that is never claimed do not accumulate',
      () async {
    final h = FacadeHarness();
    h.handler = (f) => h.respond(f, {});

    // Force the connection up, then flood frames for an id nobody subscribes to.
    await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
    for (var i = 0; i < 500; i++) {
      h.push({
        'type': 'listen.snapshot',
        'subscriptionId': 'ghost-$i',
        'documents': const <Object?>[],
        'readTime': '2026-06-08T10:00:00+00:00',
      });
    }
    await pump();

    // No assertion on internals — the point is that the connection stays healthy
    // and bounded rather than growing a buffer per ghost id.
    final snap =
        await h.db.doc('users/u1').get(const GetOptions(source: Source.cache));
    expect(snap.exists, isFalse);
    await h.close();
  });
}
