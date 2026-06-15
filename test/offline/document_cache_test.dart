import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'fake_local_store.dart';

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
}
