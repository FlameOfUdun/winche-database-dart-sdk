/// Winche Database exceptions for all error status codes (PROTOCOL §5.1).
library;

/// Base exception for all Winche Database errors.
///
/// [status] is one of the PROTOCOL §5.1 status strings.
/// [message] is the human-readable description.
/// [details] is an optional map with additional context (e.g. jsonPath, code).
class WincheException implements Exception {
  const WincheException(this.status, this.message, [this.details]);

  final String status;
  final String message;
  final Map<String, Object?>? details;

  /// Factory that returns the most specific subclass for the given [status].
  factory WincheException.fromError(
    String status,
    String message, [
    Map<String, Object?>? details,
  ]) {
    return switch (status) {
      'ABORTED' => AbortedException(message, details),
      'PERMISSION_DENIED' => PermissionDeniedException(message, details),
      'UNAUTHENTICATED' => UnauthenticatedException(message, details),
      'INVALID_QUERY' => InvalidQueryException(message, details),
      'INVALID_ARGUMENT' => InvalidArgumentException(message, details),
      'NOT_FOUND' => NotFoundException(message, details),
      'ALREADY_EXISTS' => AlreadyExistsException(message, details),
      'FAILED_PRECONDITION' => FailedPreconditionException(message, details),
      'DEADLINE_EXCEEDED' => DeadlineExceededException(message, details),
      'INTERNAL' => InternalException(message, details),
      'UNAVAILABLE' => UnavailableException(message, details),
      _ => WincheException(status, message, details),
    };
  }

  @override
  String toString() => 'WincheException($status): $message';
}

/// `ABORTED` — transaction conflict, expired, or unknown transaction id.
class AbortedException extends WincheException {
  const AbortedException(String message, [Map<String, Object?>? details])
      : super('ABORTED', message, details);

  @override
  String toString() => 'AbortedException: $message';
}

/// `PERMISSION_DENIED` — access rule denied the operation.
class PermissionDeniedException extends WincheException {
  const PermissionDeniedException(String message,
      [Map<String, Object?>? details])
      : super('PERMISSION_DENIED', message, details);

  @override
  String toString() => 'PermissionDeniedException: $message';
}

/// `UNAUTHENTICATED` — authentication token invalid or missing.
class UnauthenticatedException extends WincheException {
  const UnauthenticatedException(String message,
      [Map<String, Object?>? details])
      : super('UNAUTHENTICATED', message, details);

  @override
  String toString() => 'UnauthenticatedException: $message';
}

/// `INVALID_QUERY` — query or pipeline parse / validation error.
///
/// For JSON parse errors, [jsonPath] contains the path (from `details.jsonPath`).
/// For plan-validation failures, [code] contains the validation code
/// (from `details.code`).
class InvalidQueryException extends WincheException {
  const InvalidQueryException(String message, [Map<String, Object?>? details])
      : super('INVALID_QUERY', message, details);

  /// JSON path of the parse error, if available (e.g. `"$.where.op"`).
  String? get jsonPath => details?['jsonPath'] as String?;

  /// Validation code for plan-validation failures
  /// (e.g. `"ORDERBY_FIELD_NOT_FILTERED"`).
  String? get code => details?['code'] as String?;

  @override
  String toString() => 'InvalidQueryException: $message';
}

/// `INVALID_ARGUMENT` — malformed request, bad field types, batch size
/// exceeded, or an invalid write shape.
class InvalidArgumentException extends WincheException {
  const InvalidArgumentException(String message,
      [Map<String, Object?>? details])
      : super('INVALID_ARGUMENT', message, details);

  @override
  String toString() => 'InvalidArgumentException: $message';
}

/// `NOT_FOUND` — an `UpdateWrite` or `exists: true` precondition targeted a
/// document that does not exist.
class NotFoundException extends WincheException {
  const NotFoundException(String message, [Map<String, Object?>? details])
      : super('NOT_FOUND', message, details);

  @override
  String toString() => 'NotFoundException: $message';
}

/// `ALREADY_EXISTS` — an `exists: false` precondition targeted an existing
/// document.
class AlreadyExistsException extends WincheException {
  const AlreadyExistsException(String message, [Map<String, Object?>? details])
      : super('ALREADY_EXISTS', message, details);

  @override
  String toString() => 'AlreadyExistsException: $message';
}

/// `FAILED_PRECONDITION` — an `updateTime` precondition did not match.
class FailedPreconditionException extends WincheException {
  const FailedPreconditionException(String message,
      [Map<String, Object?>? details])
      : super('FAILED_PRECONDITION', message, details);

  @override
  String toString() => 'FailedPreconditionException: $message';
}

/// `DEADLINE_EXCEEDED` — the operation timed out on the server.
class DeadlineExceededException extends WincheException {
  const DeadlineExceededException(String message,
      [Map<String, Object?>? details])
      : super('DEADLINE_EXCEEDED', message, details);

  @override
  String toString() => 'DeadlineExceededException: $message';
}

/// `INTERNAL` — an unexpected server error (always a bug; report it).
class InternalException extends WincheException {
  const InternalException(String message, [Map<String, Object?>? details])
      : super('INTERNAL', message, details);

  @override
  String toString() => 'InternalException: $message';
}

/// `UNAVAILABLE` — client-side status indicating the server is unreachable,
/// the WebSocket was disconnected, or the response body could not be parsed.
///
/// This status is **client-generated** and does not appear in the PROTOCOL
/// status vocabulary; it is used by [ProtocolConnection]
/// to signal transport-level failures.
class UnavailableException extends WincheException {
  const UnavailableException(String message, [Map<String, Object?>? details])
      : super('UNAVAILABLE', message, details);

  @override
  String toString() => 'UnavailableException: $message';
}
