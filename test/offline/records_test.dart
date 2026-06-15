import 'package:test/test.dart';
import 'package:winche_database/src/offline/records.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/messages.dart';

void main() {
  group('CachedDocument', () {
    test('live document round-trips through the store record', () {
      final wire = WireDocument.fromJson({
        'path': 'users/u1',
        'id': 'u1',
        'collection': 'users',
        'fields': {
          'n': {'integerValue': '1'}
        },
        'createTime': '2026-06-08T10:00:00+00:00',
        'updateTime': '2026-06-08T10:00:00+00:00',
        'version': 1,
      });
      final rec = CachedDocument.live(wire);
      final back = CachedDocument.fromRecord(rec.toRecord());
      expect(back.deleted, isFalse);
      expect(back.document!.path, 'users/u1');
      expect(back.document!.fields['n'], const IntegerValue(1));
    });

    test('tombstone round-trips', () {
      final rec =
          CachedDocument.tombstone('users/u1', '2026-06-08T10:00:00+00:00');
      final back = CachedDocument.fromRecord(rec.toRecord());
      expect(back.deleted, isTrue);
      expect(back.document, isNull);
      expect(back.updateTime, '2026-06-08T10:00:00+00:00');
    });
  });

  group('PendingWrite', () {
    test('round-trips a SetWrite with base + batchId', () {
      final pw = PendingWrite(
        seq: 5,
        path: 'users/u1',
        write: SetWrite('users/u1', {'name': const StringValue('Alice')}),
        base: const PendingBase(
            updateTime: '2026-06-08T10:00:00+00:00', version: 3),
        batchId: 'b1',
        localCommitTime: DateTime.utc(2026, 6, 8, 10),
      );
      final back = PendingWrite.fromRecord(pw.toRecord());
      expect(back.seq, 5);
      expect(back.path, 'users/u1');
      expect(back.kind, PendingKind.set);
      expect(back.write.toJson(), pw.write.toJson());
      expect(back.base!.updateTime, '2026-06-08T10:00:00+00:00');
      expect(back.base!.version, 3);
      expect(back.batchId, 'b1');
      expect(back.localCommitTime, DateTime.utc(2026, 6, 8, 10));
    });

    test('base exists:false round-trips', () {
      final pw = PendingWrite(
        seq: 1,
        path: 'a/b',
        write: SetWrite('a/b', const {}),
        base: const PendingBase(existsFalse: true),
        localCommitTime: DateTime.utc(2026),
      );
      expect(PendingWrite.fromRecord(pw.toRecord()).base!.existsFalse, isTrue);
    });

    test('kind is derived from the write type', () {
      PendingWrite pw(Write w) => PendingWrite(
          seq: 1, path: 'a/b', write: w, localCommitTime: DateTime.utc(2026));
      expect(pw(SetWrite('a/b', const {})).kind, PendingKind.set);
      expect(pw(UpdateWrite('a/b', const {})).kind, PendingKind.update);
      expect(pw(DeleteWrite('a/b')).kind, PendingKind.delete);
    });

    test('copyWith replaces the base, keeping other fields', () {
      final pw = PendingWrite(
        seq: 2,
        path: 'a/b',
        write: SetWrite('a/b', const {}),
        localCommitTime: DateTime.utc(2026),
        base: const PendingBase(existsFalse: true),
      );
      final rebased = pw.copyWith(base: const PendingBase(updateTime: 'T'));
      expect(rebased.seq, 2);
      expect(rebased.base!.updateTime, 'T');
      expect(rebased.base!.existsFalse, isNull);
    });
  });
}
