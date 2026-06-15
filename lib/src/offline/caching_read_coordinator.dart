import '../protocol/exceptions.dart';
import '../protocol/messages.dart';
import '../protocol/query_spec.dart';
import '../core/timestamps.dart';
import '../transport/transport.dart';
import 'document_cache.dart';
import 'effective_view.dart';
import 'local_query_engine.dart';
import 'read_coordinator.dart';
import 'write_queue.dart';

/// A read coordinator backed by the local [DocumentCache] and [WriteQueue].
/// Server reads write through to the cache; the effective view (confirmed +
/// pending overlay) is what every read returns, so un-synced local writes are
/// visible immediately (latency compensation).
class CachingReadCoordinator implements ReadCoordinator {
  CachingReadCoordinator(this._transport, this._cache, this._queue,
      {LocalQueryEngine queryEngine = const LocalQueryEngine()})
      : _query = queryEngine;

  final Transport _transport;
  final DocumentCache _cache;
  final WriteQueue _queue;
  final LocalQueryEngine _query;

  @override
  Future<DocReadResult> getDocument(String path, GetOptions options) async {
    final fromCache =
        await _resolveSource(options.source, () => _serverGet(path));
    return _effectiveDoc(path, fromCache);
  }

  @override
  Future<List<DocReadResult>> getAll(
      List<String> paths, GetOptions options) async {
    if (paths.isEmpty) return const [];
    final fromCache =
        await _resolveSource(options.source, () => _serverGetAll(paths));
    return [for (final p in paths) await _effectiveDoc(p, fromCache)];
  }

  @override
  Future<QueryReadResult> runQuery(QuerySpec spec, GetOptions options) async {
    var serverHasMore = false;
    final fromCache = await _resolveSource(options.source, () async {
      serverHasMore = await _serverQuery(spec);
    });
    return _effectiveQuery(spec, fromCache,
        hasMore: !fromCache && serverHasMore);
  }

  /// Statuses treated as transient — on [Source.serverOrCache] these fall back
  /// to the local cache rather than throwing. `UnavailableException` carries
  /// status `UNAVAILABLE`, so transport failures stay covered.
  static const _transientStatuses = {
    'UNAVAILABLE',
    'DEADLINE_EXCEEDED',
    'INTERNAL'
  };

  /// Applies the read-[source] policy around [serverFetch], returning whether
  /// the result must be served from cache. For [Source.serverOrCache], a
  /// transient server failure falls back to cache; other errors propagate.
  Future<bool> _resolveSource(
      Source source, Future<void> Function() serverFetch) async {
    if (source == Source.cache) return true;
    if (source == Source.server) {
      await serverFetch();
      return false;
    }
    try {
      await serverFetch();
      return false;
    } on WincheException catch (e) {
      if (_transientStatuses.contains(e.status)) return true;
      rethrow;
    }
  }

  // --- server reads (write-through to confirmed cache) ---

  Future<void> _serverGet(String path) async {
    final result = await _transport.request(docGetFrame('', path));
    await _writeThrough(path, result['document']);
  }

  Future<void> _serverGetAll(List<String> paths) async {
    final result = await _transport.request(docGetAllFrame('', paths));
    final raw = result['documents'] as List<Object?>? ?? const [];
    for (var i = 0; i < paths.length; i++) {
      await _writeThrough(paths[i], i < raw.length ? raw[i] : null);
    }
  }

  Future<bool> _serverQuery(QuerySpec spec) async {
    final result = await _transport.request(queryFrame('', spec));
    final raw = result['documents'] as List<Object?>? ?? const [];
    for (final d in raw) {
      await _cache.putConfirmed(
          WireDocument.fromJson((d as Map).cast<String, Object?>()));
    }
    return result['hasMore'] as bool? ?? false;
  }

  Future<void> _writeThrough(String path, Object? raw) async {
    if (raw == null) {
      await _cache.putConfirmedDeleted(
          path, formatMetaTimestamp(DateTime.now()));
    } else {
      await _cache.putConfirmed(
          WireDocument.fromJson((raw as Map).cast<String, Object?>()));
    }
  }

  // --- effective view (confirmed + pending overlay) ---

  Future<DocReadResult> _effectiveDoc(String path, bool fromCache) async {
    final confirmed = await _cache.confirmed(path);
    final pending = await _queue.forPath(path);
    final eff = applyOverlay(confirmed, pending);
    return DocReadResult(
      document: eff.document,
      fromCache: fromCache,
      hasPendingWrites: pending.isNotEmpty,
    );
  }

  Future<QueryReadResult> _effectiveQuery(QuerySpec spec, bool fromCache,
      {bool hasMore = false}) async {
    final confirmed = await _cache.confirmedInCollection(spec.collection);
    final byPath = await _queue.byPathInCollection(spec.collection);
    final view = buildEffectiveView(confirmed, byPath);
    var docs = _query.runQuery(spec, view.docs);
    if (spec.select != null) {
      docs = [for (final d in docs) projectFields(d, spec.select!)];
    }
    return QueryReadResult(
      documents: docs,
      fromCache: fromCache,
      hasMore: hasMore,
      hasPendingWrites: view.anyPending,
    );
  }
}
