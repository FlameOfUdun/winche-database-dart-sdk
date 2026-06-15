part of '../../winche_database.dart';

/// True on the web, where Dart's numeric types collapse so `0` and `0.0` are
/// identical. Used to make `directoryResolver` optional on the web, which uses
/// IndexedDB and needs no file-system path.
const bool _kIsWeb = identical(0, 0.0);

/// All configuration for a [WincheDatabase] in one object — connection knobs,
/// local-store selection, and sync policy. Mirrors `winche_storage`'s
/// `WincheStorageConfig`.
///
/// Advanced transport-injection hooks (custom channel factory / sleeper) are not
/// here; use [ConnectionConfig] via [WincheDatabase.withStore] for those.
final class WincheDatabaseConfig {
  /// The WebSocket URI, e.g. `ws://host/documents/ws`.
  final Uri uri;

  /// Supplies the auth token added as the `?access_token=` query parameter on
  /// every (re)dial. Re-read per dial, so a rotated token is picked up.
  final FutureOr<String> Function()? tokenProvider;

  /// Keep-alive ping interval. Defaults to 30 seconds.
  final Duration pingInterval;

  /// Whether to auto-reconnect on unexpected disconnect. Defaults to true.
  final bool autoReconnect;

  /// Maximum backoff between reconnect attempts. Defaults to 30 seconds.
  final Duration maxBackoff;

  /// Maximum outbound write-frame size in bytes. Defaults to 1 MiB.
  final int maxFrameBytes;

  /// Use a non-persistent in-memory store instead of Hive. Defaults to false.
  final bool inMemory;

  /// Resolves the Hive directory, lazily on first store access and cached.
  /// Required on native platforms; ignored on the web (IndexedDB). Must be null
  /// when [inMemory] is true.
  final Future<String> Function()? directoryResolver;

  /// Write-conflict resolution policy. Defaults to [ConflictPolicy.manual].
  final ConflictPolicy conflictPolicy;

  const WincheDatabaseConfig({
    required this.uri,
    this.tokenProvider,
    this.pingInterval = const Duration(seconds: 30),
    this.autoReconnect = true,
    this.maxBackoff = const Duration(seconds: 30),
    this.maxFrameBytes = 1 << 20,
    this.inMemory = false,
    this.directoryResolver,
    this.conflictPolicy = ConflictPolicy.manual,
  });
}

/// The entry point for the Winche Database Dart SDK.
///
/// Connects lazily on the first operation.
final class WincheDatabase {
  /// Creates a database client from a [WincheDatabaseConfig]. Offline support is
  /// always on: reads and live listeners are served from a local cache +
  /// pending-write overlay, and writes are queued and synced.
  ///
  /// Persistence is **on by default** via Hive (boxes namespaced `winche`). On
  /// native platforms [WincheDatabaseConfig.directoryResolver] is **required** —
  /// it supplies the Hive directory, resolved lazily on first store access and
  /// cached. On the web it is ignored (Hive uses IndexedDB). Set
  /// [WincheDatabaseConfig.inMemory] to use a non-persistent [MemoryLocalStore]
  /// instead (then `directoryResolver` must be null).
  factory WincheDatabase(WincheDatabaseConfig config) {
    if (config.inMemory && config.directoryResolver != null) {
      throw ArgumentError('directoryResolver has no effect with inMemory: true.');
    }
    if (!config.inMemory && !_kIsWeb && config.directoryResolver == null) {
      throw ArgumentError(
          'directoryResolver is required on native platforms (web uses IndexedDB).');
    }
    final store = config.inMemory
        ? MemoryLocalStore()
        : LazyLocalStore(() async => HiveLocalStore.open(
              'winche',
              directory: _kIsWeb ? null : await config.directoryResolver!(),
            ));
    return WincheDatabase._(
      ConnectionConfig(
        uri: config.uri,
        tokenProvider: config.tokenProvider,
        pingInterval: config.pingInterval,
        autoReconnect: config.autoReconnect,
        maxBackoff: config.maxBackoff,
        maxFrameBytes: config.maxFrameBytes,
      ),
      store,
      config.conflictPolicy,
    );
  }

  /// Advanced / testing: creates a client over an explicitly supplied [store].
  factory WincheDatabase.withStore(
    ConnectionConfig config,
    LocalStore store, {
    ConflictPolicy conflictPolicy = ConflictPolicy.manual,
  }) =>
      WincheDatabase._(config, store, conflictPolicy);

  WincheDatabase._(
    ConnectionConfig config,
    LocalStore store,
    ConflictPolicy conflictPolicy,
  )   : _transport = WsTransport(config),
        _store = store {
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

  /// Closes the database connection, the sync controller, and the local store.
  void close() {
    _sync.dispose();
    _changes.dispose();
    _transport.dispose();
    unawaited(_store.close());
  }
}
