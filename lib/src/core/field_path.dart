import 'values.dart';

/// Resolves a dotted [fieldPath] within a field map [root], traversing nested
/// [MapValue]s. Returns null when any segment is absent or traverses into a
/// non-map. A field present with a null value resolves to [NullValue].
Value? resolvePath(Map<String, Value> root, String fieldPath) {
  final parts = fieldPath.split('.');
  Value? current = MapValue(root);
  for (final part in parts) {
    if (current is MapValue) {
      current = current.fields[part];
      if (current == null) return null;
    } else {
      return null;
    }
  }
  return current;
}

/// Sets [value] at the dotted [dotted] path within [root], creating intermediate
/// [MapValue]s as needed (copy-on-write at each level).
void setPath(Map<String, Value> root, String dotted, Value value) {
  final parts = dotted.split('.');
  var map = root;
  for (var i = 0; i < parts.length - 1; i++) {
    final child = map[parts[i]];
    final childMap = child is MapValue
        ? Map<String, Value>.of(child.fields)
        : <String, Value>{};
    map[parts[i]] = MapValue(childMap);
    map = childMap;
  }
  map[parts.last] = value;
}

/// Removes the value at the dotted [dotted] path within [root]. No-op when the
/// path does not resolve through nested maps.
void deletePath(Map<String, Value> root, String dotted) {
  final parts = dotted.split('.');
  var map = root;
  for (var i = 0; i < parts.length - 1; i++) {
    final child = map[parts[i]];
    if (child is! MapValue) return;
    final childMap = Map<String, Value>.of(child.fields);
    map[parts[i]] = MapValue(childMap);
    map = childMap;
  }
  map.remove(parts.last);
}
