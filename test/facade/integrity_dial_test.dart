@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  test('a token the server refuses at the upgrade is dropped after two failed dials; the next dial gets a new one', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var exchanges = 0;
    final dialed = <String?>[];
    final revoked = {'wit.1'};   // the project revoked the first token early
    server.listen((request) async {
      if (request.uri.path == '/integrity/v1/exchange') {
        exchanges++;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'token': 'wit.$exchanges',
            'expiresAt': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
          }));
        await request.response.close();
        return;
      }
      final token = request.headers.value('x-winche-integrity');
      dialed.add(token);
      if (token == null || revoked.contains(token)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode({'type': 'welcome', 'connectionId': 'c1'}));
      socket.listen((_) {});
    });

    final base = 'http://127.0.0.1:${server.port}';
    final app = WincheApp('integrity-dial',
        options: WincheOptions(baseUrl: Uri.parse(base), appId: 'clinic-app', endpoints: {'database': Uri.parse('ws://127.0.0.1:${server.port}/documents/v1/ws')}));
    addTearDown(app.dispose);
    app.useIntegrity(const WincheDebugIntegrity('wdt_good'));
    final db = WincheDatabase(app)..settings = const WincheDatabaseSettings(allowSignedOut: true, inMemory: true);

    final sub = db.collection('public').snapshots().listen((_) {}, onError: (_) {});
    addTearDown(sub.cancel);
    await db.connectionStates.firstWhere((s) => s == ConnectionState.ready).timeout(const Duration(seconds: 10));

    expect(dialed, ['wit.1', 'wit.1', 'wit.2']);   // refused twice, then a fresh token
    expect(exchanges, 2);
  });
}
