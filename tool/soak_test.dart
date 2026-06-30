// Stress / soak run against the live sample server.
//
// Hammers the full stack under concurrency + volume to surface races/leaks the
// deterministic unit tests can't:
//   * many concurrent query + document listeners (stresses lazy-init, per-listener
//     emit, membership, subscribe/cancel churn)
//   * heavy concurrent write / update / delete / get / getAll churn
//   * eviction enabled with a small byte cap (eviction under churn + pinning)
//   * a durable store
// Then drives every doc to a deterministic terminal state and asserts the system
// converges correctly: deletions stick (no resurrection), query membership is
// exact, and doc listeners reflect final existence.
//
// Run the sample server first (uid hard-coded "user-123"; rule allows
// userData/{userId}/**), then:
//   dart run tool/soak_test.dart [ws://localhost:5183/documents/ws] [storeDir]
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:winche_database/winche_database.dart';

const uid = 'user-123';

Future<void> main(List<String> args) async {
  final wsUrl = args.isNotEmpty ? args[0] : 'ws://localhost:5183/documents/ws';
  final dir = args.length > 1
      ? args[1]
      : Directory.systemTemp.createTempSync('winche_soak').path;
  await Directory(dir).create(recursive: true);

  final rng = Random(1337); // deterministic op stream
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final col = 'userData/$uid/soak_$run';

  const docCount = 20; // pool of documents
  const queryListeners = 8;
  const docListeners = 8;
  const batches = 15;
  const opsPerBatch = 8; // concurrent ops per batch

  final db = WincheDatabase(WincheDatabaseConfig(
    uri: Uri.parse(wsUrl),
    directoryResolver: () async => dir,
    conflictPolicy: ConflictPolicy.clientWins, // auto-resolve so the queue never stalls
    cacheSizeBytes: 16 * 1024, // small cap → eviction fires under churn
  ));

  final errors = <String>[];
  void capture(String where, Object e) => errors.add('$where: $e');

  String docPath(int i) => '$col/d$i';
  DocumentReference<Map<String, Object?>> docRef(int i) => db.doc(docPath(i));

  // ── Listeners ────────────────────────────────────────────────────────────
  final querySubs = <StreamSubscription<dynamic>>[];
  final lastQuery = <int, QuerySnapshot<Map<String, Object?>>>{};
  for (var q = 0; q < queryListeners; q++) {
    final idx = q;
    // Mix of shapes: unfiltered, filtered, and limited — distinct server targets.
    var query = db.collection(col).where('active', isEqualTo: true);
    if (q % 3 == 1) query = db.collection(col); // unfiltered
    if (q % 3 == 2) {
      query = db.collection(col).orderBy('v').limit(10);
    }
    querySubs.add(query.snapshots().listen(
          (s) => lastQuery[idx] = s,
          onError: (Object e) => capture('queryListener[$idx]', e),
        ));
  }

  final docSubs = <StreamSubscription<dynamic>>[];
  final lastDoc = <int, DocumentSnapshot<Map<String, Object?>>>{};
  for (var d = 0; d < docListeners; d++) {
    final i = d;
    docSubs.add(docRef(i).snapshots().listen(
          (s) => lastDoc[i] = s,
          onError: (Object e) => capture('docListener[$i]', e),
        ));
  }

  await Future<void>.delayed(const Duration(milliseconds: 500));
  stdout.writeln('listeners up: $queryListeners query + $docListeners doc');

  // ── Churn ──────────────────────────────────────────────────────────────────
  var ops = 0;
  for (var b = 0; b < batches; b++) {
    stdout.writeln('  batch $b ...');
    final futures = <Future<void>>[];
    for (var k = 0; k < opsPerBatch; k++) {
      final i = rng.nextInt(docCount);
      final roll = rng.nextInt(10);
      ops++;
      final label = 'd$i roll=$roll';
      futures.add(() async {
        try {
          await (() async {
            if (roll < 4) {
              await docRef(i).set({'active': true, 'v': rng.nextInt(1000)});
            } else if (roll < 6) {
              await docRef(i).update({'v': rng.nextInt(1000)});
            } else if (roll < 8) {
              await docRef(i).delete();
            } else if (roll < 9) {
              await docRef(i).get(const GetOptions(source: Source.cache));
            } else {
              final refs = [for (var j = 0; j < 5; j++) docRef(rng.nextInt(docCount))];
              await db.getAll(refs, const GetOptions(source: Source.cache));
            }
          })().timeout(const Duration(seconds: 15));
        } on TimeoutException {
          capture('TIMEOUT', label);
        } on NotFoundException {
          // update on a missing doc — expected under random churn
        } on WincheException catch (e) {
          capture('op($label)', e);
        }
      }());
    }
    // Transient listener churn: create + cancel short-lived listeners.
    if (b % 5 == 0) {
      final transient = <StreamSubscription<dynamic>>[
        for (var t = 0; t < 5; t++)
          db.collection(col).snapshots().listen((_) {},
              onError: (Object e) => capture('transient', e)),
      ];
      futures.add(Future<void>.delayed(const Duration(milliseconds: 30),
          () => Future.wait(transient.map((s) => s.cancel()))));
    }
    await Future.wait(futures);
    // Pace batches: a write that triggers a drain awaits the queue emptying, so a
    // non-stop burst would block it for the whole run. A small gap lets each
    // batch's writes drain — closer to real usage.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  stdout.writeln('churn done: $ops ops, ${errors.length} errors so far');

  // ── Terminal state (deterministic): even = present, odd = deleted ──────────
  final present = <int>{};
  final deleted = <int>{};
  for (var i = 0; i < docCount; i++) {
    if (i.isEven) {
      await docRef(i).set({'active': true, 'v': i});
      present.add(i);
    } else {
      try {
        await docRef(i).delete();
      } on WincheException catch (e) {
        capture('terminal-delete(d$i)', e);
      }
      deleted.add(i);
    }
  }
  stdout.writeln('terminal writes queued; draining...');
  await db.waitForPendingWrites();
  stdout.writeln('drained; settling...');
  await Future<void>.delayed(const Duration(seconds: 3)); // let listeners settle

  // ── Assertions ─────────────────────────────────────────────────────────────
  final failures = <String>[];

  if (errors.isNotEmpty) {
    failures.add('unexpected errors (${errors.length}): ${errors.take(5).join(" | ")}');
  }

  // Query listeners: unfiltered + filtered must show exactly the present set.
  for (var q = 0; q < queryListeners; q++) {
    if (q % 3 == 2) continue; // limited query: membership is a capped subset — skip exact check
    final snap = lastQuery[q];
    if (snap == null) {
      failures.add('queryListener[$q] never emitted');
      continue;
    }
    final got = snap.docs.map((d) => int.parse(d.id.substring(1))).toSet();
    if (!_setEq(got, present)) {
      failures.add('queryListener[$q] membership wrong: got ${_sorted(got)} want ${_sorted(present)}');
    }
  }

  // Doc listeners: existence matches terminal state.
  for (var i = 0; i < docListeners; i++) {
    final snap = lastDoc[i];
    if (snap == null) {
      failures.add('docListener[$i] never emitted');
      continue;
    }
    if (snap.exists != present.contains(i)) {
      failures.add('docListener[$i] exists=${snap.exists}, expected ${present.contains(i)}');
    }
  }

  // No resurrection: a cache read of a deleted doc must be missing.
  for (final i in deleted) {
    final s = await docRef(i).get(const GetOptions(source: Source.cache));
    if (s.exists) failures.add('deleted d$i resurfaced from cache');
  }

  // getAll reflects terminal existence.
  final all = await db.getAll(
      [for (var i = 0; i < docCount; i++) docRef(i)],
      const GetOptions(source: Source.cache));
  for (var i = 0; i < docCount; i++) {
    if (all[i].exists != present.contains(i)) {
      failures.add('getAll d$i exists=${all[i].exists}, expected ${present.contains(i)}');
    }
  }

  // ── Teardown (also a clean-cancel / leak check) ────────────────────────────
  await Future.wait([
    for (final s in querySubs) s.cancel(),
    for (final s in docSubs) s.cancel(),
  ]);
  db.close();

  stdout.writeln('dir=$dir  present=${present.length} deleted=${deleted.length} '
      'queryListeners=$queryListeners docListeners=$docListeners ops=$ops');
  if (failures.isEmpty) {
    stdout.writeln('SOAK OK — converged correctly under churn');
    exit(0);
  }
  stderr.writeln('SOAK FAILED:');
  for (final f in failures) {
    stderr.writeln('  - $f');
  }
  exit(1);
}

bool _setEq(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);
List<int> _sorted(Set<int> s) => s.toList()..sort();
