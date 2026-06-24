import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/offline/sembast_local_store.dart';
import 'package:winche_database/src/protocol/messages.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('winche_sembast_test'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('documents and pending survive a reopen (durability)', () async {
    var store = await SembastLocalStore.open('t', directory: dir.path);
    final seq = await store.nextPendingSeq();
    await store.putDocument('users/u1', {'path': 'users/u1', 'n': 1});
    await store.putPending(seq, {'seq': seq, 'path': 'users/u1'});
    await store.close();

    store = await SembastLocalStore.open('t', directory: dir.path);
    expect(await store.getDocument('users/u1'), {'path': 'users/u1', 'n': 1});
    expect((await store.allPending()).single['seq'], seq);
    expect(await store.nextPendingSeq(), greaterThan(seq));
    await store.close();
  });

  test('collection scan excludes sub-collections', () async {
    final store = await SembastLocalStore.open('t2', directory: dir.path);
    await store.putDocument('users/u1', {'path': 'users/u1'});
    await store.putDocument('users/u1/posts/p1', {'path': 'users/u1/posts/p1'});
    final inUsers = await store.documentsInCollection('users');
    expect(inUsers.map((d) => d['path']), ['users/u1']);
    await store.close();
  });

  test('clear wipes documents, pending and meta', () async {
    final store = await SembastLocalStore.open('t3', directory: dir.path);
    await store.putDocument('a/b', {'path': 'a/b'});
    await store.putMeta('k', 'v');
    final seq = await store.nextPendingSeq();
    await store.putPending(seq, {'seq': seq});
    await store.clear();
    expect(await store.getDocument('a/b'), isNull);
    expect(await store.getMeta('k'), isNull);
    expect(await store.allPending(), isEmpty);
    await store.close();
  });

  test('nested map/list fields survive reopen and cast to JSON types',
      () async {
    var store = await SembastLocalStore.open('nested', directory: dir.path);
    final record = {
      'path': 'users/u1',
      'id': 'u1',
      'collection': 'users',
      'fields': {
        'name': {'stringValue': 'Alice'},
        'tags': {
          'arrayValue': {
            'values': [
              {'stringValue': 'x'}
            ],
          },
        },
      },
      'createTime': '2026-06-08T10:00:00+00:00',
      'updateTime': '2026-06-08T10:00:00+00:00',
      'version': 1,
    };
    await store.putDocument('users/u1', record);
    await store.close();

    store = await SembastLocalStore.open('nested', directory: dir.path);
    final back = (await store.getDocument('users/u1'))!;

    final fields = back['fields'] as Map<String, Object?>;
    expect(fields['name'], {'stringValue': 'Alice'});
    final tagsVal = fields['tags'] as Map<String, Object?>;
    final tagsArr = (tagsVal['arrayValue'] as Map<String, Object?>)['values']
        as List<Object?>;
    expect(tagsArr.first, {'stringValue': 'x'});

    final doc = WireDocument.fromJson(back);
    expect(doc.fields['name'], const StringValue('Alice'));

    await store.close();
  });
}
