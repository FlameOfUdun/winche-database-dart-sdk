import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  group('WincheProtocolException.fromError', () {
    test('maps every protocol status to its typed subclass', () {
      expect(WincheProtocolException.fromError('NOT_FOUND', 'm'),
          isA<NotFoundException>());
      expect(WincheProtocolException.fromError('ALREADY_EXISTS', 'm'),
          isA<AlreadyExistsException>());
      expect(WincheProtocolException.fromError('FAILED_PRECONDITION', 'm'),
          isA<FailedPreconditionException>());
      expect(WincheProtocolException.fromError('INVALID_ARGUMENT', 'm'),
          isA<InvalidArgumentException>());
      expect(WincheProtocolException.fromError('DEADLINE_EXCEEDED', 'm'),
          isA<DeadlineExceededException>());
      expect(
          WincheProtocolException.fromError('INTERNAL', 'm'), isA<InternalException>());

      // Previously-mapped statuses still map.
      expect(
          WincheProtocolException.fromError('ABORTED', 'm'), isA<AbortedException>());
      expect(WincheProtocolException.fromError('PERMISSION_DENIED', 'm'),
          isA<PermissionDeniedException>());
      expect(WincheProtocolException.fromError('UNAUTHENTICATED', 'm'),
          isA<UnauthenticatedException>());
      expect(WincheProtocolException.fromError('INVALID_QUERY', 'm'),
          isA<InvalidQueryException>());
      expect(WincheProtocolException.fromError('UNAVAILABLE', 'm'),
          isA<UnavailableException>());
    });

    test('preserves status, message and details on typed subclasses', () {
      final e =
          WincheProtocolException.fromError('NOT_FOUND', 'gone', {'path': 'users/u1'});
      expect(e.status, 'NOT_FOUND');
      expect(e.message, 'gone');
      expect(e.details, {'path': 'users/u1'});
    });

    test('unknown status falls back to the base WincheProtocolException', () {
      final e = WincheProtocolException.fromError('WEIRD_STATUS', 'm');
      expect(e.runtimeType, WincheProtocolException);
      expect(e.status, 'WEIRD_STATUS');
    });

    test('typed subclasses report the correct status', () {
      expect(const NotFoundException('m').status, 'NOT_FOUND');
      expect(const AlreadyExistsException('m').status, 'ALREADY_EXISTS');
      expect(
          const FailedPreconditionException('m').status, 'FAILED_PRECONDITION');
      expect(const InvalidArgumentException('m').status, 'INVALID_ARGUMENT');
      expect(const DeadlineExceededException('m').status, 'DEADLINE_EXCEEDED');
      expect(const InternalException('m').status, 'INTERNAL');
    });
  });
}
