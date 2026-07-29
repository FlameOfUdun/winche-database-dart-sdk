import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  group('WincheUnboundException', () {
    test('is an Exception and explains how to recover', () {
      final error = WincheUnboundException();
      expect(error, isA<Exception>());
      expect(error.toString(), contains('sign in'));
    });

    test('is not a StateError, which means terminal', () {
      expect(WincheUnboundException(), isNot(isA<StateError>()));
    });
  });
}
