part of '../../winche_database.dart';

// Forward declaration — DocumentReference is defined in references.dart.
// We need its path for ReferenceValue encoding.
// To avoid a circular import, we expose a public interface here that
// DocumentReference implements.

/// Marker interface for objects that carry a document [path].
/// [DocumentReference] implements this, enabling [toValue] to convert
/// references without creating a circular import.

/// Validates that [key] does not contain a dot (`.`).
///
/// Dotted keys in set/nested-map contexts produce ambiguous field paths on
/// the wire and cannot be addressed by transforms (I1). Throw [ArgumentError]
/// with the offending key and its [keyPath].
///
/// Dotted keys are valid ONLY as top-level keys in `update()` (via
/// [splitUpdateData]), not inside nested maps or [toValue].
void _assertNoDot(String key, {required String keyPath}) {
  if (key.contains('.')) {
    throw ArgumentError(
      'Map key "$key" at path "${keyPath.isEmpty ? '<root>' : keyPath}" '
      'contains a dot (\'.\'), which is illegal in set/nested-map contexts. '
      'Dotted keys are only valid as top-level update() keys.',
    );
  }
}

/// Converts a native Dart object to a [Value], following the type mapping
/// described in PROTOCOL §1.
///
/// Supported types:
/// - `null` → [NullValue]
/// - `bool` → [BooleanValue]
/// - `int` → [IntegerValue]
/// - `double` → [DoubleValue]
/// - `String` → [StringValue]
/// - `DateTime` → [TimestampValue] (UTC)
/// - `Uint8List` → [BytesValue]
/// - [GeoPoint] → [GeoPointValue]
/// - An object with a `.path` (i.e. `DocumentReference`) → [ReferenceValue]
/// - `List` → [ArrayValue] (recursive; [FieldValue] sentinels inside lists are
///   rejected with [ArgumentError])
/// - `Map<String, dynamic>` → [MapValue] (recursive; sentinels at any depth
///   are extracted as transforms — use [splitWriteData] at the top level)
/// - [Value] → passed through unchanged (escape hatch)
///
/// Throws [ArgumentError] for any unsupported type.
///
/// [keyPath] is used only for error messages (dot-joined path to the
/// offending value); callers should pass `''` at the top level.
Value toValue(Object? obj, {String keyPath = ''}) {
  if (obj == null) return const NullValue();
  if (obj is Value) return obj; // escape hatch

  if (obj is bool) return BooleanValue(obj);
  if (obj is int) return IntegerValue(obj);
  if (obj is double) return DoubleValue(obj);
  if (obj is String) return StringValue(obj);

  if (obj is DateTime) return TimestampValue(obj.toUtc());

  if (obj is Uint8List) return BytesValue(obj);

  if (obj is GeoPoint) return GeoPointValue(obj.latitude, obj.longitude);

  // DocumentReference fields become referenceValue.
  if (obj is DocumentReference) return ReferenceValue(obj.path);

  if (obj is List) {
    return ArrayValue([
      for (var i = 0; i < obj.length; i++)
        _toValueInList(obj[i],
            keyPath: keyPath.isEmpty ? '[$i]' : '$keyPath[$i]'),
    ]);
  }

  if (obj is Map) {
    final map = obj.cast<String, Object?>();
    return MapValue({
      for (final entry in map.entries)
        entry.key: () {
          final childPath =
              keyPath.isEmpty ? entry.key : '$keyPath.${entry.key}';
          _assertNoDot(entry.key, keyPath: childPath);
          return toValue(entry.value, keyPath: childPath);
        }(),
    });
  }

  throw ArgumentError(
    'Unsupported type ${obj.runtimeType} at key path '
    '"${keyPath.isEmpty ? '<root>' : keyPath}"',
  );
}

/// Like [toValue] but rejects [FieldValue] sentinels (sentinels inside Lists
/// are always illegal per PROTOCOL §3.6).
Value _toValueInList(Object? obj, {required String keyPath}) {
  if (obj is FieldValue) {
    throw ArgumentError(
      'FieldValue sentinels are not allowed inside List values '
      '(at key path "$keyPath")',
    );
  }
  return toValue(obj, keyPath: keyPath);
}

/// Converts a [Value] back to a native Dart object.
///
/// - [NullValue] → `null`
/// - [BooleanValue] → `bool`
/// - [IntegerValue] → `int`
/// - [DoubleValue] → `double`
/// - [TimestampValue] → `DateTime` (UTC)
/// - [StringValue] → `String`
/// - [BytesValue] → `Uint8List`
/// - [GeoPointValue] → [GeoPoint]
/// - [ReferenceValue] → calls [refFromPath] to create a `DocumentReference`
/// - [ArrayValue] → `List<Object?>`
/// - [MapValue] → `Map<String, Object?>`
/// - [DeleteFieldValue] → [ArgumentError] (write-time sentinel, not a read
///   value)
Object? fromValue(Value value) {
  return switch (value) {
    NullValue() => null,
    BooleanValue(:final value) => value,
    IntegerValue(:final value) => value,
    DoubleValue(:final value) => value,
    TimestampValue(:final value) => value, // already UTC DateTime
    StringValue(:final value) => value,
    BytesValue(:final value) => value,
    GeoPointValue(:final latitude, :final longitude) =>
      GeoPoint(latitude, longitude),
    ReferenceValue(:final path) => path,
    ArrayValue(:final elements) => [for (final e in elements) fromValue(e)],
    MapValue(:final fields) => {
        for (final entry in fields.entries) entry.key: fromValue(entry.value),
      },
    DeleteFieldValue() => throw ArgumentError(
        'DeleteFieldValue is a write-time sentinel and cannot be read back '
        'as a native value'),
  };
}

