import 'dart:convert';
import 'dart:typed_data';

/// Sealed base class for all Winche Database tagged value types.
///
/// Wire format: each value is a JSON object with exactly one type-discriminator
/// key. The parser rejects objects with zero or more than one key.
sealed class Value {
  const Value();

  /// Converts this value to its wire JSON representation.
  Object toJson();

  /// Parses a tagged-value object from wire JSON.
  ///
  /// Throws [FormatException] if:
  /// - [json] is not a [Map].
  /// - The map has zero or more than one key.
  /// - The tag is unknown.
  /// - The payload is invalid for the tag (e.g. `nullValue` with a non-null payload).
  static Value fromJson(Object? json) {
    if (json is! Map) {
      throw FormatException(
          'Expected a JSON object for a tagged value, got: ${json.runtimeType}');
    }
    final map = json;
    if (map.length != 1) {
      throw FormatException(
        'Tagged value must have exactly one key; found ${map.length}: ${map.keys.toList()}',
      );
    }
    final tag = map.keys.first as String;
    final payload = map[tag];
    switch (tag) {
      case 'nullValue':
        if (payload != null) {
          throw FormatException(
            'nullValue payload must be JSON null, got: $payload',
          );
        }
        return const NullValue();

      case 'booleanValue':
        if (payload is! bool) {
          throw FormatException(
              'booleanValue payload must be a bool, got: ${payload.runtimeType}');
        }
        return BooleanValue(payload);

      case 'integerValue':
        if (payload is int) {
          return IntegerValue(payload);
        } else if (payload is String) {
          final parsed = int.tryParse(payload);
          if (parsed == null) {
            throw FormatException(
                'integerValue payload is not a valid integer string: "$payload"');
          }
          return IntegerValue(parsed);
        }
        throw FormatException(
            'integerValue payload must be a string or int, got: ${payload.runtimeType}');

      case 'doubleValue':
        if (payload is num) {
          return DoubleValue(payload.toDouble());
        } else if (payload is String) {
          switch (payload) {
            case 'NaN':
              return const DoubleValue(double.nan);
            case 'Infinity':
              return const DoubleValue(double.infinity);
            case '-Infinity':
              return const DoubleValue(double.negativeInfinity);
            default:
              throw FormatException(
                'doubleValue string payload must be "NaN", "Infinity", or "-Infinity", got: "$payload"',
              );
          }
        }
        throw FormatException(
          'doubleValue payload must be a number or special string, got: ${payload.runtimeType}',
        );

      case 'timestampValue':
        if (payload is! String) {
          throw FormatException(
              'timestampValue payload must be a string, got: ${payload.runtimeType}');
        }
        return TimestampValue.parse(payload);

      case 'stringValue':
        if (payload is! String) {
          throw FormatException(
              'stringValue payload must be a string, got: ${payload.runtimeType}');
        }
        return StringValue(payload);

      case 'bytesValue':
        if (payload is! String) {
          throw FormatException(
              'bytesValue payload must be a base64 string, got: ${payload.runtimeType}');
        }
        final Uint8List bytes;
        try {
          bytes = base64.decode(payload);
        } catch (_) {
          throw FormatException(
              'bytesValue payload is not valid base64: "$payload"');
        }
        return BytesValue(bytes);

      case 'referenceValue':
        if (payload is! String) {
          throw FormatException(
              'referenceValue payload must be a string, got: ${payload.runtimeType}');
        }
        return ReferenceValue(payload);

      case 'geoPointValue':
        if (payload is! Map) {
          throw FormatException(
              'geoPointValue payload must be an object, got: ${payload.runtimeType}');
        }
        final lat = payload['latitude'];
        final lng = payload['longitude'];
        if (lat is! num || lng is! num) {
          throw FormatException(
            'geoPointValue must have numeric latitude and longitude, got: $payload',
          );
        }
        return GeoPointValue(lat.toDouble(), lng.toDouble());

      case 'arrayValue':
        if (payload is! Map) {
          throw FormatException(
              'arrayValue payload must be an object, got: ${payload.runtimeType}');
        }
        final valuesRaw = payload['values'];
        if (valuesRaw == null) {
          return ArrayValue([]);
        }
        if (valuesRaw is! List) {
          throw FormatException(
              'arrayValue.values must be a list, got: ${valuesRaw.runtimeType}');
        }
        return ArrayValue([for (final v in valuesRaw) Value.fromJson(v)]);

      case 'mapValue':
        if (payload is! Map) {
          throw FormatException(
              'mapValue payload must be an object, got: ${payload.runtimeType}');
        }
        final fieldsRaw = payload['fields'];
        if (fieldsRaw == null) {
          return MapValue({});
        }
        if (fieldsRaw is! Map) {
          throw FormatException(
              'mapValue.fields must be an object, got: ${fieldsRaw.runtimeType}');
        }
        return MapValue({
          for (final entry in fieldsRaw.entries)
            entry.key as String: Value.fromJson(entry.value),
        });

      case 'deleteField':
        // deleteField is a write-time sentinel.
        if (payload is! bool || !payload) {
          throw FormatException(
              'deleteField payload must be true, got: $payload');
        }
        return const DeleteFieldValue();

      default:
        throw FormatException('Unknown value tag: "$tag"');
    }
  }
}

