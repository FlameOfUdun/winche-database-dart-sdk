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

  /// Use a non-persistent in-memory store instead of sembast. Defaults to false.
  final bool inMemory;

  /// Resolves the namespace that scopes the persistent store to one identity —
  /// return the signed-in user's id. **Required** unless [inMemory] is true;
  /// must be null when it is.
  ///
  /// The local store is single-tenant: it holds the document cache, the pending
  /// write queue, listener resume tokens and query membership, none of which
  /// carry an identity. Sharing one store across users means the second user
  /// reads the first user's cached documents, and the first user's un-synced
  /// writes replay under the second user's token (the server rejects them with
  /// `PERMISSION_DENIED`, and they are dropped). Requiring a namespace makes
  /// that a decision you take rather than one you can forget.
  ///
  /// Each identity gets its own database file (`winche_<namespace>.db`; the
  /// IndexedDB database name on the web), so a user switch is
  /// `await db.close()` followed by a new [WincheDatabase]. The previous user's
  /// queued writes stay on disk and drain when they sign back in.
  ///
  /// Like [directoryResolver] this is resolved lazily on first store access and
  /// **cached** — it pins the identity for the lifetime of this
  /// [WincheDatabase]. Returning a changing value does not migrate a live
  /// instance to another user; closing and rebuilding is what does that.
  ///
  /// The resolved value must match `[A-Za-z0-9._-]+` (it becomes a file-name
  /// component); anything else throws [ArgumentError] when the store opens.
  final FutureOr<String> Function()? namespaceResolver;

  /// Resolves the sembast directory, lazily on first store access and cached.
  /// Required on native platforms; ignored on the web (IndexedDB). Must be null
  /// when [inMemory] is true.
  final Future<String> Function()? directoryResolver;

  /// Write-conflict resolution policy. Defaults to [ConflictPolicy.manual].
  final ConflictPolicy conflictPolicy;

  /// Maximum number of live documents kept in the local cache. When exceeded,
  /// the least-recently-used documents not referenced by an active listener or a
  /// pending write are evicted (re-fetched on next read). Null (default) disables
  /// eviction. Composes with [cacheSizeBytes] (either cap triggers eviction).
  final int? maxCachedDocuments;

  /// Maximum approximate size in bytes of the local document cache. When
  /// exceeded, least-recently-used unpinned documents are evicted. Null (default)
  /// disables the byte cap. Composes with [maxCachedDocuments] (either cap
  /// triggers eviction).
  final int? cacheSizeBytes;

  const WincheDatabaseConfig({
    required this.uri,
    this.tokenProvider,
    this.pingInterval = const Duration(seconds: 30),
    this.autoReconnect = true,
    this.maxBackoff = const Duration(seconds: 30),
    this.maxFrameBytes = 1 << 20,
    this.inMemory = false,
    this.namespaceResolver,
    this.directoryResolver,
    this.conflictPolicy = ConflictPolicy.manual,
    this.maxCachedDocuments,
    this.cacheSizeBytes,
  });
}