/// Splits a Dart write-data map into wire-ready fields and field transforms.
///
/// Walks [data] recursively:
/// - Regular values → converted with [toValue] and collected in [fields] at
///   their top-level key (non-sentinel nested maps become [MapValue]s).
/// - [FieldValue.delete] → stored as [DeleteFieldValue] in [fields] at their
///   top-level key or nested inside a [MapValue] (for set-merge writes).
///   For update writes where dotted-path keys are needed, the caller should
///   flatten the map before calling this function (see [flattenForUpdate]).
/// - Other [FieldValue] sentinels → collected as [FieldTransform] entries
///   keyed by **dotted field path** (valid at any map depth per PROTOCOL §3.4).
///   Sentinels inside `List` values throw [ArgumentError].
///
/// Returns `(fields, transforms)` where:
/// - [fields]: top-level keyed map ready for [SetWrite] or (after flattening)
///   [UpdateWrite].
/// - [transforms]: FieldTransform list with dotted field paths, ready for
///   either write type.
(Map<String, Value> fields, List<FieldTransform> transforms) splitWriteData(
  Map<String, Object?> data,
) {
  final fields = <String, Value>{};
  final transforms = <FieldTransform>[];
  _walkTopMap(data, fields, transforms, prefix: '');
  return (fields, transforms);
}

/// Like [splitWriteData] but enforces update() semantics:
/// - Top-level dotted keys (`'a.b': value`) are ALLOWED (they are field paths).
/// - Nested [FieldValue.delete] sentinels inside a map value are ILLEGAL and
///   throw [ArgumentError] ("delete sentinels in update must be top-level
///   dotted keys").
/// - Top-level `'a.b': FieldValue.delete()` keeps working.
(Map<String, Value> fields, List<FieldTransform> transforms) splitUpdateData(
  Map<String, Object?> data,
) {
  final fields = <String, Value>{};
  final transforms = <FieldTransform>[];
  // Top-level: allow dotted keys (they are valid update field paths).
  for (final entry in data.entries) {
    final key = entry.key;
    final value = entry.value;
    final fieldPath = key; // top-level: key IS the field path (may be dotted)

    if (value is FieldValue) {
      _handleSentinel(value, fieldPath, key, fields, transforms);
    } else if (value is Map) {
      final nested = value.cast<String, Object?>();
      _assertNoNestedDelete(nested, parentPath: fieldPath);
      if (nested.isEmpty) {
        fields[key] = const MapValue({});
      } else {
        final (subFields, subTransforms) =
            _walkNestedMap(nested, prefix: fieldPath);
        transforms.addAll(subTransforms);
        if (subFields.isNotEmpty) {
          fields[key] = MapValue(subFields);
        }
      }
    } else {
      fields[key] = toValue(value, keyPath: fieldPath);
    }
  }
  return (fields, transforms);
}

/// Recursively checks that no [DeleteSentinel] appears nested inside [data].
/// Throws [ArgumentError] if one is found.
void _assertNoNestedDelete(
  Map<String, Object?> data, {
  required String parentPath,
}) {
  for (final entry in data.entries) {
    final value = entry.value;
    final path = '$parentPath.${entry.key}';
    if (value is DeleteSentinel) {
      throw ArgumentError(
        'delete sentinels in update() must be top-level dotted keys. '
        'Found FieldValue.delete() at nested path "$path". '
        'Use \'$path\': FieldValue.delete() as a top-level key instead.',
      );
    }
    if (value is Map) {
      _assertNoNestedDelete(value.cast<String, Object?>(), parentPath: path);
    }
  }
}

/// Walks a map at the top level, placing non-sentinel fields in [fields]
/// (literal keys) and sentinel fields as [FieldTransform]s in [transforms].
/// Nested maps are recursed but their non-sentinel content is returned as
/// a [MapValue] at the top-level key.
void _walkTopMap(
  Map<String, Object?> data,
  Map<String, Value> fields,
  List<FieldTransform> transforms, {
  required String prefix,
}) {
  for (final entry in data.entries) {
    final key = entry.key;
    final value = entry.value;
    final fieldPath = prefix.isEmpty ? key : '$prefix.$key';
    _assertNoDot(key, keyPath: fieldPath);

    if (value is FieldValue) {
      _handleSentinel(value, fieldPath, key, fields, transforms);
    } else if (value is Map) {
      final nested = value.cast<String, Object?>();
      if (nested.isEmpty) {
        // Originally empty map — emit MapValue({}) explicitly (I3).
        fields[key] = const MapValue({});
      } else {
        // Check if the nested map contains any sentinels (at any depth).
        final (subFields, subTransforms) =
            _walkNestedMap(nested, prefix: fieldPath);
        transforms.addAll(subTransforms);
        if (subFields.isNotEmpty) {
          fields[key] = MapValue(subFields);
        }
        // If subFields is empty (all were non-delete sentinels extracted as
        // transforms), no MapValue is emitted. This is correct: the server
        // applies the transforms independently.
      }
    } else {
      fields[key] = toValue(value, keyPath: fieldPath);
    }
  }
}

