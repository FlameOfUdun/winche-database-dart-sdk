import 'dart:async';

import '../protocol/exceptions.dart';
import '../protocol/messages.dart';
import '../core/paths.dart';
import '../core/timestamps.dart';
import '../core/values.dart';
import '../protocol/writes.dart';
import '../transport/transport.dart';
import 'document_cache.dart';
import 'effective_view.dart';
import 'local_change_notifier.dart';
import 'records.dart';
import 'sync_event.dart';
import 'write_queue.dart';

/// Result of draining one unit: a clean ack (drop it from the in-memory view),
/// any other queue mutation (re-read fresh), or the server was offline (stop).
enum _DrainOutcome { acked, mutated, offline }

/// Drains the offline [WriteQueue] to the server, advancing the confirmed cache
/// on ack and reporting progress on [events].
class SyncController {
  SyncController(
    this._transport,
    this._cache,
    this._queue, {
    ConflictPolicy conflictPolicy = ConflictPolicy.manual,
    LocalChangeNotifier? changeNotifier,
  })  : _policy = conflictPolicy,
        _changes = changeNotifier;

  final Transport _transport;
  final DocumentCache _cache;
  final WriteQueue _queue;
  final ConflictPolicy _policy;
  final LocalChangeNotifier? _changes;

  /// Keys (batchId for batches, else path) of units awaiting conflict resolution.
  final Set<String> _pausedKeys = {};

  /// Per-unit (keyed by head seq) count of automatic conflict resolutions, used to
  /// drop a unit whose auto-resolution can't make progress instead of livelocking
  /// the drain (e.g. a clientWins overwrite of an UPDATE to a missing doc keeps
  /// returning NOT_FOUND).
  final Map<int, int> _autoResolveAttempts = {};
  static const _maxAutoResolveAttempts = 1;

  final List<Completer<void>> _pendingWaiters = [];

  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();
  Stream<SyncEvent> get events => _events.stream;

  bool _draining = false;
  StreamSubscription<void>? _reconnectSub;

  /// Subscribes to reconnect events to drive draining; call once after wiring.
  void start() {
    _reconnectSub = _transport.reconnects.listen(
      (_) => drain(),
      onError: (_) {}, // connection errors are handled inside drain()
      cancelOnError: false,
    );
  }

  /// Called by the write coordinator after a write is enqueued.
  Future<void> notifyEnqueued() => drain();

