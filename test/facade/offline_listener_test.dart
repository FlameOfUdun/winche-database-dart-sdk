import 'dart:async';
import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';
import '../offline/fake_local_store.dart';

void main() {
  late WincheDatabase db;
  setUp(() {
    db = WincheDatabase(
      ConnectionConfig(
          uri: Uri.parse('ws://localhost:1/documents/ws'),
          autoReconnect: false),
      store: FakeLocalStore(),
    );
  });
  tearDown(() => db.close());

  test('query.snapshots emits cache-first and reacts to local writes',
      () async {
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = db.collection('users').snapshots().listen(snaps.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps, isNotEmpty);
    expect(snaps.first.docs, isEmpty);
    expect(snaps.first.metadata.fromCache, isTrue);

    await db.doc('users/u1').set({'name': 'Alice'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps.last.docs.map((d) => d.id), ['u1']);
    expect(snaps.last.docs.single.data(), {'name': 'Alice'});
    expect(snaps.last.metadata.hasPendingWrites, isTrue);

    await db.doc('users/u1').delete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps.last.docs, isEmpty);

    await sub.cancel();
  });

  test('query.snapshots reflects a local update with ordering', () async {
    await db.doc('users/a').set({'age': 30});
    await db.doc('users/b').set({'age': 20});
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub =
        db.collection('users').orderBy('age').snapshots().listen(snaps.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps.last.docs.map((d) => d.id), ['b', 'a']);
    await sub.cancel();
  });

  test('doc.snapshots reflects a local set then delete', () async {
    final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = db.doc('users/x').snapshots().listen(snaps.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps.last.exists, isFalse);
    await db.doc('users/x').set({'n': 1});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps.last.exists, isTrue);
    expect(snaps.last.data(), {'n': 1});
    await db.doc('users/x').delete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snaps.last.exists, isFalse);
    await sub.cancel();
  });

  test('cancelling immediately after listen does not throw or leak', () async {
    final sub = db.collection('users').snapshots().listen((_) {});
    await sub.cancel(); // may cancel during the initial async emit
    // A later write must not surface errors from a leaked listener.
    await db.doc('users/u1').set({'n': 1});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // Reaching here without an unhandled exception is success.
    expect(true, isTrue);
  });
}
