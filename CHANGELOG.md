# Changelog

## 7.0.0

**Breaking: this release discards every existing local store — again.** Two
independent changes move the path, and neither migrates: `storageKey` became a
digest in `winche_core` 0.2.0, and the store gained a per-package subdirectory.
On first launch under 7.0 every user starts from an empty cache and **any writes
that had not yet synced are lost, silently and with nothing in the UI to notice
it**. Drain pending writes before upgrading if that matters to you — check
`db.hasPendingWrites` and wait for it to clear while 6.0 is still installed.

That this is the second consecutive release to say so is deliberate rather than
careless: both path changes were landed together, in one release, precisely so
users pay the cost once. Doing the subdirectory change later would have orphaned
everyone a second time.

### Requires `winche_core` ^0.2.0

The floor moves from `^0.1.0`, which does not unify with `^0.2.0` — an app
cannot hold `winche_database` 6.0.0 and any 0.2.0-based package at the same
time. Verified against the published 0.2.0 from pub.dev, not a path override.

### Changed

- **Breaking: the local store moved to
  `<root>/winche/<storageKey>/database/index.db`** (web: IndexedDB database
  `winche_<storageKey>_database`). Previously `<root>/winche/<storageKey>/db.db`
  and `winche_<storageKey>`.

  The file is `index.db` rather than `db.db` to match `winche_storage`, whose
  own index sits beside its `cache/` and `staging/` directories under the same
  name. One layout, one filename, across the stack.

  The layout is now stack-wide: every Winche package shares the per-identity
  directory and takes one subdirectory of its own beneath it, so
  `winche_storage` sits alongside at `<root>/winche/<storageKey>/storage/`.
  Forgetting a user becomes a single recursive delete of
  `<root>/winche/<storageKey>`, whatever mix of Winche packages an app uses —
  previously that was one delete per package, each with its own naming rule to
  remember.

  `storageKey` itself also changed, in `winche_core` 0.2.0: it is now a 128-bit
  SHA-256 digest of the identity id, rendered as 32 lowercase hex characters,
  rather than the id itself. It cannot be collapsed by a case-insensitive
  filesystem, it yields a usable path for *any* id a backend issues, its length
  is fixed however long the id, and the user's id no longer lands on disk.

- **Breaking: `WincheException` is now `WincheProtocolException`.** Every
  status subclass — `PermissionDeniedException`, `UnauthenticatedException`,
  `NotFoundException`, `AlreadyExistsException`, `FailedPreconditionException`,
  `AbortedException`, `InvalidQueryException`, `InvalidArgumentException`,
  `DeadlineExceededException`, `InternalException`, `UnavailableException` —
  keeps its name and now extends it. `WincheException.fromError` is
  `WincheProtocolException.fromError`. `status` and `details` are unchanged;
  `message` is inherited rather than declared here.

  `winche_core` 0.2.0 introduced its own `WincheException` as the root for the
  whole stack, and two classes of that name in two libraries cannot both be
  imported unprefixed — Dart only reconciles a duplicate name when it is
  literally the same declaration, so keeping the name and extending core's was
  not available. The new name is the better one regardless: `on
  WincheProtocolException` asks "did the database backend reject this?", `on
  WincheException` asks "did any Winche SDK fail?", and those are different
  questions.

  **Migration:** replace `on WincheException` with `on
  WincheProtocolException` wherever you mean backend failures. Leaving it as
  `on WincheException` still compiles, against core's root, and silently widens
  the catch — including over `WincheUnboundException`, which you almost
  certainly do not want handled next to a `PERMISSION_DENIED`.

