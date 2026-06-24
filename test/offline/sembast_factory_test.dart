import 'package:sembast/sembast.dart';
import 'package:test/test.dart';
import 'package:winche_database/src/offline/sembast_factory.dart';

void main() {
  test('sembastFactory returns a usable DatabaseFactory on the VM', () {
    expect(sembastFactory(), isA<DatabaseFactory>());
  });
}
