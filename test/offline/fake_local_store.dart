import 'package:winche_database/src/offline/local_store.dart';

/// In-memory [LocalStore] for tests (not durable across process restarts;
/// `reopen()` simulates a restart by preserving data in a new instance).
class FakeLocalStore implements LocalStore {
  FakeLocalStore({
    Map<String, Map<String, Object?>>? docs,
    Map<int, Map<String, Object?>>? pending,
    Map<String, Object?>? meta,
    int seq = 0,
  })  : _docs = docs ?? {},
        _pending = pending ?? {},
        _meta = meta ?? {},
        _seq = seq;

  final Map<String, Map<String, Object?>> _docs;
  final Map<int, Map<String, Object?>> _pending;
  final Map<String, Object?> _meta;
  int _seq;

  /// Returns a new store sharing copies of this store's data — simulates an
  /// app restart.
  FakeLocalStore reopen() => FakeLocalStore(
        docs: Map.of(_docs),
        pending: Map.of(_pending),
        meta: Map.of(_meta),
        seq: _seq,
      );

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) async {
    _docs[path] = Map.of(record);
  }

  @override
  Future<Map<String, Object?>?> getDocument(String path) async {
    final r = _docs[path];
    return r == null ? null : Map.of(r);
  }

  @override
  Future<void> removeDocument(String path) async {
    _docs.remove(path);
  }

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(
      String collectionPath) async {
    final depth = collectionPath.split('/').length + 1;
    return [
      for (final e in _docs.entries)
        if (e.key.startsWith('$collectionPath/') &&
            e.key.split('/').length == depth)
          Map.of(e.value),
    ];
  }

  @override
  Future<int> nextPendingSeq() async => ++_seq;

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) async {
    _pending[seq] = Map.of(entry);
  }

  @override
  Future<List<Map<String, Object?>>> allPending() async {
    final seqs = _pending.keys.toList()..sort();
    return [for (final s in seqs) Map.of(_pending[s]!)];
  }

  @override
  Future<void> removePending(int seq) async {
    _pending.remove(seq);
  }

  @override
  Future<void> putMeta(String key, Object? value) async {
    _meta[key] = value;
  }

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
