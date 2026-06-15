import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:winche_database/src/core/value_order.dart';
import 'package:winche_database/src/core/values.dart';

void main() {
  group('cross-type ordering (TypeRank)', () {
    final ascending = <Value>[
      const NullValue(),
      const BooleanValue(false),
      const BooleanValue(true),
      const DoubleValue(double.nan),
      const DoubleValue(-1.5),
      const IntegerValue(0),
      const IntegerValue(5),
      TimestampValue(DateTime.utc(2026, 1, 1)),
      const StringValue('a'),
      const StringValue('b'),
      BytesValue(Uint8List.fromList([1])),
      const ReferenceValue('users/a'),
      const GeoPointValue(1.0, 2.0),
      const ArrayValue([IntegerValue(1)]),
      const MapValue({'a': IntegerValue(1)}),
    ];

    test('ranks order strictly ascending', () {
      for (var i = 0; i < ascending.length - 1; i++) {
        expect(compareValues(ascending[i], ascending[i + 1]), lessThan(0),
            reason: '${ascending[i]} should sort before ${ascending[i + 1]}');
        expect(compareValues(ascending[i + 1], ascending[i]), greaterThan(0));
      }
    });

    test('NaN sorts before all finite numbers', () {
      expect(
          compareValues(const DoubleValue(double.nan), const IntegerValue(-99)),
          lessThan(0));
    });
  });

  group('numeric equality', () {
    test('int 5 equals double 5.0', () {
      expect(compareValues(const IntegerValue(5), const DoubleValue(5.0)), 0);
      expect(
          valueEquals(const IntegerValue(5), const DoubleValue(5.0)), isTrue);
    });
    test('-0.0 equals 0.0', () {
      expect(compareValues(const DoubleValue(-0.0), const DoubleValue(0.0)), 0);
    });
    test('NaN equals NaN (typed equality)', () {
      expect(
          valueEquals(
              const DoubleValue(double.nan), const DoubleValue(double.nan)),
          isTrue);
    });
  });

  group('within-type ordering', () {
    test('strings use code-point (UTF-8) order', () {
      expect(compareValues(const StringValue('Z'), const StringValue('a')),
          lessThan(0)); // 'Z'(0x5A) < 'a'(0x61)
    });
    test('bytes use unsigned lexicographic order', () {
      expect(
          compareValues(BytesValue(Uint8List.fromList([1, 2])),
              BytesValue(Uint8List.fromList([1, 2, 0]))),
          lessThan(0)); // shorter prefix first
      expect(
          compareValues(BytesValue(Uint8List.fromList([200])),
              BytesValue(Uint8List.fromList([1]))),
          greaterThan(0)); // unsigned
    });
    test('arrays compare element-wise, shorter prefix first', () {
      expect(
          compareValues(const ArrayValue([IntegerValue(1)]),
              const ArrayValue([IntegerValue(1), IntegerValue(0)])),
          lessThan(0));
      expect(
          compareValues(const ArrayValue([IntegerValue(1), IntegerValue(2)]),
              const ArrayValue([IntegerValue(1), IntegerValue(3)])),
          lessThan(0));
    });
    test('maps compare interleaved key,value; shorter wins on prefix tie', () {
      expect(
          compareValues(
              const MapValue({'a': IntegerValue(1), 'b': IntegerValue(0)}),
              const MapValue({'a': IntegerValue(2)})),
          lessThan(0));
      expect(
          compareValues(const MapValue({'a': IntegerValue(1)}),
              const MapValue({'a': IntegerValue(1), 'b': IntegerValue(0)})),
          lessThan(0));
    });
    test('geopoint compares latitude then longitude', () {
      expect(
          compareValues(
              const GeoPointValue(1.0, 9.0), const GeoPointValue(2.0, 0.0)),
          lessThan(0));
      expect(
          compareValues(
              const GeoPointValue(1.0, 1.0), const GeoPointValue(1.0, 2.0)),
          lessThan(0));
    });
  });

  group('sameTypeClass', () {
    test('int and double share the number class', () {
      expect(
          sameTypeClass(const IntegerValue(1), const DoubleValue(2.0)), isTrue);
      expect(
          sameTypeClass(const IntegerValue(1), const DoubleValue(double.nan)),
          isTrue);
    });
    test('number and string are different classes', () {
      expect(sameTypeClass(const IntegerValue(1), const StringValue('1')),
          isFalse);
    });
  });
}
