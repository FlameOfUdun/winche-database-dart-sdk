import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  final uri = Uri.parse('ws://fake/documents/ws');

  test('inMemory: true constructs without a directoryResolver', () {
    final db = WincheDatabase(WincheDatabaseConfig(uri: uri, inMemory: true));
    db.close();
  });

  test('native default requires a directoryResolver', () {
    // On the VM (_kIsWeb == false), omitting directoryResolver throws.
    expect(() => WincheDatabase(WincheDatabaseConfig(uri: uri)),
        throwsArgumentError);
  });

  test('inMemory: true with a directoryResolver throws', () {
    expect(
      () => WincheDatabase(WincheDatabaseConfig(
          uri: uri, inMemory: true, directoryResolver: () async => '/tmp/winche')),
      throwsArgumentError,
    );
  });

  test('withStore injects a store directly', () {
    final db = WincheDatabase.withStore(
        ConnectionConfig(uri: uri, autoReconnect: false), MemoryLocalStore());
    db.close();
  });
}
