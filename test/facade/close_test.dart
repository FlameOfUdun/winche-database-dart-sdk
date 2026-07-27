import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import '../offline/fake_local_store.dart';
import 'facade_harness.dart';

/// A [LocalStore] that behaves like sembast: every operation after [close]
/// throws. `MemoryLocalStore`/`FakeLocalStore` keep serving reads after close,
/// which hides use-after-close bugs.
class _StrictStore implements LocalStore {
  _StrictStore([FakeLocalStore? inner]) : _inner = inner ?? FakeLocalStore();

  final FakeLocalStore _inner;
  bool closed = false;

  void _check() {
    if (closed) throw StateError('database is closed');
  }

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) async {
    _check();
    return _inner.putDocument(path, record);
  }

  @override
  Future<Map<String, Object?>?> getDocument(String path) async {
    _check();
    return _inner.getDocument(path);
  }

  @override
  Future<void> removeDocument(String path) async {
    _check();
    return _inner.removeDocument(path);
  }

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(String p) async {
    _check();
    return _inner.documentsInCollection(p);
  }

  @override
  Future<List<Map<String, Object?>>> allDocuments() async {
    _check();
    return _inner.allDocuments();
  }

  @override
  Future<int> nextPendingSeq() async {
    _check();
    return _inner.nextPendingSeq();
  }

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) async {
    _check();
    return _inner.putPending(seq, entry);
  }

  @override
  Future<List<Map<String, Object?>>> allPending() async {
    _check();
    return _inner.allPending();
  }

  @override
  Future<void> removePending(int seq) async {
    _check();
    return _inner.removePending(seq);
  }

  @override
  Future<void> putMeta(String key, Object? value) async {
    _check();
    return _inner.putMeta(key, value);
  }

  @override
  Future<Object?> getMeta(String key) async {
    _check();
    return _inner.getMeta(key);
  }

  @override
  Future<void> clear() async {
    _check();
    return _inner.clear();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test('close() with a live doc listener does not touch the closed store',
      () async {
    final errors = <Object>[];
    final store = _StrictStore();

    await runZonedGuarded(() async {
      final h = FacadeHarness(store: store);
      h.handler = (f) {
        if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
      };

      final sub = h.db.doc('users/u1').snapshots().listen((_) {});
      await pump();

      h.push({
        'type': 'listen.snapshot',
        'subscriptionId': 's',
        'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
        'readTime': '2026-06-08T10:00:00+00:00',
      });
      await pump();

      await h.db.close();
      await pump(20);
      await sub.cancel();
    }, (e, _) => errors.add(e));

    expect(errors, isEmpty, reason: 'close() raced the live listener: $errors');
  });

  test('close() with a live query listener does not touch the closed store',
      () async {
    final errors = <Object>[];
    final store = _StrictStore();

    await runZonedGuarded(() async {
      final h = FacadeHarness(store: store);
      h.handler = (f) {
        if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 's'});
      };

      final sub = h.db.collection('users').snapshots().listen((_) {});
      await pump();

      h.push({
        'type': 'listen.snapshot',
        'subscriptionId': 's',
        'documents': [wireDoc('users/u1', wireFields({'name': 'Alice'}))],
        'readTime': '2026-06-08T10:00:00+00:00',
      });
      await pump();

      await h.db.close();
      await pump(20);
      await sub.cancel();
    }, (e, _) => errors.add(e));

    expect(errors, isEmpty, reason: 'close() raced the live listener: $errors');
  });

  test('close() completes live snapshot streams with done', () async {
    final h = FacadeHarness();
    h.handler = (f) {
      if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
    };

    var done = false;
    h.db.doc('users/u1').snapshots().listen((_) {}, onDone: () => done = true);
    await pump();

    await h.db.close();
    await pump();

    expect(done, isTrue);
    expect(h.db.isClosed, isTrue);
  });

  test('close() only closes the store once, and waits for it', () async {
    final store = _StrictStore();
    final h = FacadeHarness(store: store);
    await h.db.doc('users/u1').get(const GetOptions(source: Source.cache));

    await h.db.close();
    expect(store.closed, isTrue,
        reason: 'close() must await the store, not fire-and-forget it');

    // Idempotent: a second close is a no-op, not a second teardown.
    await h.db.close();
  });

  test('close() while a write is draining does not hang or hit the store',
      () async {
    final errors = <Object>[];
    final store = _StrictStore();

    await runZonedGuarded(() async {
      final h = FacadeHarness(store: store);
      // Never answer the write frame: the drain stays parked on the request.
      h.handler = (f) {
        if (f['type'] != 'write') h.respond(f, {});
      };

      // Not awaited: `set` resolves only once the drain it kicks off settles,
      // and this drain is parked on the unanswered write frame.
      unawaited(h.db.doc('users/u1').set({'name': 'Alice'}));
      await pump();

      await h.db.close().timeout(const Duration(seconds: 5));
      await pump(20);
    }, (e, _) => errors.add(e));

    expect(errors, isEmpty, reason: 'close() raced the draining write: $errors');
    expect(store.closed, isTrue);
  });
}
