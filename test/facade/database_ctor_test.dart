import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  final uri = Uri.parse('ws://fake/documents/ws');

  test('withStore injects a store directly', () async {
    final db = WincheDatabase(WincheApp('database-ctor'))
      ..debugBindStore(
          ConnectionConfig(uri: uri, autoReconnect: false), MemoryLocalStore());
    await db.dispose();
  });
}
