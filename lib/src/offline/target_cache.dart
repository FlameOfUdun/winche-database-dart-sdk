import 'dart:convert';

import '../protocol/query_spec.dart';
import 'local_store.dart';

/// Durable record of each query's server-authoritative membership: the ordered
/// document paths the server last reported for a query. Backed by a single
/// [LocalStore] metadata blob with a lazily-hydrated in-memory mirror.
///
/// Lets cold-start listeners and one-shot cache gets serve a query from its true
/// result set instead of re-deriving over the whole collection (which would
/// resurface out-of-window or stale-but-locally-matching documents).
///
/// Entries are bounded to [maxEntries] (insert-time LRU); the oldest-set query
/// is dropped when the cap is exceeded.
class TargetCache {
  TargetCache(this._store, {this.maxEntries = 1000});

  final LocalStore _store;
  final int maxEntries;
  static const _metaKey = 'targetMembers';
  // Memoize the in-flight load (not just its result) so concurrent first-access —
  // e.g. several listeners starting at once — share one hydration and can't clobber
  // each other's writes.
  Future<Map<String, List<String>>>? _loading;

  /// A stable key for [spec] — canonical JSON of the query. Equal specs (built
  /// the same way) produce identical JSON and therefore the same key.
  static String keyOf(QuerySpec spec) => jsonEncode(spec.toJson());

  Future<Map<String, List<String>>> _ensureLoaded() => _loading ??= _load();

  Future<Map<String, List<String>>> _load() async {
    final raw = await _store.getMeta(_metaKey);
    final map = <String, List<String>>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        map[e.key as String] = [for (final p in (e.value as List)) p as String];
      }
    }
    return map;
  }

  /// The last known ordered member paths for [spec], or null if unknown.
  Future<List<String>?> members(QuerySpec spec) async =>
      (await _ensureLoaded())[keyOf(spec)];

  /// Records the ordered member paths for [spec]'s target and persists the map.
  /// Re-inserts the key at the most-recently-set end and drops the oldest
  /// entries past [maxEntries].
  Future<void> setMembers(QuerySpec spec, List<String> orderedPaths) async {
    final map = await _ensureLoaded();
    final key = keyOf(spec);
    final existing = map[key];
    // Skip the durable write when membership is unchanged (e.g. a delta that
    // modified a doc without moving the result set) — avoids blob churn.
    if (existing != null && _orderedEquals(existing, orderedPaths)) return;
    map.remove(key); // re-insert at the most-recently-set end
    map[key] = List<String>.from(orderedPaths);
    while (map.length > maxEntries) {
      map.remove(map.keys.first); // drop the oldest-set entry
    }
    await _store.putMeta(_metaKey, map);
  }

  static bool _orderedEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
