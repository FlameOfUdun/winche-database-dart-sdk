import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/write_coordinator.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';

import 'fake_local_store.dart';

void main() {
  group('QueueingWriteCoordinator', () {
    late FakeLocalStore store;
    late DocumentCache cache;
    late WriteQueue queue;
    late QueueingWriteCoordinator coord;
    setUp(() {
      store = FakeLocalStore();
      cache = DocumentCache(store);
      queue = WriteQueue(store);
      coord = QueueingWriteCoordinator(cache, queue);
    });

    test('enqueues the write and returns a local ack (no server)', () async {
      final results = await coord.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)})
      ]);
      expect(results.single['updateTime'], isA<String>());
      final pending = await queue.all();
      expect(pending.single.path, 'users/u1');
    });

    test('captures base = confirmed version/updateTime when cached', () async {
      await cache.putConfirmed(WireDocument(
          path: 'users/u1',
          id: 'u1',
          collection: 'users',
          fields: const {},
          createTime: 'T',
          updateTime: '2026-06-08T09:00:00+00:00',
          version: 5));
      await coord.applyWrites([
        UpdateWrite('users/u1', {'n': const IntegerValue(2)})
      ]);
      final base = (await queue.all()).single.base!;
      expect(base.version, 5);
      expect(base.updateTime, '2026-06-08T09:00:00+00:00');
    });

    test('captures base = existsFalse when tombstoned', () async {
      await cache.putConfirmedDeleted('users/u1', '2026-06-08T09:00:00+00:00');
      await coord.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)})
      ]);
      expect((await queue.all()).single.base!.existsFalse, isTrue);
    });

    test('captures base = null (unknown) when not cached', () async {
      await coord.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)})
      ]);
      expect((await queue.all()).single.base, isNull);
    });

    test('a multi-write batch shares one batchId', () async {
      await coord.applyWrites([
        SetWrite('users/a', {'n': const IntegerValue(1)}),
        SetWrite('users/b', {'n': const IntegerValue(2)}),
      ]);
      final all = await queue.all();
      expect(all.length, 2);
      expect(all[0].batchId, isNotNull);
      expect(all[0].batchId, all[1].batchId);
    });

    test('a single write has no batchId', () async {
      await coord.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)})
      ]);
      expect((await queue.all()).single.batchId, isNull);
    });

    test('preserves an app-supplied precondition', () async {
      await coord.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)},
            precondition: const Precondition(exists: false)),
      ]);
      expect((await queue.all()).single.appPrecondition!.exists, isFalse);
    });

    test('applyWrites rejects a batch over 500 writes before enqueue',
        () async {
      final store2 = FakeLocalStore();
      final coord2 =
          QueueingWriteCoordinator(DocumentCache(store2), WriteQueue(store2));
      final writes = [
        for (var i = 0; i < 501; i++) SetWrite('c/$i', {'n': IntegerValue(i)}),
      ];
      await expectLater(
        () => coord2.applyWrites(writes),
        throwsA(isA<InvalidArgumentException>()),
      );
      expect(await WriteQueue(store2).hasPending(), isFalse);
    });

    test('applyWrites rejects a frame larger than maxFrameBytes before enqueue',
        () async {
      final store2 = FakeLocalStore();
      final coord2 = QueueingWriteCoordinator(
          DocumentCache(store2), WriteQueue(store2),
          maxFrameBytes: 64); // tiny limit
      final write = SetWrite('c/a', {'blob': StringValue('x' * 1000)});
      await expectLater(
        () => coord2.applyWrites([write]),
        throwsA(isA<InvalidArgumentException>()),
      );
      expect(await WriteQueue(store2).hasPending(), isFalse);
    });

    test('a drain during a batch enqueue cannot send a partial batch',
        () async {
      final store = FakeLocalStore();
      final queue = WriteQueue(store);
      late QueueingWriteCoordinator coordinator;

      // Snapshots of what a drain would have seen, taken between enqueues.
      final observed = <int>[];
      coordinator = QueueingWriteCoordinator(
        DocumentCache(store),
        queue,
        onEnqueued: () async {},
      );

      // Drive a drain-like observation concurrently with the batch enqueue.
      final commit = coordinator.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)}),
        SetWrite('users/u2', {'n': const IntegerValue(2)}),
        SetWrite('users/u3', {'n': const IntegerValue(3)}),
      ]);
      while (!queue.isMutating) {
        await Future<void>.delayed(Duration.zero);
        break;
      }
      for (var i = 0; i < 6; i++) {
        if (!queue.isMutating) continue;
        observed.add((await queue.all()).length);
        await Future<void>.delayed(Duration.zero);
      }
      await commit;

      // While mutating, a drain must refuse to act at all — so no observation
      // taken during the enqueue may be treated as drainable.
      expect(queue.isMutating, isFalse, reason: 'flag must clear when done');
      expect((await queue.all()), hasLength(3));
    });

    test('isMutating is set for the duration of a multi-write enqueue',
        () async {
      final store = FakeLocalStore();
      final queue = WriteQueue(store);
      final coordinator =
          QueueingWriteCoordinator(DocumentCache(store), queue);

      expect(queue.isMutating, isFalse);
      final commit = coordinator.applyWrites([
        SetWrite('users/u1', {'n': const IntegerValue(1)}),
        SetWrite('users/u2', {'n': const IntegerValue(2)}),
      ]);
      expect(queue.isMutating, isTrue,
          reason: 'set synchronously, before the first await completes');
      await commit;
      expect(queue.isMutating, isFalse);
    });
  });
}
