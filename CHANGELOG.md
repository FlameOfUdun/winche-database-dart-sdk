# Changelog

## 4.0.0

- **Breaking:** the durable persistence backend is now **sembast** instead of
  Hive. `HiveLocalStore` is removed and replaced by `SembastLocalStore`; the
  `hive_ce` dependency is dropped in favour of `sembast`/`sembast_web`. This
  removes Hive's 255-character key limit, so long/deeply-nested document paths
  are stored as-is. Persistence remains on by default, with the same
  `directoryResolver` contract (required on native, ignored on web/IndexedDB).
  No data migration is provided.

## 3.0.0

- **Breaking:** `WriteBatch.set` and `Transaction.set` now accept typed `T data`
  and convert it through the reference's converter, mirroring
  `DocumentReference.set`. Untyped references use the identity converter, so
  map-based call sites are unchanged; typed-converter call sites must now pass a
  `T` instead of a pre-built `Map`.

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
