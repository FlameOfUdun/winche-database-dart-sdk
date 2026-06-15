# winche_database

Type-safe Dart client for **Winche Database** — an offline-first, real-time
document store over a single WebSocket connection.

- **Documents & collections** with a fluent reference API
- **Typed values**: null, bool, int, double (incl. `NaN`/`Infinity`), string,
  bytes, timestamp, reference, geo-point, arrays, nested maps
- **Writes**: set / merge-set / update / delete, with field transforms
  (increment, server timestamp, array union/remove, min/max) and preconditions
- **Queries**: filters, ordering, limits, cursors, client-side projection,
  and `count`
- **Real-time listeners** for documents and queries
- **Optimistic transactions** with automatic retry
- **Offline-first**: every read is served from a local cache + pending-write
  overlay; every write is queued locally and synced in the background
- **Durable persistence** (Hive, on by default) or in-memory

For the authoritative wire-protocol specification, see the server repository's
[PROTOCOL.md](https://github.com/FlameOfUdun/Winche-Database/blob/main/docs/PROTOCOL.md).

---

## Architecture

Offline support is always on. Reads return the **effective view** (the confirmed
local cache with un-synced local writes overlaid); writes are appended to a
durable queue and drained to the server by a background sync controller.

```mermaid
flowchart TD
  App[Your app] --> Facade["Facade<br/>collection · doc · query · batch · runTransaction"]
  Facade --> Reads[ReadCoordinator]
  Facade --> Writes[WriteCoordinator]
  Reads --> Cache[(Confirmed cache)]
  Writes -- enqueue --> Queue[(Pending-write queue)]
  Sync[SyncController] -- drain --> Queue
  Reads --> T[WsTransport]
  Sync --> T
  T <-->|WebSocket| Server[(Winche Database server)]
  Cache --- Store[(LocalStore<br/>Memory or Hive)]
  Queue --- Store
```

---

## Getting started

```dart
import 'package:winche_database/winche_database.dart';

final db = WincheDatabase(
  WincheDatabaseConfig(
    uri: Uri.parse('ws://localhost:5183/documents/ws'),
    tokenProvider: () => currentAuthToken,     // optional
    directoryResolver: () async => appDir,     // required on native (Hive directory)
  ),
);
```

The connection dials lazily on the first operation. Authentication happens at the
WebSocket upgrade via an `?access_token=` query parameter built from
`tokenProvider`. There is **no in-band auth-refresh**: to rotate an expired token,
return the new value from `tokenProvider` — the reconnect path picks it up
automatically.

All options live on `WincheDatabaseConfig`: `uri`, `tokenProvider`, `pingInterval`
(default 30 s), `autoReconnect` (default true), `maxBackoff` (default 30 s),
`maxFrameBytes` (default 1 MiB — see [Writes](#writes-offline-first)), `inMemory`
(default false), `directoryResolver` (Hive directory; see
[Persistence](#persistence)), and `conflictPolicy` (default `manual`).

---

## Documents & collections

```dart
final users = db.collection('users');
final alice = users.doc('u1');                 // users/u1
final posts = alice.collection('posts');       // users/u1/posts (sub-collection)

final snap = await alice.get();
if (snap.exists) {
  print(snap.data());      // Map<String, Object?>
  print(snap.id);          // 'u1'
  print(snap.version);     // server version
  print(snap.updateTime);  // DateTime
}

await alice.set({'name': 'Alice', 'age': 30});            // replace
await alice.set({'age': 31}, merge: true);                // deep-merge
await alice.update({'address.city': 'Oslo'});             // patch (dotted paths)
await alice.delete();                                     // optionally cascade: true

final ref = await users.add({'name': 'Bob'});             // auto-generated id
```

### Values & field transforms

Native Dart values map to typed wire values: `int`, `double`, `bool`, `String`,
`DateTime` (→ timestamp), `Uint8List` (→ bytes), `GeoPoint`, a
`DocumentReference` (→ reference), `List`, and nested `Map`.

`FieldValue` sentinels express server-side transforms inside `set`/`update`:

```dart
await counter.update({
  'views':    FieldValue.increment(1),
  'seenAt':   FieldValue.serverTimestamp(),
  'tags':     FieldValue.arrayUnion(['featured']),
  'old':      FieldValue.arrayRemove(['draft']),
  'peak':     FieldValue.maximum(99),
  'obsolete': FieldValue.delete(),
});
```

### Preconditions

```dart
await ref.set(data, precondition: const Precondition(exists: false));      // create-only
await ref.update(data, precondition: Precondition.updateTimeRaw(snap.updateTimeRaw!));
```

---

## Reads & sources

Every read goes through the cache. `GetOptions.source` picks the policy:

- `Source.serverOrCache` (default) — read the server, refreshing the cache; on a
  **transient** failure (unavailable / timeout / internal) fall back to cache.
  Actionable errors (`PERMISSION_DENIED`, `UNAUTHENTICATED`, `INVALID_*`) propagate.
- `Source.server` — server only; throws when unreachable.
- `Source.cache` — local only; never contacts the server.

```mermaid
flowchart TD
  A["get() / query()"] --> S{source}
  S -->|cache| EV
  S -->|server / serverOrCache| Req[request server]
  Req -->|ok| WT["write full docs to cache"] --> EV
  Req -->|transient error| EV["effective view:<br/>cache + pending overlay"]
  Req -->|permission / invalid| Err[throw]
  EV --> Sel{select?}
  Sel -->|yes| Proj["trim to selected fields"] --> Out[Snapshot]
  Sel -->|no| Out[Snapshot]
```

`db.getAll([ref1, ref2])` fetches several documents in one round-trip.

---

## Queries

A `CollectionReference` is itself a query, so builders chain directly:

```dart
final snap = await db.collection('users')
    .where('age', isGreaterThanOrEqualTo: 18)
    .where('active', isEqualTo: true)
    .orderBy('age', descending: true)
    .limit(20)
    .get();

for (final doc in snap.docs) print(doc.data());
print(snap.hasMore); // true if the server had more beyond the limit
```

Filter operators (named args on `where`): `isEqualTo`, `isNotEqualTo`,
`isLessThan`, `isLessThanOrEqualTo`, `isGreaterThan`, `isGreaterThanOrEqualTo`,
`arrayContains`, `arrayContainsAny`, `arrayContainsAll`, `whereIn`, `whereNotIn`,
`contains`, `startsWith`, `endsWith`, `matchesRegex`, `isNull`, `isNan`, `exists`.

Cursors operate on the `orderBy` keys: `startAt`, `startAfter`, `endAt`,
`endBefore`. Counting:

```dart
final n = await db.collection('users').where('active', isEqualTo: true).count();
```

### Field projection (`select`)

`Query.select([...])` is applied **client-side**. The SDK fetches full documents
(the projection is never sent to the server), caches them normally, and trims
each result to the selected fields locally.

This keeps `select` consistent with the rest of the SDK: results reflect
un-synced local writes and work offline, and the local cache only ever holds
complete documents (never partials). The trade-off is bandwidth — full documents
cross the wire, so `select` is a convenience for shaping results, not a transfer
optimization.

> The server supports server-side projection for other clients; this SDK
> deliberately does not use it, for the consistency reasons above.

---

## Real-time listeners

`snapshots()` returns a stream that emits an immediate cache-first snapshot, then
the server's authoritative snapshot, then incremental updates. `QuerySnapshot`
exposes `docs` and `docChanges` (added / modified / removed).

```dart
final sub = db.collection('users')
    .where('active', isEqualTo: true)
    .orderBy('name')
    .snapshots()
    .listen((qs) {
      for (final c in qs.docChanges) {
        print('${c.type} ${c.doc.id} @${c.newIndex}');
      }
    });

final docSub = db.doc('users/u1').snapshots().listen((s) => print(s.data()));
```

```mermaid
flowchart TD
  Sub["snapshots()"] --> CF["emit cache-first snapshot"]
  Sub --> L["listen frame -> server"]
  L --> Snap["server snapshot (full ordered set)"] --> E["emit QuerySnapshot + docChanges"]
  D["server delta: added / modified / removed"] --> A[apply to local set] --> E
  W["local write (latency compensation)"] --> E
```

A permanently-failing subscription (`PERMISSION_DENIED` / `UNAUTHENTICATED` /
invalid query) surfaces the error on the stream and stops retrying; transient
drops reconnect silently.

---

## Writes, offline-first

Writes are **local-first**: `set` / `update` / `delete` append to a durable queue
and return an optimistic acknowledgement immediately. The local cache reflects
the change at once (latency compensation), and the `SyncController` drains the
queue to the server in the background. Watch `db.syncEvents` for the outcome.

```mermaid
flowchart TD
  W["set / update / delete / batch.commit()"] --> G{">500 writes or<br/>> maxFrameBytes?"}
  G -->|yes| R[throw InvalidArgument]
  G -->|no| Q["enqueue + optimistic ack"]
  Q --> LC["local cache updated immediately"]
  Q --> Dr[SyncController drains]
  Dr -->|ack| SY["WriteSynced"]
  Dr -->|version conflict| CO["WriteConflict<br/>retry / discard / overwrite"]
  Dr -->|permission / etc| FA["WriteFailed (dropped)"]
  Dr -->|offline| OF["stays queued, retries on reconnect"]
```

```dart
db.syncEvents.listen((e) {
  if (e is WriteSynced) {
    // server acknowledged the write
  } else if (e is WriteConflict) {
    // ConflictPolicy.manual (default): resolve explicitly
    e.discard(); // or e.retry() / e.overwrite()
  } else if (e is WriteFailed) {
    // permanent (e.g. permission denied); dropped from the queue
    print(e.error);
  }
});

await db.waitForPendingWrites();   // see the manual-conflict caveat in the API docs
final pending = await db.hasPendingWrites;
await db.clearPersistence();       // wipe local cache + queue
```

Conflict handling is governed by `WincheDatabaseConfig.conflictPolicy`:
`manual` (default — pause and surface a `WriteConflict`), `clientWins`, or
`serverWins`.

> **Frame guard:** a batch over 500 writes, or whose serialized frame exceeds
> `maxFrameBytes` (default 1 MiB), is rejected with `InvalidArgumentException`
> *before* it enters the queue — so it never loops on the wire.

### Batches

```dart
final batch = db.batch()
  ..set(db.doc('users/u1'), {'name': 'Alice'})
  ..update(db.doc('users/u2'), {'active': false})
  ..delete(db.doc('users/u3'));
await batch.commit(); // atomic
```

---

## Transactions

`runTransaction` runs reads-then-writes atomically and retries automatically on
conflict. Reads (`tx.get` / `tx.query`) must precede writes. Transactions are
**online-only**.

```dart
final newBalance = await db.runTransaction((tx) async {
  final snap = await tx.get(db.doc('accounts/a1'));
  final balance = (snap.data()!['balance'] as int) - 100;
  tx.update(db.doc('accounts/a1'), {'balance': balance});
  return balance;
});
```

---

## Connection & errors

```dart
db.connectionState;                 // ConnectionState.ready, .disconnected, ...
db.connectionStates.listen(...);    // transitions (survives reconnects)
db.reconnects.listen(...);          // fires on each successful reconnect
```

```mermaid
stateDiagram-v2
  [*] --> connecting
  connecting --> ready: welcome
  ready --> disconnected: socket drop
  disconnected --> reconnecting: autoReconnect
  reconnecting --> ready: welcome
  ready --> closed: close()
  closed --> [*]
```

The client reconnects automatically on any drop (network loss, server restart,
any close code). The only way to reach `closed` is by calling `close()`.

Operations throw a `WincheException` subclass on failure:
`PermissionDeniedException`, `UnauthenticatedException`, `NotFoundException`,
`AlreadyExistsException`, `FailedPreconditionException`, `AbortedException`,
`InvalidQueryException` (with `jsonPath` / `code`), `InvalidArgumentException`,
`DeadlineExceededException`, `InternalException`, `UnavailableException`.

---

## Persistence

Persistence is **on by default** via Hive. The Hive directory is resolved lazily
on first store access from `WincheDatabaseConfig.directoryResolver` — **required
on native** platforms, ignored on the web (which uses IndexedDB):

```dart
final db = WincheDatabase(WincheDatabaseConfig(
  uri: uri,
  directoryResolver: () async => (await getApplicationDocumentsDirectory()).path,
));
```

For a non-durable in-memory store (state lost on exit), set `inMemory: true`
(then `directoryResolver` must be omitted):

```dart
final db = WincheDatabase(WincheDatabaseConfig(uri: uri, inMemory: true));
```

Advanced / testing: inject a custom `LocalStore` (using the lower-level
`ConnectionConfig`) with `WincheDatabase.withStore(connectionConfig, store)`.

---

## Platform notes

- **Web int precision:** Dart integers compiled to JavaScript are limited to
  2^53; larger int64 values from the server lose precision on web.
- Offline array-membership transforms use type-naive equality and are reconciled
  by the server acknowledgement.
