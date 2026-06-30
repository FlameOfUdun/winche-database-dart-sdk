/// In-memory LRU bookkeeping for live cached documents. When the tracked set
/// exceeds the document-count cap [maxDocuments] and/or the byte cap [maxBytes],
/// removes the oldest documents that are not pinned (referenced by an active
/// target or a pending write).
///
/// A plain [Map] preserves insertion order, so re-inserting a key on access
/// moves it to the most-recently-used end; `keys` iterates oldest-first.
/// In-memory only: recency is rebuilt cold (in store order) on restart.
class EvictionManager {
  EvictionManager({this.maxDocuments, this.maxBytes});

  final int? maxDocuments;
  final int? maxBytes;

  /// path -> serialized byte size.
  final Map<String, int> _lru = {};
  int _totalBytes = 0;

  /// Returns the paths that must NOT be evicted (active targets + pending writes).
  Future<Set<String>> Function()? pinnedPaths;

  /// Physically removes a document from the durable store (evict != tombstone).
  Future<void> Function(String path)? removeDocument;

  int get trackedCount => _lru.length;
  int get trackedBytes => _totalBytes;

  /// Marks [path] most-recently-used with serialized size [bytes] (and tracks it
  /// if new), replacing any previous size.
  void recordAccess(String path, int bytes) {
    _drop(path);
    _lru[path] = bytes;
    _totalBytes += bytes;
  }

  /// Stops tracking [path] (e.g. it was tombstoned or removed).
  void forget(String path) => _drop(path);

  void _drop(String path) {
    final prev = _lru.remove(path);
    if (prev != null) _totalBytes -= prev;
  }

  bool _overCap() =>
      (maxDocuments != null && _lru.length > maxDocuments!) ||
      (maxBytes != null && _totalBytes > maxBytes!);

  /// Evicts oldest unpinned documents until within both caps, or none remain.
  ///
  /// Note: a single document larger than [maxBytes] is admitted then evicted on
  /// the next pass (it cannot fit). The caller still receives it from the freshly
  /// fetched server result; it just will not persist offline.
  Future<void> evictIfNeeded() async {
    if (!_overCap()) return;
    final remove = removeDocument;
    if (remove == null) return;
    final pinned = await pinnedPaths?.call() ?? const <String>{};
    for (final path in _lru.keys.where((p) => !pinned.contains(p)).toList()) {
      if (!_overCap()) break;
      await remove(path);
      _drop(path);
    }
  }
}
