// Live end-to-end check for Phase 3 cold-start resume against the sample server.
//
// Exercises the real stack over a PERSISTENT store across two sessions:
//   Session 1 writes a doc, syncs it, and observes the server snapshot
//             (persisting the durable cache + resume token).
//   Session 2 (a fresh WincheDatabase over the SAME store = a "restart") cold-
//             starts: its first emission is the durable-cached doc (fromCache),
//             then a covered resume (listen.current) clears fromCache WITHOUT
//             losing the document (the C1 fix path).
//
// Run the sample server first (uid hard-coded to "user-123"; rule allows
// userData/{userId}/** when auth.uid == userId), then:
//   dart run tool/resume_e2e.dart [ws://localhost:5183/documents/ws] [storeDir]
import 'dart:io';

import 'package:winche_database/winche_database.dart';

Future<void> main(List<String> args) async {
  final wsUrl =
      args.isNotEmpty ? args[0] : 'ws://localhost:5183/documents/ws';
  final dir = args.length > 1
      ? args[1]
      : Directory.systemTemp.createTempSync('winche_resume_e2e').path;
  await Directory(dir).create(recursive: true);

  const uid = 'user-123';
  final runId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final path = 'userData/$uid/resume_$runId/doc1';

  WincheDatabase open() => WincheDatabase(WincheDatabaseConfig(
        uri: Uri.parse(wsUrl),
        directoryResolver: () async => dir,
      ));

  print('resume e2e  dir=$dir  path=$path');

  // ── Session 1: write + sync + observe a server snapshot ──────────────────
  final db1 = open();
  await db1.doc(path).set({'n': 1, 'name': 'Alice'});
  await db1.waitForPendingWrites();
  final seen1 = <bool>[];
  final sub1 = db1.doc(path).snapshots().listen((s) => seen1.add(s.exists));
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await sub1.cancel();
  db1.close();
  // close() fires the persistent-store close unawaited — give it a moment to
  // flush and release the file before session 2 reopens the same directory.
  await Future<void>.delayed(const Duration(seconds: 1));
  if (seen1.isEmpty || seen1.last != true) {
    throw StateError('session1: listener did not observe the doc; saw $seen1');
  }
  print('session1: doc written, synced, observed present');

  // ── Session 2: cold start over the SAME store ────────────────────────────
  final db2 = open();
  final emissions = <({bool exists, bool fromCache})>[];
  final sub2 = db2.doc(path).snapshots().listen((s) =>
      emissions.add((exists: s.exists, fromCache: s.metadata.fromCache)));
  await Future<void>.delayed(const Duration(seconds: 2));
  await sub2.cancel();
  db2.close();

  if (emissions.isEmpty) throw StateError('session2: no emissions');
  print('session2 emissions: $emissions');
  final first = emissions.first;
  final last = emissions.last;
  if (!first.exists || !first.fromCache) {
    throw StateError(
        'session2: cache-first emission should be present+fromCache; got $first');
  }
  if (!last.exists) {
    throw StateError('session2: cold-start LOST the document (C1 regression)');
  }
  if (last.fromCache) {
    throw StateError('session2: never went live (fromCache stuck true)');
  }
  print('OK: cold-start served the doc from durable cache and went live '
      '(fromCache cleared via covered resume)');
}
