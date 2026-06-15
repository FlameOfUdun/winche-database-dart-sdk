import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/sync_controller.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/transport/transport.dart';

import 'fake_local_store.dart';

class _FakeTransport implements Transport {
  final StreamController<void> _reconnects = StreamController<void>.broadcast();
  final List<Map<String, Object?>> requests = [];
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    requests.add(frame);
    return {
      'writeResults': [
        {'updateTime': 'T', 'transformResults': null}
      ]
    };
  }

  @override
  Stream<ServerFrame> listenEvents(String s) => const Stream.empty();
  @override
  void releaseSubscription(String s) {}
  @override
  Stream<void> get reconnects => _reconnects.stream;

  @override
  Stream<ConnectionState> get connectionStates =>
      const Stream<ConnectionState>.empty();
  void fireReconnect() => _reconnects.add(null);
  @override
  ConnectionState get connectionState => ConnectionState.ready;
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
    sync = SyncController(transport, cache, queue)..start();
  });

  tearDown(() => sync.dispose());

  test('reconnect triggers a drain', () async {
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    transport.fireReconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await queue.hasPending(), isFalse);
  });

  test('notifyEnqueued drains when online', () async {
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    await sync.notifyEnqueued();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await queue.hasPending(), isFalse);
  });
}
