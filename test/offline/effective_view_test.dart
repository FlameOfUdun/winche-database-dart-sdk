import 'package:test/test.dart';
import 'package:winche_database/src/offline/effective_view.dart';
import 'package:winche_database/src/offline/records.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';

WireDocument wire(String path, Map<String, Value> fields,
        {String updateTime = '2026-06-08T10:00:00+00:00', int version = 1}) =>
    WireDocument(
        path: path,
        id: path.split('/').last,
        collection: path.split('/').first,
        fields: fields,
        createTime: updateTime,
        updateTime: updateTime,
        version: version);

PendingWrite pw(int seq, Write w) => PendingWrite(
    seq: seq,
    path: w is SetWrite
        ? w.path
        : (w is UpdateWrite ? w.path : (w as DeleteWrite).path),
    write: w,
    localCommitTime: DateTime.utc(2026, 6, 8, 12));

void main() {
  test('buildEffectiveView overlays pending writes and reports anyPending', () {
    final base = [
      wire('c/a', {'n': const IntegerValue(1)})
    ];
    final pendingByPath = <String, List<PendingWrite>>{
      'c/b': [
        pw(1, SetWrite('c/b', {'n': const IntegerValue(2)}))
      ],
    };
    final view = buildEffectiveView(base, pendingByPath);
    expect(view.docs.map((d) => d.path).toSet(), {'c/a', 'c/b'});
    expect(view.anyPending, isTrue);
  });

  test('no pending writes → confirmed base, no pending flag', () {
    final base = wire('users/u1', {'n': const IntegerValue(1)});
    final eff = applyOverlay(base, const []);
    expect(eff.exists, isTrue);
    expect(eff.document!.fields['n'], const IntegerValue(1));
    expect(eff.hasPendingWrites, isFalse);
  });

  test('set (replace) overwrites all fields', () {
    final base = wire('users/u1', {'a': const IntegerValue(1)});
    final eff = applyOverlay(base, [
      pw(1, SetWrite('users/u1', {'b': const IntegerValue(2)})),
    ]);
    expect(eff.document!.fields.keys, ['b']);
    expect(eff.hasPendingWrites, isTrue);
  });

  test('set with merge deep-merges into existing', () {
    final base = wire('users/u1', {
      'm': const MapValue({'x': IntegerValue(1)}),
      'k': const IntegerValue(9),
    });
    final eff = applyOverlay(base, [
      pw(
          1,
          SetWrite(
              'users/u1',
              {
                'm': const MapValue({'y': IntegerValue(2)})
              },
              merge: true)),
    ]);
    expect(eff.document!.fields['m'],
        const MapValue({'x': IntegerValue(1), 'y': IntegerValue(2)}));
    expect(eff.document!.fields['k'], const IntegerValue(9));
  });

  test('update patches a dotted field without disturbing siblings', () {
    final base = wire('users/u1', {
      'a': const MapValue({'b': IntegerValue(1), 'c': IntegerValue(2)}),
    });
    final eff = applyOverlay(base, [
      pw(1, UpdateWrite('users/u1', {'a.b': const IntegerValue(9)})),
    ]);
    expect(eff.document!.fields['a'],
        const MapValue({'b': IntegerValue(9), 'c': IntegerValue(2)}));
  });

  test('update deleteField removes a dotted field', () {
    final base = wire('users/u1', {
      'a': const MapValue({'b': IntegerValue(1), 'c': IntegerValue(2)}),
    });
    final eff = applyOverlay(base, [
      pw(1, UpdateWrite('users/u1', {'a.b': const DeleteFieldValue()})),
    ]);
    expect(eff.document!.fields['a'], const MapValue({'c': IntegerValue(2)}));
  });

  test('delete makes the document effectively absent', () {
    final base = wire('users/u1', {'n': const IntegerValue(1)});
    final eff = applyOverlay(base, [pw(1, DeleteWrite('users/u1'))]);
    expect(eff.exists, isFalse);
    expect(eff.document, isNull);
    expect(eff.hasPendingWrites, isTrue);
  });

  test('set on a null base creates the document', () {
    final eff = applyOverlay(null, [
      pw(1, SetWrite('users/u1', {'n': const IntegerValue(1)})),
    ]);
    expect(eff.exists, isTrue);
    expect(eff.document!.path, 'users/u1');
  });

  test('increment transform applies over the current value', () {
    final base = wire('users/u1', {'n': const IntegerValue(10)});
    final eff = applyOverlay(base, [
      pw(
          1,
          SetWrite('users/u1', {
            'n': const IntegerValue(10)
          }, transforms: const [
            FieldTransform('n', TransformKind.increment, IntegerValue(5)),
          ])),
    ]);
    expect(eff.document!.fields['n'], const IntegerValue(15));
  });

  test('arrayUnion / arrayRemove transforms', () {
    final base = wire('users/u1', {
      'tags': const ArrayValue([StringValue('a')]),
    });
    final eff = applyOverlay(base, [
      pw(
          1,
          UpdateWrite('users/u1', const {}, transforms: const [
            FieldTransform('tags', TransformKind.arrayUnion,
                ArrayValue([StringValue('b')])),
          ])),
      pw(
          2,
          UpdateWrite('users/u1', const {}, transforms: const [
            FieldTransform('tags', TransformKind.arrayRemove,
                ArrayValue([StringValue('a')])),
          ])),
    ]);
    expect((eff.document!.fields['tags'] as ArrayValue).elements,
        const [StringValue('b')]);
  });

  test('serverTimestamp transform resolves to a timestamp', () {
    final base = wire('users/u1', const {});
    final eff = applyOverlay(base, [
      pw(
          1,
          UpdateWrite('users/u1', const {}, transforms: const [
            FieldTransform('t', TransformKind.serverTimestamp),
          ])),
    ]);
    expect(eff.document!.fields['t'], isA<TimestampValue>());
  });

  test('chained pending writes apply in seq order', () {
    final base = wire('users/u1', {'n': const IntegerValue(0)});
    final eff = applyOverlay(base, [
      pw(1, UpdateWrite('users/u1', {'n': const IntegerValue(5)})),
      pw(
          2,
          UpdateWrite('users/u1', const {}, transforms: const [
            FieldTransform('n', TransformKind.increment, IntegerValue(1)),
          ])),
    ]);
    expect(eff.document!.fields['n'], const IntegerValue(6));
  });

  test(
      'maximum/minimum on a missing or non-numeric field resolve to the operand',
      () {
    final base = wire('users/u1', {'s': const StringValue('x')});
    final eff = applyOverlay(base, [
      pw(
          1,
          UpdateWrite('users/u1', const {}, transforms: const [
            FieldTransform('hi', TransformKind.maximum, IntegerValue(-5)),
            FieldTransform('lo', TransformKind.minimum, IntegerValue(5)),
            FieldTransform('s', TransformKind.maximum, IntegerValue(3)),
          ])),
    ]);
    expect(eff.document!.fields['hi'], const IntegerValue(-5));
    expect(eff.document!.fields['lo'], const IntegerValue(5));
    // non-numeric current 's' → operand wins
    expect(eff.document!.fields['s'], const IntegerValue(3));
  });

  test('increment on a missing field equals the operand', () {
    final base = wire('users/u1', const {});
    final eff = applyOverlay(base, [
      pw(
          1,
          UpdateWrite('users/u1', const {}, transforms: const [
            FieldTransform('n', TransformKind.increment, IntegerValue(7)),
          ])),
    ]);
    expect(eff.document!.fields['n'], const IntegerValue(7));
  });

  test('synthetic updateTime preserves sub-second precision (shared formatter)',
      () {
    final eff = applyOverlay(null, [
      PendingWrite(
        seq: 1,
        path: 'users/u1',
        write: SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026, 6, 8, 12, 0, 0, 500), // .500s
      ),
    ]);
    expect(eff.document!.updateTime, contains('.5'));
  });

  test('projectFields keeps only selected dotted paths, preserves metadata',
      () {
    final doc = WireDocument(
      path: 'users/u1',
      id: 'u1',
      collection: 'users',
      fields: {
        'name': const StringValue('Alice'),
        'age': const IntegerValue(30),
        'address': MapValue({
          'city': const StringValue('Oslo'),
          'zip': const StringValue('0001'),
        }),
      },
      createTime: 'T1',
      updateTime: 'T2',
      version: 3,
    );
    final p = projectFields(doc, ['name', 'address.city']);
    expect(p.fields.keys.toSet(), {'name', 'address'});
    expect((p.fields['address'] as MapValue).fields.keys, ['city']);
    expect(p.fields.containsKey('age'), isFalse);
    expect(p.path, 'users/u1');
    expect(p.id, 'u1');
    expect(p.version, 3);
    expect(p.createTime, 'T1');
    expect(p.updateTime, 'T2');
  });

  test('projectFields skips a selected path that is absent', () {
    final doc = WireDocument(
      path: 'c/a',
      id: 'a',
      collection: 'c',
      fields: {'name': const StringValue('x')},
      createTime: 'T',
      updateTime: 'T',
      version: 1,
    );
    final p = projectFields(doc, ['name', 'missing']);
    expect(p.fields.keys, ['name']);
  });
}
