import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  final uri = Uri.parse('ws://fake/documents/ws');

  test('inMemory: true constructs without a directoryResolver', () async {
    final db = WincheDatabase(WincheDatabaseConfig(uri: uri, inMemory: true));
    await db.close();
  });

  test('native default requires a directoryResolver', () {
    // On the VM (_kIsWeb == false), omitting directoryResolver throws.
    expect(
        () => WincheDatabase(WincheDatabaseConfig(
            uri: uri, namespaceResolver: () => 'u1')),
        throwsArgumentError);
  });

  test('a persistent store requires a namespaceResolver', () {
    expect(
        () => WincheDatabase(WincheDatabaseConfig(
            uri: uri, directoryResolver: () async => '/tmp/winche')),
        throwsArgumentError);
  });

  test('inMemory: true with a directoryResolver throws', () {
    expect(
      () => WincheDatabase(WincheDatabaseConfig(
          uri: uri, inMemory: true, directoryResolver: () async => '/tmp/winche')),
      throwsArgumentError,
    );
  });

  test('withStore injects a store directly', () async {
    final db = WincheDatabase.withStore(
        ConnectionConfig(uri: uri, autoReconnect: false), MemoryLocalStore());
    await db.close();
  });
}
