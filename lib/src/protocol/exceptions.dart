// The per-kind subclasses are deprecated for callers, but the database still throws them for one release so
// existing catches keep working.
// ignore_for_file: deprecated_member_use_from_same_package

/// Winche Database exceptions (PROTOCOL §5).
library;

import 'package:winche_core/winche_core.dart';

/// A database request failed.
///
/// [code] is the kind every Winche package shares; switch on it. [reason] is
/// the server's more precise code where it sent one (`invalid-query` for a
/// query that doesn't parse or validate), and [details] anything else it sent
/// (`jsonPath`, a plan-validation `code`, an `errorId`).
///
/// `on WincheException` asks "did any Winche SDK fail?"; `on
/// WincheDatabaseException` asks "did the database?". A client-side lifecycle
/// failure such as [WincheUnboundException] is neither.
class WincheDatabaseException extends WincheException {
  /// Creates an exception. The database itself throws through [of].
  const WincheDatabaseException(super.code, super.message, {this.reason, this.details});

  /// The reason a query was refused: [WincheErrorCode.invalidArgument] with this.
  static const invalidQuery = 'invalid-query';

  /// The server's more precise code, when it sent one.
  final String? reason;

  /// What else the server sent, if anything.
  final Map<String, Object?>? details;

  /// An exception of kind [code]: for this release, the deprecated subclass for
  /// that kind when there is one, so catches on those keep working.
  factory WincheDatabaseException.of(WincheErrorCode code, String message, {String? reason, Map<String, Object?>? details}) =>
      switch (code) {
        WincheErrorCode.invalidArgument when reason == invalidQuery => InvalidQueryException(message, details),
        WincheErrorCode.invalidArgument => InvalidArgumentException(message, details, reason),
        WincheErrorCode.aborted => AbortedException(message, details, reason),
        WincheErrorCode.permissionDenied => PermissionDeniedException(message, details, reason),
        WincheErrorCode.unauthenticated => UnauthenticatedException(message, details, reason),
        WincheErrorCode.notFound => NotFoundException(message, details, reason),
        WincheErrorCode.alreadyExists => AlreadyExistsException(message, details, reason),
        WincheErrorCode.failedPrecondition => FailedPreconditionException(message, details, reason),
        WincheErrorCode.deadlineExceeded => DeadlineExceededException(message, details, reason),
        WincheErrorCode.internal => InternalException(message, details, reason),
        WincheErrorCode.unavailable => UnavailableException(message, details, reason),
        _ => WincheDatabaseException(code, message, reason: reason, details: details),
      };

  /// Reads the `error` object of an error frame (or a REST error body):
  /// `{code, message, reason?, details?}`.
  factory WincheDatabaseException.fromWire(Map<String, Object?> error) {
    final named = error['code'] as String?;
    final code = WincheErrorCode.tryParse(named);
    return WincheDatabaseException.of(
      code ?? WincheErrorCode.unknown,
      error['message'] as String? ?? 'The database refused the request.',
      reason: error['reason'] as String? ?? (code == null ? named : null),
      details: switch (error['details']) {
        final Map<String, Object?> d => d,
        _ => null,
      },
    );
  }

  /// The old wire status (`NOT_FOUND`, `INVALID_QUERY`, …).
  @Deprecated('Use code (WincheErrorCode) and reason. Removed in the next major version.')
  String get status => code == WincheErrorCode.invalidArgument && reason == invalidQuery
      ? 'INVALID_QUERY'
      : code.wireName.toUpperCase().replaceAll('-', '_');

  /// The old way to make one, from a wire status.
  @Deprecated('Use WincheDatabaseException.of. Removed in the next major version.')
  factory WincheDatabaseException.fromError(String status, String message, [Map<String, Object?>? details]) =>
      status == 'INVALID_QUERY'
          ? WincheDatabaseException.of(WincheErrorCode.invalidArgument, message, reason: invalidQuery, details: details)
          : WincheDatabaseException.of(
              WincheErrorCode.tryParse(status.toLowerCase().replaceAll('_', '-')) ?? WincheErrorCode.unknown,
              message,
              details: details,
            );

