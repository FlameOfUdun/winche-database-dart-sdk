import 'package:test/test.dart';
import 'package:winche_database/src/offline/filter_eval.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';
import 'package:winche_database/src/core/values.dart';

WireDocument doc(Map<String, Value> fields) => WireDocument(
    path: 'c/d',
    id: 'd',
    collection: 'c',
    fields: fields,
    createTime: 'T',
    updateTime: 'T',
    version: 1);

bool match(WireDocument d, FilterSpec f) => matchesFilter(d, f.toJson());

void main() {
  test('resolveField maps __name__ to the document reference', () {
    expect(
        resolveField(doc(const {}), '__name__'), const ReferenceValue('c/d'));
  });

  final alice = doc({
    'name': const StringValue('Alice'),
    'age': const IntegerValue(30),
    'tags': const ArrayValue([StringValue('x'), StringValue('y')]),
    'score': const DoubleValue(4.5),
    'nick': const NullValue(),
  });

  group('field operators', () {
    test('eq with cross-type numeric', () {
      expect(
          match(alice,
              FilterSpec.field('age', FieldOp.eq, const DoubleValue(30.0))),
          isTrue);
    });
    test('ne (present + not equal); missing field does not match', () {
      expect(
          match(alice,
              FilterSpec.field('age', FieldOp.ne, const IntegerValue(31))),
          isTrue);
      expect(
          match(alice,
              FilterSpec.field('absent', FieldOp.ne, const IntegerValue(1))),
          isFalse);
    });
    test('gt/gte/lt/lte are same-type-class only', () {
      expect(
          match(alice,
              FilterSpec.field('age', FieldOp.gt, const IntegerValue(18))),
          isTrue);
      expect(
          match(alice,
              FilterSpec.field('age', FieldOp.lte, const IntegerValue(30))),
          isTrue);
      expect(
          match(alice,
              FilterSpec.field('name', FieldOp.gt, const IntegerValue(0))),
          isFalse);
    });
    test('in / notIn', () {
      expect(
          match(
              alice,
              FilterSpec.field('age', FieldOp.inOp,
                  const ArrayValue([IntegerValue(30), IntegerValue(40)]))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field(
                  'age', FieldOp.notIn, const ArrayValue([IntegerValue(40)]))),
          isTrue);
    });
    test('arrayContains / Any / All', () {
      expect(
          match(
              alice,
              FilterSpec.field(
                  'tags', FieldOp.arrayContains, const StringValue('x'))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field('tags', FieldOp.arrayContainsAny,
                  const ArrayValue([StringValue('z'), StringValue('y')]))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field('tags', FieldOp.arrayContainsAll,
                  const ArrayValue([StringValue('x'), StringValue('y')]))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field('tags', FieldOp.arrayContainsAll,
                  const ArrayValue([StringValue('x'), StringValue('z')]))),
          isFalse);
    });
    test('string contains/startsWith/endsWith/regex (case-sensitive)', () {
      expect(
          match(
              alice,
              FilterSpec.field(
                  'name', FieldOp.contains, const StringValue('lic'))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field(
                  'name', FieldOp.startsWith, const StringValue('Al'))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field(
                  'name', FieldOp.endsWith, const StringValue('ce'))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field(
                  'name', FieldOp.regex, const StringValue('^A.*e\$'))),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.field(
                  'name', FieldOp.contains, const StringValue('LIC'))),
          isFalse);
    });
  });

  group('unary operators', () {
    test('isNull / isNan / exists', () {
      expect(match(alice, FilterSpec.unary('nick', UnaryOp.isNull)), isTrue);
      expect(match(alice, FilterSpec.unary('age', UnaryOp.isNull)), isFalse);
      expect(
          match(doc({'r': const DoubleValue(double.nan)}),
              FilterSpec.unary('r', UnaryOp.isNan)),
          isTrue);
      expect(match(alice, FilterSpec.unary('age', UnaryOp.exists)), isTrue);
      expect(match(alice, FilterSpec.unary('absent', UnaryOp.exists)), isFalse);
      expect(match(alice, FilterSpec.unary('nick', UnaryOp.exists)), isTrue);
    });
  });

  group('composite + compare', () {
    test('and / or / not', () {
      expect(
          match(
              alice,
              FilterSpec.and([
                FilterSpec.field('age', FieldOp.gte, const IntegerValue(18)),
                FilterSpec.field(
                    'name', FieldOp.eq, const StringValue('Alice')),
              ])),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.or([
                FilterSpec.field('age', FieldOp.gt, const IntegerValue(99)),
                FilterSpec.field(
                    'name', FieldOp.eq, const StringValue('Alice')),
              ])),
          isTrue);
      expect(
          match(
              alice,
              FilterSpec.not(
                  FilterSpec.field('age', FieldOp.eq, const IntegerValue(30)))),
          isFalse);
    });
    test('field-compare filter (field vs field)', () {
      final d =
          doc({'start': const IntegerValue(1), 'end': const IntegerValue(5)});
      expect(match(d, FilterSpec.compare('start', FieldOp.lt, 'end')), isTrue);
      expect(match(d, FilterSpec.compare('end', FieldOp.lt, 'start')), isFalse);
    });
  });

  group('NaN inequality (unordered)', () {
    final nanDoc = doc({'r': const DoubleValue(double.nan)});
    test('NaN field never satisfies lt/lte/gt/gte against a finite number', () {
      expect(
          match(
              nanDoc, FilterSpec.field('r', FieldOp.lt, const IntegerValue(5))),
          isFalse);
      expect(
          match(nanDoc,
              FilterSpec.field('r', FieldOp.lte, const IntegerValue(5))),
          isFalse);
      expect(
          match(
              nanDoc, FilterSpec.field('r', FieldOp.gt, const IntegerValue(5))),
          isFalse);
      expect(
          match(nanDoc,
              FilterSpec.field('r', FieldOp.gte, const IntegerValue(5))),
          isFalse);
    });
    test('a finite field never satisfies an inequality against a NaN operand',
        () {
      final five = doc({'n': const IntegerValue(5)});
      expect(
          match(five,
              FilterSpec.field('n', FieldOp.gt, const DoubleValue(double.nan))),
          isFalse);
      expect(
          match(five,
              FilterSpec.field('n', FieldOp.lt, const DoubleValue(double.nan))),
          isFalse);
    });
    test('NaN eq NaN is still true (typed equality)', () {
      expect(
          match(nanDoc,
              FilterSpec.field('r', FieldOp.eq, const DoubleValue(double.nan))),
          isTrue);
    });
  });

  group('compare eq/ne (field vs field)', () {
    test('compare eq with cross-type numeric, and ne', () {
      final d = doc({
        'a': const IntegerValue(5),
        'b': const DoubleValue(5.0),
        'c': const IntegerValue(6)
      });
      expect(match(d, FilterSpec.compare('a', FieldOp.eq, 'b')), isTrue);
      expect(match(d, FilterSpec.compare('a', FieldOp.ne, 'c')), isTrue);
      expect(match(d, FilterSpec.compare('a', FieldOp.eq, 'c')), isFalse);
    });
  });

  group('__name__ pseudo-field', () {
    final d = doc({'n': const IntegerValue(1)}); // path 'c/d'
    test('eq on __name__ matches by path', () {
      expect(
          match(
              d,
              FilterSpec.field(
                  '__name__', FieldOp.eq, const StringValue('c/d'))),
          isTrue);
      expect(
          match(
              d,
              FilterSpec.field(
                  '__name__', FieldOp.eq, const StringValue('c/x'))),
          isFalse);
    });
    test('whereIn/notIn on __name__ match by path', () {
      expect(
          match(
              d,
              FilterSpec.field('__name__', FieldOp.inOp,
                  const ArrayValue([StringValue('c/d'), StringValue('c/x')]))),
          isTrue);
      expect(
          match(
              d,
              FilterSpec.field('__name__', FieldOp.notIn,
                  const ArrayValue([StringValue('c/x')]))),
          isTrue);
    });
  });
}
