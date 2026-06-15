import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  test('commit sends all staged writes in order and returns results', () async {
    h.handler = (f) => h.respond(f, writeResultsPayload(count: 3));

    final batch = h.db.batch()
      ..set(h.db.doc('users/u1'), {'name': 'Alice'})
      ..update(h.db.doc('users/u2'), {'age': 30})
      ..delete(h.db.doc('users/u3'));

    final results = await batch.commit();

    expect(h.lastRequest['type'], 'write');
    final writes = h.lastRequest['writes'] as List<Object?>;
    expect(
        writes.map((w) => (w as Map).keys.single), ['set', 'update', 'delete']);
    expect(results, hasLength(3));
  });

  test('set with merge and update with transforms encode correctly', () async {
    h.handler = (f) => h.respond(f, writeResultsPayload(count: 2));

    final batch = h.db.batch()
      ..set(h.db.doc('users/u1'), {'a': 1}, merge: true)
      ..update(h.db.doc('users/u2'), {'count': FieldValue.increment(2)});
    await batch.commit();

    final writes = h.lastRequest['writes'] as List<Object?>;
    final set = (writes[0] as Map)['set'] as Map<String, Object?>;
    expect(set['merge'], true);
    final update = (writes[1] as Map)['update'] as Map<String, Object?>;
    expect(update['transforms'], [
      {
        'field': 'count',
        'kind': 'increment',
        'operand': {'integerValue': '2'},
      },
    ]);
  });

  test('empty batch commits with no writes', () async {
    h.handler = (f) => h.respond(f, {'writeResults': <Object?>[]});
    final results = await h.db.batch().commit();
    expect(results, isEmpty);
    // Nothing is queued or sent for an empty batch.
    expect(h.requests.where((f) => f['type'] == 'write'), isEmpty);
  });

  test('precondition is carried on a batched write', () async {
    h.handler = (f) => h.respond(f, writeResultsPayload());
    final batch = h.db.batch()
      ..delete(h.db.doc('users/u1'),
          precondition: const Precondition(exists: true));
    await batch.commit();
    final del =
        ((h.lastRequest['writes'] as List).single as Map)['delete'] as Map;
    expect(del['precondition'], {'exists': true});
  });
}
