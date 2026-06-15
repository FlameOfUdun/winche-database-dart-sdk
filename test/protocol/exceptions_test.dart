import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  group('WincheException.fromError', () {
    test('maps every protocol status to its typed subclass', () {
      expect(WincheException.fromError('NOT_FOUND', 'm'),
          isA<NotFoundException>());
      expect(WincheException.fromError('ALREADY_EXISTS', 'm'),
          isA<AlreadyExistsException>());
      expect(WincheException.fromError('FAILED_PRECONDITION', 'm'),
          isA<FailedPreconditionException>());
      expect(WincheException.fromError('INVALID_ARGUMENT', 'm'),
          isA<InvalidArgumentException>());
      expect(WincheException.fromError('DEADLINE_EXCEEDED', 'm'),
          isA<DeadlineExceededException>());
      expect(
          WincheException.fromError('INTERNAL', 'm'), isA<InternalException>());

      // Previously-mapped statuses still map.
      expect(
          WincheException.fromError('ABORTED', 'm'), isA<AbortedException>());
      expect(WincheException.fromError('PERMISSION_DENIED', 'm'),
          isA<PermissionDeniedException>());
      expect(WincheException.fromError('UNAUTHENTICATED', 'm'),
          isA<UnauthenticatedException>());
      expect(WincheException.fromError('INVALID_QUERY', 'm'),
          isA<InvalidQueryException>());
      expect(WincheException.fromError('UNAVAILABLE', 'm'),
          isA<UnavailableException>());
    });

    test('preserves status, message and details on typed subclasses', () {
      final e =
          WincheException.fromError('NOT_FOUND', 'gone', {'path': 'users/u1'});
      expect(e.status, 'NOT_FOUND');
      expect(e.message, 'gone');
      expect(e.details, {'path': 'users/u1'});
    });

    test('unknown status falls back to the base WincheException', () {
      final e = WincheException.fromError('WEIRD_STATUS', 'm');
      expect(e.runtimeType, WincheException);
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
