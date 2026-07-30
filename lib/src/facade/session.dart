part of '../../winche_database.dart';

/// The per-identity internals of a [WincheDatabase]: the transport, local
/// store, and every offline/sync collaborator built on top of them.
///
/// One of these is built per signed-in identity. The facade holds a single
/// nullable reference to it; swapping identities means disposing the old
/// session and building a new one.
class _DatabaseSession {
  _DatabaseSession(
    ConnectionConfig config,
    this.store,
    ConflictPolicy conflictPolicy, {
    int? maxCachedDocuments,
    int? cacheSizeBytes,
  }) : transport = WsTransport(config) {
    activeTargets = ActiveTargets();
    final eviction = (maxCachedDocuments == null && cacheSizeBytes == null)
        ? null
        : EvictionManager(
            maxDocuments: maxCachedDocuments, maxBytes: cacheSizeBytes);
    cache = DocumentCache(store, eviction: eviction);
    queue = WriteQueue(store);
    targets = TargetCache(store);
    resumeTokens = ResumeTokenStore(store);
    if (eviction != null) {
      eviction
        ..pinnedPaths = (() async => {
              ...activeTargets.all(),
              for (final p in await queue.all()) p.path,
            }) // parens required: otherwise the cascade binds to the Set literal
        ..removeDocument = store.removeDocument;
    }
    changes = LocalChangeNotifier();
    sync = SyncController(transport, cache, queue,
        conflictPolicy: conflictPolicy, changeNotifier: changes)
      ..start();
    reads = CachingReadCoordinator(transport, cache, queue, targets: targets);
    writes = QueueingWriteCoordinator(cache, queue,
        maxFrameBytes: config.maxFrameBytes, onEnqueued: () async {
      changes.notify();
      // Local-first: the write is durably queued and the local view already
      // reflects it, so hand control back now. Awaiting the drain here would
      // make every set/update/delete block on a server round-trip, which is
      // exactly what the optimistic acknowledgement is meant to avoid.
      unawaited(sync.notifyEnqueued().catchError((Object _) {
        // Drain outcomes are reported on `syncEvents`; a failure there must not
        // surface as an unhandled async error from an already-acked local write.
      }));
    });

    // Dial as soon as a session exists, rather than waiting for a read, a
    // listener, or a queued write. The SDK already behaved this way, but only as
    // a side effect of subscribing to the transport's now-deleted event-stream
    // getter (formerly the mechanism for surfacing successful re-dials); making
    // it explicit is what let that getter be deleted.
    //
    // Fire-and-forget on purpose: the auto-reconnect loop owns recovery, so a
    // failure here has no caller to report to. Swallowed so it cannot surface as
    // an unhandled async error during construction.
    unawaited(transport.reconnect().catchError((Object _) {}));
  }

  final Transport transport;
  final LocalStore store;
  late final ReadCoordinator reads;
  late final WriteCoordinator writes;
  late final WriteQueue queue;
  late final SyncController sync;
  late final DocumentCache cache;
  late final TargetCache targets;
  late final ResumeTokenStore resumeTokens;
  late final ActiveTargets activeTargets;
  late final LocalChangeNotifier changes;

  bool _disposed = false;

  /// Whether [dispose] has run. Live listeners gate their emissions on this in
  /// a later task.
  bool get isDisposed => _disposed;

  Future<void> dispose() async {
    if (_disposed) return;
    // Set first: every listener emission and feed callback is gated on it, so
    // anything triggered by the teardown below becomes a no-op.
    _disposed = true;

    // 1. Live listeners — detach from their feeds and complete consumer streams
    //    while the store is still open.
    final snapshot = List<_LiveListener<Object?>>.of(listeners);
    listeners.clear();
    for (final l in snapshot) {
      await l._shutdown();
    }

    // 2. Transport — awaited, so no subscription frame can still arrive. This
    //    comes before the sync controller on purpose: closing the connection
    //    fails every in-flight request, which is what lets a drain blocked on a
    //    write response unwind (step 3 waits for it).
    await transport.dispose();

    // 3. Sync controller (waits out an in-flight drain) and the local-change
    //    signal.
    await sync.dispose();
    await changes.dispose();

    // 4. Store last: nothing above can touch it any more.
    await store.close();
  }

  /// Live listeners currently attached, so [dispose] can tear them down before
  /// the store goes away.
  final Set<_LiveListener<Object?>> listeners = {};

  void _registerListener(_LiveListener<Object?> l) => listeners.add(l);
  void _unregisterListener(_LiveListener<Object?> l) => listeners.remove(l);
}
