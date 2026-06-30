// Feature smoke test for the Winche Database Dart SDK against a live server.
//
// It exercises every public SDK feature and verifies behavior against the
// access rules configured in samples/Winche.Database.Sample/Program.cs:
//
//   * claims are hard-coded to  uid = "user-123"  (no token needed)
//   * rule:  match userData/{userId}/{document=**}  allow All if auth.uid == userId
//
// So every operation under  userData/user-123/...  is ALLOWED and everything
// else is DENIED. The script checks both sides.
//
// Run the server first:
//   dotnet run --project samples/Winche.Database.Sample      (listens on :5183)
//
// Then, from the SDK package root:
//   dart run tool/feature_smoke_test.dart
//   dart run tool/feature_smoke_test.dart ws://localhost:5183/documents/ws
//
// Exit code is non-zero if any check fails.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:winche_database/winche_database.dart';

const _defaultWs = 'ws://localhost:5183/documents/ws';
const uid = 'user-123';

late final WincheDatabase db;
final runId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

int _pass = 0;
final List<String> _failures = [];

void _ok(String msg) {
  _pass++;
  print('  ✓ $msg');
}

void _fail(String msg, Object? detail) {
  _failures.add(msg);
  print('  ✗ $msg');
  print('      $detail');
}

void expect(bool cond, String why) {
  if (!cond) throw _AssertionError(why);
}

