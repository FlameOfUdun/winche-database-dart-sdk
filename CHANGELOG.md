# Changelog

## 2.0.0

- **Breaking:** `WincheDatabase` now takes a single `WincheDatabaseConfig` —
  connection options + local-store selection + conflict policy in one object,
  mirroring `winche_storage`'s `WincheStorageConfig`. Replaces the previous
  `WincheDatabase(ConnectionConfig, {store, inMemory, ...})` constructor.
- **Breaking:** persistence is now **on by default** (Hive). On native platforms a
  `directoryResolver` is required; the Hive directory is resolved **lazily** on
  first store access (web uses IndexedDB, no path needed). Set `inMemory: true`
  for the previous non-persistent behavior.
- `directoryResolver` lets the Hive directory be resolved lazily, so apps no
  longer need to `await HiveLocalStore.open(...)` before constructing the database.
- Added `LazyLocalStore`, a `LocalStore` decorator that opens its underlying store
  on first use (memoized; safe under concurrent first-callers).
- `WincheDatabase.close()` now also closes the database-owned local store.
- Custom store injection moved to `WincheDatabase.withStore(connectionConfig, store)`.

## 1.1.0

- `ConnectionConfig.tokenProvider` now accepts an async callback
  (`FutureOr<String> Function()`), so auth tokens can be fetched or refreshed
  asynchronously on each (re)dial. Synchronous providers continue to work
  unchanged.

## 1.0.0

Initial release.

- Offline-first document store over a single WebSocket connection.
- Typed values: null, bool, int, double (incl. `NaN`/`Infinity`), string, bytes,
  timestamp, reference, geo-point, arrays, and nested maps.
- Writes: set / merge-set / update / delete with field transforms (increment,
  server timestamp, array union/remove, min/max) and preconditions.
- Queries: filters, ordering, limits, cursors, client-side projection (`select`),
  and `count`.
- Real-time document and query listeners.
- Optimistic transactions with automatic retry.
- Local cache + pending-write overlay + background sync, backed by an in-memory
  or durable (Hive) store.
- Authentication at the WebSocket upgrade via an `?access_token=` query parameter;
  token rotation by reconnect.
