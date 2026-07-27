import '../protocol/exceptions.dart';
import '../protocol/messages.dart';
import 'records.dart';

/// How unresolved write conflicts are handled by default.
enum ConflictPolicy {
  /// Pause the conflicting write and wait for explicit resolution via the
  /// [WriteConflict] event (default).
  manual,

  /// Automatically re-send the local write without a version precondition
  /// (local write overwrites the server).
  clientWins,

  /// Automatically discard the local write and keep the server's version.
  serverWins,
}

/// An event emitted on `WincheDatabase.syncEvents` as the write queue drains.
sealed class SyncEvent {
  const SyncEvent();
}

/// A pending write (or batch) was acknowledged by the server.
final class WriteSynced extends SyncEvent {
  const WriteSynced({required this.paths, this.batchId});

  /// The document path(s) the synced unit touched.
  final List<String> paths;
  final String? batchId;
}

/// A pending write (or batch) was rejected by a version precondition. Resolve
/// it with [retry], [discard], or [overwrite].
final class WriteConflict extends SyncEvent {
  WriteConflict({
    required this.paths,
    required this.error,
    required this.serverDocuments,
    required Future<void> Function() onRetry,
    required Future<void> Function() onDiscard,
    required Future<void> Function() onOverwrite,
  })  : _retry = onRetry,
        _discard = onDiscard,
        _overwrite = onOverwrite;

  final List<String> paths;
  final WincheException error;

  /// The server's current document per path (null = absent), for the app to
  /// inspect while resolving.
  final Map<String, WireDocument?> serverDocuments;

  final Future<void> Function() _retry;
  final Future<void> Function() _discard;
  final Future<void> Function() _overwrite;

  bool _resolved = false;

  /// Rebase the local write onto the server's current version and re-queue it.
  Future<void> retry() => _resolveOnce(_retry);

  /// Drop the local write and refresh the cache from the server.
  Future<void> discard() => _resolveOnce(_discard);

  /// Re-send the local write without a version precondition (client wins).
  Future<void> overwrite() => _resolveOnce(_overwrite);

  Future<void> _resolveOnce(Future<void> Function() action) {
    if (_resolved) {
      throw StateError('This write conflict has already been resolved.');
    }
    _resolved = true;
    return action();
  }
}

/// A pending write (or batch) failed permanently (e.g. permission denied) and
/// was dropped from the queue.
///
/// [writes] carries the dropped entries in full, so an app can surface or
/// re-apply the lost work — once this event is emitted, the queue no longer
/// holds them anywhere.
final class WriteFailed extends SyncEvent {
  const WriteFailed({
    required this.paths,
    required this.error,
    required this.writes,
    this.batchId,
  });

  final List<String> paths;
  final WincheException error;

  /// The dropped pending writes, in queue order.
  final List<PendingWrite> writes;

  final String? batchId;
}

/// The queue is stalled because the server rejected the head unit with
/// `UNAUTHENTICATED` — the token is missing, expired, or no longer valid.
///
/// Unlike [WriteFailed] nothing is dropped: an auth failure says nothing about
/// the write itself, so the unit stays queued exactly where it was. Refresh the
/// token behind `tokenProvider` and call `WincheDatabase.reconnect()` to resume
/// draining.
final class SyncPaused extends SyncEvent {
  const SyncPaused({required this.paths, required this.error});

  /// The document path(s) of the unit the queue is stalled on.
  final List<String> paths;
  final UnauthenticatedException error;
}
