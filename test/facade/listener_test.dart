import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

/// Builds a `listen.snapshot` server frame.
Map<String, Object?> snapshotFrame(
  String subId,
  List<Map<String, Object?>> documents, {
  required int resumeToken,
  String readTime = '2026-06-08T12:00:00+00:00',
}) =>
    {
      'type': 'listen.snapshot',
      'subscriptionId': subId,
      'documents': documents,
      'readTime': readTime,
      'resumeToken': resumeToken,
    };

/// Builds a `listen.delta` server frame.
Map<String, Object?> deltaFrame(
  String subId,
  List<Map<String, Object?>> changes, {
  required int count,
  required int resumeToken,
  String readTime = '2026-06-08T12:00:01+00:00',
}) =>
    {
      'type': 'listen.delta',
      'subscriptionId': subId,
      'changes': changes,
      'count': count,
      'readTime': readTime,
      'resumeToken': resumeToken,
    };

/// Builds a wire change entry for a `listen.delta`.
Map<String, Object?> wireChange(
  String kind,
  Map<String, Object?> document, {
  int oldIndex = -1,
  int newIndex = -1,
}) =>
    {
      'kind': kind,
      'document': document,
      'oldIndex': oldIndex,
      'newIndex': newIndex,
    };

/// A handler that answers `listen` with [subId] and `unlisten` with `{}`.
void Function(Map<String, Object?>) listenHandler(
  FacadeHarness h, {
  String subId = 'sub-1',
}) =>
    (frame) {
      switch (frame['type']) {
        case 'listen':
          h.respond(frame, {'subscriptionId': subId});
        case 'unlisten':
          h.respond(frame, const {});
        default:
          h.respond(frame, const {});
      }
    };

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());

  QueryReference<Map<String, Object?>> users() => h.db.collection('users');

  int listenCount() => h.requests.where((f) => f['type'] == 'listen').length;
  int unlistenCount() =>
      h.requests.where((f) => f['type'] == 'unlisten').length;

  test('first snapshot emits all-added changes in order', () async {
    h.handler = listenHandler(h);

    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = users().snapshots().listen(events.add);
    await pump();

    expect(listenCount(), 1);

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1})),
          wireDoc('users/u2', wireFields({'n': 2})),
        ],
        resumeToken: 10));
    await pump();

    // First emission is the cache-first (empty) snapshot; the server snapshot
    // follows with the all-added changes.
    final snap = events.last;
    expect(snap.docs.map((d) => d.id), ['u1', 'u2']);
    expect(snap.docChanges.every((c) => c.type == DocumentChangeType.added),
        isTrue);
    expect(snap.docChanges.map((c) => c.newIndex), [0, 1]);

    await sub.cancel();
  });

  test('delta add inserts a document', () async {
    h.handler = listenHandler(h);
    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = users().snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1}))
        ],
        resumeToken: 1));
    await pump();

    h.push(deltaFrame(
        'sub-1',
        [
          wireChange('added', wireDoc('users/u2', wireFields({'n': 2})),
              newIndex: 1),
        ],
        count: 2,
        resumeToken: 2));
    await pump();

    expect(events.last.docs.map((d) => d.id), ['u1', 'u2']);
    expect(events.last.docChanges.single.type, DocumentChangeType.added);
    expect(events.last.docChanges.single.doc.id, 'u2');

    await sub.cancel();
  });

  test('delta modified replaces a document in place', () async {
    h.handler = listenHandler(h);
    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = users().snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1}),
              updateTime: '2026-06-08T12:00:00+00:00'),
        ],
        resumeToken: 1));
    await pump();

    h.push(deltaFrame(
        'sub-1',
        [
          wireChange(
            'modified',
            wireDoc('users/u1', wireFields({'n': 99}),
                updateTime: '2026-06-08T12:05:00+00:00'),
            oldIndex: 0,
            newIndex: 0,
          ),
        ],
        count: 1,
        resumeToken: 2));
    await pump();

    expect(events.last.docs.single.data(), {'n': 99});
    expect(events.last.docChanges.single.type, DocumentChangeType.modified);

    await sub.cancel();
  });

  test('delta removed deletes a document', () async {
    h.handler = listenHandler(h);
    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = users().snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1})),
          wireDoc('users/u2', wireFields({'n': 2})),
        ],
        resumeToken: 1));
    await pump();

    h.push(deltaFrame(
        'sub-1',
        [
          wireChange('removed', wireDoc('users/u2', wireFields({'n': 2})),
              oldIndex: 1),
        ],
        count: 1,
        resumeToken: 2));
    await pump();

    expect(events.last.docs.map((d) => d.id), ['u1']);
    expect(events.last.docChanges.single.type, DocumentChangeType.removed);

    await sub.cancel();
  });

  test('re-snapshot diffs against previous (added + removed, no-op unchanged)',
      () async {
    h.handler = listenHandler(h);
    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = users().snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1}),
              updateTime: '2026-06-08T12:00:00+00:00'),
          wireDoc('users/u2', wireFields({'n': 2})),
        ],
        resumeToken: 1));
    await pump();

    // u2 removed, u3 added, u1 unchanged (same updateTime → not a change).
    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1}),
              updateTime: '2026-06-08T12:00:00+00:00'),
          wireDoc('users/u3', wireFields({'n': 3})),
        ],
        resumeToken: 2));
    await pump();

    final changes = events.last.docChanges;
    expect(events.last.docs.map((d) => d.id), ['u1', 'u3']);
    expect(changes.map((c) => '${c.type.name}:${c.doc.id}'),
        containsAll(['removed:u2', 'added:u3']));
    expect(changes.any((c) => c.doc.id == 'u1'), isFalse,
        reason: 'unchanged doc must not appear in changes');

    await sub.cancel();
  });

  test('count mismatch triggers a transparent re-subscribe', () async {
    h.handler = listenHandler(h);
    final events = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = users().snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1}))
        ],
        resumeToken: 1));
    await pump();
    expect(events, hasLength(2)); // cache-first (empty) + server snapshot

    // Delta that yields 2 docs but claims count 5 → mismatch.
    h.push(deltaFrame(
        'sub-1',
        [
          wireChange('added', wireDoc('users/u2', wireFields({'n': 2})),
              newIndex: 1),
        ],
        count: 5,
        resumeToken: 2));
    await pump();

    // No snapshot emitted for the mismatched delta; a fresh re-subscribe
    // occurred. The old subscription is dropped locally (the server already
    // considers it inconsistent), so no unlisten is sent — just a second listen.
    expect(events, hasLength(2));
    expect(unlistenCount(), 0);
    expect(listenCount(), 2);

    await sub.cancel();
  });

  test('subscribe failure surfaces as a stream error then done', () async {
    h.handler = (frame) {
      if (frame['type'] == 'listen') {
        h.respondError(frame, 'INVALID_QUERY', 'bad query');
      } else {
        h.respond(frame, const {});
      }
    };

    Object? error;
    var done = false;
    users().snapshots().listen(
          (_) {},
          onError: (Object e) => error = e,
          onDone: () => done = true,
        );
    await pump();

    expect(error, isA<InvalidQueryException>());
    // The consumer stream is NOT closed on a query error — the redesign keeps
    // live listeners alive across failures; only the error is surfaced once.
    expect(done, isFalse);
  });

  test('cancel sends an unlisten for the active subscription', () async {
    h.handler = listenHandler(h);
    final sub = users().snapshots().listen((_) {});
    await pump();

    h.push(snapshotFrame(
        'sub-1',
        [
          wireDoc('users/u1', wireFields({'n': 1}))
        ],
        resumeToken: 1));
    await pump();

    await sub.cancel();
    await pump();

    expect(unlistenCount(), 1);
    final unlisten = h.requests.firstWhere((f) => f['type'] == 'unlisten');
    expect(unlisten['subscriptionId'], 'sub-1');
  });

  test('denied live query surfaces a PermissionDeniedException on the stream',
      () async {
    h.handler = (f) {
      if (f['type'] == 'listen') {
        h.respondError(f, 'PERMISSION_DENIED', 'denied');
      }
    };
    final stream = h.db.collection('users').snapshots();
    // The live query emits a cache-first snapshot before the server responds,
    // so we expect a snapshot (possibly empty) followed by the error.
    await expectLater(
        stream,
        emitsInOrder([
          isA<QuerySnapshot<Map<String, Object?>>>(),
          emitsError(isA<PermissionDeniedException>()),
        ]));
    await h.close();
  });
}
