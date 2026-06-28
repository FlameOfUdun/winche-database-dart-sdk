import '../core/value_order.dart';
import '../core/values.dart';
import '../protocol/messages.dart';
import '../protocol/query_spec.dart';
import 'filter_eval.dart';

/// One resolved sort key (field + direction), including the implicit `__name__`
/// tiebreaker.
class _OrderKey {
  const _OrderKey(this.field, this.descending);
  final String field;
  final bool descending;
}

/// Evaluates a [QuerySpec] over an in-memory document set, matching server
/// query semantics (PROTOCOL §4). Pure: callers supply the candidate documents
/// (e.g. effective views from the cache).
class LocalQueryEngine {
  const LocalQueryEngine();

  List<WireDocument> runQuery(QuerySpec spec, Iterable<WireDocument> docs) {
    spec.validate();
    final keys = _orderKeys(spec);

    // 1. where filter.
    var result = <WireDocument>[
      for (final doc in docs)
        if (spec.where == null || matchesFilter(doc, spec.where!.toJson())) doc,
    ];

    // 2. Implicit exists filter for every ordered field (PROTOCOL §4.4):
    //    documents missing an ordered field are excluded.
    for (final key in keys) {
      result = [
        for (final doc in result)
          if (resolveField(doc, key.field) != null) doc,
      ];
    }

    // 3. Sort by the ordered keys (tiebroken by __name__).
    result.sort((a, b) => _compareByKeys(a, b, keys));

    // 4. Cursors.
    if (spec.start != null) {
      result = [
        for (final doc in result)
          if (_passesStart(doc, spec.start!, keys)) doc,
      ];
    }
    if (spec.end != null) {
      result = [
        for (final doc in result)
          if (_passesEnd(doc, spec.end!, keys)) doc,
      ];
    }

    // 5. Offset: skip the first N (after cursors, before limit). PROTOCOL §4.1.
    if (spec.offset != null && spec.offset! > 0) {
      result = spec.offset! >= result.length
          ? <WireDocument>[]
          : result.sublist(spec.offset!);
    }

    // 6. Limit / limitToLast. limitToLast takes the last N of the ascending
    //    order (results are already sorted ascending) and keeps that order.
    if (spec.limitToLast != null) {
      if (result.length > spec.limitToLast!) {
        result = result.sublist(result.length - spec.limitToLast!);
      }
    } else if (spec.limit != null && result.length > spec.limit!) {
      result = result.sublist(0, spec.limit!);
    }
    return result;
  }

  /// Explicit orderBy keys plus the implicit `__name__` tiebreaker. When there
  /// are no explicit keys, results are ordered by `__name__` ascending.
  List<_OrderKey> _orderKeys(QuerySpec spec) {
    final explicit = spec.orderBy ?? const <OrderSpec>[];
    final keys = [
      for (final o in explicit)
        _OrderKey(o.field, o.direction == SortDirection.desc),
    ];
    final tiebreakDesc = keys.isNotEmpty ? keys.last.descending : false;
    keys.add(_OrderKey('__name__', tiebreakDesc));
    return keys;
  }

  int _compareByKeys(WireDocument a, WireDocument b, List<_OrderKey> keys) {
    for (final key in keys) {
      final va = resolveField(a, key.field);
      final vb = resolveField(b, key.field);
      // Ordered fields are guaranteed present by the implicit-exists step,
      // except __name__ which always resolves.
      var c = compareValues(va!, vb!);
      if (key.descending) c = -c;
      if (c != 0) return c;
    }
    return 0;
  }

  /// Directional comparison of [doc] against a cursor [values] prefix.
  int _compareCursor(
      WireDocument doc, List<Value> values, List<_OrderKey> keys) {
    for (var i = 0; i < values.length; i++) {
      final dv = resolveField(doc, keys[i].field);
      if (dv == null) return -1;
      var c = compareValues(dv, values[i]);
      if (keys[i].descending) c = -c;
      if (c != 0) return c;
    }
    return 0;
  }

  bool _passesStart(WireDocument doc, CursorSpec start, List<_OrderKey> keys) {
    final cmp = _compareCursor(doc, start.values, keys);
    // before:true → startAt (inclusive, doc >= cursor);
    // before:false → startAfter (exclusive, doc > cursor).
    return start.before ? cmp >= 0 : cmp > 0;
  }

  bool _passesEnd(WireDocument doc, CursorSpec end, List<_OrderKey> keys) {
    final cmp = _compareCursor(doc, end.values, keys);
    // before:true → endBefore (exclusive, doc < cursor);
    // before:false → endAt (inclusive, doc <= cursor).
    return end.before ? cmp < 0 : cmp <= 0;
  }
}
