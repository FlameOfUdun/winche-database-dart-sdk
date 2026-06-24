/// The kind of an aggregation in an `aggregate` request.
enum AggregateKind { count, sum, average }

/// One aggregation over a query: a [kind], a result [alias] (the key under
/// which the server returns the value), and a [field] (required for sum and
/// average, null for count).
class Aggregate {
  final AggregateKind kind;
  final String alias;
  final String? field;

  const Aggregate._(this.kind, this.alias, this.field);

  /// Counts matching documents.
  factory Aggregate.count({required String alias}) =>
      Aggregate._(AggregateKind.count, alias, null);

  /// Sums [field] across matching documents.
  factory Aggregate.sum(String field, {required String alias}) =>
      Aggregate._(AggregateKind.sum, alias, field);

  /// Averages [field] across matching documents.
  factory Aggregate.average(String field, {required String alias}) =>
      Aggregate._(AggregateKind.average, alias, field);

  /// The wire form `{kind, alias, field?}`. `kind.name` yields the exact
  /// tokens the server expects: `count` | `sum` | `average`.
  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'alias': alias,
        if (field != null) 'field': field,
      };
}
