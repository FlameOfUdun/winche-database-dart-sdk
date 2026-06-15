import '../core/field_path.dart';
import '../core/value_order.dart';
import '../core/values.dart';
import '../protocol/messages.dart';

/// Resolves [field] against [doc]. The pseudo-field `__name__` resolves to the
/// document path as a [ReferenceValue] (PROTOCOL §2.3); all other fields resolve
/// through the document's field map.
Value? resolveField(WireDocument doc, String field) {
  if (field == '__name__') return ReferenceValue(doc.path);
  return resolvePath(doc.fields, field);
}

/// Evaluates a filter (given as its `FilterSpec.toJson()` shape) against [doc],
/// mirroring the server's matching semantics (PROTOCOL §4.2/§4.3).
bool matchesFilter(WireDocument doc, Map<String, Object?> filter) {
  if (filter['and'] case final List<Object?> clauses) {
    return clauses.every((c) => matchesFilter(doc, _m(c)));
  }
  if (filter['or'] case final List<Object?> clauses) {
    return clauses.any((c) => matchesFilter(doc, _m(c)));
  }
  if (filter['not'] case final Object not) {
    return !matchesFilter(doc, _m(not));
  }
  if (filter['unary'] case final String op) {
    return _matchUnary(doc, op, filter['field'] as String);
  }
  if (filter['compare'] case final Map<Object?, Object?> cmp) {
    final c = _m(cmp);
    return _matchCompare(
        doc, c['left'] as String, c['op'] as String, c['right'] as String);
  }
  // Field filter.
  return _matchField(doc, filter['field'] as String, filter['op'] as String,
      Value.fromJson(filter['value']));
}

Map<String, Object?> _m(Object? o) => (o as Map).cast<String, Object?>();

bool _matchUnary(WireDocument doc, String op, String field) {
  final v = resolveField(doc, field);
  return switch (op) {
    'isNull' => v is NullValue,
    'isNan' => v is DoubleValue && v.value.isNaN,
    'exists' => v != null,
    _ => throw FormatException('Unknown unary op: "$op"'),
  };
}

bool _matchCompare(WireDocument doc, String left, String op, String right) {
  final l = resolveField(doc, left);
  final r = resolveField(doc, right);
  if (l == null || r == null) return false;
  return _applyOp(op, l, r);
}

bool _matchField(WireDocument doc, String field, String op, Value operand) {
  final v = resolveField(doc, field);
  operand = _normalizeNameOperand(field, operand);
  switch (op) {
    case 'eq':
      return v != null && valueEquals(v, operand);
    case 'ne':
      return v != null && !valueEquals(v, operand);
    case 'gt':
    case 'gte':
    case 'lt':
    case 'lte':
      return v != null && _applyOp(op, v, operand);
    case 'in':
      return v != null &&
          operand is ArrayValue &&
          operand.elements.any((e) => valueEquals(v, e));
    case 'notIn':
      return v != null &&
          operand is ArrayValue &&
          !operand.elements.any((e) => valueEquals(v, e));
    case 'arrayContains':
      return v is ArrayValue && v.elements.any((e) => valueEquals(e, operand));
    case 'arrayContainsAny':
      return v is ArrayValue &&
          operand is ArrayValue &&
          operand.elements
              .any((e) => v.elements.any((ve) => valueEquals(ve, e)));
    case 'arrayContainsAll':
      return v is ArrayValue &&
          operand is ArrayValue &&
          operand.elements
              .every((e) => v.elements.any((ve) => valueEquals(ve, e)));
    case 'contains':
      return v is StringValue &&
          operand is StringValue &&
          v.value.contains(operand.value);
    case 'startsWith':
      return v is StringValue &&
          operand is StringValue &&
          v.value.startsWith(operand.value);
    case 'endsWith':
      return v is StringValue &&
          operand is StringValue &&
          v.value.endsWith(operand.value);
    case 'regex':
      return v is StringValue &&
          operand is StringValue &&
          RegExp(operand.value).hasMatch(v.value);
    default:
      throw FormatException('Unknown field op: "$op"');
  }
}

/// For the `__name__` pseudo-field, document paths resolve to [ReferenceValue],
/// but user operands arrive as [StringValue] (or an array of them). Normalize
/// the operand to references so equality/membership comparisons line up.
Value _normalizeNameOperand(String field, Value operand) {
  if (field != '__name__') return operand;
  if (operand is StringValue) return ReferenceValue(operand.value);
  if (operand is ArrayValue) {
    return ArrayValue([
      for (final e in operand.elements)
        e is StringValue ? ReferenceValue(e.value) : e,
    ]);
  }
  return operand;
}

/// Comparison operators that require same-type-class operands.
bool _applyOp(String op, Value a, Value b) {
  switch (op) {
    case 'eq':
      return valueEquals(a, b);
    case 'ne':
      return !valueEquals(a, b);
    case 'gt':
      if (_isNan(a) || _isNan(b)) return false; // NaN is unordered
      return sameTypeClass(a, b) && compareValues(a, b) > 0;
    case 'gte':
      if (_isNan(a) || _isNan(b)) return false;
      return sameTypeClass(a, b) && compareValues(a, b) >= 0;
    case 'lt':
      if (_isNan(a) || _isNan(b)) return false;
      return sameTypeClass(a, b) && compareValues(a, b) < 0;
    case 'lte':
      if (_isNan(a) || _isNan(b)) return false;
      return sameTypeClass(a, b) && compareValues(a, b) <= 0;
    default:
      throw FormatException('Unsupported compare op: "$op"');
  }
}

bool _isNan(Value v) => v is DoubleValue && v.value.isNaN;
