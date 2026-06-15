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
}