/// The entry point for the Winche Database Dart SDK.
///
/// Connects lazily on the first operation.
///
/// NOTE: a persistent (sembast) database must be owned by a single isolate. Do
/// not open the same on-disk database from multiple isolates concurrently.
final class WincheDatabase {
  /// Creates a database client from a [WincheDatabaseConfig]. Offline support is
  /// always on: reads and live listeners are served from a local cache +
  /// pending-write overlay, and writes are queued and synced.
  ///
  /// Persistence is **on by default** via sembast (database file `winche.db`). On
  /// native platforms [WincheDatabaseConfig.directoryResolver] is **required** —
  /// it supplies the sembast directory, resolved lazily on first store access and
  /// cached. On the web it is ignored (sembast uses IndexedDB). Set
  /// [WincheDatabaseConfig.inMemory] to use a non-persistent [MemoryLocalStore]
  /// instead (then `directoryResolver` must be null).
  factory WincheDatabase(WincheDatabaseConfig config) {
    if (config.inMemory && config.directoryResolver != null) {
      throw ArgumentError('directoryResolver has no effect with inMemory: true.');
    }
    if (config.inMemory && config.namespaceResolver != null) {
      throw ArgumentError('namespaceResolver has no effect with inMemory: true.');
    }
    if (!config.inMemory && config.namespaceResolver == null) {
      throw ArgumentError('namespaceResolver is required for a persistent store '
          '— return the signed-in user id, so one user cannot read or replay '
          "another's local state. Use inMemory: true for an unscoped, "
          'non-persistent store.');
    }
    if (!config.inMemory && !_kIsWeb && config.directoryResolver == null) {
      throw ArgumentError(
          'directoryResolver is required on native platforms (web uses IndexedDB).');
    }
    final store = config.inMemory
        ? MemoryLocalStore()
        : LazyLocalStore(() async => SembastLocalStore.open(
              _databaseName(await config.namespaceResolver!()),
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
      maxCachedDocuments: config.maxCachedDocuments,
      cacheSizeBytes: config.cacheSizeBytes,
    );
  }

  /// The sembast database name for a resolved namespace. Validated rather than
  /// sanitised: it becomes a file-name component, and silently rewriting a user
  /// id would collapse two identities onto one store.
  static final _namespacePattern = RegExp(r'^[A-Za-z0-9._-]+$');

  static String _databaseName(String namespace) {
    if (!_namespacePattern.hasMatch(namespace) ||
        namespace == '.' ||
        namespace == '..') {
      throw ArgumentError.value(namespace, 'namespace',
          'must match [A-Za-z0-9._-]+ (it is used as a file-name component)');
    }
    return 'winche_$namespace';
  }

  /// Advanced / testing: creates a client over an explicitly supplied [store].
  factory WincheDatabase.withStore(
    ConnectionConfig config,
    LocalStore store, {
    ConflictPolicy conflictPolicy = ConflictPolicy.manual,
    int? maxCachedDocuments,
    int? cacheSizeBytes,
  }) =>
      WincheDatabase._(config, store, conflictPolicy,
          maxCachedDocuments: maxCachedDocuments,
          cacheSizeBytes: cacheSizeBytes);

  WincheDatabase._(
    ConnectionConfig config,
    LocalStore store,
    ConflictPolicy conflictPolicy, {
    int? maxCachedDocuments,
    int? cacheSizeBytes,
  }) : _session = _DatabaseSession(config, store, conflictPolicy,
            maxCachedDocuments: maxCachedDocuments,
            cacheSizeBytes: cacheSizeBytes);

  _DatabaseSession? _session;

  /// Internal: the transport, for other facade parts (transactions, live
  /// feeds) that need to issue requests directly.
  Transport get _transport => _session!.transport;

  /// Internal: the document cache (used by the facade live listeners).
  DocumentCache get cache => _session!.cache;

  /// Internal: the per-query membership cache (used by listeners + read coordinator).
  TargetCache get targets => _session!.targets;

  /// Internal: durable per-subscription resume tokens (used by live feeds).
  ResumeTokenStore get resumeTokens => _session!.resumeTokens;

  /// Internal: the active-subscription reference registry (pins docs against eviction).
  ActiveTargets get activeTargets => _session!.activeTargets;

  /// Internal: the write queue.
  WriteQueue get queue => _session!.queue;

  /// Internal: the local-change signal that fires on cache/queue mutations.
  LocalChangeNotifier get localChanges => _session!.changes;

  /// The read coordinator (always cache-aware).
  ReadCoordinator get reads => _session!.reads;

  /// The write coordinator (always queueing + syncing).
  WriteCoordinator get writes => _session!.writes;

  /// Stream of sync progress/conflict events as the write queue drains.
  Stream<SyncEvent> get syncEvents => _session!.sync.events;

  /// Whether there are un-synced local writes.
  Future<bool> get hasPendingWrites => _session!.queue.hasPending();

  /// Completes when the pending-write queue has drained.
  ///
  /// Under [ConflictPolicy.manual] (the default), a write rejected by a version
  /// conflict is **paused**, not drained — so this future stays pending until
  /// the conflict is resolved via the [WriteConflict] event on [syncEvents]
  /// (`retry`/`discard`/`overwrite`). Use [ConflictPolicy.clientWins] or
  /// [ConflictPolicy.serverWins] to auto-resolve conflicts instead.
  Future<void> waitForPendingWrites() => _session!.sync.waitForPendingWrites();

  /// Wipes the local cache and pending-write queue.
  Future<void> clearPersistence() => _session!.store.clear();

  Stream<ServerFrame> listenEvents(String subscriptionId) {
    return _session!.transport.listenEvents(subscriptionId);
  }

  void releaseSubscription(String subscriptionId) {
    _session!.transport.releaseSubscription(subscriptionId);
  }

  Stream<void> get reconnects => _session!.transport.reconnects;

  /// Stable stream of connection-state transitions (survives reconnects).
  Stream<ConnectionState> get connectionStates =>
      _session!.transport.connectionStates;

  /// The current connection state.
  ConnectionState get connectionState => _session!.transport.connectionState;

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
        await reads.getAll([for (final r in refs) r.path], options);
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

  /// Drops the current socket and re-dials, re-reading
  /// [WincheDatabaseConfig.tokenProvider].
  ///
  /// The auth token rides on the WebSocket upgrade, so it is fixed for the life
  /// of a socket: rotating it has no effect until the connection is re-dialled.
  /// Call this after refreshing the token. Live listeners resubscribe in place
  /// (including any that had died on a `PERMISSION_DENIED` / `UNAUTHENTICATED`
  /// subscribe), and a write queue stalled with [SyncPaused] resumes draining.
  ///
  /// Throws [UnauthenticatedException] if the server rejects the new token, or
  /// [UnavailableException] if it is unreachable; the connection then falls back
  /// to its usual auto-reconnect behaviour.
  ///
  /// This is for a **token change, not a user change**. Switching identities
  /// means a new local store: `await db.close()`, then a new [WincheDatabase]
  /// with the new [WincheDatabaseConfig.namespace].
  Future<void> reconnect() async {
    if (isClosed) {
      throw StateError('WincheDatabase has been closed.');
    }
    // Clear the latches before re-dialling, so the `reconnects` event that the
    // successful dial emits finds every feed willing to resubscribe.
    for (final l in _session!.listeners) {
      l._clearPermanentFailure();
    }
    await _transport.reconnect();
  }

  /// Closes the database connection, the sync controller, and the local store.
  ///
  /// Tears down in dependency order — live listeners first, then the sync
  /// controller, then the transport, and only then the local store — so nothing
  /// can read the store after it is closed. Live `snapshots()` streams complete
  /// with `done`; in-flight `get`/write calls fail with [UnavailableException].
  ///
  /// Await it before re-opening a database over the same on-disk file (e.g. when
  /// switching users): the returned future completes only once the store is
  /// actually closed. Idempotent.
  Future<void> close() => _closing ??= _session!.dispose();

  Future<void>? _closing;

  /// Whether [close] has been called. Live listeners consult this before every
  /// emission so a teardown can never drive a read of a closed store.
  bool get isClosed => _session!.isDisposed;

  void _registerListener(_LiveListener<Object?> l) =>
      _session!._registerListener(l);
  void _unregisterListener(_LiveListener<Object?> l) =>
      _session!._unregisterListener(l);
}
