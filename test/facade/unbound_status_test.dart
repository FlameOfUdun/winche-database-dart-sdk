import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  // A connection chip built before anyone signs in must read "not connected",
  // not crash the widget tree.
  test('connectionState is readable while unbound', () {
    final db = WincheDatabase(WincheApp('unbound-status'));
    addTearDown(db.dispose);

    expect(db.connectionState, equals(ConnectionState.disconnected));
  });

  test('connectionStates is subscribable while unbound', () async {
    final db = WincheDatabase(WincheApp('unbound-status-stream'));
    addTearDown(db.dispose);

    final seen = <ConnectionState>[];
    db.connectionStates.listen(seen.add);
    await Future<void>.delayed(Duration.zero);

    expect(seen, equals([ConnectionState.disconnected]));
  });
}
