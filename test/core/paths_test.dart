import 'package:test/test.dart';
import 'package:winche_database/src/core/paths.dart';

void main() {
  group('paths', () {
    test('docId returns last segment', () {
      expect(docId('users/u1'), 'u1');
      expect(docId('users/u1/posts/p9'), 'p9');
      expect(docId('users'), 'users');
    });
    test('collectionOf returns everything before last slash', () {
      expect(collectionOf('users/u1'), 'users');
      expect(collectionOf('users/u1/posts/p9'), 'users/u1/posts');
      expect(collectionOf('users'), '');
    });
    test('parentOf returns null for top-level segment', () {
      expect(parentOf('users/u1'), 'users');
      expect(parentOf('users'), isNull);
    });
    test('segments splits on slash', () {
      expect(segments('users/u1/posts'), ['users', 'u1', 'posts']);
    });
  });

  group('validateDocumentPath', () {
    test('accepts well-formed document paths', () {
      expect(() => validateDocumentPath('users/u1'), returnsNormally);
      expect(() => validateDocumentPath('users/u1/posts/p9'), returnsNormally);
    });

    test('rejects an empty path', () {
      expect(() => validateDocumentPath(''), throwsArgumentError);
    });

    test('rejects a leading slash (empty first segment)', () {
      expect(() => validateDocumentPath('/users/u1'), throwsArgumentError);
    });

    test('rejects a trailing slash (empty last segment)', () {
      expect(() => validateDocumentPath('users/u1/'), throwsArgumentError);
    });

    test('rejects a doubled slash (empty middle segment)', () {
      expect(() => validateDocumentPath('users//u1'), throwsArgumentError);
    });

    test('rejects a "." segment', () {
      expect(() => validateDocumentPath('users/.'), throwsArgumentError);
    });

    test('rejects a ".." segment', () {
      expect(() => validateDocumentPath('users/..'), throwsArgumentError);
    });

    test('rejects a reserved "__*__" segment', () {
      expect(
          () => validateDocumentPath('users/__reserved__'), throwsArgumentError);
    });

    test('does not reject a segment merely starting or ending with "__"', () {
      // Only a segment that BOTH starts and ends with "__" is reserved.
      expect(() => validateDocumentPath('users/__prefix'), returnsNormally);
      expect(() => validateDocumentPath('users/suffix__'), returnsNormally);
    });

    test('rejects a segment exceeding the 1500-byte limit', () {
      final tooLong = 'a' * 1501;
      expect(() => validateDocumentPath('users/$tooLong'), throwsArgumentError);
    });

    test('accepts a segment at exactly the 1500-byte limit', () {
      final atLimit = 'a' * 1500;
      expect(
          () => validateDocumentPath('users/$atLimit'), returnsNormally);
    });

    test('rejects an odd number of segments', () {
      expect(() => validateDocumentPath('users'), throwsArgumentError);
      expect(
          () => validateDocumentPath('users/u1/posts'), throwsArgumentError);
    });
  });

  group('validateCollectionPath', () {
    test('accepts well-formed collection paths', () {
      expect(() => validateCollectionPath('users'), returnsNormally);
      expect(
          () => validateCollectionPath('users/u1/posts'), returnsNormally);
    });

    test('rejects an even number of segments', () {
      expect(() => validateCollectionPath('users/u1'), throwsArgumentError);
    });

    test('rejects the same malformed-segment rules as a document path', () {
      expect(() => validateCollectionPath('users//posts'), throwsArgumentError);
      expect(() => validateCollectionPath('users/./posts'), throwsArgumentError);
      expect(
          () => validateCollectionPath('users/__x__/posts'),
          throwsArgumentError);
    });
  });
}
