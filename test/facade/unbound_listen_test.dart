import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  late WincheDatabase db;

  setUp(() => db = WincheDatabase(WincheApp('unbound-listen')));
  tearDown(() => db.dispose());

  // The defect this file exists for: `snapshots()` used to resolve the session
  // in a constructor initializer list, so it threw at the CALL site. For a
  // StreamBuilder that call site is `build()`, which means a sign-out landing
  // mid-rebuild tore down the widget tree instead of surfacing an error the
  // consumer could render.
  test('query snapshots() does not throw when unbound', () {
    expect(() => db.collection('users').snapshots(), returnsNormally);
  });

  test('doc snapshots() does not throw when unbound', () {
    expect(() => db.doc('users/u1').snapshots(), returnsNormally);
  });

  test('query snapshots() reports unbound as a stream error', () {
    expect(
      db.collection('users').snapshots(),
      emitsInOrder([emitsError(isA<WincheUnboundException>()), emitsDone]),
    );
  });

  test('doc snapshots() reports unbound as a stream error', () {
    expect(
      db.doc('users/u1').snapshots(),
      emitsInOrder([emitsError(isA<WincheUnboundException>()), emitsDone]),
    );
  });

  // The error path never bound a session, so teardown must not reach for one.
  // Reading it would throw over an error the consumer has already handled.
  test('cancelling after the unbound error does not throw', () async {
    final errors = <Object>[];
    final sub = db
        .collection('users')
        .snapshots()
        .listen((_) {}, onError: errors.add);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(sub.cancel(), completes);
    expect(errors.single, isA<WincheUnboundException>());
  });

  test('every listener gets the error, not just the first', () async {
    for (var i = 0; i < 3; i++) {
      await expectLater(
        db.collection('users').snapshots().first,
        throwsA(isA<WincheUnboundException>()),
      );
    }
  });

  // One-shot reads were always catchable — they are `async`, so an unbound
  // database rejects their Future. Pinned here because the fix above exists to
  // make `snapshots()` agree with them, and a regression that made reads throw
  // synchronously would break callers the same way.
  test('one-shot reads still reject rather than throw synchronously', () {
    late Future<Object?> pending;
    expect(() => pending = db.doc('users/u1').get(), returnsNormally);
    expect(pending, throwsA(isA<WincheUnboundException>()));
  });
}
