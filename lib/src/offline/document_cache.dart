import 'dart:convert';

import '../protocol/messages.dart';
import 'eviction_manager.dart';
import 'local_store.dart';
import 'records.dart';

/// Reads and writes confirmed (server-acknowledged) documents in the
/// [LocalStore]. The optimistic overlay is layered on top of this in a later
/// component; this class only deals with confirmed state and tombstones.
class DocumentCache {
  DocumentCache(this.store, {EvictionManager? eviction}) : _eviction = eviction;

  final LocalStore store;
  final EvictionManager? _eviction;
  // Memoize the in-flight prime (not just a "done" flag) so concurrent first
  // writes share one priming pass — and none evicts on a half-primed LRU.
  Future<void>? _priming;

  static int _sizeOf(Map<String, Object?> record) =>
      utf8.encode(jsonEncode(record)).length;

  /// Seeds the eviction LRU from documents already on disk and enforces the cap
  /// against them — once, lazily, before the first eviction-relevant operation.
  Future<void> _ensurePrimed() => _priming ??= _prime();

  Future<void> _prime() async {
    final ev = _eviction;
    if (ev == null) return;
    for (final rec in await store.allDocuments()) {
      final cached = CachedDocument.fromRecord(rec);
      if (!cached.deleted) ev.recordAccess(cached.path, _sizeOf(rec));
    }
    await ev.evictIfNeeded();
  }

  /// Stores a server-confirmed document.
  Future<void> putConfirmed(WireDocument doc) async {
    // Prime BEFORE writing so startup priming can only evict pre-existing docs —
    // never the doc we are about to write (which then survives at the MRU end).
    if (_eviction != null) await _ensurePrimed();
    final record = CachedDocument.live(doc).toRecord();
    await store.putDocument(doc.path, record);
    if (_eviction != null) {
      _eviction.recordAccess(doc.path, _sizeOf(record));
      await _eviction.evictIfNeeded();
    }
  }

  /// Stores many server-confirmed documents, running a SINGLE eviction pass after
  /// all writes (instead of one per document) — so a bulk write-through computes
  /// the pinned set / scans the pending queue once, not per doc.
  Future<void> putConfirmedAll(Iterable<WireDocument> docs) async {
    if (_eviction != null) await _ensurePrimed();
    for (final doc in docs) {
      final record = CachedDocument.live(doc).toRecord();
      await store.putDocument(doc.path, record);
      _eviction?.recordAccess(doc.path, _sizeOf(record));
    }
    await _eviction?.evictIfNeeded();
  }

  /// Stores a confirmed deletion as a tombstone (known-absent).
  Future<void> putConfirmedDeleted(String path, String updateTime) async {
    await store.putDocument(
        path, CachedDocument.tombstone(path, updateTime).toRecord());
    _eviction?.forget(path); // tombstones are not LRU-managed live docs
  }

  /// The confirmed live document, or null if unknown or tombstoned.
  Future<WireDocument?> confirmed(String path) async {
    final rec = await store.getDocument(path);
    if (rec == null) return null;
    final cached = CachedDocument.fromRecord(rec);
    if (cached.deleted) return null;
    // A read only bumps recency; priming (and its eviction pass) is confined to
    // writes, so a read never deletes another document from disk.
    _eviction?.recordAccess(path, _sizeOf(rec));
    return cached.document;
  }

  /// True when the path is cached as a tombstone (known to not exist).
  Future<bool> isKnownAbsent(String path) async {
    final rec = await store.getDocument(path);
    return rec != null && CachedDocument.fromRecord(rec).deleted;
  }

  /// All confirmed live documents directly in [collectionPath].
  Future<List<WireDocument>> confirmedInCollection(
      String collectionPath) async {
    final records = await store.documentsInCollection(collectionPath);
    return [
      for (final r in records)
        if (CachedDocument.fromRecord(r)
            case CachedDocument(deleted: false, :final document?))
          document,
    ];
  }
}
