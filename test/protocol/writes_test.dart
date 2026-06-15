import 'dart:convert';

import 'package:test/test.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';

void main() {
  group('Write polymorphism', () {
    test('path and precondition are accessible without switching', () {
      const pc = Precondition(exists: true);
      final writes = <Write>[
        SetWrite('c/a', const {}, precondition: pc),
        UpdateWrite('c/b', const {}, precondition: pc),
        DeleteWrite('c/d', precondition: pc),
      ];
      expect(writes.map((w) => w.path), ['c/a', 'c/b', 'c/d']);
      expect(writes.every((w) => identical(w.precondition, pc)), isTrue);
    });
    test('withPrecondition replaces the precondition, preserving other fields',
        () {
      final s = SetWrite('c/a', const {}, merge: true);
      final s2 = s.withPrecondition(const Precondition(exists: false));
      expect(s2, isA<SetWrite>());
      expect(s2.merge, isTrue);
      expect(s2.path, 'c/a');
      expect(s2.precondition?.exists, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // SetWrite — PROTOCOL §3.2
  // ---------------------------------------------------------------------------
  group('SetWrite', () {
    test('basic set — PROTOCOL §3.2 example shape', () {
      final write = SetWrite(
        'users/u1',
        {'name': StringValue('Alice')},
        merge: false,
        precondition: const Precondition(exists: false),
      );
      final j = write.toJson();
      expect(j.keys.toList(), equals(['set']));
      final body = j['set'] as Map<String, Object?>;
      expect(body['path'], equals('users/u1'));
      expect(body['merge'], equals(false));
      expect(body['fields'], isA<Map<String, Object?>>());
      final pc = body['precondition'] as Map<String, Object?>;
      expect(pc['exists'], equals(false));
    });

    test('merge: true', () {
      final write = SetWrite('c/a', {}, merge: true);
      final body = write.toJson()['set'] as Map<String, Object?>;
      expect(body['merge'], equals(true));
    });

    test('with transforms', () {
      final write = SetWrite(
        'counters/c1',
        {'n': IntegerValue(0)},
        transforms: [
          FieldTransform('n', TransformKind.increment, IntegerValue(1)),
        ],
      );
      final body = write.toJson()['set'] as Map<String, Object?>;
      final transforms = body['transforms'] as List<Object?>;
      expect(transforms.length, equals(1));
      final t = transforms[0] as Map<String, Object?>;
      expect(t['field'], equals('n'));
      expect(t['kind'], equals('increment'));
      expect(t['operand'], equals({'integerValue': '1'}));
    });

    test('without optional fields — no transforms/precondition keys emitted',
        () {
      final write = SetWrite('a/b', {'x': NullValue()});
      final body = write.toJson()['set'] as Map<String, Object?>;
      expect(body.containsKey('transforms'), isFalse);
      expect(body.containsKey('precondition'), isFalse);
    });

    test('deleteField sentinel in merge-set nested mapValue', () {
      // PROTOCOL §3.6 example
      final write = SetWrite(
        'c/a',
        {
          'm': MapValue({
            'drop': const DeleteFieldValue(),
            'keep': IntegerValue(1),
          }),
        },
        merge: true,
      );
      final body = write.toJson()['set'] as Map<String, Object?>;
      final fields = body['fields'] as Map<String, Object?>;
      final m = fields['m'] as Map<String, Object?>;
      final mFields = (m['mapValue'] as Map<String, Object?>)['fields']
          as Map<String, Object?>;
      expect(mFields['drop'], equals({'deleteField': true}));
      expect(mFields['keep'], equals({'integerValue': '1'}));
    });
  });

  // ---------------------------------------------------------------------------
  // UpdateWrite — PROTOCOL §3.3
  // ---------------------------------------------------------------------------
  group('UpdateWrite', () {
    test('basic update — PROTOCOL §3.3 example shape', () {
      final write = UpdateWrite(
        'users/u1',
        {
          'address.city': StringValue('Oslo'),
          'address.old': const DeleteFieldValue(),
        },
        precondition: Precondition(
          updateTime: DateTime.utc(2026, 6, 7, 10, 5),
        ),
      );
      final j = write.toJson();
      expect(j.keys.toList(), equals(['update']));
      final body = j['update'] as Map<String, Object?>;
      expect(body['path'], equals('users/u1'));
      final fields = body['fields'] as Map<String, Object?>;
      expect(fields['address.city'], equals({'stringValue': 'Oslo'}));
      expect(fields['address.old'], equals({'deleteField': true}));
      final pc = body['precondition'] as Map<String, Object?>;
      expect(pc['updateTime'], equals('2026-06-07T10:05:00+00:00'));
    });

    test('without optional fields', () {
      final write = UpdateWrite('a/b', {'x': StringValue('y')});
      final body = write.toJson()['update'] as Map<String, Object?>;
      expect(body.containsKey('transforms'), isFalse);
      expect(body.containsKey('precondition'), isFalse);
    });

    test('with transforms', () {
      final write = UpdateWrite(
        'docs/d1',
        {'count': IntegerValue(0)},
        transforms: [
          FieldTransform('count', TransformKind.serverTimestamp),
        ],
      );
      final body = write.toJson()['update'] as Map<String, Object?>;
      final ts =
          (body['transforms'] as List<Object?>)[0] as Map<String, Object?>;
      expect(ts['kind'], equals('serverTimestamp'));
      expect(ts.containsKey('operand'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // DeleteWrite — PROTOCOL §3.4
  // ---------------------------------------------------------------------------
  group('DeleteWrite', () {
    test('basic delete — PROTOCOL §3.4 example shape', () {
      final write = DeleteWrite(
        'users/u1',
        cascade: false,
        precondition: const Precondition(exists: true),
      );
      final j = write.toJson();
      expect(j.keys.toList(), equals(['delete']));
      final body = j['delete'] as Map<String, Object?>;
      expect(body['path'], equals('users/u1'));
      expect(body['cascade'], equals(false));
      final pc = body['precondition'] as Map<String, Object?>;
      expect(pc['exists'], equals(true));
    });

    test('cascade: true', () {
      final write = DeleteWrite('users/u1', cascade: true);
      final body = write.toJson()['delete'] as Map<String, Object?>;
      expect(body['cascade'], equals(true));
    });

    test('without optional precondition', () {
      final write = DeleteWrite('a/b');
      final body = write.toJson()['delete'] as Map<String, Object?>;
      expect(body.containsKey('precondition'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Transforms — all 6 kinds, per PROTOCOL §3.7
  // ---------------------------------------------------------------------------
  group('FieldTransform — all 6 kinds', () {
    test('serverTimestamp — no operand', () {
      final t = FieldTransform('time', TransformKind.serverTimestamp);
      final j = t.toJson();
      expect(j['kind'], equals('serverTimestamp'));
      expect(j.containsKey('operand'), isFalse);
    });

    test('increment', () {
      final t =
          FieldTransform('count', TransformKind.increment, IntegerValue(1));
      final j = t.toJson();
      expect(j['kind'], equals('increment'));
      expect(j['operand'], equals({'integerValue': '1'}));
    });

    test('maximum', () {
      final t =
          FieldTransform('high', TransformKind.maximum, DoubleValue(99.5));
      final j = t.toJson();
      expect(j['kind'], equals('maximum'));
      expect(j['operand'], equals({'doubleValue': 99.5}));
    });

    test('minimum', () {
      final t = FieldTransform('low', TransformKind.minimum, IntegerValue(0));
      final j = t.toJson();
      expect(j['kind'], equals('minimum'));
      expect(j['operand'], equals({'integerValue': '0'}));
    });

    test('arrayUnion', () {
      final t = FieldTransform(
        'tags',
        TransformKind.arrayUnion,
        ArrayValue([StringValue('new')]),
      );
      final j = t.toJson();
      expect(j['kind'], equals('arrayUnion'));
      expect(
        j['operand'],
        equals({
          'arrayValue': {
            'values': [
              {'stringValue': 'new'},
            ],
          },
        }),
      );
    });

    test('arrayRemove', () {
      final t = FieldTransform(
        'old',
        TransformKind.arrayRemove,
        ArrayValue([StringValue('x')]),
      );
      final j = t.toJson();
      expect(j['kind'], equals('arrayRemove'));
    });
  });

  // ---------------------------------------------------------------------------
  // Precondition variants — PROTOCOL §3.5
  // ---------------------------------------------------------------------------
  group('Precondition', () {
    test('exists: true', () {
      final pc = const Precondition(exists: true).toJson();
      expect(pc, equals({'exists': true}));
    });

    test('exists: false', () {
      final pc = const Precondition(exists: false).toJson();
      expect(pc, equals({'exists': false}));
    });

    test('updateTime DateTime', () {
      final pc = Precondition(
        updateTime: DateTime.utc(2026, 6, 7, 10, 5),
      ).toJson();
      expect(pc['updateTime'], equals('2026-06-07T10:05:00+00:00'));
    });

    test('exists + updateTime combined', () {
      final pc = Precondition(
        exists: true,
        updateTime: DateTime.utc(2026, 6, 7, 10, 5),
      ).toJson();
      expect(pc['exists'], equals(true));
      expect(pc['updateTime'], equals('2026-06-07T10:05:00+00:00'));
    });

    test('updateTimeRaw echo-back — server format string unchanged', () {
      // Simulates echo-back of a WireDocument.updateTime raw string.
      const raw = '2026-06-07T10:05:00+00:00';
      final pc = const Precondition.updateTimeRaw(raw).toJson();
      expect(pc['updateTime'], equals(raw));
    });

    test('updateTimeRaw with trimmed fractional zeros', () {
      const raw = '2026-06-07T10:05:00.001+00:00';
      final pc = const Precondition.updateTimeRaw(raw).toJson();
      expect(pc['updateTime'], equals(raw));
    });

    test('Minor 4 — exists + updateTimeRaw combined emits both fields', () {
      const raw = '2026-06-07T10:05:00+00:00';
      final pc = const Precondition.updateTimeRaw(raw, exists: true).toJson();
      expect(pc['exists'], equals(true));
      expect(pc['updateTime'], equals(raw));
    });

    test('Minor 4 — empty Precondition() asserts at least one field', () {
      expect(
          () => const Precondition().toJson(), throwsA(isA<AssertionError>()));
    });
  });

  // ---------------------------------------------------------------------------
  // Full PROTOCOL §7.3 :commit body shape
  // ---------------------------------------------------------------------------
  test(':commit batch shape (PROTOCOL §7.3)', () {
    final writes = [
      SetWrite('users/u1', {'name': StringValue('Alice')}),
      SetWrite(
        'counters/c1',
        {'n': IntegerValue(0)},
        transforms: [
          FieldTransform('n', TransformKind.increment, IntegerValue(1)),
        ],
      ),
    ];
    final body = {
      'writes': [for (final w in writes) w.toJson()]
    };
    final jsonStr = json.encode(body);
    expect(jsonStr, contains('"set"'));
    expect(jsonStr, contains('"users/u1"'));
    expect(jsonStr, contains('"increment"'));
  });
}