/// `{"nullValue": null}`
final class NullValue extends Value {
  const NullValue();

  @override
  Object toJson() => {'nullValue': null};

  @override
  bool operator ==(Object other) => other is NullValue;

  @override
  int get hashCode => (NullValue).hashCode;

  @override
  String toString() => 'NullValue()';
}

/// `{"booleanValue": true|false}`
final class BooleanValue extends Value {
  const BooleanValue(this.value);

  final bool value;

  @override
  Object toJson() => {'booleanValue': value};

  @override
  bool operator ==(Object other) =>
      other is BooleanValue && other.value == value;

  @override
  int get hashCode => Object.hash(BooleanValue, value);

  @override
  String toString() => 'BooleanValue($value)';
}

/// `{"integerValue": "<string>"}` — wire format is always a string.
///
/// Both string and numeric forms are accepted on read (per PROTOCOL §1).
/// The write form always uses a string to preserve int64 precision.
///
/// **Web limitation:** Dart integers compiled to JavaScript are limited to
/// 53-bit safe-integer precision. See [Value] class doc-comment for details.
final class IntegerValue extends Value {
  const IntegerValue(this.value);

  final int value;

  @override
  Object toJson() => {'integerValue': value.toString()};

  @override
  bool operator ==(Object other) =>
      other is IntegerValue && other.value == value;

  @override
  int get hashCode => Object.hash(IntegerValue, value);

  @override
  String toString() => 'IntegerValue($value)';
}

/// `{"doubleValue": <number>}` or `{"doubleValue": "NaN"|"Infinity"|"-Infinity"}`
final class DoubleValue extends Value {
  const DoubleValue(this.value);

  final double value;

  @override
  Object toJson() {
    if (value.isNaN) return {'doubleValue': 'NaN'};
    if (value == double.infinity) return {'doubleValue': 'Infinity'};
    if (value == double.negativeInfinity) return {'doubleValue': '-Infinity'};
    return {'doubleValue': value};
  }

  @override
  bool operator ==(Object other) {
    if (other is! DoubleValue) return false;
    // NaN equals NaN for value-equality purposes.
    if (value.isNaN && other.value.isNaN) return true;
    return value == other.value;
  }

  @override
  int get hashCode {
    if (value.isNaN) return Object.hash(DoubleValue, 'NaN');
    return Object.hash(DoubleValue, value);
  }

  @override
  String toString() => 'DoubleValue($value)';
}

/// `{"timestampValue": "yyyy-MM-ddTHH:mm:ss.ffffffZ"}`
///
/// Wire format uses exactly 6 fractional digits (microseconds) with UTC `Z`
/// suffix. Sub-microsecond precision is truncated, not rounded.
///
/// **Note:** metadata timestamps in document fields (`createTime`,
/// `updateTime`) use a different format (`+00:00` offset, trimmed zeros) and
/// are stored as raw strings — see [WireDocument].
final class TimestampValue extends Value {
  TimestampValue(DateTime value) : value = _truncateToMicros(value.toUtc());

  final DateTime value;

  /// Parses a timestamp string in the wire format `yyyy-MM-ddTHH:mm:ss.ffffffZ`.
  static TimestampValue parse(String s) {
    final dt = DateTime.tryParse(s);
    if (dt == null) {
      throw FormatException('Invalid timestampValue string: "$s"');
    }
    return TimestampValue(dt.toUtc());
  }

  static DateTime _truncateToMicros(DateTime dt) {
    // DateTime already has microsecond precision on the VM; sub-µs is not
    // representable, so no truncation is needed beyond converting to UTC.
    return dt;
  }

  @override
  Object toJson() => {'timestampValue': _format(value)};

  static String _format(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final us = dt.microsecond.toString().padLeft(6, '0');
    return '$y-$mo-${d}T$h:$mi:$s.${us}Z';
  }

  @override
  bool operator ==(Object other) =>
      other is TimestampValue && other.value == value;

  @override
  int get hashCode => Object.hash(TimestampValue, value);

