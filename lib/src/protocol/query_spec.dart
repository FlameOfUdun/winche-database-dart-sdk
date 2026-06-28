import '../core/values.dart';

// ---------------------------------------------------------------------------
// Filter operators
// ---------------------------------------------------------------------------

/// Field filter operators matching PROTOCOL §4.3 wire strings exactly.
///
/// 15 field operators (eq, ne, gt, gte, lt, lte, in, notIn, arrayContains,
/// arrayContainsAny, arrayContainsAll, contains, startsWith, endsWith, regex).
enum FieldOp {
  eq,
  ne,
  gt,
  gte,
  lt,
  lte,
  // ignore: constant_identifier_names
  inOp, // wire: "in"
  notIn,
  arrayContains,
  arrayContainsAny,
  arrayContainsAll,
  contains,
  startsWith,
  endsWith,
  regex,
}

extension FieldOpWire on FieldOp {
  String get wire => switch (this) {
        FieldOp.eq => 'eq',
        FieldOp.ne => 'ne',
        FieldOp.gt => 'gt',
        FieldOp.gte => 'gte',
        FieldOp.lt => 'lt',
        FieldOp.lte => 'lte',
        FieldOp.inOp => 'in',
        FieldOp.notIn => 'notIn',
        FieldOp.arrayContains => 'arrayContains',
        FieldOp.arrayContainsAny => 'arrayContainsAny',
        FieldOp.arrayContainsAll => 'arrayContainsAll',
        FieldOp.contains => 'contains',
        FieldOp.startsWith => 'startsWith',
        FieldOp.endsWith => 'endsWith',
        FieldOp.regex => 'regex',
      };
}

/// Unary filter operators (PROTOCOL §4.3): isNull, isNan, exists.
enum UnaryOp { isNull, isNan, exists }

extension UnaryOpWire on UnaryOp {
  String get wire => switch (this) {
        UnaryOp.isNull => 'isNull',
        UnaryOp.isNan => 'isNan',
        UnaryOp.exists => 'exists',
      };
}

// ---------------------------------------------------------------------------
// FilterSpec
// ---------------------------------------------------------------------------

/// Immutable filter specification, producing wire JSON per PROTOCOL §4.2.
sealed class FilterSpec {
  const FilterSpec();

  /// Field filter: `{"field": ..., "op": ..., "value": ...}`
  factory FilterSpec.field(String field, FieldOp op, Value value) =>
      _FieldFilter(field, op, value);

  /// Unary filter: `{"unary": ..., "field": ...}`
  factory FilterSpec.unary(String field, UnaryOp op) => _UnaryFilter(field, op);

  /// Composite AND: `{"and": [...]}`
  factory FilterSpec.and(List<FilterSpec> filters) => _AndFilter(filters);

  /// Composite OR: `{"or": [...]}`
  factory FilterSpec.or(List<FilterSpec> filters) => _OrFilter(filters);

  /// NOT filter: `{"not": ...}`
  factory FilterSpec.not(FilterSpec filter) => _NotFilter(filter);

  /// Field-compare filter: `{"compare": {"left": ..., "op": ..., "right": ...}}`
  factory FilterSpec.compare(String left, FieldOp op, String right) =>
      _CompareFilter(left, op, right);

  Map<String, Object?> toJson();
}

final class _FieldFilter extends FilterSpec {
  const _FieldFilter(this.field, this.op, this.value);
  final String field;
  final FieldOp op;
  final Value value;

  @override
  Map<String, Object?> toJson() => {
        'field': field,
        'op': op.wire,
        'value': value.toJson(),
      };
}

final class _UnaryFilter extends FilterSpec {
  const _UnaryFilter(this.field, this.op);
  final String field;
  final UnaryOp op;

  @override
  Map<String, Object?> toJson() => {
        'unary': op.wire,
        'field': field,
      };
}

final class _AndFilter extends FilterSpec {
  const _AndFilter(this.filters);
  final List<FilterSpec> filters;

  @override
  Map<String, Object?> toJson() => {
        'and': [for (final f in filters) f.toJson()],
      };
}

final class _OrFilter extends FilterSpec {
  const _OrFilter(this.filters);
  final List<FilterSpec> filters;

  @override
  Map<String, Object?> toJson() => {
        'or': [for (final f in filters) f.toJson()],
      };
}

