// End-to-end driver for the example app, against a live server.
//
// Drives the REAL widgets against a REAL server — no fakes, no mocks.
// `runAsync` is what makes that possible: the default fake-async zone freezes
// the socket's timers, so nothing would ever arrive.
//
// Skips itself when no server is listening, so it is safe to run always:
//
//   dotnet run --launch-profile http   (from samples/Winche.Database.Sample)
//   flutter test
//
// This is the test that caught the sign-out race: `_signOut` announced before
// clearing `_uid`, so the `connectionStates` listener rebuilt the records tab
// against an already-unbound database and threw into the widget tree.
//
// ignore_for_file: avoid_print — progress output is the point of this file;
// when a step fails you want to see how far it got.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_flutter_demo/main.dart';

/// Pumps for real wall-clock time so live frames can actually land.
Future<void> settle(WidgetTester tester,
    {Duration total = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(total);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Pumps until [test] passes or the deadline expires. Returns whether it passed,
/// so a caller can assert with a useful message instead of a bare timeout.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return test();
}

/// Whether anything is listening where the app expects the server.
Future<bool> serverIsUp() async {
  final uri = Uri.parse(kUri);
  try {
    final socket = await Socket.connect(uri.host, uri.port,
        timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  testWidgets('example app end to end against a live server', (tester) async {
    await tester.runAsync(() async {
      if (!await serverIsUp()) {
        markTestSkipped(
          'no server on $kUri — start the sample API first: '
          'dotnet run --launch-profile http',
        );
        return;
      }
      tester.view.physicalSize = const Size(1400, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // A private store directory, for two reasons. `path_provider`'s platform
      // channel does not exist under `flutter test`, so the app's own resolver
      // would throw; and the running app already owns its sembast files, which
      // must not be opened by a second process.
      final dir = Directory.systemTemp
          .createTempSync('winche_e2e_')
          .path
          .replaceAll(r'\', '/');
      addTearDown(() {
        try {
          Directory(dir).deleteSync(recursive: true);
        } catch (_) {
          // Best effort: the socket may still hold a handle on Windows.
        }
      });

      Winche.initializeApp(
        options: WincheOptions(
          databaseEndpoint: Uri.parse(kUri),
          directoryResolver: () async => dir,
        ),
      );
      addTearDown(() async => Winche.deinitializeApp());

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await settle(tester);

      // ---------------------------------------------------------------
      // 1-2. The app auto-signs-in as alice, so a session must bind and dial
      // without any interaction. The signed-out view is reached later, via an
      // explicit sign-out (step 10).
      // ---------------------------------------------------------------
      final connected = await pumpUntil(
          tester, () => find.text('Add').evaluate().isNotEmpty);
      expect(connected, isTrue,
          reason: 'auto sign-in never bound a session (no Add button)');
      expect(find.text('Signed out'), findsNothing);
      print('  [ok] 1. auto-signed in as alice, session bound');

      // ---------------------------------------------------------------
      // 3. Create a record through the editor sheet.
      // ---------------------------------------------------------------
      final title = 'E2E ${DateTime.now().millisecondsSinceEpoch}';
      await tester.tap(find.text('Add'));
      await settle(tester, total: const Duration(seconds: 1));
      expect(find.text('New record'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, title);
      await settle(tester, total: const Duration(seconds: 1));
      await tester.tap(find.text('Save'));
      await settle(tester, total: const Duration(seconds: 4));

      final created =
          await pumpUntil(tester, () => find.text(title).evaluate().isNotEmpty);
      expect(created, isTrue, reason: 'the new record never appeared in the list');
      print('  [ok] 3. created a record, live list picked it up');

      // ---------------------------------------------------------------
      // 4. Toggle done via the tile checkbox.
      // ---------------------------------------------------------------
      final tile = find.ancestor(
          of: find.text(title), matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: tile, matching: find.byType(Checkbox)));
      await settle(tester, total: const Duration(seconds: 3));
      print('  [ok] 4. toggled done');

      // ---------------------------------------------------------------
      // 5. Filters: Done shows it, Active does not.
      // ---------------------------------------------------------------
      await tester.tap(find.widgetWithText(FilterChip, 'Done'));
      await settle(tester, total: const Duration(seconds: 3));
      final inDone =
          await pumpUntil(tester, () => find.text(title).evaluate().isNotEmpty);
      expect(inDone, isTrue, reason: 'a done record is missing from the Done filter');

      await tester.tap(find.widgetWithText(FilterChip, 'Active'));
      await settle(tester, total: const Duration(seconds: 3));
      final goneFromActive =
          await pumpUntil(tester, () => find.text(title).evaluate().isEmpty);
      expect(goneFromActive, isTrue,
          reason: 'a done record still shows under the Active filter');

      await tester.tap(find.widgetWithText(FilterChip, 'All'));
      await settle(tester, total: const Duration(seconds: 3));
      print('  [ok] 5. filters All/Active/Done query the server correctly');

      // ---------------------------------------------------------------
      // 6. Server-side count.
      // ---------------------------------------------------------------
      await tester.tap(find.byIcon(Icons.tag));
      // Look for ANY SnackBar: _showCount reports failure the same way it
      // reports success, so matching only the success text would make a real
      // count failure indistinguishable from the snack never appearing.
      final snacked = await pumpUntil(
          tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
      final snackText = snacked
          ? (find
              .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .join(' | '))
          : '(no snackbar appeared)';
      expect(snacked, isTrue, reason: 'count() produced no feedback at all');
      expect(snackText, contains('Server count'),
          reason: 'count() reported: $snackText');
      print('  [ok] 6. server count returned — "$snackText"');

      // ---------------------------------------------------------------
      // 7. Switch to bob — alice's rows must not leak into his session.
      // ---------------------------------------------------------------
      await tester.tap(find.byType(PopupMenuButton<({String? uid})>));
      await settle(tester, total: const Duration(seconds: 1));
      await tester.tap(find.text('bob').last);
      await settle(tester, total: const Duration(seconds: 5));

      final isolated =
          await pumpUntil(tester, () => find.text(title).evaluate().isEmpty);
      expect(isolated, isTrue,
          reason: "alice's record is visible in bob's session — rules or store "
              'scoping is broken');
      print('  [ok] 7. switched to bob; alice rows correctly absent');

      // ---------------------------------------------------------------
      // 8. Switch back to alice — her record is still there.
      // ---------------------------------------------------------------
      await tester.tap(find.byType(PopupMenuButton<({String? uid})>));
      await settle(tester, total: const Duration(seconds: 1));
      await tester.tap(find.text('alice').last);
      await settle(tester, total: const Duration(seconds: 5));

      final restored =
          await pumpUntil(tester, () => find.text(title).evaluate().isNotEmpty);
      expect(restored, isTrue, reason: "alice's record vanished after switching back");
      print('  [ok] 8. switched back to alice; her record is intact');

      // ---------------------------------------------------------------
      // 9. Delete it.
      // ---------------------------------------------------------------
      final tile2 = find.ancestor(
          of: find.text(title), matching: find.byType(ListTile));
      await tester.tap(
          find.descendant(of: tile2, matching: find.byIcon(Icons.delete_outline)));
      await settle(tester, total: const Duration(seconds: 4));
      final deleted =
          await pumpUntil(tester, () => find.text(title).evaluate().isEmpty);
      expect(deleted, isTrue, reason: 'the deleted record is still listed');
      print('  [ok] 9. deleted the record');

      // ---------------------------------------------------------------
      // 10. Sign out — the bug that shipped once. Must actually unbind.
      // ---------------------------------------------------------------
      await tester.tap(find.byType(PopupMenuButton<({String? uid})>));
      await settle(tester, total: const Duration(seconds: 1));
      await tester.tap(find.text('Sign out'));
      await settle(tester, total: const Duration(seconds: 3));
      final signedOut = await pumpUntil(
          tester, () => find.text('Signed out').evaluate().isNotEmpty);
      expect(signedOut, isTrue, reason: 'sign-out did nothing — the menu bug is back');
      print('  [ok] 10. signed out, database unbound again');

      // ---------------------------------------------------------------
      // 11. Sign back in from the signed-out view — a fresh session binds.
      // ---------------------------------------------------------------
      expect(find.text('Sign in as alice'), findsOneWidget);
      await tester.tap(find.text('Sign in as alice'));
      await settle(tester, total: const Duration(seconds: 5));
      final reboundIn = await pumpUntil(
          tester, () => find.text('Add').evaluate().isNotEmpty);
      expect(reboundIn, isTrue, reason: 'could not sign back in after signing out');
      print('  [ok] 11. signed back in; a new session bound');

      // Let the socket close before the test zone tears down.
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, total: const Duration(seconds: 2));
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
