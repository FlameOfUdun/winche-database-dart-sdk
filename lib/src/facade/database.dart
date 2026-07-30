part of '../../winche_database.dart';

/// True on the web, where Dart's numeric types collapse so `0` and `0.0` are
/// identical. Used to make `directoryResolver` optional on the web, which uses
/// IndexedDB and needs no file-system path.
const bool _kIsWeb = identical(0, 0.0);

/// All configuration for a [WincheDatabase] in one object — connection knobs,
/// local-store selection, and sync policy. Mirrors `winche_storage`'s
/// `WincheStorageConfig`.
final class WincheDatabaseConfig {
  /// Keep-alive ping interval. Defaults to 30 seconds.
  final Duration pingInterval;

  /// Maximum backoff between reconnect attempts. Defaults to 30 seconds.
  final Duration maxBackoff;

  /// Maximum outbound write-frame size in bytes. Defaults to 1 MiB.
  final int maxFrameBytes;

  /// Use a non-persistent in-memory store instead of sembast. Defaults to false.
  final bool inMemory;

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
    this.pingInterval = const Duration(seconds: 30),
    this.maxBackoff = const Duration(seconds: 30),
    this.maxFrameBytes = 1 << 20,
    this.inMemory = false,
    this.conflictPolicy = ConflictPolicy.manual,
    this.maxCachedDocuments,
    this.cacheSizeBytes,
  });
}

/// `<root>/winche/<storageKey>` — where this identity's store lives.
///
/// `storageKey`, not `id`: on NTFS and default macOS APFS `User1` and `user1`
/// are the same directory, and backends do issue case-sensitive ids.
@visibleForTesting
String storeDirectoryFor(String root, WincheIdentity identity) =>
    '$root/winche/${identity.storageKey}';

/// The IndexedDB database name on the web, where there is no filesystem.
@visibleForTesting
String webDatabaseNameFor(WincheIdentity identity) =>
    'winche_${identity.storageKey}';

/// The entry point for the Winche Database Dart SDK.
///
/// Connects lazily on the first operation.
///
/// NOTE: a persistent (sembast) database must be owned by a single isolate. Do
/// not open the same on-disk database from multiple isolates concurrently.
final class WincheDatabase extends WincheDatabaseService {
  /// Creates the database and registers it with [app].
  ///
  /// Prefer [instance]; construct directly only to attach to a non-default app.
  WincheDatabase(super.app);

  /// The database attached to the default app, building it if needed.
  static WincheDatabase get instance => instanceFor(Winche.app);

  /// The database attached to [app], building it if needed.
  static WincheDatabase instanceFor(WincheApp app) =>
      WincheService.instanceFor(app, () => WincheDatabase(app));

  _DatabaseSession? _session;

  /// The current session, or null when unbound. For tests and the core
  /// contract suite only.
  @visibleForTesting
  Object? get debugSession => _session;

  /// Whether [_require] has been called since the current session (or lack of
  /// one) was established — i.e. whether this facade has actually been used.
  bool _started = false;

  WincheDatabaseConfig _config = const WincheDatabaseConfig();

  /// Tuning for the sessions this facade builds.
  WincheDatabaseConfig get config => _config;

  /// Throws a [StateError] once the current session has started — opened its
  /// store or dialled its socket.
  ///
  /// Construction is lazy, so a session core bound synchronously during
  /// `WincheDatabase.instance` has not started yet. That window is what lets
  /// `instance.config = ...` work on the line after `.instance`.
  set config(WincheDatabaseConfig value) {
    if (_started) {
      throw StateError(
        'WincheDatabase.config cannot be changed once the database has been '
        'used. Set it immediately after first obtaining the instance.',
      );
    }
    _config = value;
  }

  final _connectionRelay = StatusRelay<ConnectionState>(
    ConnectionState.disconnected,
  );
  final _syncRelay = EventRelay<SyncEvent>();

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    if (session == null) {
      await _clearSession()?.dispose();
      return;
    }

    final endpoint = app.options?.databaseEndpoint;
    if (endpoint == null) {
      throw StateError(
        'WincheOptions.databaseEndpoint is required to use winche_database.',
      );
    }

