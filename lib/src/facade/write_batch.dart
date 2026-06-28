part of '../../winche_database.dart';

// ---------------------------------------------------------------------------
// WriteBatch
// ---------------------------------------------------------------------------

/// Accumulates multiple write operations and commits them atomically.
///
/// Obtain via [WincheDatabase.batch].
final class WriteBatch {
  WriteBatch(this._db);

  final WincheDatabase _db;
  final List<Write> _writes = [];

  /// Stages a set (replace or merge) operation.
  void set<T>(
    DocumentReference<T> ref,
    T data, {
    bool merge = false,
    List<String>? mergeFields,
    Precondition? precondition,
  }) {
    _writes.add(stageSet(ref.path, ref._converter.toMap(data),
        merge: merge, mergeFields: mergeFields, precondition: precondition));
  }

  /// Stages an update (patch) operation.
  ///
  /// Top-level dotted keys are valid field paths. Nested [FieldValue.delete]
  /// sentinels inside a map value are illegal — use a top-level dotted key.
  void update<T>(
    DocumentReference<T> ref,
    Map<String, Object?> data, {
    Precondition? precondition,
  }) {
    _writes.add(stageUpdate(ref.path, data, precondition: precondition));
  }

  /// Stages a delete operation.
  void delete<T>(
    DocumentReference<T> ref, {
    bool cascade = false,
    Precondition? precondition,
  }) {
    _writes.add(
        stageDelete(ref.path, cascade: cascade, precondition: precondition));
  }

  /// Commits all staged writes atomically.
  ///
  /// Returns the [WriteResult] for each staged write, in order.
  Future<List<WriteResult>> commit() async {
    final results = await _db.writes.applyWrites(_writes);
    return [for (final r in results) WriteResult.fromJson(r, _db.doc)];
  }
}