- **Breaking: `WincheUnboundException` moved to `winche_core`** and is not
  re-exported here. Import `package:winche_core/winche_core.dart` for it, which
  an app using this SDK already imports for `Winche.initializeApp`. "Nobody is
  signed in" is a condition every Winche service shares, so it belongs where
  every service can name it — one `catch` for an app using two Winche packages,
  and a third package does not make it three.

  It is now a `WincheException` (core's root) and therefore catchable by `on
  WincheException`; it is still **not** a `WincheProtocolException`, because it
  never crosses the wire. Being signed out is fixed by signing in, not by
  handling it where server errors are handled.

### Fixed

- **Documentation: `.snapshots()` no longer carries a "Known gap" warning that
  has been wrong since 6.0.0.** The README still claimed it throws a raw
  `TypeError` while unbound. It returns normally and emits
  `WincheUnboundException` as a stream error, which is what 6.0.0 changed and
  what `test/facade/unbound_listen_test.dart` pins. The README now documents the
  real behaviour with a `StreamBuilder` example, since the point of that fix was
  that the call site is usually inside `build()`.

## 6.0.0

**Breaking: this release discards every existing local store.** The on-disk layout moved from
`<root>/winche_<namespace>.db` to `<root>/winche/<storageKey>/`, and no migration is performed. On
first launch under 6.0 every user starts from an empty cache and **any writes that had not yet synced
are lost**. Drain pending writes before upgrading if that matters to you.

### Changed

- **Breaking: connectivity is a level you observe, not a thing you steer.**
  `connectionStates` now hands every new subscriber the current state before
  forwarding changes, suppresses consecutive duplicates, and never completes on a
  failed dial — so a `StreamBuilder` built at any moment, including after a user
  switch, renders the truth immediately instead of waiting for the next
  transition. `connectionState` is also readable while unbound, reporting
  `disconnected` rather than throwing `WincheUnboundException`: a widget that
  renders a connection chip must be able to build before anyone signs in.
  Reconnection is unconditional, and a session dials as soon as it binds rather
  than waiting for a read, a listener, or a queued write.
- **Breaking: `winche_database` is now built on `winche_core`.** `WincheDatabase` is a
  `WincheDatabaseService` — construct it once via `Winche.initializeApp(...)` and then
  `WincheDatabase.instance` (or `instanceFor(app)`), not `WincheDatabase(config)`. Core owns the
  session lifecycle: it builds a session for whichever identity is currently signed in (announced by
  a `WincheAuthService`, e.g. a real auth package, or `ScriptedAuthService` from
  `package:winche_core/testing.dart`) and disposes it on sign-out or when the identity changes.
  `winche_database` itself has no sign-in surface and never sees a token directly — it reads one from
  the session on every (re)dial.
- **Breaking: `WincheDatabaseConfig` keeps only tuning**, set via
  `WincheDatabase.instance.config = ...` immediately after obtaining the instance (it now **throws a
  `StateError` once the database has been used** — opened its store or dialled its socket — because
  construction is lazy and that window is what makes "immediately after `.instance`" reliable). The
  surviving fields are unchanged: `pingInterval`, `autoReconnect`, `maxBackoff`, `maxFrameBytes`,
  `inMemory`, `conflictPolicy`, `maxCachedDocuments`, `cacheSizeBytes`. Four fields left, each replaced
  by something on the core side:
  - `uri` → `WincheOptions.databaseEndpoint`, passed once to `Winche.initializeApp`.
  - `tokenProvider` → gone; the session's token is read from whichever `WincheAuthService` is
    registered with the app.
  - `namespaceResolver` → gone; the store is scoped by the signed-in identity itself, not a value you
    supply — see the on-disk layout change above.
  - `directoryResolver` → `WincheOptions.directoryResolver`, also passed once to
    `Winche.initializeApp` and shared by every Winche service under that app.
- **Breaking: `WincheDatabase.close()`, `isClosed` and `reconnect()` are gone.** There is nothing left
  to call them on: the session backing the facade is owned entirely by core, torn down automatically
  on sign-out and rebuilt automatically on sign-in or a user switch, and re-dialled automatically when
  the auth service reports a token rotation. Token rotation is now a nudge (the existing session
  re-dials in place), not a rebuild — so it no longer tears down and reopens the local store the way an
  explicit `reconnect()` implied.
- **Breaking: calling the database while no identity is signed in now throws `WincheUnboundException`**
  instead of running against an unscoped/default store. It fires from every member that actually
  touches the session — `.get()`, `.set()`, `.update()`, `.delete()`, `.commit()`, `runTransaction`,
  `waitForPendingWrites`, and so on. **Nuance:** `doc()` and `batch()` are lazy factories — building a
  reference or a batch is synchronous local bookkeeping, so they never throw; the exception surfaces on
  the first call that actually needs the session. `WincheUnboundException` is deliberately not a
  `WincheException` (it never crosses the wire), so `on WincheException` does not catch it — gate on
  sign-in state instead of handling it as a server error. **Known gap:** `.snapshots()` does not yet
  follow this rule — calling it while unbound throws a raw `TypeError` (null-check failure) rather than
  `WincheUnboundException`, because `_LiveListener`'s constructor force-unwraps the session. Gate
  `.snapshots()` on sign-in state yourself until this is fixed.
- **Breaking: a user switch now completes every `snapshots()` stream** (`onDone`), because a listener
  is displaying one identity's data and must not silently start showing the next identity's documents.
  The app is expected to resubscribe — in practice this falls out of the same rebuild that already
  reacts to a sign-in state change. `connectionStates`, `syncEvents` and `reconnects` describe the
  connection rather than any one identity's data, so they **survive** a user switch instead: they go
  quiet (`connectionStates` emits `ConnectionState.disconnected`) rather than ending.
- The `inMemory` × `namespaceResolver` validation from 5.0 (rejecting a persistent store configured
  without a namespace, and rejecting a namespace supplied alongside `inMemory: true`) is gone because
  it is no longer expressible — there is no `namespaceResolver` left to validate against `inMemory`.

### Removed

- **Breaking: `WincheDatabase.reconnects`.** It carried no information
  `connectionStates` lacks — it fired at exactly the two points where the state
  reached `ready` on a *re*-dial, and deliberately not on the first connect, so it
  was `connectionStates.where(ready)` minus its first element. Derive it if you
  want it:
  `db.connectionStates.where((s) => s == ConnectionState.ready).skip(1)`.
- **Breaking: `WincheDatabaseConfig.autoReconnect`.** Reconnection is
  unconditional; an app cannot stop the SDK from recovering.
- **Breaking: `Transport` and `ConnectionConfig` are no longer exported.** No
  consumer implements a transport, and `ConnectionConfig.channelFactory` is an
  injection seam that should not be part of the public surface.
- **Breaking: `WincheDatabase.listenEvents` and `releaseSubscription`.** Both were
  dead — nothing called them — and both returned `ServerFrame`, a type the barrel
  does not export, so a caller could not name the return value.

### Fixed

- **Offline writes now sync when the connection comes back.** Two defects had to
  line up for this to fail, and neither was covered by tests. First, a queue
  restored from disk had no drain trigger at all: `notifyEnqueued` fires only in
  the session that enqueued a write, and the old `reconnects` signal could not
  fire for a first connect. Second and worse, a failed first dial made recovery
  impossible: `connect()` made exactly one attempt and threw without entering the
  reconnect loop, and the transport's `reconnects` getter *completed its stream*
  on that failure, leaving the sync controller permanently deaf for the life of
  the session. So "open the app offline, write something, network returns" never
  synced. Draining is now driven by the connection state reaching `ready`, which
  covers the first connect, every reconnect, and binding onto an already-live
  socket. Verified end to end against the .NET sample server, including two users
  queueing writes with the server down: each user's writes drain on their own
  sign-in and only then, leaving the other's queue untouched.
- **A `WriteBatch.commit()` can no longer be split across two frames.**
  `applyWrites` assigned a `batchId` and then enqueued each write in a loop with
  two await points per iteration, notifying the drain only afterwards. A drain
  firing between iterations read a *partial* batch and sent it, so the server
  could apply half of an atomic commit. Reachable before this release whenever a
  reconnect landed mid-batch; draining on connection state made it routine,
  because the first `ready` typically arrives while a batch is still being
  enqueued. The queue now reports that a multi-insert is in flight and the drain
  skips while it is — the coordinator drains once the batch is durable, so no
  trigger is lost.
- **A closed connection can no longer be revived by a reconnect already in
  flight.** `close()` marked the state `closed`, but the reconnect loop set
  `reconnecting` at entry without checking, and `_setState` had no guard against
  adding to a closed controller. A loop scheduled moments before teardown could
  therefore resurrect the connection, keep dialling a socket nobody owned, and
  throw `StateError` from inside a callback where nothing catches it. Previously
  masked by `autoReconnect: false`; unconditional reconnection made it reachable
  on any teardown racing a drop.
- **A disposed database releases its status subscribers.** The relay behind
  `connectionStates` forwarded values and errors but not completion, so disposal
  left every subscriber attached to an open controller.
- **Breaking: `snapshots()` reports an unbound database as a stream error**
  rather than throwing at the call site. It resolved the session in a
  constructor initializer list, so it could only fail by throwing — and its call
  site is typically a `StreamBuilder` inside `build()`, where an identity change
  landing between a rebuild and the app updating its own state tore down the
  widget tree instead of reaching the `hasError` branch. It was also the only
  entry point that behaved this way: `get`/`set`/`update`/`delete` are `async`,
  so an unbound database rejects their Future. The session is now bound when the
  stream is listened to. A *disposed* session still completes with `done` — the
  documented signal for an identity swap under a live listener — and only the
  absence of one is an error.

## 5.0.0

### Added

- **`WincheDatabaseConfig.namespaceResolver`** — **required** for a persistent
  store; scopes it to one identity (`winche_<namespace>.db`). The local store is
  single-tenant: the document cache, pending-write queue, resume tokens and query
  membership carry no identity, so a shared store let a second user on the same
  device read the previous user's cached documents and replay their un-synced
  writes under the new token (rejected with `PERMISSION_DENIED`, and dropped).
  Switching users is now `await db.close()` + a new database; each user's queued
  writes stay on disk and drain when they sign back in. Resolved lazily and
  cached, like `directoryResolver` — it pins the identity for the lifetime of the
  instance.
- **`WincheDatabase.reconnect()`** — drops the socket and re-dials, re-reading
  `tokenProvider`. The token rides on the WebSocket upgrade, so it was previously
  impossible to apply a rotated token to a live connection: the client kept using
  the old one until the socket happened to drop. Listeners resubscribe in place,
  including any that had died permanently on a `PERMISSION_DENIED` /
  `UNAUTHENTICATED` subscribe.
- `SyncPaused` sync event and `WriteFailed.writes` (see below).

### Fixed

- **A listener no longer loses its initial snapshot to a frame race.** A client
  learns its `subscriptionId` from the subscribe *response*, so it could only
  register a frame listener after that response landed — but a server may push
  the first `listen.snapshot` before it, and `ProtocolConnection` dropped frames
  for an unregistered subscription id. The listener then sat on its cache-first
  emission forever, never going live. Observed against the .NET sample server for
  any query carrying an `orderBy` (which reordered the two frames), and it broke
  the Flutter example app's record list. Frames arriving ahead of their
  subscription are now buffered and replayed, in arrival order, when the listener
  attaches; the buffer is bounded so unclaimed subscription ids cannot grow it.
- **`close()` no longer races live listeners.** Closing the database while a
  `snapshots()` listener was active tore down the socket and the local store at
  the same time; the socket teardown drove one last listener emission, which read
  a store that had already closed and threw an uncatchable
  `Bad state: database is closed`. `close()` now tears down in dependency order —
  live listeners, then the transport, then the sync controller, then the store —
  and every listener emission is gated on the database still being open. Live
  `snapshots()` streams now complete with `done` on close.
- The sync controller waits for an in-flight drain to unwind before the store is
  closed underneath it, and `LazyLocalStore` degrades to no-ops after `close()`
  so a straggling callback can never surface a store error.
- `WsTransport` no longer re-dials a fresh socket if an operation is issued after
  `dispose()`; it fails with `UnavailableException` instead.
- **`set` / `update` / `delete` / `batch.commit` no longer block on the server.**
  The write coordinator awaited the drain it kicked off, so an "optimistic
  acknowledgement" actually waited for the round-trip whenever the connection was
  up — it only appeared instant offline, where the request fails fast. They now
  return as soon as the write is durably queued and the local view reflects it,
  with the drain running in the background as documented. Watch `syncEvents` (or
  `waitForPendingWrites()`) for the server outcome.
- **An `UNAUTHENTICATED` write is no longer destroyed.** The drain treated any
  non-conflict status as terminal, deleting the unit from the queue — so an
  expired token silently discarded un-synced work. It now halts the drain (like
  being offline), leaves the queue untouched, and reports `SyncPaused`; the next
  reconnect resumes it. `PERMISSION_DENIED` is still terminal, but `WriteFailed`
  now carries the dropped `PendingWrite`s in `writes` so the work is recoverable.

### Changed

- **Breaking:** `WincheDatabase.close()` returns `Future<void>` and should be
  awaited. It is idempotent, and resolves only once the local store is really
  closed — await it before opening another database over the same file (e.g. when
  switching users). Existing `db.close();` call sites keep compiling.
- **Breaking:** `Transport.dispose()` returns `Future<void>` (was `void`) and
  `Transport.reconnect()` is new. Only affects custom `Transport`
  implementations.
- **Breaking:** `SyncEvent` gained the `SyncPaused` variant — exhaustive
  `switch`es over it need a new arm. `WriteFailed` gained a required `writes`
  argument (only affects code constructing the event, not consumers reading it).
- **Breaking:** a persistent `WincheDatabase` now requires
  `namespaceResolver`, and its database file moves from `winche.db` to
  `winche_<namespace>.db`. **There is no migration.** Existing caches simply
  rebuild themselves, but any un-synced writes sitting in the old queue are
  orphaned — drain the queue (`waitForPendingWrites()`) before shipping this
  upgrade if that matters. `inMemory: true` is unaffected.
- New `WincheDatabase.isClosed`.

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
