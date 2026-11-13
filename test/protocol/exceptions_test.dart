// The 7.x names are exercised on purpose: they must keep working for a release.
// ignore_for_file: deprecated_member_use
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  group('WincheDatabaseException', () {
    test('reads the shared error object: code, message, reason, details', () {
      final e = WincheDatabaseException.fromWire(
          {'code': 'invalid-argument', 'reason': 'invalid-query', 'message': 'Unknown operator', 'details': {'jsonPath': r'$.where.op'}});
      expect([e.code, e.reason, e.message, e.details], [WincheErrorCode.invalidArgument, 'invalid-query', 'Unknown operator', {'jsonPath': r'$.where.op'}]);
      expect(e, isA<WincheException>());
      expect(WincheDatabaseException.fromWire({'code': 'aborted', 'message': 'm'}).isTransient, isTrue);
    });

    test('a code outside the shared list is unknown, with the code kept as the reason', () {
      final e = WincheDatabaseException.fromWire({'code': 'WEIRD', 'message': 'm'});
      expect([e.code, e.reason], [WincheErrorCode.unknown, 'WEIRD']);
    });

    test('for this release, of still throws the old subclasses, so their catches keep working', () {
      expect(WincheDatabaseException.of(WincheErrorCode.notFound, 'm'), isA<NotFoundException>());
      expect(WincheDatabaseException.of(WincheErrorCode.aborted, 'm'), isA<AbortedException>());
      expect(WincheDatabaseException.of(WincheErrorCode.unavailable, 'm'), isA<UnavailableException>());
      expect(WincheDatabaseException.of(WincheErrorCode.invalidArgument, 'm', reason: WincheDatabaseException.invalidQuery),
          isA<InvalidQueryException>());
      expect(WincheDatabaseException.of(WincheErrorCode.resourceExhausted, 'm').runtimeType, WincheDatabaseException);
    });
  });

  group('the 7.x names', () {
    test('WincheProtocolException is WincheDatabaseException', () {
      expect(WincheDatabaseException.of(WincheErrorCode.internal, 'm'), isA<WincheProtocolException>());
    });

    test('fromError maps the old statuses, and status gives them back', () {
      for (final status in ['NOT_FOUND', 'ALREADY_EXISTS', 'FAILED_PRECONDITION', 'INVALID_ARGUMENT', 'DEADLINE_EXCEEDED',
          'INTERNAL', 'ABORTED', 'PERMISSION_DENIED', 'UNAUTHENTICATED', 'INVALID_QUERY', 'UNAVAILABLE']) {
        expect(WincheDatabaseException.fromError(status, 'm').status, status);
      }
      expect(WincheDatabaseException.fromError('INVALID_QUERY', 'm', {'code': 'LIMIT_CONFLICT'}),
          isA<InvalidQueryException>().having((e) => e.validationCode, 'validationCode', 'LIMIT_CONFLICT'));
      expect(const NotFoundException('m').status, 'NOT_FOUND');
    });
  });
}
