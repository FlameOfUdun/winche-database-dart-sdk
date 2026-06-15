import '../protocol/writes.dart';
import 'local_store.dart';
import 'records.dart';

/// Durable, ordered queue of pending offline writes, backed by [LocalStore].
class WriteQueue {
  WriteQueue(this._store);
  final LocalStore _store;

  /// Appends [write] to the queue with a fresh seq and returns the stored
  /// [PendingWrite].
  Future<PendingWrite> enqueue(
    Write write, {
    required DateTime localCommitTime,
    PendingBase? base,
    Precondition? appPrecondition,
    String? batchId,
  }) async {
    final seq = await _store.nextPendingSeq();
    final pending = PendingWrite(
      seq: seq,
      path: write.path,
      write: write,
      base: base,
      appPrecondition: appPrecondition,
      batchId: batchId,
      localCommitTime: localCommitTime,
    );
    await _store.putPending(seq, pending.toRecord());
    return pending;
  }

  /// All pending writes in ascending seq order.
  Future<List<PendingWrite>> all() async =>
      [for (final r in await _store.allPending()) PendingWrite.fromRecord(r)];

  /// Pending writes for a single document [path], in seq order.
  Future<List<PendingWrite>> forPath(String path) async => [
        for (final p in await all())
          if (p.path == path) p
      ];

  /// Pending writes grouped by document path, restricted to documents whose
  /// immediate parent collection is [collectionPath].
  Future<Map<String, List<PendingWrite>>> byPathInCollection(
      String collectionPath) async {
    final depth = collectionPath.split('/').length + 1;
    final out = <String, List<PendingWrite>>{};
    for (final p in await all()) {
      if (p.path.startsWith('$collectionPath/') &&
          p.path.split('/').length == depth) {
        (out[p.path] ??= []).add(p);
      }
    }
    return out;
  }

  /// Rebases every queued entry for [path] onto a new version [base]
  /// (used after a sibling write of the same path is acked).
  Future<void> rebasePath(String path, PendingBase base) async {
    for (final p in await forPath(path)) {
      await _store.putPending(p.seq, p.copyWith(base: base).toRecord());
    }
  }

  Future<void> remove(int seq) => _store.removePending(seq);

  /// Overwrites the stored entry at [seq] with [entry] (same seq).
  Future<void> replace(int seq, PendingWrite entry) =>
      _store.putPending(seq, entry.toRecord());

  Future<bool> hasPending() async => (await _store.allPending()).isNotEmpty;
}
