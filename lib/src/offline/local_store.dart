/// Durable key/value backing store for the offline cache, write queue and sync
/// metadata. All values are JSON-safe (`Map`/`List`/`String`/`num`/`bool`/null).
///
/// Implementations need not be transactional; callers maintain durability
/// invariants by writing the queue before mutating the cache and replaying
/// idempotently.
abstract interface class LocalStore {
  // --- Documents (keyed by document path) ---
  Future<void> putDocument(String path, Map<String, Object?> record);
  Future<Map<String, Object?>?> getDocument(String path);
  Future<void> removeDocument(String path);

  /// Documents whose immediate parent collection is [collectionPath]
  /// (i.e. `path == "<collectionPath>/<id>"`), excluding deeper sub-collections.
  Future<List<Map<String, Object?>>> documentsInCollection(
      String collectionPath);

  // --- Pending write queue (keyed by monotonic seq) ---
  /// Returns a new, strictly increasing sequence number (persisted).
  Future<int> nextPendingSeq();
  Future<void> putPending(int seq, Map<String, Object?> entry);

  /// All pending entries ordered by ascending seq.
  Future<List<Map<String, Object?>>> allPending();
  Future<void> removePending(int seq);

  // --- Metadata ---
  Future<void> putMeta(String key, Object? value);
  Future<Object?> getMeta(String key);

  // --- Lifecycle ---
  Future<void> clear();
  Future<void> close();
}
