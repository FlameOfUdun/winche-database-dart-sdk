import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  List<String> frameTypes() =>
      h.requests.map((f) => f['type'] as String).toList();

  test('read-write transaction: begin → commit with staged writes', () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-1'});
        case 'tx.commit':
          h.respond(f, writeResultsPayload());
        default:
          h.respond(f, const {});
      }
    };

    final result = await h.db.runTransaction((tx) async {
      tx.set(h.db.doc('users/u1'), {'name': 'Alice'});
      return 'done';
    });

    expect(result, 'done');
    expect(frameTypes(), ['tx.begin', 'tx.commit']);

    final commit = h.requests.firstWhere((f) => f['type'] == 'tx.commit');
    expect(commit['transactionId'], 'tx-1');
    final writes = commit['writes'] as List<Object?>;
    expect((writes.single as Map)['set'], isNotNull);
  });

  test('read-only transaction rolls back instead of committing', () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-1'});
        case 'tx.get':
          h.respond(f, {
            'document': wireDoc('users/u1', wireFields({'n': 1}))
          });
        case 'tx.rollback':
          h.respond(f, const {});
        default:
          h.respond(f, const {});
      }
    };

    final n = await h.db.runTransaction((tx) async {
      final snap = await tx.get(h.db.doc('users/u1'));
      return snap.data()!['n'];
    });

    expect(n, 1);
    expect(frameTypes(), ['tx.begin', 'tx.get', 'tx.rollback']);
    expect(frameTypes().contains('tx.commit'), isFalse);
  });

  test('tx.get parses a document; tx.query parses a list', () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-1'});
        case 'tx.get':
          h.respond(f, {
            'document': wireDoc('users/u1', wireFields({'n': 1}))
          });
        case 'tx.query':
          h.respond(f, {
            'documents': [
              wireDoc('users/u1', wireFields({'n': 1})),
              wireDoc('users/u2', wireFields({'n': 2})),
            ],
          });
        case 'tx.rollback':
          h.respond(f, const {});
        default:
          h.respond(f, const {});
      }
    };

    await h.db.runTransaction((tx) async {
      final doc = await tx.get(h.db.doc('users/u1'));
      expect(doc.exists, isTrue);
      expect(doc.id, 'u1');

      final list = await tx.query(h.db.collection('users'));
      expect(list.map((d) => d.id), ['u1', 'u2']);
    });

    final getFrame = h.requests.firstWhere((f) => f['type'] == 'tx.get');
    expect(getFrame['path'], 'users/u1');
    expect(getFrame['transactionId'], 'tx-1');
    final queryFrame = h.requests.firstWhere((f) => f['type'] == 'tx.query');
    expect((queryFrame['query'] as Map)['collection'], 'users');
  });

  test('reading after a staged write throws StateError and rolls back',
      () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-1'});
        default:
          h.respond(f, const {});
      }
    };

    await expectLater(
      h.db.runTransaction((tx) async {
        tx.set(h.db.doc('users/u1'), {'a': 1});
        await tx.get(h.db.doc('users/u2')); // read after write → illegal
      }),
      throwsA(isA<StateError>()),
    );

    expect(frameTypes().contains('tx.rollback'), isTrue);
    expect(frameTypes().contains('tx.commit'), isFalse);
  });

  test('non-aborted handler exception rolls back and rethrows', () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-1'});
        default:
          h.respond(f, const {});
      }
    };

    await expectLater(
      h.db.runTransaction((tx) async {
        throw const FormatException('boom');
      }),
      throwsA(isA<FormatException>()),
    );
    expect(frameTypes().contains('tx.rollback'), isTrue);
  });

  test('ABORTED on commit retries with a fresh begin, then succeeds', () async {
    var begins = 0;
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          begins++;
          h.respond(f, {'transactionId': 'tx-$begins'});
        case 'tx.commit':
          if (begins == 1) {
            h.respondError(f, 'ABORTED', 'write conflict');
          } else {
            h.respond(f, writeResultsPayload());
          }
        default:
          h.respond(f, const {});
      }
    };

    final result = await h.db.runTransaction((tx) async {
      tx.set(h.db.doc('users/u1'), {'a': 1});
      return 'ok';
    }, maxAttempts: 3);

    expect(result, 'ok');
    expect(begins, 2, reason: 'one retry after the aborted commit');
  });

  test('ABORTED from a read inside the handler retries', () async {
    var begins = 0;
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          begins++;
          h.respond(f, {'transactionId': 'tx-$begins'});
        case 'tx.get':
          if (begins == 1) {
            h.respondError(f, 'ABORTED', 'conflict');
          } else {
            h.respond(f, {
              'document': wireDoc('users/u1', wireFields({'n': 1}))
            });
          }
        case 'tx.rollback':
          h.respond(f, const {});
        default:
          h.respond(f, const {});
      }
    };

    final n = await h.db.runTransaction((tx) async {
      final snap = await tx.get(h.db.doc('users/u1'));
      return snap.data()!['n'];
    }, maxAttempts: 3);

    expect(n, 1);
    expect(begins, 2);
  });

  test('exhausting maxAttempts rethrows the AbortedException', () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-x'});
        case 'tx.commit':
          h.respondError(f, 'ABORTED', 'always conflicts');
        default:
          h.respond(f, const {});
      }
    };

    await expectLater(
      h.db.runTransaction((tx) async {
        tx.set(h.db.doc('users/u1'), {'a': 1});
      }, maxAttempts: 2),
      throwsA(isA<AbortedException>()),
    );
  });

  test('staged update and delete are sent in the commit', () async {
    h.handler = (f) {
      switch (f['type']) {
        case 'tx.begin':
          h.respond(f, {'transactionId': 'tx-1'});
        case 'tx.commit':
          h.respond(f, writeResultsPayload(count: 2));
        default:
          h.respond(f, const {});
      }
    };

    await h.db.runTransaction((tx) async {
      tx.update(h.db.doc('users/u1'), {'a': 1});
      tx.delete(h.db.doc('users/u2'));
    });

    final commit = h.requests.firstWhere((f) => f['type'] == 'tx.commit');
    final writes = commit['writes'] as List<Object?>;
    expect((writes[0] as Map).keys.single, 'update');
    expect((writes[1] as Map).keys.single, 'delete');
  });
}
