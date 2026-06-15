# winche_flutter_demo

A small Flutter **Records** app built on the [`winche_database`](../) Dart SDK,
running live against the .NET sample server.

Connection is hardcoded (`ws://localhost:5183`, uid `user-123`, collection
`smoke-users`) and the app auto-connects on launch — no setup screen.

## What it shows

**Records tab**
- A `ListView` of records with a checkbox (done), inline note, and delete.
- A floating **Add** button and a **bottom sheet** for adding/editing records.
- A live banner when data is served from cache or contains unsynced changes.
- Records update reactively via `doc.snapshots()`.

**Pending tab**
- An **Online/Offline** switch (`setNetworkEnabled`) and a **Sync now** button
  (drains the queue + `waitForPendingWrites`).
- A live list of every queued write (op type, path, seq) with a count badge on
  the tab.

## How it maps to the SDK + server rules

The sample server's `OwnerReadRule` only lets the caller read their **own**
document (`smoke-users/user-123`). So records are stored as a map **inside that
one document** (`records: { id: {title, note, done} }`):

- add / edit → `set({'records': {id: {...}}}, merge: true)`
- delete → `set({'records': {id: FieldValue.delete()}}, merge: true)`

Every change is a single write, so it flows through the offline queue: edit
while offline and the list updates immediately (latency compensation) while the
write shows up in the Pending tab until you sync.

Offline support uses an in-memory `LocalStore`
([`lib/memory_store.dart`](lib/memory_store.dart)), so it works on web and
desktop with no filesystem setup. The Pending tab reads the queued entries
directly from that store.

## Running

Start the .NET sample server (`ws://localhost:5183`), then:

```bash
flutter pub get
flutter run -d chrome      # or: flutter run -d windows
```
