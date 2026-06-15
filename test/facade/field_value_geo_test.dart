import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  // ---------------------------------------------------------------------------
  // FieldValue factories → concrete sentinel subtypes
  // ---------------------------------------------------------------------------
  group('FieldValue factories', () {
    test('delete() → DeleteSentinel', () {
      expect(FieldValue.delete(), isA<DeleteSentinel>());
    });

    test('serverTimestamp() → ServerTimestampSentinel', () {
      expect(FieldValue.serverTimestamp(), isA<ServerTimestampSentinel>());
    });

    test('increment() → IncrementSentinel carrying delta', () {
      final s = FieldValue.increment(5) as IncrementSentinel;
      expect(s.delta, 5);
    });

    test('maximum() → MaximumSentinel carrying value', () {
      final s = FieldValue.maximum(9) as MaximumSentinel;
      expect(s.value, 9);
    });

    test('minimum() → MinimumSentinel carrying value', () {
      final s = FieldValue.minimum(-3) as MinimumSentinel;
      expect(s.value, -3);
    });

    test('arrayUnion() → ArrayUnionSentinel carrying values', () {
      final s = FieldValue.arrayUnion(['a', 'b']) as ArrayUnionSentinel;
      expect(s.values, ['a', 'b']);
    });

    test('arrayRemove() → ArrayRemoveSentinel carrying values', () {
      final s = FieldValue.arrayRemove([1, 2]) as ArrayRemoveSentinel;
      expect(s.values, [1, 2]);
    });
  });

  group('FieldValue toString', () {
    test('renders sentinel kind and operands', () {
      expect(FieldValue.delete().toString(), 'FieldValue.delete()');
      expect(FieldValue.serverTimestamp().toString(),
          'FieldValue.serverTimestamp()');
      expect(FieldValue.increment(2).toString(), 'FieldValue.increment(2)');
      expect(FieldValue.maximum(4).toString(), 'FieldValue.maximum(4)');
      expect(FieldValue.minimum(1).toString(), 'FieldValue.minimum(1)');
      expect(FieldValue.arrayUnion(['x']).toString(),
          'FieldValue.arrayUnion([x])');
      expect(FieldValue.arrayRemove(['y']).toString(),
          'FieldValue.arrayRemove([y])');
    });
  });

  // ---------------------------------------------------------------------------
  // GeoPoint
  // ---------------------------------------------------------------------------
  group('GeoPoint', () {
    test('stores latitude/longitude', () {
      const g = GeoPoint(12.5, -34.25);
      expect(g.latitude, 12.5);
      expect(g.longitude, -34.25);
    });

    test('value equality and hashCode', () {
      expect(const GeoPoint(1.0, 2.0), const GeoPoint(1.0, 2.0));
      expect(
          const GeoPoint(1.0, 2.0).hashCode, const GeoPoint(1.0, 2.0).hashCode);
    });

    test('inequality on differing coordinates', () {
      expect(const GeoPoint(1.0, 2.0), isNot(const GeoPoint(1.0, 2.1)));
      expect(const GeoPoint(1.0, 2.0), isNot(const GeoPoint(9.0, 2.0)));
    });

    test('identical is equal', () {
      const g = GeoPoint(1.0, 2.0);
      expect(g == g, isTrue);
    });

    test('toString', () {
      expect(const GeoPoint(1.0, 2.0).toString(), 'GeoPoint(1.0, 2.0)');
    });
  });
}
