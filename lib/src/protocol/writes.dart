import '../core/timestamps.dart';
import '../core/values.dart';

/// Sealed base class for write operations in a batch.
///
/// Every write is one of: [SetWrite], [UpdateWrite], [DeleteWrite].
/// Wire format: `{"set": {...}}`, `{"update": {...}}`, `{"delete": {...}}`.
sealed class Write {
  const Write();

  /// Converts this write to its wire JSON representation (the one-of envelope).
  Map<String, Object?> toJson();

  /// The document path this write targets.
  String get path;

  /// The precondition guarding this write, if any.
  Precondition? get precondition;

  /// Returns a copy of this write with [pc] as its precondition.
  Write withPrecondition(Precondition? pc);

  /// Parses a write envelope (`{set|update|delete: {...}}`) back into a [Write].
  ///
  /// Throws [FormatException] if the envelope has no recognised key.
  static Write fromJson(Map<String, Object?> json) {
    if (json case {'set': final Map<String, Object?> body}) {
      return SetWrite(
        body['path'] as String,
        _parseFields(body['fields'] as Map<String, Object?>? ?? const {}),
        merge: body['merge'] as bool? ?? false,
        transforms: _parseTransforms(body['transforms']),
        precondition: Precondition.fromJson(
            body['precondition'] as Map<String, Object?>?),
      );
    }
    if (json case {'update': final Map<String, Object?> body}) {
      return UpdateWrite(
        body['path'] as String,
        _parseFields(body['fields'] as Map<String, Object?>? ?? const {}),
        transforms: _parseTransforms(body['transforms']),
        precondition: Precondition.fromJson(
            body['precondition'] as Map<String, Object?>?),
      );
    }
    if (json case {'delete': final Map<String, Object?> body}) {
      return DeleteWrite(
        body['path'] as String,
        cascade: body['cascade'] as bool? ?? false,
        precondition: Precondition.fromJson(
            body['precondition'] as Map<String, Object?>?),
      );
    }
    throw FormatException('Unknown write envelope: ${json.keys.toList()}');
  }

  static Map<String, Value> _parseFields(Map<String, Object?> raw) => {
        for (final e in raw.entries) e.key: Value.fromJson(e.value),
      };

  static List<FieldTransform>? _parseTransforms(Object? raw) {
    if (raw == null) return null;
    return [
      for (final t in raw as List<Object?>)
        FieldTransform.fromJson(t as Map<String, Object?>),
    ];
  }
}

/// Optional precondition that must hold for a write to succeed.
///
/// At least one of [exists] or [updateTime] must be set.
///
/// `updateTime` can be provided either as a [DateTime] (formatted with
/// `+00:00` offset per PROTOCOL §2.1) or as a raw server-format string
/// via [Precondition.updateTimeRaw] — allowing exact echo-back of a timestamp
/// received from a [WireDocument] without parsing/reformatting.
final class Precondition {
  const Precondition({this.exists, DateTime? updateTime})
      : _updateTimeRaw = null,
        _updateTime = updateTime;

  /// Creates a precondition whose `updateTime` is stored as a raw string and
  /// emitted verbatim. Use this when echoing a timestamp received from the
  /// server (e.g. from [WireDocument.updateTime]) to avoid any
  /// formatting differences.
  ///
  /// Optionally combine with [exists] to require both conditions.
  const Precondition.updateTimeRaw(String raw, {this.exists})
      : _updateTimeRaw = raw,
        _updateTime = null;

  final bool? exists;
  final DateTime? _updateTime;
  final String? _updateTimeRaw;

  /// The `updateTime` as a [DateTime], if provided as one (null otherwise).
  DateTime? get updateTime => _updateTime;

  /// The raw `updateTime` string, if provided via [Precondition.updateTimeRaw].
  String? get updateTimeRaw => _updateTimeRaw;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{};
    if (exists != null) map['exists'] = exists;
    if (_updateTimeRaw != null) {
      map['updateTime'] = _updateTimeRaw;
    } else if (_updateTime != null) {
      map['updateTime'] = formatMetaTimestamp(_updateTime);
    }
    assert(map.isNotEmpty, 'Precondition must have at least one field set');
    return map;
  }

  /// Parses a precondition body, or returns null for a null/empty input.
  static Precondition? fromJson(Map<String, Object?>? json) {
    if (json == null || json.isEmpty) return null;
    final exists = json['exists'] as bool?;
    final updateTime = json['updateTime'] as String?;
    if (updateTime != null) {
      return Precondition.updateTimeRaw(updateTime, exists: exists);
    }
    return Precondition(exists: exists);
  }
}