/// Walks a nested map, returning (fields, transforms) where:
/// - [fields] is keyed by plain (non-prefixed) local keys — ready to be
///   wrapped in a [MapValue].
/// - [transforms] have dotted field paths relative to the root.
(Map<String, Value> fields, List<FieldTransform> transforms) _walkNestedMap(
  Map<String, Object?> data, {
  required String prefix,
}) {
  final fields = <String, Value>{};
  final transforms = <FieldTransform>[];

  for (final entry in data.entries) {
    final key = entry.key;
    final value = entry.value;
    final fieldPath = '$prefix.$key';
    _assertNoDot(key, keyPath: fieldPath);

    if (value is FieldValue) {
      // Sentinel: emit transform (or delete) at the dotted path.
      // For delete: we emit it as DeleteFieldValue in fields at local key so
      // the MapValue carries it (for merge-set semantics).
      if (value is DeleteSentinel) {
        fields[key] = const DeleteFieldValue();
      } else {
        _handleSentinel(value, fieldPath, key, fields, transforms);
      }
    } else if (value is Map) {
      final nested = value.cast<String, Object?>();
      if (nested.isEmpty) {
        // Originally empty map — emit MapValue({}) explicitly (I3).
        fields[key] = const MapValue({});
      } else {
        final (subFields, subTransforms) =
            _walkNestedMap(nested, prefix: fieldPath);
        transforms.addAll(subTransforms);
        if (subFields.isNotEmpty) {
          fields[key] = MapValue(subFields);
        }
      }
    } else {
      fields[key] = toValue(value, keyPath: fieldPath);
    }
  }
  return (fields, transforms);
}

/// Handles a [FieldValue] sentinel at [fieldPath].
///
/// For [DeleteSentinel]: places [DeleteFieldValue] in [fields] at [localKey].
/// For all other sentinels: adds to [transforms] with [fieldPath].
void _handleSentinel(
  FieldValue sentinel,
  String fieldPath,
  String localKey,
  Map<String, Value> fields,
  List<FieldTransform> transforms,
) {
  switch (sentinel) {
    case DeleteSentinel():
      // deleteField goes into fields as a DeleteFieldValue sentinel.
      fields[localKey] = const DeleteFieldValue();

    case ServerTimestampSentinel():
      transforms.add(FieldTransform(fieldPath, TransformKind.serverTimestamp));

    case IncrementSentinel(:final delta):
      transforms.add(FieldTransform(
          fieldPath, TransformKind.increment, numToValue(delta)));

    case MaximumSentinel(:final value):
      transforms.add(
          FieldTransform(fieldPath, TransformKind.maximum, numToValue(value)));

    case MinimumSentinel(:final value):
      transforms.add(
          FieldTransform(fieldPath, TransformKind.minimum, numToValue(value)));

    case ArrayUnionSentinel(:final values):
      final operand = ArrayValue([
        for (var i = 0; i < values.length; i++)
          _toValueInList(values[i], keyPath: '$fieldPath[$i]'),
      ]);
      transforms
          .add(FieldTransform(fieldPath, TransformKind.arrayUnion, operand));

    case ArrayRemoveSentinel(:final values):
      final operand = ArrayValue([
        for (var i = 0; i < values.length; i++)
          _toValueInList(values[i], keyPath: '$fieldPath[$i]'),
      ]);
      transforms
          .add(FieldTransform(fieldPath, TransformKind.arrayRemove, operand));
  }
}

// ---------------------------------------------------------------------------
// Write staging — shared by references / transaction / write_batch
// ---------------------------------------------------------------------------

/// Builds a [SetWrite] from already-mapped [data].
SetWrite stageSet(String path, Map<String, Object?> data,
    {bool merge = false,
    List<String>? mergeFields,
    Precondition? precondition}) {
  final (fields, transforms) = splitWriteData(data);
  return SetWrite(path, fields,
      merge: merge,
      mergeFields: mergeFields,
      transforms: transforms.isEmpty ? null : transforms,
      precondition: precondition);
}

/// Builds an [UpdateWrite] from already-mapped [data] (top-level dotted keys ok).
UpdateWrite stageUpdate(String path, Map<String, Object?> data,
    {Precondition? precondition}) {
  final (fields, transforms) = splitUpdateData(data);
  return UpdateWrite(path, fields,
      transforms: transforms.isEmpty ? null : transforms,
      precondition: precondition);
}

/// Builds a [DeleteWrite].
DeleteWrite stageDelete(String path,
        {bool cascade = false, Precondition? precondition}) =>
    DeleteWrite(path, cascade: cascade, precondition: precondition);
