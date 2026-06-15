import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());

  group('reference factories', () {
    test('collection() returns a CollectionReference for the path', () {
      final col = h.db.collection('users');
      expect(col, isA<CollectionReference<Map<String, Object?>>>());
      expect(col.path, 'users');
    });

    test('doc() returns a DocumentReference for the path', () {
      final ref = h.db.doc('users/u1');
      expect(ref, isA<DocumentReference<Map<String, Object?>>>());
      expect(ref.path, 'users/u1');
    });

    test('batch() returns a fresh WriteBatch', () {
      expect(h.db.batch(), isA<WriteBatch>());
      expect(identical(h.db.batch(), h.db.batch()), isFalse);
    });
  });

  group('getAll()', () {
    test('sends doc.getAll and returns ordered snapshots (null → missing)',
        () async {
      h.handler = (f) => h.respond(f, {
            'documents': [
              wireDoc('users/u1', wireFields({'n': 1})),
              null,
              wireDoc('users/u3', wireFields({'n': 3})),
            ],
          });

      final snaps = await h.db.getAll([
        h.db.doc('users/u1'),
        h.db.doc('users/u2'),
        h.db.doc('users/u3'),
      ]);

      expect(h.lastRequest['type'], 'doc.getAll');
      expect(h.lastRequest['paths'], ['users/u1', 'users/u2', 'users/u3']);
      expect(snaps.map((s) => s.id), ['u1', 'u2', 'u3']);
      expect(snaps[0].exists, isTrue);
      expect(snaps[0].data(), {'n': 1});
      expect(snaps[1].exists, isFalse);
      expect(snaps[1].path, 'users/u2');
      expect(snaps[2].data(), {'n': 3});

      await h.close();
    });

    test('applies the converter carried by each reference', () async {
      h.handler = (f) => h.respond(f, {
            'documents': [
              wireDoc('users/u1', wireFields({'n': 7}))
            ],
          });
      final conv = Converter<int>((d) => d['n'] as int, (v) => {'n': v});
      final snaps =
          await h.db.getAll([h.db.doc('users/u1').withConverter(conv)]);
      expect(snaps.single.data(), 7);
      await h.close();
    });

    test('empty list returns [] without sending a request', () async {
      final snaps = await h.db.getAll<Map<String, Object?>>([]);
      expect(snaps, isEmpty);
      expect(h.requests, isEmpty);
    });
  });

  group('close()', () {
    test('completes without error', () async {
      // Force a connection first so there is something to tear down.
      h.handler = (f) => h.respond(f, {'document': null});
      await h.db.doc('users/u1').get();
      // close() is fire-and-forget; it must not throw.
      h.db.close();
      await pump();
    });

    test('reconnects stream is exposed', () {
      expect(h.db.reconnects, isA<Stream<void>>());
    });
  });
}
