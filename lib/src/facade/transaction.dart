part of '../../winche_database.dart';

/// A database transaction handler object.
///
/// Obtained by the handler argument of [WincheDatabase.runTransaction].
///
/// **Reads must precede writes.** Calling a read method after a write method
/// has been staged throws [StateError].
///
/// **Read-only transactions:** if no writes are staged, [runTransaction]
/// sends `tx.rollback` instead of `tx.commit` (the server requires ≥1 write
/// in a `tx.commit`). The handler result is still returned.
final class Transaction {
  Transaction._(this._db, this._transactionId);

  final WincheDatabase _db;
  final String _transactionId;

  final List<Write> _writes = [];
  bool _writesStarted = false;

  /// Reads a single document within the transaction.
  Future<DocumentSnapshot<T>> get<T>(DocumentReference<T> ref) {
    _assertNoWrites('get');
    return _txGet(ref);
  }

  /// Executes a query within the transaction.
  Future<List<DocumentSnapshot<T>>> query<T>(QueryReference<T> q) {
    _assertNoWrites('query');
    return _txQuery(q);
  }

  /// Stages a set operation.
  void set<T>(
    DocumentReference<T> ref,
    Map<String, Object?> data, {
    bool merge = false,
    Precondition? precondition,
  }) {
    _writesStarted = true;
    _writes.add(
        stageSet(ref.path, data, merge: merge, precondition: precondition));
  }

  /// Stages an update operation.
  ///
  /// Top-level dotted keys are valid field paths. Nested [FieldValue.delete]
  /// sentinels inside a map value are illegal — use a top-level dotted key.
  void update<T>(
    DocumentReference<T> ref,
    Map<String, Object?> data, {
    Precondition? precondition,
  }) {
    _writesStarted = true;
    _writes.add(stageUpdate(ref.path, data, precondition: precondition));
  }

  /// Stages a delete operation.
  void delete<T>(
    DocumentReference<T> ref, {
    bool cascade = false,
    Precondition? precondition,
  }) {
    _writesStarted = true;
    _writes.add(
        stageDelete(ref.path, cascade: cascade, precondition: precondition));
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _assertNoWrites(String operation) {
    if (_writesStarted) {
      throw StateError(
        'Cannot perform a read ("$operation") after writes have been staged '
        'in a transaction. Reads must precede writes.',
      );
    }
  }

  Future<DocumentSnapshot<T>> _txGet<T>(DocumentReference<T> docRef) async {
    final result = await _db._transport
        .request(txGetFrame('', _transactionId, docRef.path));
    final wire = WireDocument.fromAny(result['document']);
    if (wire == null) return DocumentSnapshot._missing(docRef);
    return DocumentSnapshot._fromWire(docRef, wire);
  }

  Future<List<DocumentSnapshot<T>>> _txQuery<T>(
      QueryReference<T> queryRef) async {
    final result = await _db._transport
        .request(txQueryFrame('', _transactionId, queryRef.spec));
    final docsRaw = result['documents'] as List<Object?>? ?? [];
    return [
      for (final d in docsRaw)
        () {
          final raw = d as Map<String, Object?>;
          final wire0 = WireDocument.fromJson(raw);
          final wire = queryRef.spec.select == null
              ? wire0
              : projectFields(wire0, queryRef.spec.select!);
          final ref = _db.doc(wire.path).withConverter(queryRef._converter);
          return DocumentSnapshot._fromWire(ref, wire);
        }(),
    ];
  }

  /// Commits buffered writes.
  Future<List<WriteResult>> _commit() async {
    final result = await _db._transport
        .request(txCommitFrame('', _transactionId, _writes));
    final raw = result['writeResults'] as List<Object?>? ?? [];
    return [
      for (final r in raw)
        WriteResult.fromJson(r as Map<String, Object?>, _db.doc),
    ];
  }

  /// Rolls back the transaction.
  Future<void> _rollback() async {
    await _db._transport.request(txRollbackFrame('', _transactionId));
  }
}
