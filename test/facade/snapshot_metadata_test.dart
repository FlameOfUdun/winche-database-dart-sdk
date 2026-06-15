import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  test('default metadata is server-confirmed with no pending writes', () {
    const m = SnapshotMetadata();
    expect(m.fromCache, isFalse);
    expect(m.hasPendingWrites, isFalse);
  });

  test('metadata equality and toString', () {
    expect(const SnapshotMetadata(fromCache: true, hasPendingWrites: true),
        const SnapshotMetadata(fromCache: true, hasPendingWrites: true));
    expect(const SnapshotMetadata(fromCache: true).toString(),
        contains('fromCache: true'));
  });

  test('metadata inequality on differing fields', () {
    expect(const SnapshotMetadata(fromCache: true),
        isNot(const SnapshotMetadata(fromCache: false)));
    expect(const SnapshotMetadata(hasPendingWrites: true),
        isNot(const SnapshotMetadata()));
  });

  test('equal metadata share a hashCode', () {
    expect(
        const SnapshotMetadata(fromCache: true, hasPendingWrites: true)
            .hashCode,
        const SnapshotMetadata(fromCache: true, hasPendingWrites: true)
            .hashCode);
  });

  test('toString includes both fields', () {
    expect(
        const SnapshotMetadata(hasPendingWrites: true).toString(),
        allOf(
            contains('fromCache: false'), contains('hasPendingWrites: true')));
  });
}
