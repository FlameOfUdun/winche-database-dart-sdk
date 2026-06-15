import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winche_flutter_demo/main.dart';

void main() {
  // Smoke test: the app builds without a live connection (autoConnect: false).
  // runAsync lets the SDK's internal timers settle so they don't linger as
  // fake-async pending timers when the test ends.
  testWidgets('app renders', (tester) async {
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
}