  @override
  String toString() => '$runtimeType(${code.wireName}${reason == null ? '' : '/$reason'}): $message';
}

/// The old name of [WincheDatabaseException].
@Deprecated('Use WincheDatabaseException. Removed in the next major version.')
typedef WincheProtocolException = WincheDatabaseException;

/// `aborted` — a transaction conflict, an expired or unknown transaction.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.aborted. Removed in the next major version.')
class AbortedException extends WincheDatabaseException {
  const AbortedException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.aborted, message, details: details, reason: reason);
}

/// `permissionDenied` — the rules refused the operation.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.permissionDenied. Removed in the next major version.')
class PermissionDeniedException extends WincheDatabaseException {
  const PermissionDeniedException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.permissionDenied, message, details: details, reason: reason);
}

/// `unauthenticated` — no valid sign-in.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.unauthenticated. Removed in the next major version.')
class UnauthenticatedException extends WincheDatabaseException {
  const UnauthenticatedException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.unauthenticated, message, details: details, reason: reason);
}

/// `invalidArgument` with reason `invalid-query` — a query that doesn't parse or validate.
@Deprecated('Catch WincheDatabaseException and check reason == WincheDatabaseException.invalidQuery. Removed in the next major version.')
class InvalidQueryException extends WincheDatabaseException {
  const InvalidQueryException(String message, [Map<String, Object?>? details])
      : super(WincheErrorCode.invalidArgument, message, details: details, reason: WincheDatabaseException.invalidQuery);

  /// The JSON path of a parse error, when there is one.
  String? get jsonPath => details?['jsonPath'] as String?;

  /// The plan-validation code (e.g. `LIMIT_CONFLICT`), when there is one.
  String? get validationCode => details?['code'] as String?;
}

/// `invalidArgument` — a malformed request or bad values.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.invalidArgument. Removed in the next major version.')
class InvalidArgumentException extends WincheDatabaseException {
  const InvalidArgumentException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.invalidArgument, message, details: details, reason: reason);
}

/// `notFound` — an update or `exists: true` precondition on a missing document.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.notFound. Removed in the next major version.')
class NotFoundException extends WincheDatabaseException {
  const NotFoundException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.notFound, message, details: details, reason: reason);
}

/// `alreadyExists` — an `exists: false` precondition on an existing document.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.alreadyExists. Removed in the next major version.')
class AlreadyExistsException extends WincheDatabaseException {
  const AlreadyExistsException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.alreadyExists, message, details: details, reason: reason);
}

/// `failedPrecondition` — an `updateTime` precondition that didn't hold.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.failedPrecondition. Removed in the next major version.')
class FailedPreconditionException extends WincheDatabaseException {
  const FailedPreconditionException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.failedPrecondition, message, details: details, reason: reason);
}

/// `deadlineExceeded` — no answer in time.
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.deadlineExceeded. Removed in the next major version.')
class DeadlineExceededException extends WincheDatabaseException {
  const DeadlineExceededException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.deadlineExceeded, message, details: details, reason: reason);
}

/// `internal` — an unexpected server error (always a bug; `details.errorId` finds it in the server's log).
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.internal. Removed in the next major version.')
class InternalException extends WincheDatabaseException {
  const InternalException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.internal, message, details: details, reason: reason);
}

/// `unavailable` — the server is unreachable or the connection dropped (raised by the client).
@Deprecated('Catch WincheDatabaseException and check code == WincheErrorCode.unavailable. Removed in the next major version.')
class UnavailableException extends WincheDatabaseException {
  const UnavailableException(String message, [Map<String, Object?>? details, String? reason])
      : super(WincheErrorCode.unavailable, message, details: details, reason: reason);
}
