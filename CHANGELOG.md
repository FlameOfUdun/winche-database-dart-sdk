# Changelog

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
