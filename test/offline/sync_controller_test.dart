import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/local_change_notifier.dart';
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
  bool online = true;
  final List<Map<String, Object?>> requests = [];
  Map<String, Object?> Function(Map<String, Object?>) responder = (f) => {};

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    if (!online) throw const UnavailableException('offline');
    requests.add(frame);
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
      online ? ConnectionState.ready : ConnectionState.disconnected;
  @override
  void dispose() {}
}

void main() {
  late FakeLocalStore store;
  late DocumentCache cache;
  late WriteQueue queue;
  late _FakeTransport transport;
  late SyncController sync;

  setUp(() {
    store = FakeLocalStore();
    cache = DocumentCache(store);
    queue = WriteQueue(store);
    transport = _FakeTransport();
    sync = SyncController(transport, cache, queue);
  });

  test(
      'drain replays a queued set, advances cache, dequeues, emits WriteSynced',
      () async {
    transport.responder = (f) => {
          'writeResults': [
            {
              'updateTime': '2026-06-08T12:00:00+00:00',
              'transformResults': null
            }
          ]
        };
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));

    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();

    expect(transport.requests.single['type'], 'write');
    expect(await queue.hasPending(), isFalse);
    final doc = await cache.confirmed('users/u1');
    expect(doc!.fields['n'], const IntegerValue(1));
    expect(doc.updateTime, '2026-06-08T12:00:00+00:00');
    await Future<void>.delayed(Duration.zero);
    expect(events.single, isA<WriteSynced>());
    expect((events.single as WriteSynced).paths, ['users/u1']);
  });

  test('replay carries a version precondition from the base', () async {
    transport.responder = (f) => {
          'writeResults': [
            {
              'updateTime': '2026-06-08T12:00:00+00:00',
              'transformResults': null
            }
          ]
        };
    await queue.enqueue(UpdateWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(
            updateTime: '2026-06-08T09:00:00+00:00', version: 3),
        localCommitTime: DateTime.utc(2026));
    await sync.drain();
    final writes = transport.requests.single['writes'] as List<Object?>;
    final update = (writes.single as Map)['update'] as Map<String, Object?>;
    expect(update['precondition'], {'updateTime': '2026-06-08T09:00:00+00:00'});
  });

  test('exists:false base → precondition exists:false', () async {
    transport.responder = (f) => {
          'writeResults': [
            {
              'updateTime': '2026-06-08T12:00:00+00:00',
              'transformResults': null
            }
          ]
        };
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        base: const PendingBase(existsFalse: true),
        localCommitTime: DateTime.utc(2026));
    await sync.drain();
    final set = ((transport.requests.single['writes'] as List).single
        as Map)['set'] as Map<String, Object?>;
    expect(set['precondition'], {'exists': false});
  });

  test('app precondition overrides the version base', () async {
    transport.responder = (f) => {
          'writeResults': [
            {
              'updateTime': '2026-06-08T12:00:00+00:00',
              'transformResults': null
            }
          ]
        };
    await queue.enqueue(
        SetWrite('users/u1', {'n': const IntegerValue(1)},
            precondition: const Precondition(exists: true)),
        base: const PendingBase(updateTime: 'X'),
        appPrecondition: const Precondition(exists: true),
        localCommitTime: DateTime.utc(2026));
    await sync.drain();
    final set = ((transport.requests.single['writes'] as List).single
        as Map)['set'] as Map<String, Object?>;
    expect(set['precondition'], {'exists': true});
  });

  test('ack rebases remaining same-path entries to the new updateTime',
      () async {
    transport.responder = (f) => {
          'writeResults': [
            {
              'updateTime': '2026-06-08T12:00:00+00:00',
              'transformResults': null
            }
          ]
        };
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        base: const PendingBase(existsFalse: true),
        localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(2)}),
        base: const PendingBase(existsFalse: true),
        localCommitTime: DateTime.utc(2026));
    await sync.drainOnce();
    final remaining = await queue.forPath('users/u1');
    expect(remaining.single.base!.updateTime, '2026-06-08T12:00:00+00:00');
    expect(remaining.single.base!.existsFalse, isNull);
  });

  test('batch (shared batchId) replays atomically as one frame', () async {
    transport.responder = (f) => {
          'writeResults': [
            {'updateTime': 'T', 'transformResults': null},
            {'updateTime': 'T', 'transformResults': null},
          ]
        };
    await queue.enqueue(SetWrite('users/a', {'n': const IntegerValue(1)}),
        batchId: 'b1', localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/b', {'n': const IntegerValue(2)}),
        batchId: 'b1', localCommitTime: DateTime.utc(2026));
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.drain();
    expect(transport.requests.length, 1);
    expect((transport.requests.single['writes'] as List).length, 2);
    await Future<void>.delayed(Duration.zero);
    expect(
        (events.single as WriteSynced).paths.toSet(), {'users/a', 'users/b'});
  });

  test('offline: drain is a no-op (queue retained)', () async {
    transport.online = false;
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    await sync.drain();
    expect(await queue.hasPending(), isTrue);
  });

  test('waitForPendingWrites completes once the queue drains', () async {
    transport.responder = (f) => {
          'writeResults': [
            {'updateTime': 'T', 'transformResults': null}
          ]
        };
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    final wait = sync.waitForPendingWrites();
    await sync.drain();
    await wait;
    expect(await queue.hasPending(), isFalse);
  });

  test('short/empty writeResults does not crash; uses local commit time',
      () async {
    transport.responder =
        (f) => {'writeResults': <Object?>[]}; // server returns none
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026, 6, 8, 10));
    await sync.drain(); // must not throw
    expect(await queue.hasPending(), isFalse);
    final doc = await cache.confirmed('users/u1');
    expect(doc!.fields['n'], const IntegerValue(1));
    expect(doc.updateTime,
        contains('2026-06-08')); // fell back to local commit time
  });

  test('only the contiguous head batch is sent as a unit', () async {
    transport.responder = (f) => {
          'writeResults': [
            for (var i = 0; i < (f['writes'] as List).length; i++)
              {'updateTime': 'T', 'transformResults': null}
          ]
        };
    // batch b1 (2 writes), then a standalone write, then another b1 id reused later
    await queue.enqueue(SetWrite('users/a', {'n': const IntegerValue(1)}),
        batchId: 'b1', localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/b', {'n': const IntegerValue(2)}),
        batchId: 'b1', localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/c', {'n': const IntegerValue(3)}),
        localCommitTime: DateTime.utc(2026));
    await sync.drainOnce(); // first unit only
    // The first frame contained exactly the 2 contiguous b1 writes.
    expect((transport.requests.single['writes'] as List).length, 2);
    expect(await queue.forPath('users/c'), isNotEmpty); // not yet sent
  });

  test('a successful drain fires the change notifier', () async {
    transport.responder = (f) => {
          'writeResults': [
            {'updateTime': 'T', 'transformResults': null}
          ]
        };
    final notifier = LocalChangeNotifier();
    final fired = <void>[];
    notifier.stream.listen(fired.add);
    final s = SyncController(transport, cache, queue, changeNotifier: notifier);
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    await s.drain();
    await Future<void>.delayed(Duration.zero);
    expect(fired, isNotEmpty);
  });
}
