import 'package:test/test.dart';
import 'package:winche_database/src/core/field_path.dart';
import 'package:winche_database/src/core/values.dart';

void main() {
  group('resolvePath', () {
    test('resolves a top-level field', () {
      expect(resolvePath({'n': const IntegerValue(1)}, 'n'),
          const IntegerValue(1));
    });

    test('resolves a dotted nested field', () {
      final fields = {
        'a': const MapValue({'b': IntegerValue(2)})
      };
      expect(resolvePath(fields, 'a.b'), const IntegerValue(2));
    });

    test('missing field or non-map traversal returns null', () {
      expect(resolvePath(const {}, 'x'), isNull);
      expect(resolvePath({'a': const IntegerValue(1)}, 'a.b'), isNull);
    });

    test('a present null field resolves to NullValue (not missing)', () {
      expect(resolvePath({'x': const NullValue()}, 'x'), const NullValue());
    });
  });

  group('setPath', () {
    test('sets a top-level field', () {
      final root = <String, Value>{};
      setPath(root, 'n', const IntegerValue(7));
      expect(root['n'], const IntegerValue(7));
    });

    test('creates intermediate maps for a dotted path', () {
      final root = <String, Value>{};
      setPath(root, 'a.b', const StringValue('x'));
      expect(resolvePath(root, 'a.b'), const StringValue('x'));
    });
  });

  group('deletePath', () {
    test('removes a nested field', () {
      final root = <String, Value>{
        'a': const MapValue({'b': IntegerValue(1)}),
      };
      deletePath(root, 'a.b');
      expect(resolvePath(root, 'a.b'), isNull);
    });

    test('is a no-op when the path does not resolve', () {
      final root = <String, Value>{'a': const IntegerValue(1)};
      deletePath(root, 'a.b.c');
      expect(root['a'], const IntegerValue(1));
    });
  });
}
