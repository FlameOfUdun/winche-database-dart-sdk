import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/offline/document_cache.dart';
import 'package:winche_database/src/offline/sync_controller.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/protocol/connection.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/core/value_relay.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/transport/transport.dart';

import 'fake_local_store.dart';

class _FakeTransport implements Transport {
  final StreamController<void> _reconnects = StreamController<void>.broadcast();
  final ValueRelay<ConnectionState> _states =
      ValueRelay<ConnectionState>(ConnectionState.ready);
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
  Stream<ConnectionState> get connectionStates => _states.stream;

  /// Simulates a reconnect: the state briefly leaves `ready` and comes back,
  /// exactly as `WsTransport` transitions `connectionStates` around a real
  /// reconnect, alongside firing the (still-supported) `reconnects` event.
  void fireReconnect() {
    _states.add(ConnectionState.reconnecting);
    _states.add(ConnectionState.ready);
    _reconnects.add(null);
  }

  @override
  ConnectionState get connectionState => _states.value;
  @override
  Future<void> reconnect() async {}

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}

/// A transport whose connection state is driven by the test, published as a
/// level (current value on subscribe) like the real one.
class _StateTransport implements Transport {
  final ValueRelay<ConnectionState> _states =
      ValueRelay<ConnectionState>(ConnectionState.connecting);
  final List<Map<String, Object?>> requests = [];

  void setState(ConnectionState s) => _states.add(s);

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> frame) async {
    if (_states.value != ConnectionState.ready) {
      throw const UnavailableException('not ready');
    }
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
  Stream<void> get reconnects => const Stream<void>.empty();
  @override
  Stream<ConnectionState> get connectionStates => _states.stream;
  @override
  ConnectionState get connectionState => _states.value;
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> dispose() => _states.close();
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

  // A process restart: the writes were queued in a previous session and are
  // already on disk when the controller starts. Nothing will fire `reconnects`
  // for them — WsTransport exposes it as an `async*` that awaits the connection
  // before `yield*`-ing its events, so the event fired as that first connection
  // completes lands before the subscription attaches and is dropped (the
  // controller has no replay). Without an explicit kick, such a queue sits
  // pending forever behind a perfectly healthy socket.
  test('a queue restored from disk drains at start, with no reconnect event',
      () async {
    final restored = FakeLocalStore();
    final restoredQueue = WriteQueue(restored);
    await restoredQueue.enqueue(
        SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    expect(await restoredQueue.hasPending(), isTrue);

    final restoredTransport = _FakeTransport();
    final restoredSync =
        SyncController(restoredTransport, DocumentCache(restored), restoredQueue)
          ..start();
    addTearDown(restoredSync.dispose);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await restoredQueue.hasPending(), isFalse,
        reason: 'start() must drain a pre-existing queue on its own');
  });

  test('notifyEnqueued drains when online', () async {
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));
    await sync.notifyEnqueued();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await queue.hasPending(), isFalse);
  });

  // The real user scenario, and the one the startup-kick workaround could not
  // handle: the session begins with no socket, so the first drain attempt fails,
  // and only a later connection can succeed.
  test('a queue drains when the connection becomes ready later', () async {
    final store = FakeLocalStore();
    final queue = WriteQueue(store);
    await queue.enqueue(SetWrite('users/u1', {'n': const IntegerValue(1)}),
        localCommitTime: DateTime.utc(2026));

    final transport = _StateTransport();
    final sync = SyncController(transport, DocumentCache(store), queue)..start();
    addTearDown(sync.dispose);

    // Offline: nothing can drain.
    transport.setState(ConnectionState.reconnecting);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await queue.hasPending(), isTrue);

    // The network returns.
    transport.setState(ConnectionState.ready);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await queue.hasPending(), isFalse);
  });
}
