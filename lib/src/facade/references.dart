part of '../../winche_database.dart';

/// Generates a 32-character random document ID.
/// Alphabet: [A-Za-z0-9] (62 chars).
String _generateId() {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  return String.fromCharCodes(
    Iterable.generate(32, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
  );
}

/// A reference to a single document in the Winche Database.
final class DocumentReference<T> {
  DocumentReference._(this._db, this.path, this._converter);

  final WincheDatabase _db;
  final Converter<T> _converter;
  final String path;

  /// The document ID.
  String get id => docId(path);

  /// Returns a typed reference that converts document data to and from [R].
  DocumentReference<R> withConverter<R>(Converter<R> converter) {
    return DocumentReference<R>._(_db, path, converter);
  }

  /// The parent [CollectionReference] (carries the same converter).
  CollectionReference<T> get parent {
    final parentPath = parentOf(path);
    if (parentPath == null) {
      throw StateError('Document "$path" has no parent collection.');
    }
    return CollectionReference<T>._(_db, parentPath, _converter);
  }

  /// Returns a raw (map-typed) reference to a sub-collection named [name].
  CollectionReference<Map<String, Object?>> collection(String name) {
    return CollectionReference<Map<String, Object?>>._(
        _db, '$path/$name', Converter._identity);
  }

  /// Fetches the document once (from cache when offline).
  Future<DocumentSnapshot<T>> get(
      [GetOptions options = const GetOptions()]) async {
    final result = await _db.reads.getDocument(path, options);
    return _db._snapshotFrom(this, result);
  }

  /// Replaces or deep-merges the document with [data].
  ///
  /// If [merge] is true, performs a deep-merge instead of a full replace.
  Future<WriteResult> set(
    T data, {
    bool merge = false,
    Precondition? precondition,
  }) async {
    final write = stageSet(path, _converter.toMap(data),
        merge: merge, precondition: precondition);
    final results = await _db.writes.applyWrites([write]);
    return WriteResult.fromJson(results[0], _db.doc);
  }

  /// Patches individual fields on the document using [data].
  ///
  /// Top-level dotted keys (e.g. `'a.b': value`) are valid field paths.
  /// Nested [FieldValue.delete] sentinels inside a map value are illegal —
  /// use a top-level dotted key instead.
  Future<WriteResult> update(
    Map<String, Object?> data, {
    Precondition? precondition,
  }) async {
    final write = stageUpdate(path, data, precondition: precondition);
    final results = await _db.writes.applyWrites([write]);
    return WriteResult.fromJson(results[0], _db.doc);
  }

  /// Deletes the document.
  Future<WriteResult> delete({
    bool cascade = false,
    Precondition? precondition,
  }) async {
    final write =
        stageDelete(path, cascade: cascade, precondition: precondition);
    final results = await _db.writes.applyWrites([write]);
    return WriteResult.fromJson(results[0], _db.doc);
  }

  /// Returns a [Stream] that emits a [DocumentSnapshot] whenever the document
  /// changes.
  ///
  /// Backed by the dedicated `doc.listen` server subscription, with pending
  /// local writes overlaid for latency compensation. Emits a non-existent
  /// snapshot when the document is absent.
  Stream<DocumentSnapshot<T>> snapshots() => _LiveDocument<T>(_db, this).stream();

  @override
  String toString() => 'DocumentReference($path)';
}

/// A reference to a collection of documents in the Winche Database.
///
/// A [CollectionReference] is also a [QueryReference] over the whole
/// collection, so query builders (`where`, `orderBy`, `limit`, cursors) and
/// terminal operations (`get`, `snapshots`, `count`) are available directly:
///
/// ```dart
/// db.collection('users').where('age', isGreaterThan: 18).orderBy('age').get();
/// ```
final class CollectionReference<T> extends QueryReference<T> {
  CollectionReference._(WincheDatabase db, String path, Converter<T> converter)
      : super._(db, path, QuerySpec(path), converter);

  /// The full collection path, e.g. `users` or `users/u1/posts`.
  String get path => _collection;

  /// The collection ID (the last path segment).
  String get id => docId(_collection);

  /// Returns a typed collection that converts document data to and from [R].
  @override
  CollectionReference<R> withConverter<R>(Converter<R> converter) {
    return CollectionReference<R>._(_db, _collection, converter);
  }

  /// Returns a reference to the document with the given [id]
  /// (carries this collection's converter).
  ///
  /// If [id] is null or empty, a random 32-character ID is generated.
  DocumentReference<T> doc([String? id]) {
    final docId = (id == null || id.isEmpty) ? _generateId() : id;
    return DocumentReference<T>._(_db, '$_collection/$docId', _converter);
  }

  /// Adds a new document with [data] and a generated ID.
  ///
  /// Returns the [DocumentReference] for the new document.
  Future<DocumentReference<T>> add(T data) async {
    final ref = doc();
    await ref.set(data);
    return ref;
  }

  @override
  String toString() => 'CollectionReference($_collection)';
}

/// An immutable, composable query over a collection.
final class QueryReference<T> {
  QueryReference._(this._db, this._collection, this._spec, this._converter);

  final WincheDatabase _db;
  final String _collection;
  final QuerySpec _spec;
  final Converter<T> _converter;

  /// Returns a typed query that converts document data to and from [R].
  QueryReference<R> withConverter<R>(Converter<R> converter) {
    return QueryReference<R>._(_db, _collection, _spec, converter);
  }

  /// Adds a field filter. Multiple calls AND-compose.
  /// Multiple named args in a single call also AND-compose (I4).
  QueryReference<T> where(
    String field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    List<Object?>? arrayContainsAny,
    List<Object?>? arrayContainsAll,
    List<Object?>? whereIn,
    List<Object?>? whereNotIn,
    Object? contains,
    Object? startsWith,
    Object? endsWith,
    Object? matchesRegex,
    bool? isNull,
    bool? isNan,
    bool? exists,
  }) {
    final newFilters = <FilterSpec>[];

    if (isEqualTo != null) {
      newFilters.add(FilterSpec.field(field, FieldOp.eq, toValue(isEqualTo)));
    }
    if (isNotEqualTo != null) {
      newFilters
          .add(FilterSpec.field(field, FieldOp.ne, toValue(isNotEqualTo)));
    }
    if (isLessThan != null) {
      newFilters.add(FilterSpec.field(field, FieldOp.lt, toValue(isLessThan)));
    }
    if (isLessThanOrEqualTo != null) {
      newFilters.add(
          FilterSpec.field(field, FieldOp.lte, toValue(isLessThanOrEqualTo)));
    }
    if (isGreaterThan != null) {
      newFilters
          .add(FilterSpec.field(field, FieldOp.gt, toValue(isGreaterThan)));
    }
    if (isGreaterThanOrEqualTo != null) {
      newFilters.add(FilterSpec.field(
          field, FieldOp.gte, toValue(isGreaterThanOrEqualTo)));
    }
    if (arrayContains != null) {
      newFilters.add(FilterSpec.field(
          field, FieldOp.arrayContains, toValue(arrayContains)));
    }
    if (arrayContainsAny != null) {
      newFilters.add(FilterSpec.field(
        field,
        FieldOp.arrayContainsAny,
        ArrayValue([for (final v in arrayContainsAny) toValue(v)]),
      ));
    }
    if (arrayContainsAll != null) {
      newFilters.add(FilterSpec.field(
        field,
        FieldOp.arrayContainsAll,
        ArrayValue([for (final v in arrayContainsAll) toValue(v)]),
      ));
    }
    if (whereIn != null) {
      newFilters.add(FilterSpec.field(
        field,
        FieldOp.inOp,
        ArrayValue([for (final v in whereIn) toValue(v)]),
      ));
    }
    if (whereNotIn != null) {
      newFilters.add(FilterSpec.field(
        field,
        FieldOp.notIn,
        ArrayValue([for (final v in whereNotIn) toValue(v)]),
      ));
    }
    if (contains != null) {
      newFilters
          .add(FilterSpec.field(field, FieldOp.contains, toValue(contains)));
    }
    if (startsWith != null) {
      newFilters.add(
          FilterSpec.field(field, FieldOp.startsWith, toValue(startsWith)));
    }
    if (endsWith != null) {
      newFilters
          .add(FilterSpec.field(field, FieldOp.endsWith, toValue(endsWith)));
    }
    if (matchesRegex != null) {
      newFilters
          .add(FilterSpec.field(field, FieldOp.regex, toValue(matchesRegex)));
    }
    if (isNull != null) {
      final f = FilterSpec.unary(field, UnaryOp.isNull);
      newFilters.add(isNull ? f : FilterSpec.not(f));
    }
    if (isNan != null) {
      final f = FilterSpec.unary(field, UnaryOp.isNan);
      newFilters.add(isNan ? f : FilterSpec.not(f));
    }
    if (exists != null) {
      final f = FilterSpec.unary(field, UnaryOp.exists);
      newFilters.add(exists ? f : FilterSpec.not(f));
    }

    if (newFilters.isEmpty) return this;

    // AND-compose all new filters from this call, then AND with any existing.
    FilterSpec combined = newFilters[0];
    for (var i = 1; i < newFilters.length; i++) {
      combined = FilterSpec.and([combined, newFilters[i]]);
    }
    return _withFilter(_andFilter(_spec.where, combined));
  }

  /// Adds a raw [FilterSpec] filter (escape hatch). AND-composed with existing.
  QueryReference<T> whereFilter(FilterSpec filter) {
    return _withFilter(_andFilter(_spec.where, filter));
  }

  /// Adds an orderBy clause.
  QueryReference<T> orderBy(String field, {bool descending = false}) {
    final order = OrderSpec(
      field,
      direction: descending ? SortDirection.desc : SortDirection.asc,
    );
    final existing = _spec.orderBy ?? [];
    return _withSpec(_spec.copyWith(orderBy: [...existing, order]));
  }

  /// Sets the maximum number of documents returned.
  QueryReference<T> limit(int n) {
    return _withSpec(_spec.copyWith(limit: n));
  }

  /// Restricts returned documents to [fields] (dotted paths). Document id,
  /// path, and metadata are always included.
  QueryReference<T> select(List<String> fields) =>
      _withSpec(_spec.copyWith(select: List<String>.from(fields)));

  /// Starts the query at [values] (inclusive).
  QueryReference<T> startAt(List<Object?> values) {
    return _withSpec(_spec.copyWith(
      start: CursorSpec([for (final v in values) toValue(v)], before: true),
    ));
  }

  /// Starts the query after [values] (exclusive).
  QueryReference<T> startAfter(List<Object?> values) {
    return _withSpec(_spec.copyWith(
      start: CursorSpec([for (final v in values) toValue(v)], before: false),
    ));
  }

  /// Ends the query at [values] (inclusive).
  QueryReference<T> endAt(List<Object?> values) {
    return _withSpec(_spec.copyWith(
      end: CursorSpec([for (final v in values) toValue(v)], before: false),
    ));
  }

  /// Ends the query before [values] (exclusive).
  QueryReference<T> endBefore(List<Object?> values) {
    return _withSpec(_spec.copyWith(
      end: CursorSpec([for (final v in values) toValue(v)], before: true),
    ));
  }

  /// Executes the query and returns a one-shot [QuerySnapshot] (from cache when
  /// offline).
  Future<QuerySnapshot<T>> get(
      [GetOptions options = const GetOptions()]) async {
    final result = await _db.reads.runQuery(_spec, options);
    final docs = [
      for (final wire in result.documents)
        DocumentSnapshot<T>._fromWire(
            _db.doc(wire.path).withConverter(_converter), wire,
            metadata: SnapshotMetadata(
                fromCache: result.fromCache,
                hasPendingWrites: result.hasPendingWrites)),
    ];
    final changes = [
      for (var i = 0; i < docs.length; i++)
        DocumentChange<T>(
          type: DocumentChangeType.added,
          oldIndex: -1,
          newIndex: i,
          doc: docs[i],
        ),
    ];
    return QuerySnapshot<T>(
      docs: List.unmodifiable(docs),
      docChanges: changes,
      readTime: DateTime.now().toUtc(),
      resumeToken: null,
      hasMore: result.hasMore,
      metadata: SnapshotMetadata(
          fromCache: result.fromCache,
          hasPendingWrites: result.hasPendingWrites),
    );
  }

  /// Returns a live [Stream] of [QuerySnapshot]s (PROTOCOL §7.6).
  /// When offline support is configured, emits cache-first and reacts to local
  /// writes; otherwise delegates directly to the server-only machine.
  Stream<QuerySnapshot<T>> snapshots() {
    return _LiveQuery<T>(_db, _spec, _converter).stream();
  }

  /// Returns the number of documents matching this query.
  ///
  /// Sent as a `count` request. The server authorizes it as a `list` operation
  /// and returns `{"count": N}`. `limit` is honored by the server (it caps the
  /// count); cursors are not supported for counting.
  Future<int> count() async {
    if (_spec.start != null || _spec.end != null) {
      throw UnsupportedError(
        'count() does not support cursor constraints. '
        'Remove startAt(), startAfter(), endAt(), and endBefore() before count().',
      );
    }
    final result = await _db._transport.request(countFrame('', _spec));
    final n = result['count'];
    return n is num ? n.toInt() : 0;
  }

  /// Runs server-side [aggregations] over this query, returning a map keyed by
  /// each aggregation's `alias`.
  ///
  /// Server-only, like [count]: bypasses the local cache, requires a live
  /// connection (throws when offline), honors `where`/`orderBy`/`limit`, and
  /// rejects cursor constraints.
  Future<Map<String, Object?>> aggregate(List<Aggregate> aggregations) async {
    if (aggregations.isEmpty) {
      throw ArgumentError('aggregate() requires at least one aggregation.');
    }
    if (_spec.start != null || _spec.end != null) {
      throw UnsupportedError(
        'aggregate() does not support cursor constraints. '
        'Remove startAt(), startAfter(), endAt(), and endBefore() before aggregate().',
      );
    }
    final result = await _db._transport.request(
        aggregateFrame('', _spec, [for (final a in aggregations) a.toJson()]));
    final body = (result['result'] as Map).cast<String, Object?>();
    return {
      for (final e in body.entries) e.key: fromValue(Value.fromJson(e.value)),
    };
  }

  /// Sums [field] over matching documents (server-side). Returns `0` for an
  /// empty result. Shorthand for a single-aggregation [aggregate].
  Future<num> sum(String field) async {
    final r = await aggregate([Aggregate.sum(field, alias: r'$value')]);
    return (r[r'$value'] as num?) ?? 0;
  }

  /// Averages [field] over matching documents (server-side). Returns `null` for
  /// an empty result. Shorthand for a single-aggregation [aggregate].
  Future<num?> average(String field) async {
    final r = await aggregate([Aggregate.average(field, alias: r'$value')]);
    return r[r'$value'] as num?;
  }

  /// The underlying [QuerySpec] (for testing and listener use).
  QuerySpec get spec => _spec;

  QueryReference<T> _withSpec(QuerySpec spec) {
    return QueryReference<T>._(_db, _collection, spec, _converter);
  }

  QueryReference<T> _withFilter(FilterSpec filter) {
    return _withSpec(_spec.copyWith(where: filter));
  }

  FilterSpec _andFilter(FilterSpec? existing, FilterSpec newFilter) {
    if (existing == null) return newFilter;
    return FilterSpec.and([existing, newFilter]);
  }
}
