import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  QueryReference<Map<String, Object?>> users() => h.db.collection('users');

  // ===========================================================================
  // where() — operator → wire mapping
  // ===========================================================================
  group('where operators', () {
    test('isEqualTo → eq', () {
      expect(users().where('a', isEqualTo: 1).spec.where!.toJson(), {
        'field': 'a',
        'op': 'eq',
        'value': {'integerValue': '1'},
      });
    });

    test('isNotEqualTo → ne', () {
      expect(
          users().where('a', isNotEqualTo: 1).spec.where!.toJson()['op'], 'ne');
    });

    test('comparison operators map to lt/lte/gt/gte', () {
      expect(
          users().where('a', isLessThan: 1).spec.where!.toJson()['op'], 'lt');
      expect(
          users().where('a', isLessThanOrEqualTo: 1).spec.where!.toJson()['op'],
          'lte');
      expect(users().where('a', isGreaterThan: 1).spec.where!.toJson()['op'],
          'gt');
      expect(
          users()
              .where('a', isGreaterThanOrEqualTo: 1)
              .spec
              .where!
              .toJson()['op'],
          'gte');
    });

    test('arrayContains → arrayContains', () {
      expect(
          users().where('tags', arrayContains: 'x').spec.where!.toJson()['op'],
          'arrayContains');
    });

    test('arrayContainsAny → arrayContainsAny with ArrayValue', () {
      final json = users()
          .where('tags', arrayContainsAny: ['x', 'y'])
          .spec
          .where!
          .toJson();
      expect(json['op'], 'arrayContainsAny');
      expect(json['value'], {
        'arrayValue': {
          'values': [
            {'stringValue': 'x'},
            {'stringValue': 'y'},
          ],
        },
      });
    });

    test('arrayContainsAll → arrayContainsAll', () {
      expect(
          users()
              .where('tags', arrayContainsAll: ['x'])
              .spec
              .where!
              .toJson()['op'],
          'arrayContainsAll');
    });

    test('whereIn → in', () {
      expect(
          users().where('a', whereIn: [1, 2]).spec.where!.toJson()['op'], 'in');
    });

    test('whereNotIn → notIn with ArrayValue', () {
      final json = users().where('a', whereNotIn: [1, 2]).spec.where!.toJson();
      expect(json['op'], 'notIn');
      expect(json['value'], {
        'arrayValue': {
          'values': [
            {'integerValue': '1'},
            {'integerValue': '2'},
          ],
        },
      });
    });

    test('isNan:true → unary isNan', () {
      expect(users().where('r', isNan: true).spec.where!.toJson(), {
        'unary': 'isNan',
        'field': 'r',
      });
    });

    test('isNan:false → not(unary isNan)', () {
      expect(users().where('r', isNan: false).spec.where!.toJson(), {
        'not': {'unary': 'isNan', 'field': 'r'},
      });
    });

    test('exists:true → unary exists', () {
      expect(users().where('e', exists: true).spec.where!.toJson(), {
        'unary': 'exists',
        'field': 'e',
      });
    });

    test('exists:false → not(unary exists)', () {
      expect(users().where('e', exists: false).spec.where!.toJson(), {
        'not': {'unary': 'exists', 'field': 'e'},
      });
    });

    test('string operators map to contains/startsWith/endsWith/regex', () {
      expect(users().where('s', contains: 'x').spec.where!.toJson()['op'],
          'contains');
      expect(users().where('s', startsWith: 'x').spec.where!.toJson()['op'],
          'startsWith');
      expect(users().where('s', endsWith: 'x').spec.where!.toJson()['op'],
          'endsWith');
      expect(users().where('s', matchesRegex: 'x').spec.where!.toJson()['op'],
          'regex');
    });

    test('isNull:true → unary isNull', () {
      expect(users().where('a', isNull: true).spec.where!.toJson(), {
        'unary': 'isNull',
        'field': 'a',
      });
    });

    test('isNull:false → not(unary isNull)', () {
      expect(users().where('a', isNull: false).spec.where!.toJson(), {
        'not': {'unary': 'isNull', 'field': 'a'},
      });
    });

    test('multiple args in one where() AND-compose', () {
      final json = users()
          .where('a', isGreaterThan: 1, isLessThan: 10)
          .spec
          .where!
          .toJson();
      expect(json.containsKey('and'), isTrue);
      expect((json['and'] as List).length, 2);
    });

    test('multiple where() calls AND-compose with existing', () {
      final json = users()
          .where('a', isEqualTo: 1)
          .where('b', isEqualTo: 2)
          .spec
          .where!
          .toJson();
      expect(json.containsKey('and'), isTrue);
    });

    test('where() with no recognised arg is a no-op', () {
      final q = users();
      expect(identical(q.where('a'), q), isTrue);
    });

    test('whereFilter() composes a raw FilterSpec', () {
      final json = users()
          .whereFilter(FilterSpec.field('a', FieldOp.eq, const IntegerValue(1)))
          .spec
          .where!
          .toJson();
      expect(json['op'], 'eq');
    });
  });

  // ===========================================================================
  // orderBy / limit / cursors
  // ===========================================================================
  group('ordering and pagination', () {
    test('orderBy asc/desc and multiple clauses', () {
      final spec = users().orderBy('a').orderBy('b', descending: true).spec;
      expect(spec.orderBy!.map((o) => o.toJson()).toList(), [
        {'field': 'a', 'direction': 'asc'},
        {'field': 'b', 'direction': 'desc'},
      ]);
    });

    test('limit', () {
      expect(users().limit(25).spec.limit, 25);
    });

    test('startAt → start cursor before:true', () {
      final c = users().startAt([1]).spec.start!;
      expect(c.toJson(), {
        'values': [
          {'integerValue': '1'},
        ],
        'before': true,
      });
    });

    test('startAfter → start cursor before:false', () {
      expect(users().startAfter([1]).spec.start!.before, isFalse);
    });

    test('endAt → end cursor before:false', () {
      expect(users().endAt([1]).spec.end!.before, isFalse);
    });

    test('endBefore → end cursor before:true', () {
      expect(users().endBefore([1]).spec.end!.before, isTrue);
    });

    test('builders are immutable (each returns a new query)', () {
      final base = users();
      final filtered = base.where('a', isEqualTo: 1);
      expect(base.spec.where, isNull);
      expect(filtered.spec.where, isNotNull);
    });

    test('withConverter preserves the accumulated spec', () {
      final q = users().where('a', isEqualTo: 1).limit(5);
      final typed = q
          .withConverter(Converter<int>((d) => d['n'] as int, (v) => {'n': v}));
      expect(typed.spec.limit, 5);
      expect(typed.spec.where, isNotNull);
    });
  });

  // ===========================================================================
  // get()
  // ===========================================================================
  group('get()', () {
    test('sends query frame and parses docs as added changes', () async {
      h.handler = (f) => h.respond(f, {
            'documents': [
              wireDoc('users/u1', wireFields({'n': 1})),
              wireDoc('users/u2', wireFields({'n': 2})),
            ],
            'hasMore': true,
          });

      final snap = await users().orderBy('n').get();

      expect(h.lastRequest['type'], 'query');
      expect((h.lastRequest['query'] as Map)['collection'], 'users');

      expect(snap.docs.map((d) => d.id), ['u1', 'u2']);
      // hasMore is threaded from the server response through the effective view.
      expect(snap.hasMore, isTrue);
      expect(snap.docChanges.length, 2);
      expect(snap.docChanges.every((c) => c.type == DocumentChangeType.added),
          isTrue);
      expect(snap.docChanges[0].newIndex, 0);
      expect(snap.docChanges[1].newIndex, 1);
      expect(snap.docChanges[0].oldIndex, -1);
    });

    test('empty result set', () async {
      h.handler = (f) => h.respond(f, {'documents': <Object?>[]});
      final snap = await users().get();
      expect(snap.docs, isEmpty);
      expect(snap.hasMore, isFalse);
    });

    test('applies converter to result docs', () async {
      h.handler = (f) => h.respond(f, {
            'documents': [
              wireDoc('users/u1', wireFields({'n': 7}))
            ],
          });
      final typed = users()
          .withConverter(Converter<int>((d) => d['n'] as int, (v) => {'n': v}));
      final snap = await typed.get();
      expect(snap.docs.single.data(), 7);
    });
  });

  // ===========================================================================
  // select()
  // ===========================================================================
  group('select()', () {
    test(
        'select is NOT forwarded in the query frame (client-side projection only)',
        () async {
      h.handler = (f) => h.respond(f, {
            'documents': [
              wireDoc('users/u1', wireFields({'name': 'Alice'}))
            ],
            'hasMore': false,
          });

      await users()
          .where('age', isGreaterThan: 18)
          .select(['name'])
          .limit(5)
          .get();

      expect(h.lastRequest['type'], 'query');
      final query = h.lastRequest['query'] as Map<String, Object?>;
      // select is client-side only — must NOT appear on the wire.
      expect((query).containsKey('select'), isFalse);
      expect(query.containsKey('where'), isTrue);
      expect(query['limit'], 5);
    });

    test('select is preserved when later builders are called', () {
      final spec =
          users().select(['displayName', 'address.city']).limit(10).spec;
      expect(spec.select, ['displayName', 'address.city']);
      expect(spec.limit, 10);
    });

    test('select absent from spec when not called', () {
      expect(users().limit(5).spec.select, isNull);
    });
  });

  // ===========================================================================
  // count()
  // ===========================================================================
  group('count()', () {
    test('sends a count frame and returns the count', () async {
      h.handler = (f) => h.respond(f, {'count': 5});

      final n = await users().where('active', isEqualTo: true).count();
      expect(n, 5);

      expect(h.lastRequest['type'], 'count');
      final query = h.lastRequest['query'] as Map<String, Object?>;
      expect(query['collection'], 'users');
      expect(query.containsKey('where'), isTrue);
    });

    test('returns 0 when server returns count 0', () async {
      h.handler = (f) => h.respond(f, {'count': 0});
      expect(await users().count(), 0);
    });

    test('limit is permitted and forwarded in the query', () async {
      h.handler = (f) => h.respond(f, {'count': 3});
      final n = await users().limit(5).count();
      expect(n, 3);
      expect(h.lastRequest['type'], 'count');
      final query = h.lastRequest['query'] as Map<String, Object?>;
      expect(query['limit'], 5);
    });

    test('throws UnsupportedError when a cursor is set', () async {
      expect(
          () => users().startAt([1]).count(), throwsA(isA<UnsupportedError>()));
    });
  });
}
