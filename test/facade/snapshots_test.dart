import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // WriteResult.fromJson
  // ---------------------------------------------------------------------------
  group('WriteResult.fromJson', () {
    test('parses updateTime as UTC, no transforms', () {
      final wr = WriteResult.fromJson(
        {'updateTime': '2026-06-08T10:00:00+00:00'},
        (p) => p,
      );
      expect(wr.updateTime, DateTime.utc(2026, 6, 8, 10));
      expect(wr.updateTime.isUtc, isTrue);
      expect(wr.transformResults, isNull);
    });

    test('parses transformResults into native values', () {
      final wr = WriteResult.fromJson(
        {
          'updateTime': '2026-06-08T10:00:00+00:00',
          'transformResults': {
            'count': const IntegerValue(7).toJson(),
            'ts': const StringValue('hi').toJson(),
          },
        },
        (p) => p,
      );
      expect(wr.transformResults, {'count': 7, 'ts': 'hi'});
    });
  });

  // ---------------------------------------------------------------------------
  // Converter
  // ---------------------------------------------------------------------------
  group('Converter', () {
    test('custom converter round-trips through fromMap/toMap', () {
      final converter = Converter<int>(
        (data) => data['n'] as int,
        (value) => {'n': value},
      );
      expect(converter.fromMap({'n': 5}), 5);
      expect(converter.toMap(5), {'n': 5});
    });
  });

  // ---------------------------------------------------------------------------
  // DocumentSnapshot (obtained via the real get() path)
  // ---------------------------------------------------------------------------
  group('DocumentSnapshot', () {
    test('existing document exposes data, metadata, id, path', () async {
      final h = FacadeHarness();
      h.handler = (frame) => h.respond(frame, {
            'document': wireDoc(
              'users/u1',
              wireFields({'name': 'Alice', 'age': 30}),
              createTime: '2026-06-01T08:00:00+00:00',
              updateTime: '2026-06-08T09:30:00+00:00',
              version: 4,
            ),
          });

      final snap = await h.db.doc('users/u1').get();

      expect(snap.exists, isTrue);
      expect(snap.id, 'u1');
      expect(snap.path, 'users/u1');
      expect(snap.data(), {'name': 'Alice', 'age': 30});
      expect(snap.nativeData(), {'name': 'Alice', 'age': 30});
      expect(snap.createTime, DateTime.utc(2026, 6, 1, 8));
      expect(snap.updateTime, DateTime.utc(2026, 6, 8, 9, 30));
      expect(snap.updateTimeRaw, '2026-06-08T09:30:00+00:00');
      expect(snap.version, 4);

      await h.close();
    });

    test('missing document: exists=false, data()/metadata null', () async {
      final h = FacadeHarness();
      h.handler = (frame) => h.respond(frame, {'document': null});

      final snap = await h.db.doc('users/missing').get();

      expect(snap.exists, isFalse);
      expect(snap.data(), isNull);
      expect(snap.nativeData(), isNull);
      expect(snap.createTime, isNull);
      expect(snap.updateTime, isNull);
      expect(snap.version, isNull);
      expect(snap.id, 'missing');
      expect(snap.path, 'users/missing');

      await h.close();
    });

    test('typed converter applied to data()', () async {
      final h = FacadeHarness();
      h.handler = (frame) => h.respond(frame, {
            'document': wireDoc('users/u1', wireFields({'n': 42})),
          });

      final converter = Converter<int>(
        (data) => data['n'] as int,
        (value) => {'n': value},
      );
      final snap = await h.db.doc('users/u1').withConverter(converter).get();

      expect(snap.data(), 42);
      // nativeData ignores the converter.
      expect(snap.nativeData(), {'n': 42});

      await h.close();
    });
  });

  // ---------------------------------------------------------------------------
  // QuerySnapshot / DocumentChange (public constructors)
  // ---------------------------------------------------------------------------
  group('QuerySnapshot / DocumentChange', () {
    test('holds docs, changes, readTime, resumeToken, hasMore', () async {
      // Obtain a real DocumentSnapshot to embed in a DocumentChange.
      final h = FacadeHarness();
      h.handler = (frame) => h.respond(frame, {
            'document': wireDoc('users/u1', wireFields({'n': 1})),
          });
      final docSnap = await h.db.doc('users/u1').get();

      final readTime = DateTime.utc(2026, 6, 8);
      final change = DocumentChange<Map<String, Object?>>(
        type: DocumentChangeType.added,
        oldIndex: -1,
        newIndex: 0,
        doc: docSnap,
      );
      final snap = QuerySnapshot<Map<String, Object?>>(
        docs: [docSnap],
        docChanges: [change],
        readTime: readTime,
        resumeToken: 99,
        hasMore: true,
      );
      expect(snap.docs.single.id, 'u1');
      expect(snap.docChanges.single.type, DocumentChangeType.added);
      expect(snap.docChanges.single.oldIndex, -1);
      expect(snap.docChanges.single.newIndex, 0);
      expect(snap.readTime, readTime);
      expect(snap.resumeToken, 99);
      expect(snap.hasMore, isTrue);

      await h.close();
    });

    test('hasMore defaults to false', () {
      final snap = QuerySnapshot<Map<String, Object?>>(
        docs: const [],
        docChanges: const [],
        readTime: DateTime.utc(2026),
        resumeToken: null,
      );
      expect(snap.hasMore, isFalse);
    });
  });
}
