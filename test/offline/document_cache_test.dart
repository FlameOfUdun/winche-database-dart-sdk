import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/eviction_manager.dart';
import 'package:winche_database/src/offline/memory_local_store.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'fake_local_store.dart';

WireDocument _doc(String path) => WireDocument(
      path: path,
      id: path.split('/').last,
      collection: path.split('/').first,
      fields: const {},
      createTime: '2026-06-30T10:00:00+00:00',
      updateTime: '2026-06-30T10:00:00+00:00',
      version: 1,
    );

WireDocument wire(String path, Map<String, Object?> fields,
        {String updateTime = '2026-06-08T10:00:00+00:00', int version = 1}) =>
    WireDocument.fromJson({
      'path': path,
      'id': path.split('/').last,
      'collection': path.split('/').first,
      'fields': {for (final e in fields.entries) e.key: e.value},
      'createTime': updateTime,
      'updateTime': updateTime,
      'version': version,
    });

void main() {
  late DocumentCache cache;
  setUp(() => cache = DocumentCache(FakeLocalStore()));

  test('putConfirmed then confirmed returns the document', () async {
    await cache
        .putConfirmed(wire('users/u1', {'n': const IntegerValue(1).toJson()}));
    final doc = await cache.confirmed('users/u1');
    expect(doc!.path, 'users/u1');
    expect(doc.fields['n'], const IntegerValue(1));
  });

  test('unknown path returns null', () async {
    expect(await cache.confirmed('users/none'), isNull);
  });

  test('tombstone: confirmed returns null but isKnownAbsent is true', () async {
    await cache.putConfirmedDeleted('users/u1', '2026-06-08T11:00:00+00:00');
    expect(await cache.confirmed('users/u1'), isNull);
    expect(await cache.isKnownAbsent('users/u1'), isTrue);
    expect(await cache.isKnownAbsent('users/never'), isFalse);
  });

  test('documentsInCollection returns live confirmed docs only', () async {
    await cache.putConfirmed(wire('users/u1', const {}));
    await cache.putConfirmed(wire('users/u2', const {}));
    await cache.putConfirmedDeleted('users/u3', '2026-06-08T11:00:00+00:00');
    final docs = await cache.confirmedInCollection('users');
    expect(docs.map((d) => d.path).toSet(), {'users/u1', 'users/u2'});
  });

  test('evicts the oldest unpinned live doc once the cap is exceeded', () async {
    final store = MemoryLocalStore();
    final eviction = EvictionManager(maxDocuments: 2)
      ..pinnedPaths = (() async => const <String>{}) // parens: keep the cascade on the manager, not the Set
      ..removeDocument = store.removeDocument;
    final cache = DocumentCache(store, eviction: eviction);

    await cache.putConfirmed(_doc('c/a'));
    await cache.putConfirmed(_doc('c/b'));
    await cache.putConfirmed(_doc('c/c')); // exceeds cap → evict oldest ('c/a')

    expect(await cache.confirmed('c/a'), isNull, reason: 'c/a should be evicted');
    expect(await cache.confirmed('c/b'), isNotNull);
    expect(await cache.confirmed('c/c'), isNotNull);
  });

  test('putConfirmed primes before writing, so the written doc is not evicted',
      () async {
    final store = MemoryLocalStore();
    // Pre-persist 3 docs (no eviction) as a prior session would have.
    final seed = DocumentCache(store);
    for (final id in ['a', 'b', 'c']) {
      await seed.putConfirmed(_doc('c/$id'));
    }

    final eviction = EvictionManager(maxDocuments: 2)
      ..pinnedPaths = (() async => const <String>{})
      ..removeDocument = store.removeDocument;
    final cache = DocumentCache(store, eviction: eviction);

    // Re-confirm an EXISTING doc; startup priming runs first, so the just-written
    // doc must survive (I1 regression: prime-before-put).
    await cache.putConfirmed(_doc('c/a'));

    expect(await cache.confirmed('c/a'), isNotNull,
        reason: 'the just-written doc must survive startup priming eviction');
  });

  group('never goes back in time', () {
    test('a read computed before our write, answered after its ack, is ignored', () async {
      // Our write's ack: the server's format, +00:00 and trimmed digits.
      await cache.putConfirmed(wire('t/a', {'logo': const StringValue('new').toJson()},
          updateTime: '2026-11-17T18:31:21.542507+00:00'));
      // The list read sent just before it, answered just after.
      await cache.putConfirmedAll([
        wire('t/a', {'logo': const StringValue('old').toJson()}, updateTime: '2026-11-17T18:31:14.16Z'),
        wire('t/b', const {}, updateTime: '2026-11-17T18:31:14.16Z'),
      ]);
      final a = await cache.confirmed('t/a');
      expect(a!.updateTime, '2026-11-17T18:31:21.542507+00:00');
      expect(a.fields['logo'], const StringValue('new'));
      expect(await cache.confirmed('t/b'), isNotNull); // the others are stored
    });

    test('a later or equal state replaces it', () async {
      await cache.putConfirmed(wire('t/a', {'n': const IntegerValue(1).toJson()}, updateTime: '2026-11-17T18:00:00+00:00'));
      await cache.putConfirmed(wire('t/a', {'n': const IntegerValue(2).toJson()}, updateTime: '2026-11-17T18:00:00Z'));
      expect((await cache.confirmed('t/a'))!.fields['n'], const IntegerValue(2));
      await cache.putConfirmed(wire('t/a', {'n': const IntegerValue(3).toJson()}, updateTime: '2026-11-17T18:00:00.000001+00:00'));
      expect((await cache.confirmed('t/a'))!.fields['n'], const IntegerValue(3));
    });

    test('a document deleted after the read stays deleted', () async {
      await cache.putConfirmedDeleted('t/a', '2026-11-17T18:31:48.858+00:00');
      await cache.putConfirmed(wire('t/a', const {}, updateTime: '2026-11-17T18:31:45.8+00:00'));
      expect(await cache.isKnownAbsent('t/a'), isTrue);
      await cache.putConfirmed(wire('t/a', const {}, updateTime: '2026-11-17T18:40:00+00:00')); // made again
      expect(await cache.confirmed('t/a'), isNotNull);
    });
  });
}
