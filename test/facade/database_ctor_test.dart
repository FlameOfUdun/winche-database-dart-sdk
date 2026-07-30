import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';
import 'package:winche_database/src/protocol/connection.dart'
    show ConnectionConfig;

void main() {
  final uri = Uri.parse('ws://fake/documents/ws');

  test('withStore injects a store directly', () async {
    final db = WincheDatabase(WincheApp('database-ctor'))
      ..debugBindStore(
        ConnectionConfig(
          uri: uri,
          // Reconnection is unconditional; without a channelFactory this
          // would attempt a real network dial (slow to fail) and then retry
          // forever. Fail fast with a real-but-small backoff instead.
          channelFactory: (_) => throw Exception('no real socket in this test'),
          sleeper: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
        ),
        MemoryLocalStore(),
      );
    await db.dispose();
  });
}
