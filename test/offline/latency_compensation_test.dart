import 'package:test/test.dart';
import 'package:winche_database/src/offline/caching_read_coordinator.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/read_coordinator.dart';
import 'package:winche_database/src/offline/write_coordinator.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/transport/transport.dart';

import 'fake_local_store.dart';

class _OfflineTransport implements Transport {
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async =>
      throw const UnavailableException('offline');
  @override
  Stream<ServerFrame> listenEvents(String s) => const Stream.empty();
  @override
  void releaseSubscription(String s) {}
  @override
  Stream<void> get reconnects => const Stream.empty();

  @override
  Stream<ConnectionState> get connectionStates =>
      const Stream<ConnectionState>.empty();
  @override
  ConnectionState get connectionState => ConnectionState.disconnected;
  @override
  void dispose() {}
}

void main() {
  late FakeLocalStore store;
  late DocumentCache cache;
  late WriteQueue queue;
  late QueueingWriteCoordinator writes;
  late CachingReadCoordinator reads;

  setUp(() {
    store = FakeLocalStore();
    cache = DocumentCache(store);
    queue = WriteQueue(store);
    writes = QueueingWriteCoordinator(cache, queue);
    reads = CachingReadCoordinator(_OfflineTransport(), cache, queue);
  });

  test('offline set is visible to a subsequent get (hasPendingWrites)',
      () async {
    await writes.applyWrites([
      SetWrite('users/u1', {'name': const StringValue('Alice')})
    ]);
    final r = await reads.getDocument('users/u1', const GetOptions());
    expect(r.document!.fields['name'], const StringValue('Alice'));
    expect(r.fromCache, isTrue);
    expect(r.hasPendingWrites, isTrue);
  });

  test('offline update overlays onto confirmed doc', () async {
    await cache.putConfirmed(WireDocument(
        path: 'users/u1',
        id: 'u1',
        collection: 'users',
        fields: {'a': const IntegerValue(1), 'b': const IntegerValue(2)},
        createTime: 'T',
        updateTime: 'T',
        version: 1));
    await writes.applyWrites([
      UpdateWrite('users/u1', {'a': const IntegerValue(9)})
    ]);
    final r = await reads.getDocument('users/u1', const GetOptions());
    expect(r.document!.fields['a'], const IntegerValue(9));
    expect(r.document!.fields['b'], const IntegerValue(2));
    expect(r.hasPendingWrites, isTrue);
  });

  test('offline delete hides a confirmed doc', () async {
    await cache.putConfirmed(WireDocument(
        path: 'users/u1',
        id: 'u1',
        collection: 'users',
        fields: const {},
        createTime: 'T',
        updateTime: 'T',
        version: 1));
    await writes.applyWrites([DeleteWrite('users/u1')]);
    final r = await reads.getDocument('users/u1', const GetOptions());
    expect(r.document, isNull);
    expect(r.hasPendingWrites, isTrue);
  });

  test('no pending writes → hasPendingWrites is false', () async {
    await cache.putConfirmed(WireDocument(
        path: 'users/u1',
        id: 'u1',
        collection: 'users',
        fields: const {},
        createTime: 'T',
        updateTime: 'T',
        version: 1));
    final r = await reads.getDocument('users/u1', const GetOptions());
    expect(r.hasPendingWrites, isFalse);
  });

  test('offline query reflects local creates, updates and deletes', () async {
    await cache.putConfirmed(WireDocument(
        path: 'users/a',
        id: 'a',
        collection: 'users',
        fields: {'age': const IntegerValue(30)},
        createTime: 'T',
        updateTime: 'T',
        version: 1));
    await cache.putConfirmed(WireDocument(
        path: 'users/b',
        id: 'b',
        collection: 'users',
        fields: {'age': const IntegerValue(20)},
        createTime: 'T',
        updateTime: 'T',
        version: 1));
    await writes.applyWrites([
      SetWrite('users/c', {'age': const IntegerValue(25)})
    ]);
    await writes.applyWrites([
      UpdateWrite('users/a', {'age': const IntegerValue(40)})
    ]);
    await writes.applyWrites([DeleteWrite('users/b')]);

    final r = await reads.runQuery(
        QuerySpec('users', orderBy: const [OrderSpec('age')]),
        const GetOptions());
    expect(r.documents.map((d) => d.id), ['c', 'a']);
    expect(r.fromCache, isTrue);
    expect(r.hasPendingWrites, isTrue);
  });
}
