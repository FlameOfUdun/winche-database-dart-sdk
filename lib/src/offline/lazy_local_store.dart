import 'local_store.dart';

/// A [LocalStore] that defers opening its underlying store until the first
/// operation.
///
/// The [_open] factory is invoked at most once — its `Future` is memoized, so
/// concurrent first-callers share a single open. This makes lazy directory
/// resolution transparent to the cache / write-queue / sync layers, which only
/// ever call store methods asynchronously.
/// After [close], every operation is a silent no-op rather than an error: the
/// backing sembast database throws `database is closed` on any access, and a
/// straggling callback (a socket teardown driving one last listener emission,
/// a fire-and-forget resume-token write) would surface that as an unhandled
/// async error the caller cannot catch. Degrading to "nothing cached" is the
/// safe reading of a store that is gone.
class LazyLocalStore implements LocalStore {
  LazyLocalStore(this._open);

  final Future<LocalStore> Function() _open;
  Future<LocalStore>? _opened;
  bool _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  Future<LocalStore> _ensure() => _opened ??= _open();

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) async {
    if (_closed) return;
    return (await _ensure()).putDocument(path, record);
  }

  @override
  Future<Map<String, Object?>?> getDocument(String path) async {
    if (_closed) return null;
    return (await _ensure()).getDocument(path);
  }

  @override
  Future<void> removeDocument(String path) async {
    if (_closed) return;
    return (await _ensure()).removeDocument(path);
  }

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(
      String collectionPath) async {
    if (_closed) return const [];
    return (await _ensure()).documentsInCollection(collectionPath);
  }

  @override
  Future<List<Map<String, Object?>>> allDocuments() async {
    if (_closed) return const [];
    return (await _ensure()).allDocuments();
  }

  @override
  Future<int> nextPendingSeq() async {
    if (_closed) return 0;
    return (await _ensure()).nextPendingSeq();
  }

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) async {
    if (_closed) return;
    return (await _ensure()).putPending(seq, entry);
  }

  @override
  Future<List<Map<String, Object?>>> allPending() async {
    if (_closed) return const [];
    return (await _ensure()).allPending();
  }

  @override
  Future<void> removePending(int seq) async {
    if (_closed) return;
    return (await _ensure()).removePending(seq);
  }

  @override
  Future<void> putMeta(String key, Object? value) async {
    if (_closed) return;
    return (await _ensure()).putMeta(key, value);
  }

  @override
  Future<Object?> getMeta(String key) async {
    if (_closed) return null;
    return (await _ensure()).getMeta(key);
  }

  @override
  Future<void> clear() async {
    if (_closed) return;
    return (await _ensure()).clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return; // idempotent
    _closed = true;
    final opened = _opened;
    if (opened == null) return; // never opened — nothing to close
    await (await opened).close();
  }
}
