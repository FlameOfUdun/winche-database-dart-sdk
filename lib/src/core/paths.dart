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

/// The parent collection path, or null when [path] is a top-level segment.
String? parentOf(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? null : path.substring(0, i);
}

/// The '/'-separated segments of [path].
List<String> segments(String path) => path.split('/');
