import 'dart:convert';

import 'values.dart';

/// The cross-type sort rank of [v] per PROTOCOL §1.3. NaN ranks 29 (before all
/// finite numbers); int and (non-NaN) double share rank 30.
int typeRank(Value v) {
  return switch (v) {
    NullValue() => 10,
    BooleanValue() => 20,
    DoubleValue(:final value) when value.isNaN => 29,
    IntegerValue() => 30,
    DoubleValue() => 30,
    TimestampValue() => 40,
    StringValue() => 50,
    BytesValue() => 60,
    ReferenceValue() => 70,
    GeoPointValue() => 80,
    ArrayValue() => 90,
    MapValue() => 100,
    DeleteFieldValue() =>
      throw ArgumentError('DeleteFieldValue is not orderable'),
  };
}

/// Total order over [Value] matching the server engine (PROTOCOL §1.3/§1.4).
/// Returns <0, 0, or >0.
int compareValues(Value a, Value b) {
  final ra = typeRank(a);
  final rb = typeRank(b);
  if (ra != rb) return ra.compareTo(rb);
  switch (ra) {
    case 10: // null
    case 29: // NaN (all equal)
      return 0;
    case 20:
      final av = (a as BooleanValue).value ? 1 : 0;
      final bv = (b as BooleanValue).value ? 1 : 0;
      return av.compareTo(bv);
    case 30:
      final x = asNum(a);
      final y = asNum(b);
      if (x == y) return 0; // handles -0.0 == 0.0
      return x < y ? -1 : 1;
    case 40:
      return (a as TimestampValue).value.compareTo((b as TimestampValue).value);
    case 50:
      return _compareCodepoints(
          (a as StringValue).value, (b as StringValue).value);
    case 60:
      return _compareBytes((a as BytesValue).value, (b as BytesValue).value);
    case 70:
      return _compareCodepoints(
          (a as ReferenceValue).path, (b as ReferenceValue).path);
    case 80:
      final ga = a as GeoPointValue;
      final gb = b as GeoPointValue;
      final c = ga.latitude.compareTo(gb.latitude);
      return c != 0 ? c : ga.longitude.compareTo(gb.longitude);
    case 90:
      final ea = (a as ArrayValue).elements;
      final eb = (b as ArrayValue).elements;
      final n = ea.length < eb.length ? ea.length : eb.length;
      for (var i = 0; i < n; i++) {
        final c = compareValues(ea[i], eb[i]);
        if (c != 0) return c;
      }
      return ea.length.compareTo(eb.length);
    case 100:
      final ma = a as MapValue;
      final mb = b as MapValue;
      final ka = ma.fields.keys.toList()..sort(_compareCodepoints);
      final kb = mb.fields.keys.toList()..sort(_compareCodepoints);
      final n = ka.length < kb.length ? ka.length : kb.length;
      for (var i = 0; i < n; i++) {
        final ck = _compareCodepoints(ka[i], kb[i]);
        if (ck != 0) return ck;
        final cv = compareValues(ma.fields[ka[i]]!, mb.fields[kb[i]]!);
        if (cv != 0) return cv;
      }
      return ka.length.compareTo(kb.length);
    default:
      throw StateError('unreachable rank $ra');
  }
}

/// Typed equality used by `eq`/`ne`/`in`/`arrayContains` etc.: structural with
/// cross-type numeric equality (`int 5 == double 5.0`) and `NaN == NaN`.
bool valueEquals(Value a, Value b) {
  return compareValues(a, b) == 0;
}

/// Coarse type class for inequality operators: int/double/NaN share the
/// "number" class (rank 30); all other types use their own rank.
int _typeClass(Value v) {
  final r = typeRank(v);
  return (r == 29) ? 30 : r;
}

/// Whether [a] and [b] are in the same type-class (so `gt`/`lt`/etc. may match).
bool sameTypeClass(Value a, Value b) {
  return _typeClass(a) == _typeClass(b);
}

/// The numeric value of [v] (int or double). Returns [orElse] when [v] is null
/// or non-numeric; throws [StateError] when [v] is non-numeric and no [orElse]
/// is given.
num asNum(Value? v, {num? orElse}) {
  if (v is IntegerValue) return v.value;
  if (v is DoubleValue) return v.value;
  if (orElse != null) return orElse;
  throw StateError('not a number: $v');
}

/// Unicode code-point order via UTF-8 byte comparison (COLLATE "C").
int _compareCodepoints(String a, String b) {
  return _compareBytes(utf8.encode(a), utf8.encode(b));
}

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}
