import 'package:hive_ce/hive.dart';

import 'local_store.dart';

/// Durable [LocalStore] backed by Hive CE. Pure Dart; works on native and web
/// (Hive uses IndexedDB on web automatically).
///
/// Create instances with [HiveLocalStore.open].
class HiveLocalStore implements LocalStore {
  HiveLocalStore._(this._docs, this._pending, this._meta);

  final Box<dynamic> _docs;
  final Box<dynamic> _pending;
  final Box<dynamic> _meta;

  static const _seqKey = '__seq__';

  /// Opens (or re-opens after a close) a [HiveLocalStore].
  ///
  /// [name] is used to namespace the three internal Hive boxes so multiple
  /// stores can coexist in the same [directory].
  ///
  /// On native (VM/AOT) platforms, [directory] must be supplied; Hive uses it
  /// as the file-system location for the box files.  On the web the parameter
  /// is ignored (Hive uses IndexedDB automatically).
  static Future<HiveLocalStore> open(String name, {String? directory}) async {
    final docs = await Hive.openBox<dynamic>(
      '${name}_docs',
      path: directory,
    );
    final pending = await Hive.openBox<dynamic>(
      '${name}_pending',
      path: directory,
    );
    final meta = await Hive.openBox<dynamic>(
      '${name}_meta',
      path: directory,
    );
    return HiveLocalStore._(docs, pending, meta);
  }

  /// Recursively converts Hive's `Map<dynamic, dynamic>` (and any nested maps or
  /// lists) into JSON-typed `Map<String, Object?>` so values round-trip through
  /// `WireDocument.fromJson` and other `as Map<String, Object?>` casts.
  Map<String, Object?> _castMap(dynamic raw) {
    final m = raw as Map<dynamic, dynamic>;
    return {
      for (final e in m.entries) e.key as String: _castValue(e.value),
    };
  }

  Object? _castValue(dynamic v) {
    if (v is Map) return _castMap(v);
    if (v is List) return [for (final e in v) _castValue(e)];
    return v as Object?;
  }

  // ---------------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------------

  @override
  Future<void> putDocument(String path, Map<String, Object?> record) =>
      _docs.put(path, record);

  @override
  Future<Map<String, Object?>?> getDocument(String path) async {
    final raw = _docs.get(path);
    if (raw == null) return null;
    return _castMap(raw);
  }

  @override
  Future<void> removeDocument(String path) => _docs.delete(path);

  @override
  Future<List<Map<String, Object?>>> documentsInCollection(
    String collectionPath,
  ) async {
    final depth = collectionPath.split('/').length + 1;
    final result = <Map<String, Object?>>[];
    for (final key in _docs.keys) {
      if (key is String &&
          key.startsWith('$collectionPath/') &&
          key.split('/').length == depth) {
        final raw = _docs.get(key);
        if (raw != null) result.add(_castMap(raw));
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Pending write queue
  // ---------------------------------------------------------------------------

  @override
  Future<int> nextPendingSeq() async {
    final current = (_meta.get(_seqKey) as int?) ?? 0;
    final next = current + 1;
    await _meta.put(_seqKey, next);
    return next;
  }

  @override
  Future<void> putPending(int seq, Map<String, Object?> entry) =>
      _pending.put(seq.toString(), entry);

  @override
  Future<List<Map<String, Object?>>> allPending() async {
    final seqs = _pending.keys.cast<String>().map(int.parse).toList()..sort();
    final out = <Map<String, Object?>>[];
    for (final s in seqs) {
      final raw = _pending.get(s.toString());
      if (raw != null) out.add(_castMap(raw));
    }
    return out;
  }

  @override
  Future<void> removePending(int seq) => _pending.delete(seq.toString());

  // ---------------------------------------------------------------------------
  // Metadata
  // ---------------------------------------------------------------------------

  @override
  Future<void> putMeta(String key, Object? value) => _meta.put(key, value);

  @override
  Future<Object?> getMeta(String key) async => _meta.get(key);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> clear() async {
    await _docs.clear();
    await _pending.clear();
    await _meta.clear();
  }

  @override
  Future<void> close() async {
    await _docs.close();
    await _pending.close();
    await _meta.close();
  }
}
