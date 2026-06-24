import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  QueryReference<Map<String, Object?>> users() => h.db.collection('users');

  test('aggregate sends a frame and decodes the alias-keyed map', () async {
    h.handler = (f) => h.respond(f, {
          'result': {
            'n': {'integerValue': 42},
            'revenue': {'doubleValue': 1234.5},
          }
        });

    final r = await users().where('paid', isEqualTo: true).aggregate([
      Aggregate.count(alias: 'n'),
      Aggregate.sum('total', alias: 'revenue'),
    ]);

    expect(r, {'n': 42, 'revenue': 1234.5});
    expect(h.lastRequest['type'], 'aggregate');
    final aggs = (h.lastRequest['aggregations'] as List).cast<Map<String, Object?>>();
    expect(aggs[0]['kind'], 'count');
    expect(aggs[0]['alias'], 'n');
    expect(aggs[1]['kind'], 'sum');
    expect(aggs[1]['field'], 'total');
    final query = (h.lastRequest['query'] as Map).cast<String, Object?>();
    expect(query['collection'], 'users');
  });

  test('aggregate throws ArgumentError on an empty list', () {
    expect(() => users().aggregate([]), throwsA(isA<ArgumentError>()));
  });

  test('aggregate throws UnsupportedError when a cursor is set', () {
    expect(() => users().startAt([1]).aggregate([Aggregate.count(alias: 'n')]),
        throwsA(isA<UnsupportedError>()));
  });

  test('sum shortcut returns the value', () async {
    h.handler = (f) => h.respond(f, {
          'result': {r'$value': {'doubleValue': 99.0}}
        });
    expect(await users().sum('total'), 99.0);
  });

  test('average shortcut returns null for an empty set', () async {
    h.handler = (f) => h.respond(f, {
          'result': {r'$value': {'nullValue': null}}
        });
    expect(await users().average('total'), isNull);
  });
}
