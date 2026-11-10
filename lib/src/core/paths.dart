/// The document id: the final `/`-separated segment.
String docId(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// The parent collection path: everything before the final `/`.
/// Returns '' when [path] has no '/'.
String collectionOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// The id of a document's collection: its path's second-to-last segment
/// (`users/u1/notes/n1` → `notes`).
String collectionIdOf(String documentPath) {
  final collection = collectionOf(documentPath);
  final i = collection.lastIndexOf('/');
  return i < 0 ? collection : collection.substring(i + 1);
}

/// Whether [documentPath] is a document of a collection with id [collectionId].
bool inCollectionGroup(String documentPath, String collectionId) =>
    documentPath.split('/').length.isEven && collectionIdOf(documentPath) == collectionId;

/// The parent collection path, or null when [path] is a top-level segment.
String? parentOf(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? null : path.substring(0, i);
}

/// The '/'-separated segments of [path].
List<String> segments(String path) => path.split('/');
