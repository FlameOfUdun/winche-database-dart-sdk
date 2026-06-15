import 'local_store.dart';

/// A [LocalStore] that defers opening its underlying store until the first
/// operation.
///
/// The [_open] factory is invoked at most once — its `Future` is memoized, so
/// concurrent first-callers share a single open. This makes lazy directory
/// resolution transparent to the cache / write-queue / sync layers, which only
/// ever call store methods asynchronously.
class LazyLocalStore implements LocalStore {
  LazyLocalStore(this._open);

  final Future<LocalStore> Function() _open;
  Future<LocalStore>? _opened;

  Future<LocalStore> _ensure() => _opened ??= _open();

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) async =>
      (await _ensure()).putDocument(path, record);

  @override
  Future<Map<String, Object?>?> getDocument(String path) async =>
      (await _ensure()).getDocument(path);

  @override
  Future<void> removeDocument(String path) async =>
      (await _ensure()).removeDocument(path);

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(
          String collectionPath) async =>
      (await _ensure()).documentsInCollection(collectionPath);

  @override
  Future<int> nextPendingSeq() async => (await _ensure()).nextPendingSeq();

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) async =>
      (await _ensure()).putPending(seq, entry);

  @override
  Future<List<Map<String, Object?>>> allPending() async =>
      (await _ensure()).allPending();

  @override
  Future<void> removePending(int seq) async =>
      (await _ensure()).removePending(seq);

  @override
  Future<void> putMeta(String key, Object? value) async =>
      (await _ensure()).putMeta(key, value);

  @override
  Future<Object?> getMeta(String key) async => (await _ensure()).getMeta(key);

  @override
  Future<void> clear() async => (await _ensure()).clear();

  @override
  Future<void> close() async {
    final opened = _opened;
    if (opened == null) return; // never opened — nothing to close
    await (await opened).close();
  }
}
