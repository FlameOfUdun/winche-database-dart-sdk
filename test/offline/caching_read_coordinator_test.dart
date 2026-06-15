import 'package:test/test.dart';
import 'package:winche_database/src/offline/caching_read_coordinator.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/read_coordinator.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/transport/transport.dart';

import 'fake_local_store.dart';

class _FakeTransport implements Transport {
  _FakeTransport(this.responder);
  Map<String, Object?> Function(Map<String, Object?>) responder;
  bool offline = false;

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    if (offline) throw const UnavailableException('offline');
    return responder(frame);
  }

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
  ConnectionState get connectionState =>
      offline ? ConnectionState.disconnected : ConnectionState.ready;
  @override
  void dispose() {}
}

Map<String, Object?> wireDoc(String path, Map<String, Object?> taggedFields,
        {int version = 1}) =>
    {
      'path': path,
      'id': path.split('/').last,
      'collection': path.split('/').first,
      'fields': taggedFields,
      'createTime': 'T',
      'updateTime': 'T',
      'version': version,
    };

void main() {
  late _FakeTransport transport;
  late DocumentCache cache;
  late CachingReadCoordinator coord;

  setUp(() {
    transport = _FakeTransport((f) => {});
    final store = FakeLocalStore();
    cache = DocumentCache(store);
    coord = CachingReadCoordinator(transport, cache, WriteQueue(store));
  });

  group('getDocument', () {
    test('online (serverOrCache): reads server, writes through to cache',
        () async {
      transport.responder = (f) => {
            'document':
                wireDoc('users/u1', {'n': const IntegerValue(1).toJson()})
          };
      final r = await coord.getDocument('users/u1', const GetOptions());
      expect(r.fromCache, isFalse);
      expect(r.document!.fields['n'], const IntegerValue(1));
      expect((await cache.confirmed('users/u1'))!.fields['n'],
          const IntegerValue(1));
    });

    test('offline (serverOrCache): falls back to cache (fromCache=true)',
        () async {
      transport.responder = (f) => {
            'document':
                wireDoc('users/u1', {'n': const IntegerValue(7).toJson()})
          };
      await coord.getDocument('users/u1', const GetOptions());
      transport.offline = true;
      final r = await coord.getDocument('users/u1', const GetOptions());
      expect(r.fromCache, isTrue);
      expect(r.document!.fields['n'], const IntegerValue(7));
    });

    test('offline + uncached: returns not-exists fromCache', () async {
      transport.offline = true;
      final r = await coord.getDocument('users/none', const GetOptions());
      expect(r.document, isNull);
      expect(r.fromCache, isTrue);
    });

    test('Source.cache never hits the server', () async {
      transport.responder = (f) => throw StateError('should not be called');
      final r = await coord.getDocument(
          'users/u1', const GetOptions(source: Source.cache));
      expect(r.fromCache, isTrue);
      expect(r.document, isNull);
    });

    test('Source.server offline throws UnavailableException', () async {
      transport.offline = true;
      expect(
          coord.getDocument(
              'users/u1', const GetOptions(source: Source.server)),
          throwsA(isA<UnavailableException>()));
    });

    test('server delete (null doc) tombstones the cache', () async {
      transport.responder = (f) => {
            'document':
                wireDoc('users/u1', {'n': const IntegerValue(1).toJson()})
          };
      await coord.getDocument('users/u1', const GetOptions());
      transport.responder = (f) => {'document': null};
      final r = await coord.getDocument('users/u1', const GetOptions());
      expect(r.document, isNull);
      expect(await cache.isKnownAbsent('users/u1'), isTrue);
    });
  });

  group('runQuery', () {
    test('online: writes through results and returns them', () async {
      transport.responder = (f) => {
            'documents': [
              wireDoc('users/a', {'age': const IntegerValue(30).toJson()}),
              wireDoc('users/b', {'age': const IntegerValue(20).toJson()}),
            ],
            'hasMore': false,
          };
      final r = await coord.runQuery(QuerySpec('users'), const GetOptions());
      expect(r.fromCache, isFalse);
      expect(r.documents.map((d) => d.id).toSet(), {'a', 'b'});
      expect((await cache.confirmed('users/a'))!.fields['age'],
          const IntegerValue(30));
    });

    test('offline: runs the local engine over cached docs (fromCache=true)',
        () async {
      transport.responder = (f) => {
            'documents': [
              wireDoc('users/a', {'age': const IntegerValue(30).toJson()}),
              wireDoc('users/b', {'age': const IntegerValue(20).toJson()}),
            ],
            'hasMore': false,
          };
      await coord.runQuery(QuerySpec('users'), const GetOptions());
      transport.offline = true;
      final r = await coord.runQuery(
          QuerySpec('users', orderBy: const [OrderSpec('age')]),
          const GetOptions());
      expect(r.fromCache, isTrue);
      expect(r.documents.map((d) => d.id), ['b', 'a']);
    });
  });

  group('getAll', () {
    test('online writes through; offline serves cached + not-exists', () async {
      transport.responder = (f) => {
            'documents': [
              wireDoc('users/a', {'n': const IntegerValue(1).toJson()}),
              null,
            ]
          };
      await coord.getAll(['users/a', 'users/b'], const GetOptions());
      transport.offline = true;
      final r = await coord.getAll(['users/a', 'users/b'], const GetOptions());
      expect(r[0].fromCache, isTrue);
      expect(r[0].document!.id, 'a');
      expect(r[1].document, isNull);
    });
  });

  group('runQuery (projected / select)', () {
    test('returns full docs trimmed to select; cache holds the FULL doc',
        () async {
      transport.responder = (f) => {
            'documents': [
              wireDoc('users/u1', {
                'title': const StringValue('A').toJson(),
                'priority': const IntegerValue(1).toJson(),
              }),
            ],
            'hasMore': false,
          };
      final spec = QuerySpec(
        'users',
        where: FilterSpec.field('priority', FieldOp.eq, const IntegerValue(1)),
        select: ['title'],
      );
      final r =
          await coord.runQuery(spec, const GetOptions(source: Source.server));

      expect(r.documents, hasLength(1));
      expect(r.documents.first.fields.keys, ['title']); // trimmed
      final cached = await cache.confirmed('users/u1');
      expect(cached!.fields.keys.toSet(),
          {'title', 'priority'}); // cache has FULL doc
    });

    test('projected query works offline from cached full docs', () async {
      transport.responder = (f) => {
            'documents': [
              wireDoc('users/u1', {
                'title': const StringValue('A').toJson(),
                'priority': const IntegerValue(1).toJson(),
              }),
            ],
            'hasMore': false,
          };
      final spec = QuerySpec('users',
          where:
              FilterSpec.field('priority', FieldOp.eq, const IntegerValue(1)),
          select: ['title']);
      await coord.runQuery(
          spec, const GetOptions(source: Source.server)); // warm cache
      transport.offline = true;
      final r =
          await coord.runQuery(spec, const GetOptions(source: Source.cache));
      expect(r.fromCache, isTrue);
      expect(r.documents.single.fields.keys, ['title']);
    });
  });

  group('runQuery hasMore', () {
    test('online reflects the server hasMore; offline is false', () async {
      transport.responder = (f) => {
            'documents': [
              wireDoc('users/a', {'n': const IntegerValue(1).toJson()})
            ],
            'hasMore': true,
          };
      final online =
          await coord.runQuery(QuerySpec('users'), const GetOptions());
      expect(online.hasMore, isTrue);

      transport.offline = true;
      final offline = await coord.runQuery(
          QuerySpec('users'), const GetOptions(source: Source.cache));
      expect(offline.hasMore, isFalse);
    });
  });

  group('serverOrCache fallback', () {
    test('falls back to cache on a transient server error', () async {
      transport.responder = (f) => {
            'document':
                wireDoc('users/u1', {'n': const IntegerValue(5).toJson()})
          };
      await coord.getDocument('users/u1', const GetOptions()); // warm cache
      transport.responder =
          (f) => throw const DeadlineExceededException('slow');
      final r = await coord.getDocument('users/u1', const GetOptions());
      expect(r.fromCache, isTrue);
      expect(r.document!.fields['n'], const IntegerValue(5));
    });

    test('rethrows PERMISSION_DENIED instead of falling back', () async {
      transport.responder = (f) => throw const PermissionDeniedException('no');
      expect(
        coord.getDocument('users/u1', const GetOptions()),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });
}
