import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  test('doc.snapshots sends a doc.listen frame with the path, not a query listen',
      () async {
    h.handler = (f) {
      if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
    };

    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();

    final docListen = h.requests.firstWhere((f) => f['type'] == 'doc.listen');
    expect(docListen['path'], 'users/u1');
    expect(h.requests.any((f) => f['type'] == 'listen'), isFalse,
        reason: 'doc.snapshots must use doc.listen, not a query listen');

    await sub.cancel();
  });

  test('emits a missing snapshot first, then a live one from the server', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(snaps.add);
    await pump();

    expect(snaps.first.exists, isFalse);

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
      'readTime': '2026-06-08T10:00:00+00:00',
    });
    await pump();

    expect(snaps.last.exists, isTrue);
    expect(snaps.last.data()!['name'], 'Alice');

    await sub.cancel();
  });

  test('a removed delta emits a missing snapshot', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(snaps.add);
    await pump();

    h.push({
      'type': 'listen.snapshot',
      'subscriptionId': 's',
      'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
      'readTime': '2026-06-08T10:00:00+00:00',
    });
    await pump();
    expect(snaps.last.exists, isTrue);

    h.push({
      'type': 'listen.delta',
      'subscriptionId': 's',
      'changes': [
        {
          'kind': 'removed',
          'document': wireDoc('users/u1', wireFields({'name': 'Alice'})),
          'oldIndex': 0,
          'newIndex': -1,
        }
      ],
      'count': 0,
      'readTime': '2026-06-08T10:00:00+00:00',
    });
    await pump();

    expect(snaps.last.exists, isFalse);

    await sub.cancel();
  });
}
