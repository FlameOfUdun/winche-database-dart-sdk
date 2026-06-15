import 'package:test/test.dart';

import 'facade_harness.dart';

void main() {
  // Regression: a `limit` on a live listener can interact badly with server-side
  // per-document read rules (limit applied before the read filter), dropping the
  // watched document. `doc.snapshots()` therefore must NOT send a limit — the
  // `__name__ ==` filter already matches at most one document.
  test('doc.snapshots sends no limit in its listen query', () async {
    final h = FacadeHarness();
    h.handler = (f) {
      if (f['type'] == 'listen') {
        h.respond(f, {'subscriptionId': 's'});
      } else {
        h.respond(f, const {});
      }
    };

    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();

    final listen = h.requests.firstWhere((f) => f['type'] == 'listen');
    final query = (listen['query'] as Map).cast<String, Object?>();
    expect(query.containsKey('limit'), isFalse,
        reason: 'doc.snapshots must not apply a limit to its live listen');
    expect(query['where'], isNotNull,
        reason: 'doc.snapshots still filters on __name__');

    await sub.cancel();
    await h.close();
  });
}
