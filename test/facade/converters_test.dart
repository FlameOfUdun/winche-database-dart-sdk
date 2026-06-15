import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  // ---------------------------------------------------------------------------
  // toValue — native → tagged Value
  // ---------------------------------------------------------------------------
  group('toValue', () {
    test('null → NullValue', () {
      expect(toValue(null), const NullValue());
    });

    test('bool → BooleanValue', () {
      expect(toValue(true), const BooleanValue(true));
      expect(toValue(false), const BooleanValue(false));
    });

    test('int → IntegerValue', () {
      expect(toValue(42), const IntegerValue(42));
      expect(toValue(-7), const IntegerValue(-7));
    });

    test('double → DoubleValue', () {
      expect(toValue(3.5), const DoubleValue(3.5));
    });

    test('String → StringValue', () {
      expect(toValue('hi'), const StringValue('hi'));
    });

    test('DateTime → TimestampValue (coerced to UTC)', () {
      final local = DateTime(2026, 1, 2, 3, 4, 5);
      final v = toValue(local) as TimestampValue;
      expect(v.value.isUtc, isTrue);
      expect(v.value, local.toUtc());
    });

    test('Uint8List → BytesValue', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(toValue(bytes), BytesValue(bytes));
    });

    test('GeoPoint → GeoPointValue', () {
      expect(
          toValue(const GeoPoint(1.5, -2.5)), const GeoPointValue(1.5, -2.5));
    });

    test('List → ArrayValue (recursive)', () {
      expect(
        toValue([1, 'a', true]),
        const ArrayValue([
          IntegerValue(1),
          StringValue('a'),
          BooleanValue(true),
        ]),
      );
    });

    test('Map → MapValue (recursive)', () {
      expect(
        toValue({'a': 1, 'b': 'x'}),
        const MapValue({'a': IntegerValue(1), 'b': StringValue('x')}),
      );
    });

    test('empty Map → empty MapValue', () {
      expect(toValue(<String, Object?>{}), const MapValue({}));
    });

    test('Value passthrough (escape hatch)', () {
      const v = StringValue('already');
      expect(identical(toValue(v), v), isTrue);
    });

    test('nested map/list mix', () {
      final v = toValue({
        'nums': [1, 2],
        'meta': {'ok': true},
      });
      expect(
        v,
        const MapValue({
          'nums': ArrayValue([IntegerValue(1), IntegerValue(2)]),
          'meta': MapValue({'ok': BooleanValue(true)}),
        }),
      );
    });

    test('unsupported type throws ArgumentError with key path', () {
      expect(
        () => toValue({'bad': Object()}, keyPath: ''),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('bad'))),
      );
    });

    test('dotted key in nested map context throws ArgumentError', () {
      expect(
        () => toValue({'a.b': 1}),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('dot'))),
      );
    });

    test('FieldValue sentinel inside a List throws ArgumentError', () {
      expect(
        () => toValue([FieldValue.increment(1)]),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('List'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fromValue — tagged Value → native
  // ---------------------------------------------------------------------------
  group('fromValue', () {
    test('all scalar tags map back to native', () {
      expect(fromValue(const NullValue()), isNull);
      expect(fromValue(const BooleanValue(true)), isTrue);
      expect(fromValue(const IntegerValue(9)), 9);
      expect(fromValue(const DoubleValue(1.25)), 1.25);
      expect(fromValue(const StringValue('s')), 's');
    });

    test('TimestampValue → UTC DateTime', () {
      final dt = DateTime.utc(2026, 6, 8, 10);
      final native = fromValue(TimestampValue(dt));
      expect(native, isA<DateTime>());
      expect((native as DateTime).isUtc, isTrue);
      expect(native, dt);
    });

    test('BytesValue → Uint8List', () {
      final bytes = Uint8List.fromList([9, 8, 7]);
      expect(fromValue(BytesValue(bytes)), bytes);
    });

    test('GeoPointValue → GeoPoint', () {
      expect(
          fromValue(const GeoPointValue(3.0, 4.0)), const GeoPoint(3.0, 4.0));
    });

    test('ReferenceValue → path string', () {
      expect(fromValue(const ReferenceValue('users/u1')), 'users/u1');
    });

    test('ArrayValue → List', () {
      expect(
        fromValue(const ArrayValue([IntegerValue(1), StringValue('a')])),
        [1, 'a'],
      );
    });

    test('MapValue → Map', () {
      expect(
        fromValue(const MapValue({'k': IntegerValue(5)})),
        {'k': 5},
      );
    });

    test('DeleteFieldValue cannot be read back', () {
      expect(
        () => fromValue(const DeleteFieldValue()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('round trip', () {
    test('native → Value → native preserves data', () {
      final original = {
        'n': 1,
        'd': 2.5,
        's': 'x',
        'b': true,
        'arr': [1, 2, 3],
        'nested': {'deep': 'value'},
        'when': DateTime.utc(2026, 6, 8),
      };
      final round = fromValue(toValue(original)) as Map<String, Object?>;
      expect(round, original);
    });
  });

  // ---------------------------------------------------------------------------
  // splitWriteData — set() semantics
  // ---------------------------------------------------------------------------
  group('splitWriteData', () {
    test('plain fields, no transforms', () {
      final (fields, transforms) = splitWriteData({'a': 1, 'b': 'x'});
      expect(transforms, isEmpty);
      expect(fields, {'a': const IntegerValue(1), 'b': const StringValue('x')});
    });

    test('nested map becomes MapValue', () {
      final (fields, _) = splitWriteData({
        'm': {'x': 1},
      });
      expect(fields['m'], const MapValue({'x': IntegerValue(1)}));
    });

    test('empty nested map emits MapValue({})', () {
      final (fields, _) = splitWriteData({'m': <String, Object?>{}});
      expect(fields['m'], const MapValue({}));
    });

    test('delete sentinel → DeleteFieldValue in fields', () {
      final (fields, transforms) =
          splitWriteData({'gone': FieldValue.delete()});
      expect(fields['gone'], const DeleteFieldValue());
      expect(transforms, isEmpty);
    });

    test('serverTimestamp sentinel → transform, not in fields', () {
      final (fields, transforms) =
          splitWriteData({'ts': FieldValue.serverTimestamp()});
      expect(fields.containsKey('ts'), isFalse);
      expect(transforms.single.field, 'ts');
      expect(transforms.single.kind, TransformKind.serverTimestamp);
    });

    test('increment sentinel carries int operand', () {
      final (_, transforms) = splitWriteData({'n': FieldValue.increment(3)});
      expect(transforms.single.kind, TransformKind.increment);
      expect(transforms.single.operand, const IntegerValue(3));
    });

    test('increment with double operand', () {
      final (_, transforms) = splitWriteData({'n': FieldValue.increment(1.5)});
      expect(transforms.single.operand, const DoubleValue(1.5));
    });

    test('arrayUnion/arrayRemove carry ArrayValue operands', () {
      final (_, union) = splitWriteData({
        'tags': FieldValue.arrayUnion(['a', 'b']),
      });
      expect(union.single.kind, TransformKind.arrayUnion);
      expect(union.single.operand,
          const ArrayValue([StringValue('a'), StringValue('b')]));

      final (_, remove) = splitWriteData({
        'tags': FieldValue.arrayRemove(['c']),
      });
      expect(remove.single.kind, TransformKind.arrayRemove);
    });

    test('nested sentinel collected with dotted field path', () {
      final (fields, transforms) = splitWriteData({
        'counter': {'value': FieldValue.increment(1)},
      });
      expect(transforms.single.field, 'counter.value');
      // The non-sentinel content of the nested map is empty, so no MapValue.
      expect(fields.containsKey('counter'), isFalse);
    });

    test('top-level dotted key throws (set context)', () {
      expect(
        () => splitWriteData({'a.b': 1}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('sentinel inside list value throws', () {
      expect(
        () => splitWriteData({
          'arr': [FieldValue.increment(1)],
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // splitUpdateData — update() semantics
  // ---------------------------------------------------------------------------
  group('splitUpdateData', () {
    test('top-level dotted keys are allowed (field paths)', () {
      final (fields, _) = splitUpdateData({'a.b': 1});
      expect(fields, {'a.b': const IntegerValue(1)});
    });

    test('top-level dotted delete sentinel allowed', () {
      final (fields, _) = splitUpdateData({'a.b': FieldValue.delete()});
      expect(fields['a.b'], const DeleteFieldValue());
    });

    test('nested non-delete map becomes MapValue', () {
      final (fields, _) = splitUpdateData({
        'm': {'x': 1},
      });
      expect(fields['m'], const MapValue({'x': IntegerValue(1)}));
    });

    test('nested transform extracted with dotted path', () {
      final (_, transforms) = splitUpdateData({
        'm': {'n': FieldValue.increment(2)},
      });
      expect(transforms.single.field, 'm.n');
    });

    test('nested delete sentinel inside a map throws', () {
      expect(
        () => splitUpdateData({
          'm': {'x': FieldValue.delete()},
        }),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', contains('top-level dotted keys'))),
      );
    });

    test('empty nested map emits MapValue({})', () {
      final (fields, _) = splitUpdateData({'m': <String, Object?>{}});
      expect(fields['m'], const MapValue({}));
    });
  });
}
