import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

/// Extracts the single write envelope (`{set|update|delete: {...}}`) from a
/// captured `write` request frame.
Map<String, Object?> singleWrite(Map<String, Object?> frame) {
  expect(frame['type'], 'write');
  final writes = frame['writes'] as List<Object?>;
  expect(writes.length, 1);
  return (writes.single as Map).cast<String, Object?>();
}

void main() {
  // ===========================================================================
  // DocumentReference
  // ===========================================================================
  group('DocumentReference', () {
    test('id is the last path segment', () {
      final h = FacadeHarness();
      expect(h.db.doc('users/u1').id, 'u1');
      expect(h.db.doc('users/u1/posts/p9').id, 'p9');
    });

    test('toString', () {
      final h = FacadeHarness();
      expect(h.db.doc('users/u1').toString(), 'DocumentReference(users/u1)');
    });

    test('parent returns the enclosing collection', () {
      final h = FacadeHarness();
      final parent = h.db.doc('users/u1/posts/p1').parent;
      expect(parent, isA<CollectionReference<Map<String, Object?>>>());
      expect(parent.path, 'users/u1/posts');
    });

    test('parent throws for a top-level path with no collection', () {
      final h = FacadeHarness();
      expect(() => h.db.doc('users').parent, throwsA(isA<StateError>()));
    });

    test('collection() returns a subcollection reference', () {
      final h = FacadeHarness();
      final sub = h.db.doc('users/u1').collection('posts');
      expect(sub.path, 'users/u1/posts');
    });

    // -------------------------------------------------------------------------
    // get()
    // -------------------------------------------------------------------------
    test('get() sends doc.get with the path', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, {'document': null});
      await h.db.doc('users/u1').get();
      expect(h.lastRequest['type'], 'doc.get');
      expect(h.lastRequest['path'], 'users/u1');
      await h.close();
    });

    // -------------------------------------------------------------------------
    // set()
    // -------------------------------------------------------------------------
    test('set() sends a replace write (merge:false) and returns WriteResult',
        () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(
          f, writeResultsPayload(updateTime: '2026-06-08T11:00:00+00:00'));

      final result = await h.db.doc('users/u1').set({'name': 'Alice'});

      final set = singleWrite(h.lastRequest)['set'] as Map<String, Object?>;
      expect(set['path'], 'users/u1');
      expect(set['merge'], false);
      expect(set['fields'], {
        'name': {'stringValue': 'Alice'},
      });
      // Writes are queued; set() returns a local ack (the commit time), and the
      // sync controller drains the write to the server in the background.
      expect(result.updateTime, isA<DateTime>());
      await h.close();
    });

    test('set(merge:true) sets the merge flag', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db.doc('users/u1').set({'a': 1}, merge: true);
      final set = singleWrite(h.lastRequest)['set'] as Map<String, Object?>;
      expect(set['merge'], true);
      await h.close();
    });

    test('set() extracts sentinels as transforms', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db.doc('users/u1').set({
        'name': 'Alice',
        'visits': FieldValue.increment(1),
      });
      final set = singleWrite(h.lastRequest)['set'] as Map<String, Object?>;
      expect((set['fields'] as Map).containsKey('visits'), isFalse);
      final transforms = set['transforms'] as List<Object?>;
      expect(transforms.single, {
        'field': 'visits',
        'kind': 'increment',
        'operand': {'integerValue': '1'},
      });
      await h.close();
    });

    test('set() includes precondition when provided', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db
          .doc('users/u1')
          .set({'a': 1}, precondition: const Precondition(exists: false));
      final set = singleWrite(h.lastRequest)['set'] as Map<String, Object?>;
      expect(set['precondition'], {'exists': false});
      await h.close();
    });

    // -------------------------------------------------------------------------
    // update()
    // -------------------------------------------------------------------------
    test('update() sends an update write with dotted field paths', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db.doc('users/u1').update({'profile.age': 31});
      final update =
          singleWrite(h.lastRequest)['update'] as Map<String, Object?>;
      expect(update['path'], 'users/u1');
      expect(update['fields'], {
        'profile.age': {'integerValue': '31'},
      });
      await h.close();
    });

    test('update() with precondition', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db.doc('users/u1').update(
        {'a': 1},
        precondition:
            const Precondition.updateTimeRaw('2026-06-08T10:00:00+00:00'),
      );
      final update =
          singleWrite(h.lastRequest)['update'] as Map<String, Object?>;
      expect(
          update['precondition'], {'updateTime': '2026-06-08T10:00:00+00:00'});
      await h.close();
    });

    // -------------------------------------------------------------------------
    // delete()
    // -------------------------------------------------------------------------
    test('delete() sends a delete write (cascade:false by default)', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db.doc('users/u1').delete();
      final del = singleWrite(h.lastRequest)['delete'] as Map<String, Object?>;
      expect(del['path'], 'users/u1');
      expect(del['cascade'], false);
      await h.close();
    });

    test('delete(cascade:true, precondition) is encoded', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());
      await h.db.doc('users/u1').delete(
            cascade: true,
            precondition: const Precondition(exists: true),
          );
      final del = singleWrite(h.lastRequest)['delete'] as Map<String, Object?>;
      expect(del['cascade'], true);
      expect(del['precondition'], {'exists': true});
      await h.close();
    });

    test('a write rejected by the server surfaces as a WriteFailed sync event',
        () async {
      final h = FacadeHarness();
      h.handler = (f) =>
          h.respondError(f, 'PERMISSION_DENIED', 'Rule denied the write.');
      final failed = <WriteFailed>[];
      final sub = h.db.syncEvents.listen((e) {
        if (e is WriteFailed) failed.add(e);
      });

      // set() succeeds locally (queued); the rejection surfaces on syncEvents
      // when the queue drains.
      await h.db.doc('users/u1').set({'a': 1});
      await pump(12);

      expect(failed, isNotEmpty);
      expect(failed.first.error, isA<PermissionDeniedException>());

      await sub.cancel();
      await h.close();
    });
  });

  // ===========================================================================
  // CollectionReference
  // ===========================================================================
  group('CollectionReference', () {
    test('path and id getters', () {
      final h = FacadeHarness();
      final col = h.db.collection('users');
      expect(col.path, 'users');
      expect(col.id, 'users');

      final sub = h.db.doc('users/u1').collection('posts');
      expect(sub.path, 'users/u1/posts');
      expect(sub.id, 'posts');
    });

    test('toString', () {
      final h = FacadeHarness();
      expect(h.db.collection('users').toString(), 'CollectionReference(users)');
    });

    test('doc(id) builds a child path', () {
      final h = FacadeHarness();
      expect(h.db.collection('users').doc('u1').path, 'users/u1');
    });

    test('doc() generates a 32-char alphanumeric id', () {
      final h = FacadeHarness();
      final ids = {
        for (var i = 0; i < 50; i++) h.db.collection('users').doc().id
      };
      expect(ids.length, 50, reason: 'ids should be unique');
      final pattern = RegExp(r'^[A-Za-z0-9]{32}$');
      for (final id in ids) {
        expect(pattern.hasMatch(id), isTrue, reason: 'bad id: $id');
      }
    });

    test('add() generates an id and sends a set write', () async {
      final h = FacadeHarness();
      h.handler = (f) => h.respond(f, writeResultsPayload());

      final ref = await h.db.collection('users').add({'name': 'Bob'});

      expect(ref.path, startsWith('users/'));
      expect(ref.id.length, 32);
      final set = singleWrite(h.lastRequest)['set'] as Map<String, Object?>;
      expect(set['path'], ref.path);
      expect(set['fields'], {
        'name': {'stringValue': 'Bob'},
      });
      await h.close();
    });

    test('is also a QueryReference (where returns a query)', () {
      final h = FacadeHarness();
      final q = h.db.collection('users').where('age', isGreaterThan: 18);
      expect(q, isA<QueryReference<Map<String, Object?>>>());
      expect(q.spec.collection, 'users');
    });

    test('withConverter returns a typed CollectionReference', () {
      final h = FacadeHarness();
      final typed = h.db.collection('users').withConverter(
            Converter<int>((d) => d['n'] as int, (v) => {'n': v}),
          );
      expect(typed, isA<CollectionReference<int>>());
      expect(typed.path, 'users');
    });
  });
}
