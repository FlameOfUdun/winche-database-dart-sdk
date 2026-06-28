import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  test('SetWrite round-trips through toJson/fromJson', () {
    final w = SetWrite(
      'users/u1',
      {'name': const StringValue('Alice')},
      merge: true,
      transforms: [
        const FieldTransform('n', TransformKind.increment, IntegerValue(2)),
      ],
      precondition: const Precondition(exists: false),
    );
    final back = Write.fromJson(w.toJson());
    expect(back, isA<SetWrite>());
    expect(back.toJson(), w.toJson());
  });

  test('SetWrite round-trips with mergeFields', () {
    final w = SetWrite(
      'users/u1',
      {'name': const StringValue('Alice')},
      mergeFields: const ['name', 'address.city'],
    );
    final back = Write.fromJson(w.toJson());
    expect(back, isA<SetWrite>());
    expect((back as SetWrite).mergeFields, equals(['name', 'address.city']));
    expect(back.toJson(), w.toJson());
  });

  test('UpdateWrite round-trips (dotted fields + deleteField)', () {
    final w = UpdateWrite('users/u1', {
      'a.b': const IntegerValue(1),
      'a.old': const DeleteFieldValue(),
    });
    expect(Write.fromJson(w.toJson()).toJson(), w.toJson());
  });

  test('DeleteWrite round-trips (cascade + precondition)', () {
    final w = DeleteWrite('users/u1',
        cascade: true,
        precondition:
            const Precondition.updateTimeRaw('2026-06-08T10:00:00+00:00'));
    expect(Write.fromJson(w.toJson()).toJson(), w.toJson());
  });

  test('unknown envelope key throws FormatException', () {
    expect(() => Write.fromJson({'bogus': {}}), throwsFormatException);
  });
}
