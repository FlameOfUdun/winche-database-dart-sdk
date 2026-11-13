// Against a running emulator whose rules allow `match public/{doc} { allow read: if true; }`:
//   dart run tool/signed_out_live.dart [host:port]
import 'dart:io';

import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

Future<void> main(List<String> args) async {
  final target = args.isEmpty ? 'localhost:9090' : args.first;
  final app = WincheApp('signed-out-live', options: WincheOptions(endpoints: {'database': Uri.parse('ws://$target/documents/v1/ws')}));
  final db = WincheDatabase(app)..config = const WincheDatabaseConfig(allowSignedOut: true, inMemory: true);

  final doc = await db.doc('public/welcome').get();
  stdout.writeln('signed-out read public/welcome: exists=${doc.exists} data=${doc.data()}');
  try {
    await db.doc('users/u1').get();
    stdout.writeln('signed-out read users/u1: allowed (unexpected)');
  } on WincheProtocolException catch (e) {
    stdout.writeln('signed-out read users/u1: refused (${e.runtimeType})');
  }
  // Writes are offline-first: set() completes locally, and the server's answer
  // arrives on syncEvents.
  final rejected = db.syncEvents.first.timeout(const Duration(seconds: 10));
  await db.doc('public/new').set({'x': 1});
  stdout.writeln('signed-out write public/new: ${await rejected}');
  await app.dispose();
}
