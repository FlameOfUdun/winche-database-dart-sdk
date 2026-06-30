# Changelog

## 4.2.0

- Deletion reconciliation: server-side deletes are now tombstoned locally, so a
  deleted document disappears from every listener, `get`, and cache read and
  never resurfaces — online or offline. Adds the `deleted` listen-delta change
  kind and bumps the wire protocol to **v2**; `listen`/`doc.listen` frames now
  advertise `protocol: 2`, and the server only emits `deleted` to clients on v2.
- Membership-based offline reads: each live query records the exact ordered set
  of documents the server last reported for it (`TargetCache`). Offline reads and
  a listener's cache-first emission serve that set against the cache + pending
  overlay, so `limit` / `offset` / filter queries stay correct offline instead of
  re-deriving over the whole collection (which could resurface out-of-window or
  stale-but-locally-matching documents).
- Resume across restarts: with durable persistence, listeners persist their
  resume token (`ResumeTokenStore`) and query membership. On relaunch a listener
  emits its last-known results immediately and resumes the server subscription
  with the stored token — going live without re-downloading when nothing changed,
  or taking a fresh snapshot when the token is stale. New `listen.current` server
  frame signals a covered resume (live and up to date, no documents). With
  `inMemory: true`, resume state lasts only for the session.
- Optional bounded cache: new `WincheDatabaseConfig.maxCachedDocuments` and
  `cacheSizeBytes` caps (both default null = unbounded). When a cap is exceeded
  the least-recently-used documents not referenced by an active listener or a
  pending write are evicted; an evicted document is re-fetched on next read
  (eviction is not deletion). Caps are also enforced against already-persisted
  documents on startup. See the README's "Cache management" section.
- Conflict handling: under the automatic policies (`clientWins`/`serverWins`), a
  write that can never be resolved — e.g. an `update` to a since-deleted document
  that always fails with `NOT_FOUND` — is now reported as `WriteFailed` and
  removed from the queue instead of being retried forever.

## 4.1.0

- Query parity with the server (PROTOCOL §4.1): added `QueryReference.offset(n)`
  and `QueryReference.limitToLast(n)`. `offset` skips leading results and
  composes with `limit`; `limitToLast` returns the last N of the result window
  in ascending order, requires at least one `orderBy`, and cannot be combined
  with `limit` or `offset` (validated locally, mirroring the server's
  `INVALID_ARGUMENT`). Both are honoured for one-shot reads and live
  `snapshots()` alike, since results are evaluated by the local query engine.
- Write parity (PROTOCOL §3.2): `DocumentReference.set`, `WriteBatch.set`, and
  `Transaction.set` now accept `mergeFields` — a dotted-path field mask. Only
  the masked paths are written; a masked path absent from the data deletes it.
  Mutually exclusive with `merge`. The pending-write overlay applies the same
  mask semantics, so offline optimistic state matches the server.
- Internal: the query and single-document live listeners now share a common
  base, split by layer — `_LiveListener` (facade: snapshots + cache overlay) and
  `_LiveFeed` (server-subscription lifecycle: reconnect/resume/teardown). The
  concrete types are `_QueryListener`/`_DocumentListener` over
  `_QueryFeed`/`_DocumentFeed`, in `live_listener.dart` and `live_feed.dart`. No
  public API or behavior change.

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
