import 'local_store.dart';

/// Durable per-subscription resume tokens, keyed by a subscription key (a query
/// key, or `doc:<path>`). Backed by a single [LocalStore] metadata blob so the
/// SDK can resume each listener after a restart. In-memory mirror is hydrated
/// lazily on first access.
class ResumeTokenStore {
  ResumeTokenStore(this._store, {this.maxEntries = 1000});

  final LocalStore _store;
  final int maxEntries;
  static const _metaKey = 'resumeTokens';
  // Memoize the in-flight load (not just its result) so concurrent first-access —
  // e.g. several listeners starting at once — share one hydration and can't clobber
  // each other's writes.
  Future<Map<String, int>>? _loading;

  Future<Map<String, int>> _ensureLoaded() => _loading ??= _load();

  Future<Map<String, int>> _load() async {
    final raw = await _store.getMeta(_metaKey);
    final map = <String, int>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        map[e.key as String] = (e.value as num).toInt();
      }
    }
    return map;
  }

  /// The stored token for [key], or null if none.
  Future<int?> get(String key) async => (await _ensureLoaded())[key];

  /// Stores [token] for [key] (null removes it), persisting the whole map.
  /// On a non-null token, re-inserts the key at the most-recently-set end and
  /// drops the oldest entries past [maxEntries].
  Future<void> set(String key, int? token) async {
    final map = await _ensureLoaded();
    if (token == null) {
      if (!map.containsKey(key)) return; // nothing to remove → no write
      map.remove(key);
    } else {
      if (map[key] == token) return; // unchanged → skip the durable write
      map.remove(key); // re-insert at the most-recently-set end
      map[key] = token;
      while (map.length > maxEntries) {
        map.remove(map.keys.first); // drop the oldest-set entry
      }
    }
    await _store.putMeta(_metaKey, map);
  }
}
