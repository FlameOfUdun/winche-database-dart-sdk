part of '../../winche_database.dart';

/// Sentinel values for write operations.
///
/// Use the named constructors / factory methods to create sentinels:
/// - [FieldValue.delete] — removes the field from the document.
/// - [FieldValue.serverTimestamp] — sets the field to the server commit time.
/// - [FieldValue.increment] / [FieldValue.maximum] / [FieldValue.minimum] —
///   numeric transforms.
/// - [FieldValue.arrayUnion] / [FieldValue.arrayRemove] — array membership
///   transforms.
sealed class FieldValue {
  const FieldValue._();

  /// Removes a field from the document.
  factory FieldValue.delete() => const DeleteSentinel();

  /// Sets the field to the server commit timestamp.
  factory FieldValue.serverTimestamp() => const ServerTimestampSentinel();

  /// Atomically increments the field by [delta].
  factory FieldValue.increment(num delta) => IncrementSentinel(delta);

  /// Sets the field to the larger of its current value and [value].
  factory FieldValue.maximum(num value) => MaximumSentinel(value);

  /// Sets the field to the smaller of its current value and [value].
  factory FieldValue.minimum(num value) => MinimumSentinel(value);

  /// Adds elements from [values] that are not already in the array.
  factory FieldValue.arrayUnion(List<Object?> values) =>
      ArrayUnionSentinel(values);

  /// Removes all occurrences of elements in [values] from the array.
  factory FieldValue.arrayRemove(List<Object?> values) =>
      ArrayRemoveSentinel(values);
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class DeleteSentinel extends FieldValue {
  const DeleteSentinel() : super._();

  @override
  String toString() => 'FieldValue.delete()';
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class ServerTimestampSentinel extends FieldValue {
  const ServerTimestampSentinel() : super._();

  @override
  String toString() => 'FieldValue.serverTimestamp()';
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class IncrementSentinel extends FieldValue {
  const IncrementSentinel(this.delta) : super._();
  final num delta;

  @override
  String toString() => 'FieldValue.increment($delta)';
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class MaximumSentinel extends FieldValue {
  const MaximumSentinel(this.value) : super._();
  final num value;

  @override
  String toString() => 'FieldValue.maximum($value)';
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class MinimumSentinel extends FieldValue {
  const MinimumSentinel(this.value) : super._();
  final num value;

  @override
  String toString() => 'FieldValue.minimum($value)';
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class ArrayUnionSentinel extends FieldValue {
  const ArrayUnionSentinel(this.values) : super._();
  final List<Object?> values;

  @override
  String toString() => 'FieldValue.arrayUnion($values)';
}

/// Internal sentinel class exposed for pattern-matching in converters.
final class ArrayRemoveSentinel extends FieldValue {
  const ArrayRemoveSentinel(this.values) : super._();
  final List<Object?> values;

  @override
  String toString() => 'FieldValue.arrayRemove($values)';
}
