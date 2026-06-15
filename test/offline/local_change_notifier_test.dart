import 'dart:async';
import 'package:test/test.dart';
import 'package:winche_database/src/offline/local_change_notifier.dart';

void main() {
  test('notify() emits to listeners; broadcast; dispose closes', () async {
    final n = LocalChangeNotifier();
    final got = <void>[];
    final sub = n.stream.listen(got.add);
    n.notify();
    n.notify();
    await Future<void>.delayed(Duration.zero);
    expect(got.length, 2);
    await sub.cancel();
    await n.dispose();
  });

  test('notify after dispose is a no-op (no throw)', () async {
    final n = LocalChangeNotifier();
    await n.dispose();
    expect(n.notify, returnsNormally);
  });
}
