import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  test('online get carries fromCache=false metadata', () async {
    final h = FacadeHarness();
    h.handler = (f) => h.respond(f, {
          'document': wireDoc('users/u1', wireFields({'n': 1})),
        });
    final snap = await h.db.doc('users/u1').get();
    expect(snap.exists, isTrue);
    expect(snap.metadata.fromCache, isFalse);
    expect(snap.metadata.hasPendingWrites, isFalse);
    await h.close();
  });

  test('online query carries fromCache=false metadata', () async {
    final h = FacadeHarness();
    h.handler = (f) => h.respond(f, {
          'documents': [
            wireDoc('users/u1', wireFields({'n': 1}))
          ],
          'hasMore': false,
        });
    final qs = await h.db.collection('users').get();
    expect(qs.metadata.fromCache, isFalse);
    await h.close();
  });

  test('GetOptions(source: server) is accepted and still reads the server',
      () async {
    final h = FacadeHarness();
    h.handler = (f) => h.respond(f, {'document': null});
    final snap =
        await h.db.doc('users/u1').get(const GetOptions(source: Source.server));
    expect(snap.exists, isFalse);
    expect(snap.metadata.fromCache, isFalse);
    await h.close();
  });
}
