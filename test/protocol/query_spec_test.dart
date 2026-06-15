import 'package:test/test.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/query_spec.dart';

void main() {
  // ---------------------------------------------------------------------------
  // QuerySpec wire shape — PROTOCOL §4.1
  // ---------------------------------------------------------------------------
  group('QuerySpec', () {
    test('collection only', () {
      final q = QuerySpec('users');
      final j = q.toJson();
      expect(j['collection'], equals('users'));
      expect(j.containsKey('where'), isFalse);
      expect(j.containsKey('orderBy'), isFalse);
      expect(j.containsKey('limit'), isFalse);
    });

    test('full query — PROTOCOL §4.1 example', () {
      final q = QuerySpec(
        'users',
        where: FilterSpec.field('score', FieldOp.gte, IntegerValue(50)),
        orderBy: [OrderSpec('score', direction: SortDirection.desc)],
        limit: 10,
        start: CursorSpec([IntegerValue(100), StringValue('users/u5')],
            before: true),
        end: CursorSpec([IntegerValue(50)], before: false),
      );
      final j = q.toJson();
      expect(j['collection'], equals('users'));
      expect(j['limit'], equals(10));
      final where = j['where'] as Map<String, Object?>;
      expect(where['op'], equals('gte'));
      final orderBy = j['orderBy'] as List<Object?>;
      expect((orderBy[0] as Map<String, Object?>)['direction'], equals('desc'));
      final start = j['start'] as Map<String, Object?>;
      expect(start['before'], equals(true));
      final end = j['end'] as Map<String, Object?>;
      expect(end['before'], equals(false));
    });
  });

  // ---------------------------------------------------------------------------
  // FilterSpec — all operator kinds, PROTOCOL §4.2 + §4.3
  // ---------------------------------------------------------------------------
  group('FilterSpec', () {
    test('field filter eq — PROTOCOL §4.2', () {
      final f = FilterSpec.field('status', FieldOp.eq, StringValue('active'));
      final j = f.toJson();
      expect(j['field'], equals('status'));
      expect(j['op'], equals('eq'));
      expect(j['value'], equals({'stringValue': 'active'}));
    });

    test('all 15 field operators emit correct wire strings', () {
      const ops = [
        (FieldOp.eq, 'eq'),
        (FieldOp.ne, 'ne'),
        (FieldOp.gt, 'gt'),
        (FieldOp.gte, 'gte'),
        (FieldOp.lt, 'lt'),
        (FieldOp.lte, 'lte'),
        (FieldOp.inOp, 'in'),
        (FieldOp.notIn, 'notIn'),
        (FieldOp.arrayContains, 'arrayContains'),
        (FieldOp.arrayContainsAny, 'arrayContainsAny'),
        (FieldOp.arrayContainsAll, 'arrayContainsAll'),
        (FieldOp.contains, 'contains'),
        (FieldOp.startsWith, 'startsWith'),
        (FieldOp.endsWith, 'endsWith'),
        (FieldOp.regex, 'regex'),
      ];
      for (final (op, wire) in ops) {
        final f = FilterSpec.field('x', op, IntegerValue(0));
        expect(
          (f.toJson())['op'],
          equals(wire),
          reason: 'FieldOp.$op should emit "$wire"',
        );
      }
    });

    test('all 3 unary operators emit correct wire strings', () {
      const ops = [
        (UnaryOp.isNull, 'isNull'),
        (UnaryOp.isNan, 'isNan'),
        (UnaryOp.exists, 'exists'),
      ];
      for (final (op, wire) in ops) {
        final f = FilterSpec.unary('field', op);
        final j = f.toJson();
        expect(j['unary'], equals(wire),
            reason: 'UnaryOp.$op should emit "$wire"');
        expect(j['field'], equals('field'));
      }
    });

    test('composite AND — PROTOCOL §4.2', () {
      final f = FilterSpec.and([
        FilterSpec.field('status', FieldOp.eq, StringValue('active')),
        FilterSpec.field('score', FieldOp.gt, IntegerValue(100)),
      ]);
      final j = f.toJson();
      final and = j['and'] as List<Object?>;
      expect(and.length, equals(2));
    });

    test('composite OR — PROTOCOL §4.2', () {
      final f = FilterSpec.or([
        FilterSpec.field('a', FieldOp.eq, IntegerValue(1)),
      ]);
      expect(f.toJson().containsKey('or'), isTrue);
    });

    test('NOT filter — PROTOCOL §4.2', () {
      final f = FilterSpec.not(
        FilterSpec.field('deleted', FieldOp.eq, BooleanValue(true)),
      );
      final j = f.toJson();
      expect(j.containsKey('not'), isTrue);
      expect((j['not'] as Map<String, Object?>)['field'], equals('deleted'));
    });

    test('field-compare filter — PROTOCOL §4.2', () {
      final f = FilterSpec.compare('start', FieldOp.lt, 'end');
      final j = f.toJson();
      final cmp = j['compare'] as Map<String, Object?>;
      expect(cmp['left'], equals('start'));
      expect(cmp['op'], equals('lt'));
      expect(cmp['right'], equals('end'));
    });

    test('unary isNull — PROTOCOL §4.2 example', () {
      final f = FilterSpec.unary('nickname', UnaryOp.isNull);
      final j = f.toJson();
      expect(j['unary'], equals('isNull'));
      expect(j['field'], equals('nickname'));
    });

    test('unary isNan — PROTOCOL §4.2 example', () {
      final f = FilterSpec.unary('ratio', UnaryOp.isNan);
      expect((f.toJson())['unary'], equals('isNan'));
    });

    test('unary exists — PROTOCOL §4.2 example', () {
      final f = FilterSpec.unary('email', UnaryOp.exists);
      expect((f.toJson())['unary'], equals('exists'));
    });
  });

  // ---------------------------------------------------------------------------
  // OrderSpec — PROTOCOL §4.4
  // ---------------------------------------------------------------------------
  group('OrderSpec', () {
    test('asc (default)', () {
      final o = OrderSpec('name');
      expect(o.toJson()['direction'], equals('asc'));
    });

    test('desc', () {
      final o = OrderSpec('score', direction: SortDirection.desc);
      expect(o.toJson()['direction'], equals('desc'));
    });
  });

  // ---------------------------------------------------------------------------
  // select / copyWith — PROTOCOL §4.1 extension
  // ---------------------------------------------------------------------------
  group('select and copyWith', () {
    test(
        'select is NOT on the wire (client-side only); field is still populated',
        () {
      final withSel =
          QuerySpec('users', select: ['displayName', 'address.city']);
      expect(withSel.toJson().containsKey('select'), isFalse);
      expect(withSel.select, ['displayName', 'address.city']);
      expect(QuerySpec('users').toJson().containsKey('select'), isFalse);
    });

    test('select is NOT serialized (projection is client-side only)', () {
      final spec = QuerySpec('users', select: ['name', 'address.city']);
      final json = spec.toJson();
      expect(json.containsKey('select'), isFalse);
      expect(spec.select,
          ['name', 'address.city']); // field still set, just not on the wire
    });

    test('copyWith preserves select and overrides only the given fields', () {
      final base = QuerySpec('users', select: ['a'], limit: 5);
      final next = base.copyWith(limit: 10);
      expect(next.select, ['a']);
      expect(next.limit, 10);
    });
  });

  // ---------------------------------------------------------------------------
  // CursorSpec — PROTOCOL §4.5
  // ---------------------------------------------------------------------------
  group('CursorSpec', () {
    test('startAt (before: true) — PROTOCOL §4.5', () {
      final c = CursorSpec(
        [IntegerValue(100), StringValue('users/u5')],
        before: true,
      );
      final j = c.toJson();
      expect(j['before'], equals(true));
      final values = j['values'] as List<Object?>;
      expect(values.length, equals(2));
      expect(values[0], equals({'integerValue': '100'}));
    });

    test('endAt (before: false) — PROTOCOL §4.5', () {
      final c = CursorSpec([IntegerValue(50)], before: false);
      expect(c.toJson()['before'], equals(false));
    });
  });
}
