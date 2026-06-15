part of '../../winche_database.dart';

/// The entry point for the Winche Database Dart SDK.
///
/// Connects lazily on the first operation.
final class WincheDatabase {
  /// Creates a database client. Offline support is always on: reads and live
  /// listeners are served from a local cache + pending-write overlay, and writes
  /// are queued and synced. [store] defaults to a non-persistent
  /// [MemoryLocalStore]; pass a durable store (e.g. `HiveLocalStore`) to persist
  /// across restarts.
  WincheDatabase(
    ConnectionConfig config, {
    LocalStore? store,
    ConflictPolicy conflictPolicy = ConflictPolicy.manual,
  })  : _transport = WsTransport(config),
        _store = store ?? MemoryLocalStore() {
    _cache = DocumentCache(_store);
    _queue = WriteQueue(_store);
    _changes = LocalChangeNotifier();
    _sync = SyncController(_transport, _cache, _queue,
        conflictPolicy: conflictPolicy, changeNotifier: _changes)
      ..start();
    _reads = CachingReadCoordinator(_transport, _cache, _queue);
    _writes = QueueingWriteCoordinator(_cache, _queue,
        maxFrameBytes: config.maxFrameBytes, onEnqueued: () async {
      _changes.notify();
      await _sync.notifyEnqueued();
    });
  }

  final Transport _transport;
  final LocalStore _store;
  late final ReadCoordinator _reads;
  late final WriteCoordinator _writes;
  late final WriteQueue _queue;
  late final SyncController _sync;
  late final DocumentCache _cache;
  late final LocalChangeNotifier _changes;

  /// Internal: the document cache (used by the facade live listeners).
  DocumentCache get cache => _cache;

  /// Internal: the write queue.
  WriteQueue get queue => _queue;

  /// Internal: the local-change signal that fires on cache/queue mutations.
  LocalChangeNotifier get localChanges => _changes;

  /// The read coordinator (always cache-aware).
  ReadCoordinator get reads => _reads;

  /// The write coordinator (always queueing + syncing).
  WriteCoordinator get writes => _writes;

  /// Stream of sync progress/conflict events as the write queue drains.
  Stream<SyncEvent> get syncEvents => _sync.events;

  /// Whether there are un-synced local writes.
  Future<bool> get hasPendingWrites => _queue.hasPending();

  /// Completes when the pending-write queue has drained.
  ///
  /// Under [ConflictPolicy.manual] (the default), a write rejected by a version
  /// conflict is **paused**, not drained — so this future stays pending until
  /// the conflict is resolved via the [WriteConflict] event on [syncEvents]
  /// (`retry`/`discard`/`overwrite`). Use [ConflictPolicy.clientWins] or
  /// [ConflictPolicy.serverWins] to auto-resolve conflicts instead.
  Future<void> waitForPendingWrites() => _sync.waitForPendingWrites();

  /// Wipes the local cache and pending-write queue.
  Future<void> clearPersistence() => _store.clear();

  Stream<ServerFrame> listenEvents(String subscriptionId) {
    return _transport.listenEvents(subscriptionId);
  }

  void releaseSubscription(String subscriptionId) {
    _transport.releaseSubscription(subscriptionId);
  }

  Stream<void> get reconnects => _transport.reconnects;

  /// Stable stream of connection-state transitions (survives reconnects).
  Stream<ConnectionState> get connectionStates => _transport.connectionStates;

  /// The current connection state.
  ConnectionState get connectionState => _transport.connectionState;

  /// Returns a [CollectionReference] for [path].
  CollectionReference<Map<String, Object?>> collection(String path) {
    return CollectionReference._(this, path, Converter._identity);
  }

  /// Returns a [DocumentReference] for [path].
  DocumentReference<Map<String, Object?>> doc(String path) {
    return DocumentReference._(this, path, Converter._identity);
  }

  /// Fetches multiple documents in one round-trip, served from cache when
  /// offline. Returns one snapshot per ref, in order; missing refs yield a
  /// non-existent snapshot.
  Future<List<DocumentSnapshot<T>>> getAll<T>(
    List<DocumentReference<T>> refs, [
    GetOptions options = const GetOptions(),
  ]) async {
    if (refs.isEmpty) return <DocumentSnapshot<T>>[];
    final results =
        await _reads.getAll([for (final r in refs) r.path], options);
    return [
      for (var i = 0; i < refs.length; i++) _snapshotFrom(refs[i], results[i]),
    ];
  }

  /// Builds a typed [DocumentSnapshot] from a coordinator [DocReadResult].
  DocumentSnapshot<T> _snapshotFrom<T>(
      DocumentReference<T> ref, DocReadResult r) {
    final metadata = SnapshotMetadata(
        fromCache: r.fromCache, hasPendingWrites: r.hasPendingWrites);
    return r.document == null
        ? DocumentSnapshot._missing(ref, metadata: metadata)
        : DocumentSnapshot._fromWire(ref, r.document!, metadata: metadata);
  }

  /// Runs [handler] within a transaction with automatic retry on conflict.
  Future<T> runTransaction<T>(
    Future<T> Function(Transaction) handler, {
    int maxAttempts = 5,
  }) async {
    final rng = Random();
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      // Begin transaction.
      final beginResult = await _transport.request(txBeginFrame(''));
      final transactionId = beginResult['transactionId'] as String;
      final tx = Transaction._(this, transactionId);

      T result;
      try {
        result = await handler(tx);
      } on AbortedException {
        // AbortedException from the handler (e.g. tx.get/tx.query conflict) —
        // retry with a fresh begin under the same maxAttempts/backoff policy (I6).
        // No rollback needed: the server has already aborted the transaction.
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(
              linearBackoff(attempt, stepMs: 50, jitterMs: 50, rng: rng));
          continue;
        }
        rethrow;
      } catch (e) {
        // Any other handler exception — roll back and rethrow.
        try {
          await tx._rollback();
        } catch (_) {
          // Ignore rollback errors.
        }
        rethrow;
      }

      // Read-only transaction: rollback instead of commit.
      if (tx._writes.isEmpty) {
        await tx._rollback();
        return result;
      }

      // Commit buffered writes.
      try {
        await tx._commit();
        return result;
      } on AbortedException {
        // Conflict — retry with backoff.
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(
              linearBackoff(attempt, stepMs: 50, jitterMs: 50, rng: rng));
          continue;
        }
        rethrow;
      }
    }
    throw StateError('Transaction failed after $maxAttempts attempts.');
  }

  /// Returns a new [WriteBatch] for atomic multi-document writes.
  WriteBatch batch() {
    return WriteBatch(this);
  }

  /// Closes the database connection and the sync controller.
  void close() {
    _sync.dispose();
    _changes.dispose();
    _transport.dispose();
  }
}
