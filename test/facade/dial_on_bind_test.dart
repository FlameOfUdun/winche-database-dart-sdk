import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

void main() {
  // A session must connect because it exists, not because the app happened to
  // read something. Otherwise a restored offline queue never drains in an app
  // that only ever writes.
  test('binding a session dials with no operation performed', () async {
    final h = FacadeHarness();
    addTearDown(h.close);

    // Deliberately no reads, no writes, no listeners.
    await pump();

    expect(h.db.connectionState, equals(ConnectionState.ready),
        reason: 'the session must dial on its own');
  });
}
