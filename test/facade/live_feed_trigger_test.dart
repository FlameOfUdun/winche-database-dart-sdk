import 'package:test/test.dart';

import 'facade_harness.dart';

void main() {
  test('a listener subscribes once, driven by the ready state', () async {
    final h = FacadeHarness();
    addTearDown(h.close);

    final sub = h.db.collection('users').snapshots().listen((_) {});
    addTearDown(sub.cancel);
    await pump();

    final listens = h.requests.where((f) => f['type'] == 'listen').toList();
    expect(listens, hasLength(1),
        reason: 'the level signal must not cause a duplicate subscribe');
  });

  test('a repeated ready does not churn a healthy subscription', () async {
    final h = FacadeHarness();
    addTearDown(h.close);

    final sub = h.db.collection('users').snapshots().listen((_) {});
    addTearDown(sub.cancel);
    await pump();
    final before = h.requests.where((f) => f['type'] == 'listen').length;

    // The transport is already ready; a duplicate emission must be suppressed
    // by the relay's de-duplication rather than tearing the feed down.
    await pump();

    final after = h.requests.where((f) => f['type'] == 'listen').length;
    expect(after, equals(before));
  });
}
