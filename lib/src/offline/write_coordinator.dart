import 'dart:convert';
import 'dart:math';

import '../core/timestamps.dart';
import '../protocol/exceptions.dart';
import '../protocol/messages.dart';
import '../protocol/writes.dart';
import 'document_cache.dart';
import 'records.dart';
import 'write_queue.dart';

/// Applies writes to the local queue (which the sync controller drains to the
/// server). Returns one writeResult JSON (`{updateTime, transformResults?}`) per
/// write, in order, matching the server's `writeResults` shape.
abstract interface class WriteCoordinator {
  Future<List<Map<String, Object?>>> applyWrites(List<Write> writes);
}

/// Local-first coordinator: captures a version base from the cache, enqueues
/// each write durably, and returns a local ack stamped with the commit time.
/// Does not contact the server (the sync controller drains the queue later).
class QueueingWriteCoordinator implements WriteCoordinator {
  QueueingWriteCoordinator(this._cache, this._queue,
      {Future<void> Function()? onEnqueued, int maxFrameBytes = 1 << 20})
      : _onEnqueued = onEnqueued,
        _maxFrameBytes = maxFrameBytes;
  final DocumentCache _cache;
  final WriteQueue _queue;
  final Future<void> Function()? _onEnqueued;
  final int _maxFrameBytes;
  final Random _rng = Random();

  @override
  Future<List<Map<String, Object?>>> applyWrites(List<Write> writes) async {
    _validateBatch(writes);
    final now = DateTime.now();
    final batchId = writes.length > 1 ? _newBatchId() : null;
    final ackTime = formatMetaTimestamp(now);
    final acks = <Map<String, Object?>>[];
    for (final write in writes) {
      await _queue.enqueue(
        write,
        localCommitTime: now,
        base: await _baseFor(write.path),
        appPrecondition: write.precondition,
        batchId: batchId,
      );
      acks.add({'updateTime': ackTime, 'transformResults': null});
    }
    await _onEnqueued?.call();
    return acks;
  }

  Future<PendingBase?> _baseFor(String path) async {
    final doc = await _cache.confirmed(path);
    if (doc != null) {
      return PendingBase(version: doc.version, updateTime: doc.updateTime);
    }
    if (await _cache.isKnownAbsent(path)) {
      return const PendingBase(existsFalse: true);
    }
    return null; // unknown base → last-write-wins on replay
  }

  String _newBatchId() =>
      'b${DateTime.now().microsecondsSinceEpoch}_${_rng.nextInt(1 << 32)}';

  void _validateBatch(List<Write> writes) {
    if (writes.length > 500) {
      throw InvalidArgumentException(
          'Write batch exceeds the 500-write limit (${writes.length}).');
    }
    final bytes = utf8.encode(jsonEncode(writeFrame('', writes))).length;
    if (bytes > _maxFrameBytes) {
      throw InvalidArgumentException(
          'Write frame is $bytes bytes, exceeding maxFrameBytes ($_maxFrameBytes).');
    }
  }
}
