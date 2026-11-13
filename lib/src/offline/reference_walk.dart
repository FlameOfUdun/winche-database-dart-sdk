import '../core/values.dart';
import '../protocol/messages.dart';

/// The most references followed one after another, and the most documents one
/// read includes: the server's limits (PROTOCOL §7.7).
const int maxExpandDepth = 4;
const int maxExpandDocuments = 100;

/// Follows the references [paths] (each split into fields) reach from [roots],
/// level by level, the way the server does (PROTOCOL §7.7): maps are walked
/// into by name, lists apply the same step to each item, and a reference applies
/// the rest of the path to the document it points to. [resolve] gives a
/// referenced document (or null: missing, unknown or unreadable); each is
/// asked for once. Returns the documents found, by path.
Future<Map<String, WireDocument>> walkReferences(
  Iterable<WireDocument?> roots,
  List<List<String>> paths,
  Future<WireDocument?> Function(String path) resolve,
) async {
  final found = <String, WireDocument>{};
  final asked = <String>{};
  var level = <(String, List<String>)>[];
  for (final root in roots) {
    if (root == null) continue;
    for (final p in paths) {
      _walk(MapValue(root.fields), p, 0, level);
    }
  }
  for (var depth = 1; level.isNotEmpty && depth <= maxExpandDepth; depth++) {
    for (final (path, _) in level) {
      if (asked.contains(path) || asked.length >= maxExpandDocuments) continue;
      asked.add(path);
      final doc = await resolve(path);
      if (doc != null) found[path] = doc;
    }
    final next = <(String, List<String>)>[];
    for (final (path, rest) in level) {
      final doc = found[path];
      if (rest.isNotEmpty && doc != null) _walk(MapValue(doc.fields), rest, 0, next);
    }
    level = next;
  }
  return found;
}

void _walk(Value value, List<String> segments, int i, List<(String, List<String>)> out) {
  switch (value) {
    case ReferenceValue(:final path):
      final target = path.startsWith('/') ? path.substring(1) : path;
      if (target.split('/').length.isEven) out.add((target, segments.sublist(i)));
    case ArrayValue(:final elements):
      for (final e in elements) {
        _walk(e, segments, i, out);
      }
    case MapValue(:final fields) when i < segments.length:
      final child = fields[segments[i]];
      if (child != null) _walk(child, segments, i + 1, out);
    default:
      break;
  }
}
