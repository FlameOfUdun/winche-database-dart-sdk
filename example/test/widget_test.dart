import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_flutter_demo/main.dart';

void main() {
  // Smoke test: the app builds without a live connection (autoConnect: false,
  // so nobody ever signs in and the database is never touched beyond
  // construction). `WincheDatabase.instance` needs a Winche app to attach to,
  // so one is initialized here rather than via `main()`.
  //
  // runAsync lets the SDK's internal timers settle so they don't linger as
  // fake-async pending timers when the test ends.
  testWidgets('app renders', (tester) async {
    Winche.initializeApp(options: WincheOptions(databaseEndpoint: Uri.parse(kUri)));
    addTearDown(() => Winche.deinitializeApp());

    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: HomePage(autoConnect: false)),
      );
      await tester.pump();
      expect(find.text('Winche Records'), findsOneWidget);

      // Tear down so WsTransport.dispose's deferred timer drains.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
    });
  });

  // Guards the shape of the user menu in `_userSwitcher`.
  //
  // PopupMenuButton treats a *null* selection as a cancellation: it calls
  // `onCanceled` and never `onSelected`. A "Sign out" item written the obvious
  // way — `PopupMenuItem<String?>(value: null)` — therefore does nothing at all
  // when tapped, silently, with no error anywhere. That is exactly the bug this
  // app shipped with.
  //
  // The fix is to carry a non-null value that still means "no user", hence the
  // `({String? uid})` record. This test pins that distinction so nobody
  // "simplifies" it back.
  testWidgets('a null menu value is swallowed; a record value is not', (
    tester,
  ) async {
    Future<({bool selected, bool canceled})> tapSignOut<T>(
      T signOutValue,
    ) async {
      var selected = false;
      var canceled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PopupMenuButton<T>(
              onSelected: (_) => selected = true,
              onCanceled: () => canceled = true,
              itemBuilder: (_) => [
                PopupMenuItem<T>(value: signOutValue, child: const Text('out')),
              ],
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('out'));
      await tester.pumpAndSettle();
      return (selected: selected, canceled: canceled);
    }

    // The broken shape: null is read as "the user dismissed the menu".
    final withNull = await tapSignOut<String?>(null);
    expect(withNull.selected, isFalse);
    expect(withNull.canceled, isTrue);

    // The shape the app uses: a non-null record that carries a null uid.
    final withRecord = await tapSignOut<({String? uid})>((uid: null));
    expect(withRecord.selected, isTrue);
    expect(withRecord.canceled, isFalse);
  });
}