/// The kind of a field transform, matching the wire string names exactly
/// (per PROTOCOL §3.7).
enum TransformKind {
  serverTimestamp,
  increment,
  maximum,
  minimum,
  arrayUnion,
  arrayRemove,
}

/// A transform applied to a single field after the write data has been written.
///
/// [operand] is required for all kinds except [TransformKind.serverTimestamp].
final class FieldTransform {
  const FieldTransform(this.field, this.kind, [this.operand]);

  final String field;
  final TransformKind kind;
  final Value? operand;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'field': field,
      'kind': _kindWire(kind),
    };
    if (operand != null) {
      map['operand'] = operand!.toJson();
    }
    return map;
  }

  static String _kindWire(TransformKind k) {
    return switch (k) {
      TransformKind.serverTimestamp => 'serverTimestamp',
      TransformKind.increment => 'increment',
      TransformKind.maximum => 'maximum',
      TransformKind.minimum => 'minimum',
      TransformKind.arrayUnion => 'arrayUnion',
      TransformKind.arrayRemove => 'arrayRemove',
    };
  }

  /// Parses a transform body back into a [FieldTransform].
  static FieldTransform fromJson(Map<String, Object?> json) {
    final kind = switch (json['kind'] as String) {
      'serverTimestamp' => TransformKind.serverTimestamp,
      'increment' => TransformKind.increment,
      'maximum' => TransformKind.maximum,
      'minimum' => TransformKind.minimum,
      'arrayUnion' => TransformKind.arrayUnion,
      'arrayRemove' => TransformKind.arrayRemove,
      final k => throw FormatException('Unknown transform kind: "$k"'),
    };
    final operandRaw = json['operand'];
    return FieldTransform(
      json['field'] as String,
      kind,
      operandRaw == null ? null : Value.fromJson(operandRaw),
    );
  }
}

/// Replaces or deep-merges a document.
///
/// Wire: `{"set": {"path": "...", "fields": {...}, "merge": false, ...}}`
///
/// See PROTOCOL §3.2.
final class SetWrite extends Write {
  const SetWrite(
    this.path,
    this.fields, {
    this.merge = false,
    this.transforms,
    this.precondition,
  });

  @override
  final String path;
  final Map<String, Value> fields;
  final bool merge;
  final List<FieldTransform>? transforms;
  @override
  final Precondition? precondition;

  @override
  Map<String, Object?> toJson() {
    final body = <String, Object?>{
      'path': path,
      'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
      'merge': merge,
    };
    if (transforms != null) {
      body['transforms'] = [for (final t in transforms!) t.toJson()];
    }
    if (precondition != null) {
      body['precondition'] = precondition!.toJson();
    }
    return {'set': body};
  }

  @override
  SetWrite withPrecondition(Precondition? pc) => SetWrite(path, fields,
      merge: merge, transforms: transforms, precondition: pc);
}

/// Patches individual nested fields (via dotted field paths).
///
/// Wire: `{"update": {"path": "...", "fields": {...}, ...}}`
///
/// See PROTOCOL §3.3.
final class UpdateWrite extends Write {
  const UpdateWrite(
    this.path,
    this.fields, {
    this.transforms,
    this.precondition,
  });

  @override
  final String path;
  final Map<String, Value> fields;
  final List<FieldTransform>? transforms;
  @override
  final Precondition? precondition;

  @override
  Map<String, Object?> toJson() {
    final body = <String, Object?>{
      'path': path,
      'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
    };
    if (transforms != null) {
      body['transforms'] = [for (final t in transforms!) t.toJson()];
    }
    if (precondition != null) {
      body['precondition'] = precondition!.toJson();
    }
    return {'update': body};
  }

  @override
  UpdateWrite withPrecondition(Precondition? pc) =>
      UpdateWrite(path, fields, transforms: transforms, precondition: pc);
}

/// Deletes a document, optionally cascading to nested documents.
///
/// Wire: `{"delete": {"path": "...", "cascade": false, ...}}`
///
/// See PROTOCOL §3.4.
final class DeleteWrite extends Write {
  const DeleteWrite(
    this.path, {
    this.cascade = false,
    this.precondition,
  });

  @override
  final String path;
  final bool cascade;
  @override
  final Precondition? precondition;

  @override
  Map<String, Object?> toJson() {
    final body = <String, Object?>{
      'path': path,
      'cascade': cascade,
    };
    if (precondition != null) {
      body['precondition'] = precondition!.toJson();
    }
    return {'delete': body};
  }

  @override
  DeleteWrite withPrecondition(Precondition? pc) =>
      DeleteWrite(path, cascade: cascade, precondition: pc);
}