final class _NotFilter extends FilterSpec {
  const _NotFilter(this.filter);
  final FilterSpec filter;

  @override
  Map<String, Object?> toJson() => {'not': filter.toJson()};
}

final class _CompareFilter extends FilterSpec {
  const _CompareFilter(this.left, this.op, this.right);
  final String left;
  final FieldOp op;
  final String right;

  @override
  Map<String, Object?> toJson() => {
        'compare': {'left': left, 'op': op.wire, 'right': right},
      };
}

// ---------------------------------------------------------------------------
// OrderSpec
// ---------------------------------------------------------------------------

/// Sort direction.
enum SortDirection { asc, desc }

/// One element of an orderBy clause.
class OrderSpec {
  const OrderSpec(this.field, {this.direction = SortDirection.asc});

  final String field;
  final SortDirection direction;

  Map<String, Object?> toJson() => {
        'field': field,
        'direction': direction == SortDirection.asc ? 'asc' : 'desc',
      };
}

// ---------------------------------------------------------------------------
// CursorSpec
// ---------------------------------------------------------------------------

/// Cursor for start/end pagination bounds (PROTOCOL §4.5).
class CursorSpec {
  const CursorSpec(this.values, {required this.before});

  final List<Value> values;

  /// `true` → startAt / endBefore; `false` → startAfter / endAt.
  final bool before;

  Map<String, Object?> toJson() => {
        'values': [for (final v in values) v.toJson()],
        'before': before,
      };
}

// ---------------------------------------------------------------------------
// QuerySpec
// ---------------------------------------------------------------------------

/// Immutable query specification (PROTOCOL §4.1).
///
/// Produces the wire JSON object sent as the `query` payload in the `query`,
/// `count`, `aggregate`, `listen`, and `tx.query` WebSocket frames.
class QuerySpec {
  const QuerySpec(
    this.collection, {
    this.where,
    this.orderBy,
    this.limit,
    this.offset,
    this.limitToLast,
    this.select,
    this.start,
    this.end,
  });

  final String collection;
  final FilterSpec? where;
  final List<OrderSpec>? orderBy;
  final int? limit;

  /// Number of leading results to skip (PROTOCOL §4.1). Composes with [limit];
  /// cannot be combined with [limitToLast].
  final int? offset;

  /// Returns only the last N of the result window (PROTOCOL §4.1). Requires at
  /// least one [orderBy] and cannot be combined with [limit] or [offset];
  /// results stay in the orderBy ascending order.
  final int? limitToLast;
  final List<String>? select;
  final CursorSpec? start;
  final CursorSpec? end;

  /// Enforces the limit/offset/limitToLast invariants (PROTOCOL §4.1),
  /// throwing [ArgumentError] on violation — mirrors the server's
  /// `INVALID_ARGUMENT`. Called before every send and local evaluation.
  void validate() {
    if (limitToLast != null) {
      if (limit != null) {
        throw ArgumentError('limit and limitToLast are mutually exclusive.');
      }
      if (offset != null) {
        throw ArgumentError('offset cannot be combined with limitToLast.');
      }
      if (orderBy == null || orderBy!.isEmpty) {
        throw ArgumentError('limitToLast requires at least one orderBy.');
      }
    }
  }

  Map<String, Object?> toJson() {
    validate();
    final map = <String, Object?>{'collection': collection};
    if (where != null) map['where'] = where!.toJson();
    if (orderBy != null) {
      map['orderBy'] = [for (final o in orderBy!) o.toJson()];
    }
    if (limit != null) map['limit'] = limit;
    if (offset != null) map['offset'] = offset;
    if (limitToLast != null) map['limitToLast'] = limitToLast;
    if (start != null) map['start'] = start!.toJson();
    if (end != null) map['end'] = end!.toJson();
    return map;
  }

  QuerySpec copyWith({
    FilterSpec? where,
    List<OrderSpec>? orderBy,
    int? limit,
    int? offset,
    int? limitToLast,
    List<String>? select,
    CursorSpec? start,
    CursorSpec? end,
  }) =>
      QuerySpec(
        collection,
        where: where ?? this.where,
        orderBy: orderBy ?? this.orderBy,
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
        limitToLast: limitToLast ?? this.limitToLast,
        select: select ?? this.select,
        start: start ?? this.start,
        end: end ?? this.end,
      );
}
