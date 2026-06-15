import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';
import 'listener_test.dart' show snapshotFrame;

void main() {
  test(
      'select trims live-query docs to requested fields only and does not leak select to wire',
      () async {
    final h = FacadeHarness();
    String? capturedSubId;

    h.handler = (f) {
      switch (f['type']) {
        case 'listen':
          capturedSubId = 'sub-proj';
          h.respond(f, {'subscriptionId': capturedSubId!});
        case 'unlisten':
          h.respond(f, const {});
        default:
          h.respond(f, const {});
      }
    };

    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db
        .collection('users')
        .where('priority', isEqualTo: 1)
        .select(['title'])
        .snapshots()
        .listen(snaps.add);
    await pump();

    // Confirm the listen frame's query does NOT contain a 'select' key.
    final listenFrame = h.requests.firstWhere((f) => f['type'] == 'listen');
    final query = listenFrame['query'] as Map<String, Object?>;
    expect(query.containsKey('select'), isFalse,
        reason: 'select must not be sent in the listen wire frame');

    // Push a full document with both 'title' and 'priority' fields.
    h.push(snapshotFrame(
      'sub-proj',
      [
        wireDoc(
          'users/u1',
          wireFields({'title': 'A', 'priority': 1}),
        ),
      ],
      resumeToken: 1,
    ));
    await pump();

    // The snapshot should contain exactly one doc.
    final snap = snaps.last;
    expect(snap.docs, hasLength(1));

    // The doc's data should only contain 'title', not 'priority'.
    final data = snap.docs.single.data()!;
    expect(data, containsPair('title', 'A'));
    expect(data.containsKey('priority'), isFalse,
        reason: 'select must trim fields to only those requested');

    await sub.cancel();
    await h.close();
  });
}