class _AssertionError implements Exception {
  _AssertionError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs [body]; passes if it completes without throwing.
Future<void> check(String name, Future<void> Function() body) async {
  try {
    await body();
    _ok(name);
  } catch (e) {
    _fail(name, e);
  }
}

/// Passes only if [body] throws [PermissionDeniedException].
Future<void> expectDenied(String name, Future<void> Function() body) async {
  try {
    await body();
    _fail(name, 'expected PERMISSION_DENIED but the call succeeded');
  } on PermissionDeniedException {
    _ok('$name — denied as expected');
  } catch (e) {
    _fail(name, 'expected PERMISSION_DENIED, got ${e.runtimeType}: $e');
  }
}

// --- write-outcome tracking (writes are local-first; results arrive async) ---

final Map<String, String> _outcome =
    {}; // path -> 'synced' | 'failed:STATUS' | 'conflict:STATUS'
late final StreamSubscription<SyncEvent> _evSub;

void _initSync() {
  _evSub = db.syncEvents.listen((e) {
    switch (e) {
      case WriteSynced(:final paths):
        for (final p in paths) {
          _outcome[p] = 'synced';
        }
      case WriteFailed(:final paths, :final error):
        for (final p in paths) {
          _outcome[p] = 'failed:${error.status}';
        }
      case WriteConflict(:final paths, :final error):
        for (final p in paths) {
          _outcome[p] = 'conflict:${error.status}';
        }
        // Resolve so the queue keeps draining and we don't hang.
        e.discard();
    }
  });
}

/// Enqueues a write and waits for its server outcome.
Future<String> outcomeOf(String path, Future<void> Function() write) async {
  _outcome.remove(path);
  await write();
  return _await(() => _outcome[path]);
}

Future<String> _await(String? Function() probe,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final v = probe();
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  return 'timeout';
}

Future<void> main(List<String> args) async {
  final wsUrl = args.isNotEmpty ? args.first : _defaultWs;

  db = WincheDatabase(WincheDatabaseConfig(uri: Uri.parse(wsUrl), inMemory: true));
  _initSync();

  print('Winche SDK feature smoke test');
  print('  server : $wsUrl');
  print('  uid    : $uid (hard-coded server-side)');
  print('  runId  : $runId');

  // A unique subcollection per run keeps query results isolated and cleanup easy.
  final col = db.collection('userData').doc(uid).collection('run_$runId');
  final created = <DocumentReference<Map<String, Object?>>>[];

  // --- connectivity probe (forces the lazy connect) ---
  try {
    await db
        .doc('userData/$uid/run_$runId/_ping')
        .get(const GetOptions(source: Source.server));
  } on UnavailableException catch (e) {
    print('\nCannot reach the server: $e');
    print('Start it with: dotnet run --project samples/Winche.Database.Sample');
    await _shutdown();
    exit(2);
  } catch (_) {
    // Any non-transport error means the socket is up — fine.
  }
  print('  connected: ${db.connectionState}\n');

  // =====================================================================
  print('[ Reads & writes — allowed paths ]');
  // =====================================================================
  final alice = col.doc('alice');
  created.add(alice);

  await check('set (create) with mixed value types', () async {
    final out = await outcomeOf(
      alice.path,
      () => alice.set({
        'name': 'Alice',
        'age': 30,
        'score': 1.5,
        'active': true,
        'tags': ['a', 'b'],
        'profile': {'city': 'Oslo'},
        'loc': const GeoPoint(59.913, 10.752),
        'when': DateTime.utc(2026, 1, 1),
        'blob': Uint8List.fromList([1, 2, 3]),
        'self': alice, // reference value
      }),
    );
    expect(out == 'synced', 'write outcome: $out');
  });

  await check('get (Source.server) returns the document', () async {
    final s = await alice.get(const GetOptions(source: Source.server));
    expect(s.exists, 'document should exist');
    final d = s.data()!;
    expect(d['name'] == 'Alice', 'name mismatch: ${d['name']}');
    expect(d['age'] == 30, 'age mismatch: ${d['age']}');
    expect(d['loc'] is GeoPoint, 'geo point not decoded: ${d['loc']}');
    expect(d['when'] is DateTime, 'timestamp not decoded: ${d['when']}');
    expect(d['blob'] is Uint8List, 'bytes not decoded: ${d['blob']}');
  });

  await check('update (patch fields, keeps siblings)', () async {
    final out = await outcomeOf(
        alice.path, () => alice.update({'age': 31, 'nick': 'Al'}));
    expect(out == 'synced', 'outcome: $out');
    final d =
        (await alice.get(const GetOptions(source: Source.server))).data()!;
    expect(d['age'] == 31 && d['nick'] == 'Al', 'patch not applied: $d');
    expect(d['name'] == 'Alice', 'patch clobbered a sibling field');
  });

  await check('set with merge:true (deep merge)', () async {
    final out = await outcomeOf(
        alice.path,
        () => alice.set({
              'profile': {'country': 'NO'}
            }, merge: true));
    expect(out == 'synced', 'outcome: $out');
    final d =
        (await alice.get(const GetOptions(source: Source.server))).data()!;
    final profile = d['profile'] as Map;
    expect(profile['country'] == 'NO' && profile['city'] == 'Oslo',
        'merge did not preserve existing keys: $profile');
  });

  // =====================================================================
  print('\n[ Field transforms ]');
  // =====================================================================
  final counter = col.doc('counter');
  created.add(counter);

  await check('increment / serverTimestamp / arrayUnion / maximum', () async {
    var out = await outcomeOf(
        counter.path, () => counter.set({'n': 0, 'list': <String>[]}));
    expect(out == 'synced', 'seed: $out');
    out = await outcomeOf(
      counter.path,
      () => counter.update({
        'n': FieldValue.increment(5),
        'stamp': FieldValue.serverTimestamp(),
        'list': FieldValue.arrayUnion(['x', 'y']),
        'hi': FieldValue.maximum(10),
      }),
    );
    expect(out == 'synced', 'transform: $out');
    final d =
        (await counter.get(const GetOptions(source: Source.server))).data()!;
    expect(d['n'] == 5, 'increment failed: ${d['n']}');
    expect((d['list'] as List).length == 2, 'arrayUnion failed: ${d['list']}');
    expect(d['stamp'] is DateTime, 'serverTimestamp failed: ${d['stamp']}');
    expect(d['hi'] == 10, 'maximum failed: ${d['hi']}');
  });

  await check('arrayRemove / minimum / FieldValue.delete', () async {
    final out = await outcomeOf(
      counter.path,
      () => counter.update({
        'list': FieldValue.arrayRemove(['x']),
        'hi': FieldValue.minimum(3),
        'stamp': FieldValue.delete(),
      }),
    );
    expect(out == 'synced', 'transform: $out');
    final d =
        (await counter.get(const GetOptions(source: Source.server))).data()!;
    expect((d['list'] as List).length == 1, 'arrayRemove failed: ${d['list']}');
    expect(d['hi'] == 3, 'minimum failed: ${d['hi']}');
    expect(!d.containsKey('stamp'), 'delete sentinel failed: still has stamp');
  });

  // =====================================================================
  print('\n[ Preconditions ]');
  // =====================================================================
  await check('exists:false on an existing doc → rejected', () async {
    final out = await outcomeOf(
        alice.path,
        () => alice
            .set({'x': 1}, precondition: const Precondition(exists: false)));
    expect(out != 'synced', 'expected rejection, got: $out');
  });

  await check('updateTime precondition: match passes, stale fails', () async {
    final s = await alice.get(const GetOptions(source: Source.server));
    final match = Precondition.updateTimeRaw(s.updateTimeRaw!);
    var out = await outcomeOf(
        alice.path, () => alice.update({'touched': true}, precondition: match));
    expect(out == 'synced', 'matching precondition should pass, got: $out');

    final stale = Precondition.updateTimeRaw('2000-01-01T00:00:00+00:00');
    out = await outcomeOf(alice.path,
        () => alice.update({'touched2': true}, precondition: stale));
    expect(out != 'synced', 'stale precondition should fail, got: $out');
  });

  // =====================================================================
  print('\n[ Batch writes & getAll ]');
  // =====================================================================
  final b1 = col.doc('b1'), b2 = col.doc('b2');
  created
    ..add(b1)
    ..add(b2);

  await check('atomic batch of two sets', () async {
    _outcome
      ..remove(b1.path)
      ..remove(b2.path);
    final batch = db.batch()
      ..set(b1, {'k': 1})
      ..set(b2, {'k': 2});
    await batch.commit();
    final r1 = await _await(() => _outcome[b1.path]);
    final r2 = await _await(() => _outcome[b2.path]);
    expect(r1 == 'synced' && r2 == 'synced', 'batch outcomes: b1=$r1 b2=$r2');
  });

  await check('getAll (batch read) preserves order', () async {
    final snaps =
        await db.getAll([b1, b2], const GetOptions(source: Source.server));
    expect(snaps.length == 2, 'expected 2 snapshots');
    expect(snaps[0].data()!['k'] == 1 && snaps[1].data()!['k'] == 2,
        'wrong order/data');
  });

  // =====================================================================
  print('\n[ Queries ]');
  // =====================================================================
  await check('seed 5 query documents', () async {
    for (var i = 1; i <= 5; i++) {
      final ref = col.doc('q$i');
      created.add(ref);
      final out = await outcomeOf(ref.path,
          () => ref.set({'title': 'Item $i', 'priority': i, 'done': i.isEven}));
      expect(out == 'synced', 'seed q$i: $out');
    }
  });

  await check('where equality filter', () async {
    final qs = await col
        .where('done', isEqualTo: true)
        .get(const GetOptions(source: Source.server));
    expect(qs.docs.isNotEmpty, 'no docs returned');
    expect(qs.docs.every((d) => d.data()!['done'] == true),
        'equality returned non-matching docs');
  });

  await check('inequality + orderBy + limit', () async {
    final qs = await col
        .where('priority', isGreaterThanOrEqualTo: 3)
        .orderBy('priority')
        .limit(2)
        .get(const GetOptions(source: Source.server));
    expect(qs.docs.length == 2, 'limit not applied: ${qs.docs.length}');
    expect(qs.docs.first.data()!['priority'] == 3,
        'order wrong: ${qs.docs.map((d) => d.data()!['priority']).toList()}');
  });

  await check('cursors (orderBy + startAt/endAt)', () async {
    final qs = await col
        .orderBy('priority')
        .startAt([2]).endAt([4]).get(const GetOptions(source: Source.server));
    final ps = qs.docs.map((d) => d.data()!['priority']).toList();
    expect(ps.length == 3 && ps.first == 2 && ps.last == 4,
        'cursor range wrong: $ps');
  });

  await check('select projection (trims to selected fields)', () async {
    // Projecting away the filtered field now works: the SDK widens the wire
    // projection to include where/orderBy fields, then trims back to select().
    final qs = await col
        .where('priority', isEqualTo: 1)
        .select(['title']).get(const GetOptions(source: Source.server));
    expect(
        qs.docs.length == 1, 'expected exactly 1 doc, got ${qs.docs.length}');
    final d = qs.docs.first.data()!;
    expect(d['title'] == 'Item 1', 'projected title wrong: $d');
    expect(
        !d.containsKey('priority'), 'projection did not trim "priority": $d');
  });

  await check('whereIn filter', () async {
    final qs = await col.where('priority',
        whereIn: [1, 2]).get(const GetOptions(source: Source.server));
    expect(qs.docs.length >= 2, 'whereIn returned ${qs.docs.length}');
  });

  // =====================================================================
  print('\n[ Count ]');
  // =====================================================================
  await check('count() via the count verb', () async {
    final n = await col.where('priority', isGreaterThanOrEqualTo: 1).count();
    expect(n >= 5, 'count was $n (expected >= 5)');
  });

  // =====================================================================
  print('\n[ Real-time listeners ]');
  // =====================================================================
  await check('doc.snapshots() observes a live update', () async {
    final ref = col.doc('live');
    created.add(ref);
    await outcomeOf(ref.path, () => ref.set({'v': 1}));
    final seen = <int>[];
    final sub = ref.snapshots().listen((s) {
      if (s.exists) seen.add(s.data()!['v'] as int);
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await outcomeOf(ref.path, () => ref.update({'v': 2}));
    await _await(() => seen.contains(2) ? 'ok' : null,
        timeout: const Duration(seconds: 4));
    await sub.cancel();
    expect(seen.contains(2), 'listener never saw v=2 (saw $seen)');
  });

  await check('collection.snapshots() grows after an insert', () async {
    final sizes = <int>[];
    final sub = col
        .where('priority', isGreaterThanOrEqualTo: 1)
        .orderBy('priority')
        .snapshots()
        .listen((qs) => sizes.add(qs.docs.length));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final q6 = col.doc('q6');
    created.add(q6);
    await outcomeOf(q6.path,
        () => q6.set({'title': 'Item 6', 'priority': 6, 'done': true}));
    await _await(() => sizes.any((n) => n >= 6) ? 'ok' : null,
        timeout: const Duration(seconds: 4));
    await sub.cancel();
    expect(sizes.isNotEmpty, 'no query snapshots received');
    // The insert may transiently fall back during the pending→confirmed handoff,
    // so assert the growth was observed at some point, not that it's the last.
    expect(sizes.any((n) => n >= 6),
        'live query never observed the insert (sizes: $sizes)');
  });

  await check(
      'deletion reconciliation: server delete removes local copy, no cache resurrection',
      () async {
    final ref = col.doc('del_x');
    created.add(ref);
    await outcomeOf(ref.path, () => ref.set({'n': 1}));
    final seen = <bool>[];
    final sub = ref.snapshots().listen((s) => seen.add(s.exists));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await outcomeOf(ref.path, () => ref.delete());
    await _await(() => seen.isNotEmpty && seen.last == false ? 'ok' : null,
        timeout: const Duration(seconds: 4));
    await sub.cancel();
    expect(seen.isNotEmpty && seen.last == false,
        'listener did not observe the deletion; saw $seen');
    final cached = await ref.get(const GetOptions(source: Source.cache));
    expect(!cached.exists,
        'deleted doc reappeared from cache — tombstone missing');
  });

  // =====================================================================
  print('\n[ Transactions ]');
  // =====================================================================
  await check('runTransaction read-modify-write', () async {
    final ref = col.doc('txdoc');
    created.add(ref);
    await outcomeOf(ref.path, () => ref.set({'bal': 100}));
    await db.runTransaction((tx) async {
      final s = await tx.get(ref);
      tx.update(ref, {'bal': (s.data()!['bal'] as int) + 50});
    });
    final d = (await ref.get(const GetOptions(source: Source.server))).data()!;
    expect(d['bal'] == 150, 'transaction result wrong: ${d['bal']}');
  });

  await check('runTransaction read-only query', () async {
    final count = await db.runTransaction((tx) async {
      final docs =
          await tx.query(col.where('priority', isGreaterThanOrEqualTo: 1));
      return docs.length;
    });
    expect(count >= 5, 'tx query returned $count');
  });

  // =====================================================================
  print('\n[ Access-rule denials (another user / unrelated collections) ]');
  // =====================================================================
  const otherDoc = 'userData/other-user/data/x';

  await expectDenied('get another user\'s document', () async {
    await db.doc(otherDoc).get(const GetOptions(source: Source.server));
  });

  await expectDenied('query another user\'s collection', () async {
    await db
        .collection('userData')
        .doc('other-user')
        .collection('data')
        .get(const GetOptions(source: Source.server));
  });

  await expectDenied('query an unrelated top-level collection', () async {
    await db.collection('posts').get(const GetOptions(source: Source.server));
  });

  await expectDenied('count() on a denied collection', () async {
    await db
        .collection('userData')
        .doc('other-user')
        .collection('data')
        .count();
  });

  await expectDenied('transaction committing a write to a denied path',
      () async {
    await db.runTransaction((tx) async {
      tx.set(db.doc(otherDoc), {'k': 1});
    });
  });

  await check('write to a denied path → WriteFailed(PERMISSION_DENIED)',
      () async {
    final out = await outcomeOf(otherDoc, () => db.doc(otherDoc).set({'k': 1}));
    expect(out.contains('PERMISSION_DENIED'),
        'expected a permission failure, got: $out');
  });

  // =====================================================================
  print('\n[ Cleanup ]');
  // =====================================================================
  await check('delete all documents created by this run', () async {
    final batch = db.batch();
    for (final ref in created) {
      batch.delete(ref);
    }
    await batch.commit();
    await db
        .waitForPendingWrites()
        .timeout(const Duration(seconds: 10), onTimeout: () {});
  });

  // --- summary ---
  await _shutdown();
  final total = _pass + _failures.length;
  print('\n${'=' * 48}');
  if (_failures.isEmpty) {
    print('ALL $_pass/$total CHECKS PASSED');
    exit(0);
  } else {
    print('${_failures.length} of $total CHECKS FAILED:');
    for (final f in _failures) {
      print('  - $f');
    }
    exit(1);
  }
}

Future<void> _shutdown() async {
  await _evSub.cancel();
  db.close();
}