    await _bind(
      ConnectionConfig(
        uri: endpoint,
        tokenProvider: () async {
          final token = await session.token();
          if (token == null) {
            throw const UnauthenticatedException(
              'No auth token available for the current session.',
            );
          }
          return token;
        },
        pingInterval: _config.pingInterval,
        maxBackoff: _config.maxBackoff,
        maxFrameBytes: _config.maxFrameBytes,
      ),
      _storeFor(session),
      _config.conflictPolicy,
      maxCachedDocuments: _config.maxCachedDocuments,
      cacheSizeBytes: _config.cacheSizeBytes,
    );
  }

  /// Detaches the three [StatusRelay]s and clears [_session] (and [_started]),
  /// returning whatever session was outgoing so the caller can dispose it.
  ///
  /// Synchronous and side-effect-only up to that return — no `await`, so
  /// callers that have nothing to dispose (a fresh facade) never suspend.
  _DatabaseSession? _clearSession() {
    _connectionRelay.detach(finalValue: ConnectionState.disconnected);
    _syncRelay.detach();
    final previous = _session;
    _session = null;
    _started = false;
    return previous;
  }

  /// Tears down the current session (awaiting its disposal, if any existed)
  /// and binds a new one over [config]/[store], attaching the three
  /// [StatusRelay]s. Shared by [onSessionChanged] (real sessions, store
  /// derived from the signed-in identity) and [debugBindStore] (tests: an
  /// explicitly supplied store and transport) — one copy of the relay wiring,
  /// not two.
  Future<void> _bind(
    ConnectionConfig config,
    LocalStore store,
    ConflictPolicy conflictPolicy, {
    int? maxCachedDocuments,
    int? cacheSizeBytes,
  }) async {
    final previous = _clearSession();
    if (previous != null) await previous.dispose();

    _session = _DatabaseSession(
      config,
      store,
      conflictPolicy,
      maxCachedDocuments: maxCachedDocuments,
      cacheSizeBytes: cacheSizeBytes,
    );

    _connectionRelay.attach(_session!.transport.connectionStates);
    _syncRelay.attach(_session!.sync.events);
  }

  /// Binds a session over an explicitly supplied [store], bypassing the store
  /// that would be derived from the signed-in identity.
  ///
  /// For tests that drive a fake transport and a fake store directly. Production
  /// code binds through [onSessionChanged].
  @visibleForTesting
  void debugBindStore(
    ConnectionConfig config,
    LocalStore store, {
    ConflictPolicy conflictPolicy = ConflictPolicy.manual,
    int? maxCachedDocuments,
    int? cacheSizeBytes,
  }) {
    // Only ever called on a freshly-constructed facade (no prior session), so
    // `_bind`'s `await previous.dispose()` branch never runs and this
    // completes synchronously despite `_bind`'s `Future`-returning signature.
    unawaited(
      _bind(
        config,
        store,
        conflictPolicy,
        maxCachedDocuments: maxCachedDocuments,
        cacheSizeBytes: cacheSizeBytes,
      ),
    );
  }

  @override
  Future<void> onTokenChanged() async {
    final session = _session;
    if (session == null) return;
    // From 5.0's reconnect(): clear the latches before re-dialling, so the
    // transition to `ready` the successful dial emits finds every feed willing
    // to resubscribe.
    for (final l in session.listeners) {
      l._clearPermanentFailure();
    }
    await session.transport.reconnect();
  }

  /// Returns the active session, or throws [WincheUnboundException] if no
  /// identity is currently bound.
  ///
  /// Every public member that *operates* on data funnels through here, so the
  /// first real use of this facade is also the first call that can mark
  /// [_started].
  ///
  /// The status getters ([connectionState], [connectionStates], [syncEvents])
  /// deliberately do not. Observing whether a connection exists is not use: a
  /// widget that renders a connection chip must be able to build before anyone
  /// signs in, and reading that chip must not lock [config] or throw
  /// [WincheUnboundException].
  _DatabaseSession _require() {
    final session = _session;
    if (session == null) throw WincheUnboundException();
    _started = true;
    return session;
  }

  /// Builds the local store for [session] according to [_config].
  LocalStore _storeFor(WincheSession session) {
    if (_config.inMemory) return MemoryLocalStore();

    final root = app.options?.directoryResolver;
    if (!_kIsWeb && root == null) {
      throw StateError(
        'WincheOptions.directoryResolver is required for a persistent store on '
        'native platforms. Set inMemory: true for a non-persistent one.',
      );
    }

    return LazyLocalStore(
      () async => SembastLocalStore.open(
        _kIsWeb ? webDatabaseNameFor(session.identity) : 'db',
        directory: _kIsWeb
            ? null
            : storeDirectoryFor(await root!(), session.identity),
      ),
    );
  }

  /// Internal: the transport, for other facade parts (transactions, live
  /// feeds) that need to issue requests directly.
  Transport get _transport => _require().transport;

  /// Internal: the document cache (used by the facade live listeners).
  DocumentCache get cache => _require().cache;

  /// Internal: the per-query membership cache (used by listeners + read coordinator).
  TargetCache get targets => _require().targets;

  /// Internal: durable per-subscription resume tokens (used by live feeds).
  ResumeTokenStore get resumeTokens => _require().resumeTokens;

  /// Internal: the active-subscription reference registry (pins docs against eviction).
  ActiveTargets get activeTargets => _require().activeTargets;

  /// Internal: the write queue.
  WriteQueue get queue => _require().queue;

  /// Internal: the local-change signal that fires on cache/queue mutations.
  LocalChangeNotifier get localChanges => _require().changes;

  /// The read coordinator (always cache-aware).
  ReadCoordinator get reads => _require().reads;

  /// The write coordinator (always queueing + syncing).
  WriteCoordinator get writes => _require().writes;

  /// Stream of connection-state transitions. Survives session swaps: it goes
  /// quiet (emitting [ConnectionState.disconnected]) rather than ending when
  /// the signed-in identity changes or signs out.
  Stream<ConnectionState> get connectionStates => _connectionRelay.stream;

  /// Stream of sync progress/conflict events as the write queue drains.
  /// Survives session swaps.
  Stream<SyncEvent> get syncEvents => _syncRelay.stream;

  /// The current connection state, or [ConnectionState.disconnected] when no
  /// identity is bound.
  ///
  /// Deliberately does not throw [WincheUnboundException] like the data
  /// operations do: observing status is not an operation, and a widget that
  /// renders a connection chip must be able to build before anyone signs in.
  ConnectionState get connectionState =>
      _session?.transport.connectionState ?? ConnectionState.disconnected;

  /// Whether there are un-synced local writes.
  Future<bool> get hasPendingWrites => _require().queue.hasPending();

  /// Completes when the pending-write queue has drained.
  ///
  /// Under [ConflictPolicy.manual] (the default), a write rejected by a version
  /// conflict is **paused**, not drained — so this future stays pending until
  /// the conflict is resolved via the [WriteConflict] event on [syncEvents]
  /// (`retry`/`discard`/`overwrite`). Use [ConflictPolicy.clientWins] or
  /// [ConflictPolicy.serverWins] to auto-resolve conflicts instead.
  Future<void> waitForPendingWrites() => _require().sync.waitForPendingWrites();

  /// Wipes the local cache and pending-write queue.
  Future<void> clearPersistence() => _require().store.clear();

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
    final results = await reads.getAll([for (final r in refs) r.path], options);
    return [
      for (var i = 0; i < refs.length; i++) _snapshotFrom(refs[i], results[i]),
    ];
  }

  /// Builds a typed [DocumentSnapshot] from a coordinator [DocReadResult].
  DocumentSnapshot<T> _snapshotFrom<T>(
    DocumentReference<T> ref,
    DocReadResult r,
  ) {
    final metadata = SnapshotMetadata(
      fromCache: r.fromCache,
      hasPendingWrites: r.hasPendingWrites,
    );
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
            linearBackoff(attempt, stepMs: 50, jitterMs: 50, rng: rng),
          );
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
            linearBackoff(attempt, stepMs: 50, jitterMs: 50, rng: rng),
          );
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

  @override
  Future<void> dispose() async {
    await _session?.dispose();
    _session = null;
    await _connectionRelay.close();
    await _syncRelay.close();
    await super.dispose(); // always last
  }
}
