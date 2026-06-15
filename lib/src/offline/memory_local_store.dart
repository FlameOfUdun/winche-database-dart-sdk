import 'local_store.dart';

/// An in-memory [LocalStore] — the default store when none is supplied.
///
/// Holds the cache, write queue, and metadata in memory only: state is lost when
/// the process exits. Pass a durable store (e.g. `HiveLocalStore`) for
/// persistence across restarts. Works identically on native and web.
class MemoryLocalStore implements LocalStore {
  final Map<String, Map<String, Object?>> _docs = {};
  final Map<int, Map<String, Object?>> _pending = {};
  final Map<String, Object?> _meta = {};
  int _seq = 0;

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) async =>
      _docs[path] = record;

  @override
  Future<Map<String, Object?>?> getDocument(String path) async => _docs[path];

  @override
  Future<void> removeDocument(String path) async => _docs.remove(path);

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(
      String collectionPath) async {
    final depth = collectionPath.split('/').length + 1;
    return [
      for (final e in _docs.entries)
        if (e.key.startsWith('$collectionPath/') &&
            e.key.split('/').length == depth)
          e.value,
    ];
  }

  @override
  Future<int> nextPendingSeq() async => ++_seq;

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) async =>
      _pending[seq] = entry;

  @override
  Future<List<Map<String, Object?>>> allPending() async {
    final seqs = _pending.keys.toList()..sort();
    return [for (final s in seqs) _pending[s]!];
  }

  @override
  Future<void> removePending(int seq) async => _pending.remove(seq);

  @override
  Future<void> putMeta(String key, Object? value) async => _meta[key] = value;

  @override
  Future<Object?> getMeta(String key) async => _meta[key];

  @override
  Future<void> clear() async {
    _docs.clear();
    _pending.clear();
    _meta.clear();
    _seq = 0;
  }

  @override
  Future<void> close() async {}
}
