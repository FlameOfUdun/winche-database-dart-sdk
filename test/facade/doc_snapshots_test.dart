import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

Map<String, Object?> snapshotFrame(
  String subId,
  List<Map<String, Object?>> documents, {
  int? resumeToken,
  String readTime = '2026-06-08T12:00:00+00:00',
}) =>
    {
      'type': 'listen.snapshot',
      'subscriptionId': subId,
      'documents': documents,
      'readTime': readTime,
      if (resumeToken != null) 'resumeToken': resumeToken,
    };

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  void installDocListenHandler({String subId = 'sub-1'}) {
    h.handler = (f) {
      switch (f['type']) {
        case 'doc.listen':
          h.respond(f, {'subscriptionId': subId});
        default:
          h.respond(f, const {});
      }
    };
  }

  test('subscribes via doc.listen with the document path (not a query listen)',
      () async {
    installDocListenHandler();
    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();

    final docListen =
        h.requests.firstWhere((f) => f['type'] == 'doc.listen');
    expect(docListen['path'], 'users/u1');
    expect(h.requests.any((f) => f['type'] == 'listen'), isFalse,
        reason: 'doc.snapshots must use doc.listen, not a query listen');

    await sub.cancel();
  });

  test('emits a present DocumentSnapshot when the document exists', () async {
    installDocListenHandler();
    final events = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
      'sub-1',
      [wireDoc('users/u1', wireFields({'n': 1}))],
      resumeToken: 1,
    ));
    await pump();

    // First emission is cache-first (missing); the server snapshot follows.
    expect(events.last.exists, isTrue);
    expect(events.last.id, 'u1');
    expect(events.last.path, 'users/u1');
    expect(events.last.data(), {'n': 1});

    await sub.cancel();
  });

  test('emits a missing snapshot when the document is absent', () async {
    installDocListenHandler();
    final events = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame('sub-1', const [], resumeToken: 1));
    await pump();

    expect(events.last.exists, isFalse);
    expect(events.last.data(), isNull);
    expect(events.last.id, 'u1');
    expect(events.last.path, 'users/u1');

    await sub.cancel();
  });

  test('emits again when the document changes', () async {
    installDocListenHandler();
    final events = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
      'sub-1',
      [
        wireDoc('users/u1', wireFields({'n': 1}),
            updateTime: '2026-06-08T12:00:00+00:00'),
      ],
      resumeToken: 1,
    ));
    await pump();

    h.push(snapshotFrame(
      'sub-1',
      [
        wireDoc('users/u1', wireFields({'n': 2}),
            updateTime: '2026-06-08T13:00:00+00:00'),
      ],
      resumeToken: 2,
    ));
    await pump();

    expect(events.last.data(), {'n': 2});

    await sub.cancel();
  });

  test('applies the converter to emitted snapshots', () async {
    installDocListenHandler();
    final ref = h.db.doc('users/u1').withConverter(
          Converter<int>((d) => d['n'] as int, (v) => {'n': v}),
        );
    final events = <DocumentSnapshot<int>>[];
    final sub = ref.snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
      'sub-1',
      [wireDoc('users/u1', wireFields({'n': 7}))],
      resumeToken: 1,
    ));
    await pump();

    expect(events.last.data(), 7);

    await sub.cancel();
  });

  test('cancelling the subscription sends unlisten', () async {
    installDocListenHandler();
    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();
    h.push(snapshotFrame('sub-1', const [], resumeToken: 1));
    await pump();

    await sub.cancel();
    await pump();

    expect(h.requests.where((f) => f['type'] == 'unlisten'), hasLength(1));
  });
}
