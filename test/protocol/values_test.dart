import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:winche_database/src/core/values.dart';

void main() {
  test('numToValue maps int to IntegerValue and double to DoubleValue', () {
    expect(numToValue(5), const IntegerValue(5));
    expect(numToValue(2.5), const DoubleValue(2.5));
  });

  // ---------------------------------------------------------------------------
  // Round-trip tests — JSON fixtures lifted verbatim from PROTOCOL §1.2
  // ---------------------------------------------------------------------------
  group('round-trip — PROTOCOL §1.2 examples', () {
    void rt(String label, String wireJson) {
      test(label, () {
        final parsed = json.decode(wireJson) as Map<String, Object?>;
        final value = Value.fromJson(parsed);
        expect(json.encode(value.toJson()), equals(wireJson));
      });
    }

    rt('nullValue', '{"nullValue":null}');
    rt('booleanValue true', '{"booleanValue":true}');
    rt('integerValue string', '{"integerValue":"9007199254740993"}');
    rt('doubleValue number', '{"doubleValue":1.5}');
    rt('doubleValue NaN', '{"doubleValue":"NaN"}');
    rt('doubleValue Infinity', '{"doubleValue":"Infinity"}');
    rt('doubleValue -Infinity', '{"doubleValue":"-Infinity"}');
    rt('timestampValue', '{"timestampValue":"2026-06-07T12:34:56.000000Z"}');
    rt('stringValue', '{"stringValue":"hello"}');
    rt('bytesValue', '{"bytesValue":"SGVsbG8="}');
    rt('referenceValue', '{"referenceValue":"users/u1"}');
    rt(
      'geoPointValue',
      '{"geoPointValue":{"latitude":59.913,"longitude":10.752}}',
    );
    rt(
      'arrayValue with elements',
      '{"arrayValue":{"values":[{"integerValue":"1"},{"integerValue":"2"}]}}',
    );
    rt('arrayValue empty', '{"arrayValue":{}}');
    rt(
      'mapValue with fields',
      '{"mapValue":{"fields":{"city":{"stringValue":"Oslo"}}}}',
    );
    rt('mapValue empty', '{"mapValue":{}}');
  });

  // ---------------------------------------------------------------------------
  // int64 boundary
  // ---------------------------------------------------------------------------
  group('IntegerValue int64 boundary', () {
    test('max int64 round-trips', () {
      const max = 9223372036854775807; // dart VM: exact int64
      final v = IntegerValue(max);
      final json = v.toJson() as Map;
      expect(json['integerValue'], equals('9223372036854775807'));
      final back = Value.fromJson(json) as IntegerValue;
      expect(back.value, equals(max));
    });

    test('integerValue accepts numeric form', () {
      final v = Value.fromJson({'integerValue': 42});
      expect(v, isA<IntegerValue>());
      expect((v as IntegerValue).value, equals(42));
    });
  });

  // ---------------------------------------------------------------------------
  // Double specials
  // ---------------------------------------------------------------------------
  group('DoubleValue specials', () {
    test('NaN equality', () {
      expect(
          const DoubleValue(double.nan), equals(const DoubleValue(double.nan)));
    });

    test('Infinity', () {
      final v = Value.fromJson({'doubleValue': 'Infinity'}) as DoubleValue;
      expect(v.value, equals(double.infinity));
    });

    test('-Infinity', () {
      final v = Value.fromJson({'doubleValue': '-Infinity'}) as DoubleValue;
      expect(v.value, equals(double.negativeInfinity));
    });
  });

  // ---------------------------------------------------------------------------
  // Timestamp µs truncation
  // ---------------------------------------------------------------------------
  group('TimestampValue', () {
    test('microseconds preserved', () {
      final dt = DateTime.utc(2026, 6, 7, 12, 34, 56, 0, 123); // 123 µs
      final v = TimestampValue(dt);
      final wire = v.toJson() as Map;
      expect(wire['timestampValue'], equals('2026-06-07T12:34:56.000123Z'));
    });

    test('zero microseconds produces 000000', () {
      final dt = DateTime.utc(2026, 6, 7, 12, 34, 56);
      final v = TimestampValue(dt);
      final wire = v.toJson() as Map;
      expect(wire['timestampValue'], equals('2026-06-07T12:34:56.000000Z'));
    });

    test('parse round-trip', () {
      const s = '2026-06-07T12:34:56.000000Z';
      final v = TimestampValue.parse(s);
      expect((v.toJson() as Map)['timestampValue'], equals(s));
    });

    test('invalid timestamp string throws FormatException', () {
      expect(() => Value.fromJson({'timestampValue': 'not-a-date'}),
          throwsFormatException);
    });
  });

  // ---------------------------------------------------------------------------
  // BytesValue
  // ---------------------------------------------------------------------------
  group('BytesValue', () {
    test('round-trip Hello bytes', () {
      final bytes = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      final v = BytesValue(bytes);
      final wire = v.toJson() as Map;
      expect(wire['bytesValue'], equals('SGVsbG8='));
      final back = Value.fromJson(wire) as BytesValue;
      expect(back.value, equals(bytes));
    });

    test('equality by content', () {
      final a = BytesValue(Uint8List.fromList([1, 2, 3]));
      final b = BytesValue(Uint8List.fromList([1, 2, 3]));
      expect(a, equals(b));
    });
  });

  // ---------------------------------------------------------------------------
  // Strictness rejections
  // ---------------------------------------------------------------------------
  group('strictness', () {
    test('nullValue with non-null payload throws', () {
      expect(
          () => Value.fromJson({'nullValue': 'oops'}), throwsFormatException);
    });

    test('unknown tag throws', () {
      expect(
          () => Value.fromJson({'unknownTag': 'foo'}), throwsFormatException);
    });

    test('multiple keys throws', () {
      expect(
        () => Value.fromJson({'nullValue': null, 'booleanValue': true}),
        throwsFormatException,
      );
    });

    test('zero keys throws', () {
      expect(() => Value.fromJson(<String, Object?>{}), throwsFormatException);
    });

    test('bad base64 throws', () {
      expect(() => Value.fromJson({'bytesValue': '!!!not base64!!!'}),
          throwsFormatException);
    });

    test('non-Map input throws', () {
      expect(() => Value.fromJson('string'), throwsFormatException);
      expect(() => Value.fromJson(42), throwsFormatException);
      expect(() => Value.fromJson(null), throwsFormatException);
    });

    test('integerValue bad string throws', () {
      expect(
          () => Value.fromJson({'integerValue': 'abc'}), throwsFormatException);
    });

    test('doubleValue bad string throws', () {
      expect(
          () => Value.fromJson({'doubleValue': 'bad'}), throwsFormatException);
    });
  });

  // ---------------------------------------------------------------------------
  // Deep equality — nested array/map
  // ---------------------------------------------------------------------------
  group('deep equality', () {
    test('nested array/map equality', () {
      final a = MapValue({
        'x': ArrayValue([IntegerValue(1), StringValue('hi')]),
        'y': MapValue({'z': BooleanValue(true)}),
      });
      final b = MapValue({
        'x': ArrayValue([IntegerValue(1), StringValue('hi')]),
        'y': MapValue({'z': BooleanValue(true)}),
      });
      expect(a, equals(b));
    });

    test('nested array/map inequality', () {
      final a = MapValue({'x': IntegerValue(1)});
      final b = MapValue({'x': IntegerValue(2)});
      expect(a, isNot(equals(b)));
    });

    test('MapValue hashCode is order-independent', () {
      // Build two MapValues with the same entries inserted in different order.
      final a = MapValue({
        'alpha': IntegerValue(1),
        'beta': StringValue('hello'),
      });
      final b = MapValue({
        'beta': StringValue('hello'),
        'alpha': IntegerValue(1),
      });
      // Must be equal (this already passes).
      expect(a, equals(b));
      // hashCode must also match (this is the regression).
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  // ---------------------------------------------------------------------------
  // DeleteFieldValue sentinel
  // ---------------------------------------------------------------------------
  group('DeleteFieldValue', () {
    test('toJson emits deleteField: true', () {
      const v = DeleteFieldValue();
      expect(v.toJson(), equals({'deleteField': true}));
    });

    test('fromJson parses deleteField', () {
      final v = Value.fromJson({'deleteField': true});
      expect(v, isA<DeleteFieldValue>());
    });

    test('equality', () {
      expect(const DeleteFieldValue(), equals(const DeleteFieldValue()));
    });
  });
}
