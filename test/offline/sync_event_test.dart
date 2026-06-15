import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  test('ConflictPolicy has manual/clientWins/serverWins', () {
    expect(
        ConflictPolicy.values,
        containsAll([
          ConflictPolicy.manual,
          ConflictPolicy.clientWins,
          ConflictPolicy.serverWins
        ]));
  });
}