  /// Drains the whole queue (best-effort). No-op when already draining; when the
  /// server is unreachable the unit stays queued and is retried on reconnect.
  ///
  /// Reads the queue once and maintains it in memory: a clean ack drops the unit
  /// from the in-memory view (no re-read → linear). A conflict/error path mutates
  /// the queue unpredictably, so the view is re-read fresh — preserving exact
  /// conflict behavior.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      var queue = await _queue.all();
      while (true) {
        var unit = _firstUnpausedUnit(queue);
        if (unit == null) {
          // In-memory view exhausted of actionable units. Re-read once to pick up
          // writes enqueued while we were draining (their notifyEnqueued no-ops
          // under the _draining guard, so they aren't in our snapshot). Still
          // nothing actionable → done.
          queue = await _queue.all();
          unit = _firstUnpausedUnit(queue);
          if (unit == null) break;
        }
        final r = await _drainUnit(unit);
        if (r.outcome == _DrainOutcome.offline) break;
        queue = r.outcome == _DrainOutcome.acked
            ? await _rebaseSiblings(_withoutUnit(queue, unit), r.rebases)
            : await _queue.all();
      }
    } finally {
      _draining = false;
    }
    await _signalWaitersIfDrained();
  }

  /// Replays the head unit of the queue once. No-op (returns false) when already
  /// draining, offline, or empty. Returns true if a unit was acked or its error
  /// was handled (conflict paused/overwritten/dropped).
  Future<bool> drainOnce() async {
    if (_draining) return false;
    _draining = true;
    try {
      final all = await _queue.all();
      final unit = _firstUnpausedUnit(all);
      if (unit == null) return false;
      final r = await _drainUnit(unit);
      if (r.outcome == _DrainOutcome.acked) {
        await _rebaseSiblings(_withoutUnit(all, unit), r.rebases);
      }
      return r.outcome != _DrainOutcome.offline;
    } finally {
      _draining = false;
    }
  }

  /// Replays one unit. Callers must hold `_draining`. Returns the outcome plus,
  /// when acked, a path → server-updateTime map so the caller can rebase queued
  /// siblings from its in-memory view (no store re-scan).
  Future<({_DrainOutcome outcome, Map<String, String> rebases})> _drainUnit(
      List<PendingWrite> unit) async {
    final key = _keyOf(unit);
    final frame =
        writeFrame('', [for (final p in unit) _withReplayPrecondition(p)]);
    final Map<String, Object?> result;
    try {
      result = await _transport.request(frame);
    } on UnavailableException {
      return (outcome: _DrainOutcome.offline, rebases: const <String, String>{});
    } on WincheException catch (e) {
      await _handleError(unit, key, e);
      return (outcome: _DrainOutcome.mutated, rebases: const <String, String>{});
    }

    final writeResults = result['writeResults'] as List<Object?>? ?? const [];
    final rebases = <String, String>{};
    for (var i = 0; i < unit.length; i++) {
      final wr = (i < writeResults.length
          ? writeResults[i]
          : const <String, Object?>{}) as Map<String, Object?>;
      rebases[unit[i].path] = await _applyAck(unit[i], wr);
      await _queue.remove(unit[i].seq);
    }
    _autoResolveAttempts.remove(unit.first.seq);
    _emit(WriteSynced(
      paths: [for (final p in unit) p.path],
      batchId: unit.first.batchId,
    ));
    _changes?.notify();
    return (outcome: _DrainOutcome.acked, rebases: rebases);
  }

  /// The in-memory queue minus [unit]'s entries (by seq).
  List<PendingWrite> _withoutUnit(
      List<PendingWrite> queue, List<PendingWrite> unit) {
    final seqs = {for (final p in unit) p.seq};
    return [
      for (final p in queue)
        if (!seqs.contains(p.seq)) p
    ];
  }

  /// Rebases queued siblings of just-acked paths onto the new server version,
  /// using the in-memory [queue] (no store scan) and persisting each change.
  /// Returns the updated in-memory queue.
  Future<List<PendingWrite>> _rebaseSiblings(
      List<PendingWrite> queue, Map<String, String> rebases) async {
    if (rebases.isEmpty) return queue;
    final out = <PendingWrite>[];
    for (final p in queue) {
      final updateTime = rebases[p.path];
      if (updateTime == null) {
        out.add(p);
        continue;
      }
      final rebased = p.copyWith(base: PendingBase(updateTime: updateTime));
      await _queue.replace(p.seq, rebased);
      out.add(rebased);
    }
    return out;
  }

  /// Completes when the pending-write queue has fully drained. Stays pending
  /// (without busy-waiting) while writes remain queued — e.g. while offline or
  /// while a conflict is unresolved.
  ///
  /// Note: under [ConflictPolicy.manual] a write paused on an unresolved
  /// conflict keeps the queue non-empty, so this stays pending until the
  /// conflict is resolved via the [WriteConflict] event on [events].
  Future<void> waitForPendingWrites() async {
    if (!await _queue.hasPending()) return;
    final completer = Completer<void>();
    _pendingWaiters.add(completer);
    return completer.future;
  }

  Future<void> _signalWaitersIfDrained() async {
    if (_pendingWaiters.isEmpty) return;
    if (await _queue.hasPending()) return;
    final waiters = List<Completer<void>>.of(_pendingWaiters);
    _pendingWaiters.clear();
    for (final c in waiters) {
      if (!c.isCompleted) c.complete();
    }
  }

  // --- internals ---

  String _keyOf(List<PendingWrite> unit) =>
      unit.first.batchId ?? unit.first.path;

  /// The first contiguous unit (from the front) whose key is not paused.
  List<PendingWrite>? _firstUnpausedUnit(List<PendingWrite> all) {
    var i = 0;
    while (i < all.length) {
      final head = all[i];
      final unit = <PendingWrite>[];
      if (head.batchId == null) {
        unit.add(head);
      } else {
        for (var j = i; j < all.length; j++) {
          if (all[j].batchId == head.batchId) {
            unit.add(all[j]);
          } else {
            break;
          }
        }
      }
      if (!_pausedKeys.contains(_keyOf(unit))) return unit;
      i += unit.length;
    }
    return null;
  }

  static const _conflictStatuses = {
    'FAILED_PRECONDITION',
    'ALREADY_EXISTS',
    'NOT_FOUND',
  };

  Future<void> _handleError(
      List<PendingWrite> unit, String key, WincheException e) async {
    if (_conflictStatuses.contains(e.status)) {
      await _onConflict(unit, key, e);
    } else {
      _autoResolveAttempts.remove(unit.first.seq);
      for (final p in unit) {
        await _queue.remove(p.seq);
      }
      _emit(WriteFailed(
        paths: [for (final p in unit) p.path],
        error: e,
        batchId: unit.first.batchId,
      ));
    }
  }

  Future<void> _onConflict(
      List<PendingWrite> unit, String key, WincheException e) async {
    if (_policy != ConflictPolicy.manual) {
      final seq = unit.first.seq;
      final attempts = (_autoResolveAttempts[seq] ?? 0) + 1;
      if (attempts > _maxAutoResolveAttempts) {
        // Auto-resolution can't make progress (e.g. a clientWins overwrite of an
        // UPDATE to a now-missing doc keeps returning NOT_FOUND) — drop the unit
        // as a failed write rather than livelock the drain.
        _autoResolveAttempts.remove(seq);
        for (final p in unit) {
          await _queue.remove(p.seq);
        }
        _emit(WriteFailed(
          paths: [for (final p in unit) p.path],
          error: e,
          batchId: unit.first.batchId,
        ));
        return;
      }
      _autoResolveAttempts[seq] = attempts;
    }
    _pausedKeys.add(key);
    final serverDocs = <String, WireDocument?>{};
    for (final p in unit) {
      serverDocs[p.path] = await _fetchServerDoc(p.path);
    }

    Future<void> resolveWith(Future<void> Function() action) async {
      _pausedKeys.remove(key);
      await action();
      _changes?.notify();
      await drain();
    }

    final conflict = WriteConflict(
      paths: [for (final p in unit) p.path],
      error: e,
      serverDocuments: serverDocs,
      onRetry: () => resolveWith(() => _retry(unit, serverDocs)),
      onDiscard: () => resolveWith(() => _discard(unit, serverDocs)),
      onOverwrite: () => resolveWith(() => _overwrite(unit)),
    );

    switch (_policy) {
      case ConflictPolicy.manual:
        _emit(conflict);
      case ConflictPolicy.clientWins:
        await resolveWith(() => _overwrite(unit));
      case ConflictPolicy.serverWins:
        await resolveWith(() => _discard(unit, serverDocs));
    }
  }

  Future<WireDocument?> _fetchServerDoc(String path) async {
    try {
      final r = await _transport.request(docGetFrame('', path));
      return WireDocument.fromAny(r['document']);
    } on WincheException {
      return null;
    }
  }

  /// Rebase the unit onto the server's current version and refresh the cache;
  /// it stays queued for the next drain.
  Future<void> _retry(
      List<PendingWrite> unit, Map<String, WireDocument?> serverDocs) async {
    for (final p in unit) {
      final server = serverDocs[p.path];
      await _writeThroughServerDoc(p.path, server);
      final base = server == null
          ? const PendingBase(existsFalse: true)
          : PendingBase(version: server.version, updateTime: server.updateTime);
      await _queue.rebasePath(p.path, base);
    }
  }

  /// Drop the unit and refresh the cache from the server doc.
  Future<void> _discard(
      List<PendingWrite> unit, Map<String, WireDocument?> serverDocs) async {
    _autoResolveAttempts.remove(unit.first.seq);
    for (final p in unit) {
      await _queue.remove(p.seq);
      await _writeThroughServerDoc(p.path, serverDocs[p.path]);
    }
  }

  /// Strip the version base + app precondition so the unit replays
  /// last-write-wins (the replay precondition is derived from base/appPrecondition,
  /// so nulling both yields no precondition).
  Future<void> _overwrite(List<PendingWrite> unit) async {
    for (final p in unit) {
      await _queue.replace(
        p.seq,
        PendingWrite(
          seq: p.seq,
          path: p.path,
          write: p.write,
          localCommitTime: p.localCommitTime,
          base: null,
          appPrecondition: null,
          batchId: p.batchId,
        ),
      );
    }
  }

  Future<void> _writeThroughServerDoc(String path, WireDocument? server) async {
    if (server == null) {
      await _cache.putConfirmedDeleted(
          path, formatMetaTimestamp(DateTime.now()));
    } else {
      await _cache.putConfirmed(server);
    }
  }

  /// Returns the write with the precondition used for replay: the app
  /// precondition if present, else one derived from the version base.
  static Write _withReplayPrecondition(PendingWrite p) {
    final precondition = p.appPrecondition ?? _baseToPrecondition(p.base);
    return p.write.withPrecondition(precondition);
  }

  static Precondition? _baseToPrecondition(PendingBase? base) {
    if (base == null) return null;
    if (base.existsFalse == true) return const Precondition(exists: false);
    if (base.updateTime != null) {
      return Precondition.updateTimeRaw(base.updateTime!);
    }
    return null;
  }

  /// Promotes the acked write's optimistic effect to confirmed state, stamps the
  /// server [wr] updateTime, applies server transformResults, and returns the
  /// server updateTime (the caller rebases queued siblings of this path with it).
  Future<String> _applyAck(PendingWrite entry, Map<String, Object?> wr) async {
    final updateTime = wr['updateTime'] as String? ??
        formatMetaTimestamp(entry.localCommitTime);
    if (entry.write is DeleteWrite) {
      await _cache.putConfirmedDeleted(entry.path, updateTime);
    } else {
      final prior = await _cache.confirmed(entry.path);
      final eff = applyOverlay(prior, [entry]);
      var fields = eff.document?.fields ?? const <String, Value>{};
      fields = _applyTransformResults(fields, wr['transformResults']);
      await _cache.putConfirmed(WireDocument(
        path: entry.path,
        id: docId(entry.path),
        collection: collectionOf(entry.path),
        fields: fields,
        createTime: prior?.createTime ?? updateTime,
        updateTime: updateTime,
        version: prior?.version ?? 0,
      ));
    }
    return updateTime;
  }

  Map<String, Value> _applyTransformResults(
      Map<String, Value> fields, Object? transformResults) {
    if (transformResults is! Map) return fields;
    final out = Map<String, Value>.of(fields);
    for (final e in transformResults.entries) {
      out[e.key as String] = Value.fromJson(e.value);
    }
    return out;
  }

  void _emit(SyncEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() async {
    await _reconnectSub?.cancel();
    for (final c in _pendingWaiters) {
      if (!c.isCompleted) c.complete();
    }
    _pendingWaiters.clear();
    if (!_events.isClosed) await _events.close();
  }
}
