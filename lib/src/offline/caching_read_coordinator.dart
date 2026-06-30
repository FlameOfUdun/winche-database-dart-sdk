import '../protocol/exceptions.dart';
import '../protocol/messages.dart';
import '../protocol/query_spec.dart';
import '../core/timestamps.dart';
import '../transport/transport.dart';
import 'document_cache.dart';
import 'effective_view.dart';
import 'local_query_engine.dart';
import 'read_coordinator.dart';
import 'records.dart' show PendingWrite;
import 'target_cache.dart';
import 'write_queue.dart';

/// A read coordinator backed by the local [DocumentCache] and [WriteQueue].
/// Server reads write through to the cache; the effective view (confirmed +
/// pending overlay) is what every read returns, so un-synced local writes are
/// visible immediately (latency compensation).
class CachingReadCoordinator implements ReadCoordinator {
  CachingReadCoordinator(this._transport, this._cache, this._queue,
      {LocalQueryEngine queryEngine = const LocalQueryEngine(),
      TargetCache? targets})
      : _query = queryEngine,
        _targets = targets;

  final Transport _transport;
  final DocumentCache _cache;
  final WriteQueue _queue;
  final LocalQueryEngine _query;
  final TargetCache? _targets;

  @override
  Future<DocReadResult> getDocument(String path, GetOptions options) async {
    WireDocument? serverDoc;
    var hasServerDoc = false;
    final fromCache = await _resolveSource(options.source, () async {
      serverDoc = await _serverGet(path);
      hasServerDoc = true;
    });
    return _effectiveDoc(path, fromCache,
        serverBase: serverDoc, hasServerBase: hasServerDoc);
  }

  @override
  Future<List<DocReadResult>> getAll(
      List<String> paths, GetOptions options) async {
    if (paths.isEmpty) return const [];
    Map<String, WireDocument?>? fetched;
    final fromCache = await _resolveSource(options.source, () async {
      fetched = await _serverGetAll(paths);
    });
    // Read the pending queue ONCE and group by path, instead of one full scan
    // per requested document.
    final pendingByPath = <String, List<PendingWrite>>{};
    for (final w in await _queue.all()) {
      (pendingByPath[w.path] ??= []).add(w);
    }
    return [
      for (final p in paths)
        await _effectiveDoc(p, fromCache,
            serverBase: fetched?[p],
            hasServerBase: fetched != null,
            pending: pendingByPath[p] ?? const []),
    ];
  }

  @override
  Future<QueryReadResult> runQuery(QuerySpec spec, GetOptions options) async {
    var serverHasMore = false;
    List<WireDocument>? serverDocs;
    final fromCache = await _resolveSource(options.source, () async {
      final r = await _serverQuery(spec);
      serverHasMore = r.hasMore;
      serverDocs = r.docs;
    });
    return _effectiveQuery(spec, fromCache,
        hasMore: !fromCache && serverHasMore, serverBase: serverDocs);
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

  Future<WireDocument?> _serverGet(String path) async {
    final result = await _transport.request(docGetFrame('', path));
    final raw = result['document'];
    await _writeThrough(path, raw);
    return raw == null
        ? null
        : WireDocument.fromJson((raw as Map).cast<String, Object?>());
  }

  /// Returns the fetched document per requested path (null = absent).
  Future<Map<String, WireDocument?>> _serverGetAll(List<String> paths) async {
    final result = await _transport.request(docGetAllFrame('', paths));
    final raw = result['documents'] as List<Object?>? ?? const [];
    final fetched = <String, WireDocument?>{};
    final live = <WireDocument>[];
    for (var i = 0; i < paths.length; i++) {
      final r = i < raw.length ? raw[i] : null;
      if (r == null) {
        await _cache.putConfirmedDeleted(
            paths[i], formatMetaTimestamp(DateTime.now()));
        fetched[paths[i]] = null;
      } else {
        final doc = WireDocument.fromJson((r as Map).cast<String, Object?>());
        live.add(doc);
        fetched[paths[i]] = doc;
      }
    }
    await _cache.putConfirmedAll(live); // single eviction pass for the batch
    return fetched;
  }

  /// Returns the server's `hasMore` flag and the fetched documents (in server
  /// order). The caller builds the result directly from [docs] so it is immune
  /// to any eviction the write-through above may have triggered when the result
  /// exceeds the cache cap.
  Future<({bool hasMore, List<WireDocument> docs})> _serverQuery(
      QuerySpec spec) async {
    final result = await _transport.request(queryFrame('', spec));
    final raw = result['documents'] as List<Object?>? ?? const [];
    final docs = [
      for (final d in raw)
        WireDocument.fromJson((d as Map).cast<String, Object?>())
    ];
    await _cache.putConfirmedAll(docs); // single eviction pass for the batch
    await _targets?.setMembers(spec, [for (final d in docs) d.path]);
    return (hasMore: result['hasMore'] as bool? ?? false, docs: docs);
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

  Future<DocReadResult> _effectiveDoc(String path, bool fromCache,
      {WireDocument? serverBase,
      bool hasServerBase = false,
      List<PendingWrite>? pending}) async {
    // Online: use the just-fetched server doc directly (immune to write-through
    // eviction). Offline/cache: read the confirmed cache.
    final confirmed = hasServerBase ? serverBase : await _cache.confirmed(path);
    // [pending] is supplied by batch callers (getAll) that grouped the queue
    // once; single-doc callers fall back to a scoped lookup.
    final entries = pending ?? await _queue.forPath(path);
    final eff = applyOverlay(confirmed, entries);
    return DocReadResult(
      document: eff.document,
      fromCache: fromCache,
      hasPendingWrites: entries.isNotEmpty,
    );
  }

  Future<QueryReadResult> _effectiveQuery(QuerySpec spec, bool fromCache,
      {bool hasMore = false, List<WireDocument>? serverBase}) async {
    // Online: the just-fetched server result is the authoritative base — read it
    // directly so a result larger than the eviction cap is not truncated by the
    // write-through. Offline/cache: serve from the query's known membership when
    // we have it; otherwise re-derive over the whole collection (a cold query
    // never listened to or fetched).
    //
    // I2 (known interaction): when eviction is enabled, a member named in the
    // TargetCache may have been evicted with no active listener pinning it, so an
    // offline cache read can under-report it. It self-heals online (re-fetched);
    // full offline completeness under eviction is a Phase 3 concern.
    final List<WireDocument> base;
    if (serverBase != null) {
      base = serverBase;
    } else {
      final members = await _targets?.members(spec);
      base = members != null
          ? await _resolveMembers(members)
          : await _cache.confirmedInCollection(spec.collection);
    }
    final byPath = await _queue.byPathInCollection(spec.collection);
    final view = buildEffectiveView(base, byPath);
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

  Future<List<WireDocument>> _resolveMembers(List<String> paths) async {
    final docs = <WireDocument>[];
    for (final p in paths) {
      final doc = await _cache.confirmed(p);
      if (doc != null) docs.add(doc);
    }
    return docs;
  }
}