  @override
  String toString() => 'TimestampValue(${_format(value)})';
}

/// `{"stringValue": "..."}`
final class StringValue extends Value {
  const StringValue(this.value);

  final String value;

  @override
  Object toJson() => {'stringValue': value};

  @override
  bool operator ==(Object other) =>
      other is StringValue && other.value == value;

  @override
  int get hashCode => Object.hash(StringValue, value);

  @override
  String toString() => 'StringValue($value)';
}

/// `{"bytesValue": "<base64>"}` — standard base64 encoding.
final class BytesValue extends Value {
  const BytesValue(this.value);

  final Uint8List value;

  @override
  Object toJson() => {'bytesValue': base64.encode(value)};

  @override
  bool operator ==(Object other) {
    if (other is! BytesValue) return false;
    if (value.length != other.value.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (value[i] != other.value[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([BytesValue, ...value]);

  @override
  String toString() => 'BytesValue(${base64.encode(value)})';
}

/// `{"referenceValue": "collection/id"}` — document path string.
final class ReferenceValue extends Value {
  const ReferenceValue(this.path);

  final String path;

  @override
  Object toJson() => {'referenceValue': path};

  @override
  bool operator ==(Object other) =>
      other is ReferenceValue && other.path == path;

  @override
  int get hashCode => Object.hash(ReferenceValue, path);

  @override
  String toString() => 'ReferenceValue($path)';
}

/// `{"geoPointValue": {"latitude": <number>, "longitude": <number>}}`
final class GeoPointValue extends Value {
  const GeoPointValue(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  Object toJson() => {
        'geoPointValue': {'latitude': latitude, 'longitude': longitude},
      };

  @override
  bool operator ==(Object other) =>
      other is GeoPointValue &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(GeoPointValue, latitude, longitude);

  @override
  String toString() => 'GeoPointValue($latitude, $longitude)';
}

/// `{"arrayValue": {"values": [...]}}` — empty array omits `values`.
final class ArrayValue extends Value {
  const ArrayValue(this.elements);

  final List<Value> elements;

  @override
  Object toJson() {
    if (elements.isEmpty) {
      return {'arrayValue': <String, Object?>{}};
    }
    return {
      'arrayValue': {
        'values': [for (final e in elements) e.toJson()]
      },
    };
  }

  @override
  bool operator ==(Object other) {
    if (other is! ArrayValue) return false;
    if (elements.length != other.elements.length) return false;
    for (var i = 0; i < elements.length; i++) {
      if (elements[i] != other.elements[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([ArrayValue, ...elements]);

  @override
  String toString() => 'ArrayValue($elements)';
}

/// `{"mapValue": {"fields": {...}}}` — empty map omits `fields`.
final class MapValue extends Value {
  const MapValue(this.fields);

  final Map<String, Value> fields;

  @override
  Object toJson() {
    if (fields.isEmpty) {
      return {'mapValue': <String, Object?>{}};
    }
    return {
      'mapValue': {
        'fields': {
          for (final entry in fields.entries) entry.key: entry.value.toJson(),
        },
      },
    };
  }

  @override
  bool operator ==(Object other) {
    if (other is! MapValue) return false;
    if (fields.length != other.fields.length) return false;
    for (final key in fields.keys) {
      if (!other.fields.containsKey(key)) return false;
      if (fields[key] != other.fields[key]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // XOR per-entry hashes so insertion order doesn't affect the result.
    var h = (MapValue).hashCode;
    for (final e in fields.entries) {
      h ^= Object.hash(e.key, e.value);
    }
    return h;
  }

  @override
  String toString() => 'MapValue($fields)';
}

/// `{"deleteField": true}` — write-time sentinel that removes a field.
///
/// Legal placements:
/// - [UpdateWrite] field values (any depth via dotted path keys).
/// - [SetWrite] with `merge: true` field values — at top-level or inside
///   `mapValue` at any depth.
///
/// Not legal in `SetWrite(merge: false)`, inside `ArrayValue`, or as transform
/// operands — the server returns `INVALID_ARGUMENT` in those cases.
final class DeleteFieldValue extends Value {
  const DeleteFieldValue();

  @override
  Object toJson() => {'deleteField': true};

  @override
  bool operator ==(Object other) => other is DeleteFieldValue;

  @override
  int get hashCode => (DeleteFieldValue).hashCode;

  @override
  String toString() => 'DeleteFieldValue()';
}

/// Wraps a [num] as the matching [Value]: [int] → [IntegerValue], otherwise
/// [DoubleValue].
Value numToValue(num n) {
  return n is int ? IntegerValue(n) : DoubleValue(n.toDouble());
}
