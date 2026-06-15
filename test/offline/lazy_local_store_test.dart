import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'fake_local_store.dart';

void main() {
  test('does not open the underlying store until first use', () async {
    var opens = 0;
    LazyLocalStore(() async {
      opens++;
      return FakeLocalStore();
    });
    await Future<void>.delayed(Duration.zero);
    expect(opens, 0);
  });

  test('opens once and reuses it, even for concurrent first-callers', () async {
    var opens = 0;
    final inner = FakeLocalStore();
    final lazy = LazyLocalStore(() async {
      opens++;
      return inner;
    });

    // Two operations fired before either resolves → still a single open.
    final f1 = lazy.putMeta('k', 1);
    final f2 = lazy.getMeta('k');
    await Future.wait([f1, f2]);
    await lazy.getMeta('k'); // a later op reuses the opened store too

    expect(opens, 1);
    expect(await inner.getMeta('k'), 1); // delegated to the underlying store
  });

  test('close is a no-op when never opened', () async {
    var opens = 0;
    final lazy = LazyLocalStore(() async {
      opens++;
      return _ClosableFake();
    });
    await lazy.close();
    expect(opens, 0);
  });

  test('close closes the underlying store once opened', () async {
    final inner = _ClosableFake();
    final lazy = LazyLocalStore(() async => inner);
    await lazy.putMeta('k', 1);
    await lazy.close();
    expect(inner.closed, isTrue);
  });
}

class _ClosableFake extends FakeLocalStore {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}
