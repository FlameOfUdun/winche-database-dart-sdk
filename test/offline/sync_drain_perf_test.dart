import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/local_store.dart';
import 'package:winche_database/src/offline/memory_local_store.dart';
import 'package:winche_database/src/offline/sync_controller.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/transport/transport.dart';

/// Wraps a real store and counts how many times the pending queue is scanned.
class _CountingStore implements LocalStore {
  _CountingStore(this._inner);
  final LocalStore _inner;
  int allPendingCalls = 0;

  @override
  Future<List<Map<String, Object?>>> allPending() {
    allPendingCalls++;
    return _inner.allPending();
  }

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) =>
      _inner.putDocument(path, record);
  @override
  Future<Map<String, Object?>?> getDocument(String path) =>
      _inner.getDocument(path);
  @override
  Future<void> removeDocument(String path) => _inner.removeDocument(path);
  @override
  Future<List<Map<String, Object?>>> documentsInCollection(String c) =>
      _inner.documentsInCollection(c);
  @override
  Future<List<Map<String, Object?>>> allDocuments() => _inner.allDocuments();
  @override
  Future<int> nextPendingSeq() => _inner.nextPendingSeq();
  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) =>
      _inner.putPending(seq, entry);
  @override
  Future<void> removePending(int seq) => _inner.removePending(seq);
  @override
  Future<void> putMeta(String key, Object? value) => _inner.putMeta(key, value);
  @override
  Future<Object?> getMeta(String key) => _inner.getMeta(key);
  @override
  Future<void> clear() => _inner.clear();
  @override
  Future<void> close() => _inner.close();
}

/// A transport that acks every `write` frame successfully.
class _OkTransport implements Transport {
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    if (frame['type'] == 'write') {
      final n = (frame['writes'] as List).length;
      return {
        'writeResults': [
          for (var i = 0; i < n; i++)
            {'updateTime': 'T', 'transformResults': null}
        ]
      };
    }
    return {};
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
  ConnectionState get connectionState => ConnectionState.ready;
  @override
  void dispose() {}
}

/// A transport whose request handler is supplied per-test.
class _CallbackTransport implements Transport {
  _CallbackTransport(this._onRequest);
  final Future<Map<String, Object?>> Function(Map<String, Object?>) _onRequest;
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) =>
      _onRequest(frame);
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

void main() {
  test('drain scans the queue O(1) times, not once per unit', () async {
    final counting = _CountingStore(MemoryLocalStore());
    final cache = DocumentCache(counting);
    final queue = WriteQueue(counting);
    final sync = SyncController(_OkTransport(), cache, queue);

    const n = 40;
    for (var i = 0; i < n; i++) {
      await queue.enqueue(SetWrite('c/d$i', {'v': IntegerValue(i)}),
          localCommitTime: DateTime.utc(2026));
    }

    counting.allPendingCalls = 0; // count only the drain
    await sync.drain();
    final drainScans = counting.allPendingCalls;

    expect(await queue.hasPending(), isFalse, reason: 'queue fully drained');
    expect(drainScans, lessThanOrEqualTo(3),
        reason: 'drain must not re-scan the whole queue per unit (was O(n^2))');
  });

  test('a write enqueued mid-drain is not stranded', () async {
    final store = MemoryLocalStore();
    final cache = DocumentCache(store);
    final queue = WriteQueue(store);
    var injected = false;
    final transport = _CallbackTransport((frame) async {
      if (frame['type'] == 'write' && !injected) {
        injected = true;
        // Simulate a user write arriving during the drain (between awaits): it
        // lands in the store but not in drain's initial in-memory snapshot.
        await queue.enqueue(SetWrite('c/late', {'v': const IntegerValue(1)}),
            localCommitTime: DateTime.utc(2026));
      }
      final n = (frame['writes'] as List).length;
      return {
        'writeResults': [
          for (var i = 0; i < n; i++)
            {'updateTime': 'T', 'transformResults': null}
        ]
      };
    });
    final sync = SyncController(transport, cache, queue);

    await queue.enqueue(SetWrite('c/d0', {'v': const IntegerValue(0)}),
        localCommitTime: DateTime.utc(2026));
    await sync.drain();

    expect(await queue.hasPending(), isFalse,
        reason: 'a write enqueued during the drain must still be drained');
  });

  test('drain with same-path siblings still scans O(1) times', () async {
    final counting = _CountingStore(MemoryLocalStore());
    final cache = DocumentCache(counting);
    final queue = WriteQueue(counting);
    final sync = SyncController(_OkTransport(), cache, queue);

    const n = 20;
    for (var i = 0; i < n; i++) {
      await queue.enqueue(SetWrite('c/same', {'v': IntegerValue(i)}),
          localCommitTime: DateTime.utc(2026));
    }

    counting.allPendingCalls = 0;
    await sync.drain();
    final drainScans = counting.allPendingCalls;

    expect(await queue.hasPending(), isFalse, reason: 'queue fully drained');
    expect(drainScans, lessThanOrEqualTo(3),
        reason: 'sibling rebase must not scan the whole queue per ack');
  });
}
