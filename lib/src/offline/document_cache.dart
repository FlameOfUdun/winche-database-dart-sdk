import '../protocol/messages.dart';
import 'local_store.dart';
import 'records.dart';

/// Reads and writes confirmed (server-acknowledged) documents in the
/// [LocalStore]. The optimistic overlay is layered on top of this in a later
/// component; this class only deals with confirmed state and tombstones.
class DocumentCache {
  DocumentCache(this.store);

  final LocalStore store;

  /// Stores a server-confirmed document.
  Future<void> putConfirmed(WireDocument doc) =>
      store.putDocument(doc.path, CachedDocument.live(doc).toRecord());

  /// Stores a confirmed deletion as a tombstone (known-absent).
  Future<void> putConfirmedDeleted(String path, String updateTime) => store
      .putDocument(path, CachedDocument.tombstone(path, updateTime).toRecord());

  /// The confirmed live document, or null if unknown or tombstoned.
  Future<WireDocument?> confirmed(String path) async {
    final rec = await store.getDocument(path);
    if (rec == null) return null;
    final cached = CachedDocument.fromRecord(rec);
    return cached.deleted ? null : cached.document;
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
