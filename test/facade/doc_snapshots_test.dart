import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

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

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());

  void installListenHandler({String subId = 'sub-1'}) {
    h.handler = (f) {
      switch (f['type']) {
        case 'listen':
          h.respond(f, {'subscriptionId': subId});
        case 'unlisten':
          h.respond(f, const {});
        default:
          h.respond(f, const {});
      }
    };
  }

  test('subscribes via a query on the parent filtered by __name__ (no limit)',
      () async {
    installListenHandler();
    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();

    final listen = h.requests.firstWhere((f) => f['type'] == 'listen');
    final query = listen['query'] as Map<String, Object?>;
    expect(query['collection'], 'users');
    expect(query['where'], {
      'field': '__name__',
      'op': 'eq',
      'value': {'stringValue': 'users/u1'},
    });
    // No limit: __name__ equality matches at most one document, and a limit on a
    // live listener can interact badly with server-side read filtering.
    expect(query.containsKey('limit'), isFalse);

    await sub.cancel();
  });

  test('emits a present DocumentSnapshot when the document exists', () async {
    installListenHandler();
    final events = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('users/u1').snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
      'sub-1',
      [
        wireDoc('users/u1', wireFields({'n': 1}))
      ],
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
    installListenHandler();
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
    installListenHandler();
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
    installListenHandler();
    final ref = h.db.doc('users/u1').withConverter(
          Converter<int>((d) => d['n'] as int, (v) => {'n': v}),
        );
    final events = <DocumentSnapshot<int>>[];
    final sub = ref.snapshots().listen(events.add);
    await pump();

    h.push(snapshotFrame(
      'sub-1',
      [
        wireDoc('users/u1', wireFields({'n': 7}))
      ],
      resumeToken: 1,
    ));
    await pump();

    expect(events.last.data(), 7);

    await sub.cancel();
  });

  test('cancelling the subscription unlistens', () async {
    installListenHandler();
    final sub = h.db.doc('users/u1').snapshots().listen((_) {});
    await pump();
    h.push(snapshotFrame('sub-1', const [], resumeToken: 1));
    await pump();

    await sub.cancel();
    await pump();

    expect(h.requests.where((f) => f['type'] == 'unlisten'), hasLength(1));
  });
}
