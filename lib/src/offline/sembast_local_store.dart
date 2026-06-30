import 'package:sembast/sembast.dart';

import 'local_store.dart';
import 'sembast_factory.dart';

/// Durable [LocalStore] backed by sembast. Pure Dart; works on native (file)
/// and web (IndexedDB) via the platform-selected factory in `sembast_factory`.
///
/// Create instances with [SembastLocalStore.open]. A single sembast database
/// holds three stores: documents keyed by path, the pending-write queue keyed
/// by sequence number, and metadata. String keys have no length limit, so
/// long/deeply-nested document paths are stored as-is.
class SembastLocalStore implements LocalStore {
  SembastLocalStore._(this._db);

  final Database _db;

  static final _docs = StoreRef<String, Map<String, Object?>>('docs');
  static final _pending = StoreRef<int, Map<String, Object?>>('pending');
  static final _meta = StoreRef<String, Object?>('meta');

  static const _seqKey = '__seq__';

  /// Opens (or re-opens after a close) a [SembastLocalStore].
  ///
  /// On native platforms [directory] must be supplied; the database file is
  /// `<directory>/<name>.db`. On the web [directory] is ignored and [name] is
  /// the IndexedDB database name.
  ///
  /// [factory] is a test seam; production callers omit it and the
  /// platform-appropriate factory is selected automatically.
  static Future<SembastLocalStore> open(
    String name, {
    String? directory,
    DatabaseFactory? factory,
  }) async {
    final dbFactory = factory ?? sembastFactory();
    final path = directory != null ? '$directory/$name.db' : name;
    final db = await dbFactory.openDatabase(path);
    return SembastLocalStore._(db);
  }

  /// Recursively rebuilds sembast's immutable values into mutable JSON-typed
  /// `Map<String, Object?>` / `List<Object?>` so they round-trip through
  /// `WireDocument.fromJson` and other `as Map<String, Object?>` casts.
  Map<String, Object?> _castMap(Object? raw) {
    final m = raw as Map;
    return {
      for (final e in m.entries) e.key as String: _castValue(e.value),
    };
  }

  Object? _castValue(Object? v) {
    if (v is Map) return _castMap(v);
    if (v is List) return [for (final e in v) _castValue(e)];
    return v;
  }

  // --- Documents ---

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) =>
      _docs.record(path).put(_db, record);

  @override
  Future<Map<String, Object?>?> getDocument(String path) async {
    final raw = await _docs.record(path).get(_db);
    if (raw == null) return null;
    return _castMap(raw);
  }

  @override
  Future<void> removeDocument(String path) => _docs.record(path).delete(_db);

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(
    String collectionPath,
  ) async {
    final prefix = '$collectionPath/';
    final depth = collectionPath.split('/').length + 1;
    final records = await _docs.find(
      _db,
      finder: Finder(
        filter: Filter.custom((record) {
          final key = record.key as String;
          return key.startsWith(prefix) && key.split('/').length == depth;
        }),
      ),
    );
    return [for (final r in records) _castMap(r.value)];
  }

  @override
  Future<List<Map<String, Object?>>> allDocuments() async {
    final records = await _docs.find(_db);
    return [for (final r in records) _castMap(r.value)];
  }

  // --- Pending write queue ---

  @override
  Future<int> nextPendingSeq() async {
    final current = (await _meta.record(_seqKey).get(_db) as int?) ?? 0;
    final next = current + 1;
    await _meta.record(_seqKey).put(_db, next);
    return next;
  }

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) =>
      _pending.record(seq).put(_db, entry);

  @override
  Future<List<Map<String, Object?>>> allPending() async {
    final records = await _pending.find(
      _db,
      finder: Finder(sortOrders: [SortOrder(Field.key)]),
    );
    return [for (final r in records) _castMap(r.value)];
  }

  @override
  Future<void> removePending(int seq) => _pending.record(seq).delete(_db);

  // --- Metadata ---

  @override
  Future<void> putMeta(String key, Object? value) =>
      _meta.record(key).put(_db, value);

  @override
  Future<Object?> getMeta(String key) => _meta.record(key).get(_db);

  // --- Lifecycle ---

  @override
  Future<void> clear() async {
    await _docs.delete(_db);
    await _pending.delete(_db);
    await _meta.delete(_db);
  }

  @override
  Future<void> close() => _db.close();
}
