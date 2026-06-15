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
}
