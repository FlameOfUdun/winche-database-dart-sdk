import 'package:test/test.dart';
import 'package:winche_database/src/offline/local_query_engine.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';
import 'package:winche_database/src/core/values.dart';

WireDocument d(String id, Map<String, Value> fields) => WireDocument(
    path: 'users/$id',
    id: id,
    collection: 'users',
    fields: fields,
    createTime: 'T',
    updateTime: 'T',
    version: 1);

void main() {
  final docs = [
    d('a', {'age': const IntegerValue(30), 'team': const StringValue('red')}),
    d('b', {'age': const IntegerValue(20), 'team': const StringValue('red')}),
    d('c', {'age': const IntegerValue(40), 'team': const StringValue('blue')}),
    d('d', {'team': const StringValue('blue')}), // no age
  ];
  List<String> ids(List<WireDocument> r) => r.map((x) => x.id).toList();

  test('where filter selects matching docs', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users',
            where:
                FilterSpec.field('team', FieldOp.eq, const StringValue('red'))),
        docs);
    expect(ids(r).toSet(), {'a', 'b'});
  });

  test('orderBy adds an implicit exists filter (docs missing the field drop)',
      () {
    final r = LocalQueryEngine()
        .runQuery(QuerySpec('users', orderBy: const [OrderSpec('age')]), docs);
    expect(ids(r), ['b', 'a', 'c']);
  });

  test('orderBy descending', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age', direction: SortDirection.desc)]),
        docs);
    expect(ids(r), ['c', 'a', 'b']);
  });

  test('__name__ tiebreaker keeps a stable total order', () {
    final tie = [
      d('y', {'age': const IntegerValue(1)}),
      d('x', {'age': const IntegerValue(1)}),
    ];
    final r = LocalQueryEngine()
        .runQuery(QuerySpec('users', orderBy: const [OrderSpec('age')]), tie);
    expect(ids(r), ['x', 'y']);
  });

  test('limit truncates after ordering', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users', orderBy: const [OrderSpec('age')], limit: 2), docs);
    expect(ids(r), ['b', 'a']);
  });

  test('startAfter cursor (exclusive lower bound)', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age')],
            start: const CursorSpec([IntegerValue(20)], before: false)),
        docs);
    expect(ids(r), ['a', 'c']);
  });

  test('startAt cursor (inclusive lower bound)', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age')],
            start: const CursorSpec([IntegerValue(30)], before: true)),
        docs);
    expect(ids(r), ['a', 'c']);
  });

  test('endAt / endBefore cursors (upper bound)', () {
    final endAt = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age')],
            end: const CursorSpec([IntegerValue(30)], before: false)),
        docs);
    expect(ids(endAt), ['b', 'a']);
    final endBefore = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age')],
            end: const CursorSpec([IntegerValue(30)], before: true)),
        docs);
    expect(ids(endBefore), ['b']);
  });

  test('descending cursor respects direction', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age', direction: SortDirection.desc)],
            start: const CursorSpec([IntegerValue(40)], before: false)),
        docs);
    expect(ids(r), ['a', 'b']);
  });

  test('no orderBy → results ordered by __name__ ascending', () {
    final r = LocalQueryEngine().runQuery(QuerySpec('users'), docs);
    expect(ids(r), ['a', 'b', 'c', 'd']);
  });

  test('offset skips the first N after ordering', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users', orderBy: const [OrderSpec('age')], offset: 1), docs);
    expect(ids(r), ['a', 'c']); // ascending age is [b, a, c]; skip b
  });

  test('offset composes with limit (skip then take)', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users',
            orderBy: const [OrderSpec('age')], offset: 1, limit: 1),
        docs);
    expect(ids(r), ['a']);
  });

  test('offset beyond the result size yields empty', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users', orderBy: const [OrderSpec('age')], offset: 99), docs);
    expect(ids(r), isEmpty);
  });

  test('limitToLast returns the last N in ascending order', () {
    // ascending age is [b(20), a(30), c(40)] → last 2 = [a, c].
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users', orderBy: const [OrderSpec('age')], limitToLast: 2),
        docs);
    expect(ids(r), ['a', 'c']);
  });

  test('limitToLast larger than the result returns everything', () {
    final r = LocalQueryEngine().runQuery(
        QuerySpec('users', orderBy: const [OrderSpec('age')], limitToLast: 99),
        docs);
    expect(ids(r), ['b', 'a', 'c']);
  });

  test('limitToLast without orderBy throws (matches server)', () {
    expect(
        () => LocalQueryEngine()
            .runQuery(QuerySpec('users', limitToLast: 2), docs),
        throwsArgumentError);
  });
}
