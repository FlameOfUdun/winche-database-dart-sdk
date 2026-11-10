import 'package:test/test.dart';
import 'package:winche_database/src/core/paths.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/offline/caching_read_coordinator.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/read_coordinator.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/transport/transport.dart';

import 'fake_local_store.dart';

class _Transport implements Transport {
  bool offline = false;
  final frames = <Map<String, Object?>>[];
  Map<String, Object?> Function(Map<String, Object?>) responder = (_) => {};

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    if (offline) throw const UnavailableException('offline');
    frames.add(frame);
    return responder(frame);
  }

  @override
  Stream<ServerFrame> listenEvents(String s) => const Stream.empty();
  @override
  void releaseSubscription(String s) {}
  @override
  Stream<ConnectionState> get connectionStates => const Stream<ConnectionState>.empty();
  @override
  ConnectionState get connectionState => offline ? ConnectionState.disconnected : ConnectionState.ready;
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> dispose() async {}
}

WireDocument doc(String path, int n) => WireDocument.fromJson({
      'path': path,
      'id': docId(path),
      'collection': collectionOf(path),
      'fields': {'n': IntegerValue(n).toJson()},
      'createTime': '2026-01-01T00:00:00Z',
      'updateTime': '2026-01-01T00:00:0${n}Z',
      'version': 1,
    });

void main() {
  test('the spec carries the flag and takes only an id', () {
    final spec = QuerySpec('notes', collectionGroup: true);
    expect(spec.toJson(), {'collection': 'notes', 'collectionGroup': true});
    expect(QuerySpec('notes').toJson().containsKey('collectionGroup'), isFalse);
    expect(spec.copyWith(limit: 3).collectionGroup, isTrue);
    expect(() => QuerySpec('users/u1/notes', collectionGroup: true).validate(), throwsArgumentError);
  });

  test('collection ids of document paths', () {
    expect(collectionIdOf('users/u1/notes/n1'), 'notes');
    expect(collectionIdOf('notes/n1'), 'notes');
    expect(inCollectionGroup('users/u1/notes/n1', 'notes'), isTrue);
    expect(inCollectionGroup('notes/top', 'notes'), isTrue);
    expect(inCollectionGroup('users/u1/other/notes', 'notes'), isFalse);   // a document named notes
    expect(inCollectionGroup('users/u1/notesArchive/x', 'notes'), isFalse);
  });

  group('offline', () {
    late _Transport transport;
    late DocumentCache cache;
    late WriteQueue queue;
    late CachingReadCoordinator reads;

    setUp(() async {
      transport = _Transport();
      final store = FakeLocalStore();
      cache = DocumentCache(store);
      queue = WriteQueue(store);
      reads = CachingReadCoordinator(transport, cache, queue);
      await cache.putConfirmedAll([
        doc('users/u1/notes/a', 3),
        doc('users/u2/notes/b', 1),
        doc('notes/top', 2),
        doc('users/u1/other/notes', 9),
        doc('users/u1', 8),
      ]);
    });

    test('a group query reads every parent from the cache, with pending writes on top', () async {
      transport.offline = true;
      await queue.enqueue(SetWrite('projects/p/notes/new', {'n': const IntegerValue(0)}),
          localCommitTime: DateTime.utc(2026));
      await queue.enqueue(DeleteWrite('users/u2/notes/b'), localCommitTime: DateTime.utc(2026));

      final r = await reads.runQuery(
          QuerySpec('notes', collectionGroup: true, orderBy: const [OrderSpec('n')]), const GetOptions());

      expect(r.fromCache, isTrue);
      expect(r.documents.map((d) => d.path), ['projects/p/notes/new', 'notes/top', 'users/u1/notes/a']);
    });

    test('online, the flag goes to the server', () async {
      transport.responder = (f) => {'documents': <Object?>[], 'hasMore': false};
      await reads.runQuery(QuerySpec('notes', collectionGroup: true), const GetOptions());
      expect((transport.frames.single['query'] as Map)['collectionGroup'], isTrue);
    });
  });
}
