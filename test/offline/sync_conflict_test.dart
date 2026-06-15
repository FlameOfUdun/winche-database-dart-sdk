import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/records.dart';
import 'package:winche_database/src/offline/sync_controller.dart';
import 'package:winche_database/src/offline/sync_event.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/transport/transport.dart';

import 'fake_local_store.dart';

class _FakeTransport implements Transport {
  Map<String, Object?> Function(Map<String, Object?>) responder = (f) => {};
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async =>
      responder(frame);
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
  ConnectionState get connectionState => ConnectionState.ready;
  @override
  void dispose() {}
}

Map<String, Object?> wireDoc(String path, Map<String, Object?> tagged) => {
      'path': path,
      'id': path.split('/').last,
      'collection': path.split('/').first,
      'fields': tagged,
      'createTime': 'T',
      'updateTime': 'T2',
      'version': 9,
    };

void main() {
  late FakeLocalStore store;
  late DocumentCache cache;
  late WriteQueue queue;
  late _FakeTransport transport;

  setUp(() {
    store = FakeLocalStore();
    cache = DocumentCache(store);
    queue = WriteQueue(store);
    transport = _FakeTransport();
  });

  SyncController controller({ConflictPolicy policy = ConflictPolicy.manual}) =>
      SyncController(transport, cache, queue, conflictPolicy: policy);

  test('FAILED_PRECONDITION emits WriteConflict and pauses the write',
      () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        throw const FailedPreconditionException('stale');
      }
      return {
        'document': wireDoc('users/u1', {'n': const IntegerValue(99).toJson()})
      };
    };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));

    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);

    expect(events.single, isA<WriteConflict>());
    final c = events.single as WriteConflict;
    expect(c.paths, ['users/u1']);
    expect(c.serverDocuments['users/u1']!.fields['n'], const IntegerValue(99));
    expect(await queue.hasPending(), isTrue);
  });

  test('conflict.discard drops the write and refreshes the cache', () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        throw const FailedPreconditionException('stale');
      }
      return {
        'document': wireDoc('users/u1', {'n': const IntegerValue(99).toJson()})
      };
    };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    await (events.single as WriteConflict).discard();
    expect(await queue.hasPending(), isFalse);
    expect((await cache.confirmed('users/u1'))!.fields['n'],
        const IntegerValue(99));
  });

  test('conflict.overwrite re-sends without a precondition (then succeeds)',
      () async {
    var calls = 0;
    transport.responder = (f) {
      if (f['type'] == 'write') {
        calls++;
        final w = ((f['writes'] as List).single as Map);
        final body = (w['update'] ?? w['set']) as Map<String, Object?>;
        if (body.containsKey('precondition')) {
          throw const FailedPreconditionException('stale');
        }
        return {
          'writeResults': [
            {'updateTime': 'T3', 'transformResults': null}
          ]
        };
      }
      return {
        'document': wireDoc('users/u1', {'n': const IntegerValue(99).toJson()})
      };
    };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    await (events.first as WriteConflict).overwrite();
    expect(await queue.hasPending(), isFalse);
    expect(calls, greaterThanOrEqualTo(2));
  });

  test('ConflictPolicy.serverWins auto-discards', () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        throw const FailedPreconditionException('stale');
      }
      return {
        'document': wireDoc('users/u1', {'n': const IntegerValue(99).toJson()})
      };
    };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    final sync = controller(policy: ConflictPolicy.serverWins);
    await sync.drain();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await queue.hasPending(), isFalse);
  });

  test('ConflictPolicy.clientWins auto-overwrites', () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        final w = ((f['writes'] as List).single as Map);
        final body = (w['update'] ?? w['set']) as Map<String, Object?>;
        if (body.containsKey('precondition')) {
          throw const FailedPreconditionException('stale');
        }
        return {
          'writeResults': [
            {'updateTime': 'T3', 'transformResults': null}
          ]
        };
      }
      return {
        'document': wireDoc('users/u1', {'n': const IntegerValue(99).toJson()})
      };
    };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    final sync = controller(policy: ConflictPolicy.clientWins);
    await sync.drain();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await queue.hasPending(), isFalse);
  });

  test('hard error (PERMISSION_DENIED) emits WriteFailed and drops the write',
      () async {
    transport.responder = (f) => throw const PermissionDeniedException('nope');
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    expect(events.single, isA<WriteFailed>());
    expect(await queue.hasPending(), isFalse);
  });

  test('a conflict on one path does not block a different path', () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        final w = ((f['writes'] as List).first as Map);
        final body = (w['update'] ?? w['set']) as Map<String, Object?>;
        if (body['path'] == 'users/conflict') {
          throw const FailedPreconditionException('stale');
        }
        return {
          'writeResults': [
            {'updateTime': 'T', 'transformResults': null}
          ]
        };
      }
      return {'document': wireDoc('users/conflict', const {})};
    };
    await queue.enqueue(
        UpdateWrite('users/conflict', {'n': const IntegerValue(1)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/ok', {'n': const IntegerValue(2)}),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    expect((await queue.forPath('users/ok')), isEmpty);
    expect((await queue.forPath('users/conflict')), isNotEmpty);
  });

  test('conflict.retry rebases onto the server version and then succeeds',
      () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        final w = ((f['writes'] as List).single as Map);
        final body = (w['update'] ?? w['set']) as Map<String, Object?>;
        final pc = body['precondition'] as Map<String, Object?>?;
        if (pc?['updateTime'] == 'OLD') {
          throw const FailedPreconditionException('stale');
        }
        return {
          'writeResults': [
            {'updateTime': 'T3', 'transformResults': null}
          ]
        };
      }
      // server doc has updateTime 'T2' (see wireDoc)
      return {
        'document': wireDoc('users/u1', {'n': const IntegerValue(99).toJson()})
      };
    };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    await (events.single as WriteConflict).retry();
    expect(await queue.hasPending(), isFalse);
  });

  test('a batch conflict pauses the whole batch and resolves atomically',
      () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        throw const FailedPreconditionException('stale');
      }
      return {'document': null};
    };
    await queue.enqueue(SetWrite('users/a', {'n': const IntegerValue(1)}),
        base: const PendingBase(updateTime: 'OLD'),
        batchId: 'b1',
        localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/b', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        batchId: 'b1',
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    final c = events.single as WriteConflict;
    expect(c.paths.toSet(), {'users/a', 'users/b'});
    expect(c.serverDocuments.keys.toSet(), {'users/a', 'users/b'});
    await c.discard();
    expect(await queue.hasPending(), isFalse);
  });

  test('ALREADY_EXISTS is treated as a conflict', () async {
    transport.responder = (f) {
      if (f['type'] == 'write') throw const AlreadyExistsException('exists');
      return {'document': wireDoc('users/u1', const {})};
    };
    await queue.enqueue(
        SetWrite('users/u1', {'n': const IntegerValue(1)},
            precondition: const Precondition(exists: false)),
        base: const PendingBase(existsFalse: true),
        appPrecondition: const Precondition(exists: false),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    expect(events.single, isA<WriteConflict>());
  });

  test('resolving a conflict twice throws StateError', () async {
    transport.responder = (f) {
      if (f['type'] == 'write') {
        throw const FailedPreconditionException('stale');
      }
      return {'document': null};
    };
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    final sync = controller();
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    await Future<void>.delayed(Duration.zero);
    final c = events.single as WriteConflict;
    await c.discard();
    expect(() => c.overwrite(), throwsStateError);
  });
}
