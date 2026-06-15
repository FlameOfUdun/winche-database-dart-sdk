import 'package:test/test.dart';
import 'package:winche_database/src/offline/read_coordinator.dart';

void main() {
  test('Source default is serverOrCache', () {
    expect(const GetOptions().source, Source.serverOrCache);
  });
}
