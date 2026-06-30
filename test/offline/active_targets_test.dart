import 'package:test/test.dart';
import 'package:winche_database/src/offline/active_targets.dart';

void main() {
  test('unions pinned paths across owners; unpin removes them', () {
    final at = ActiveTargets();
    final ownerA = Object();
    final ownerB = Object();

    expect(at.all(), isEmpty);

    at.pin(ownerA, ['c/1', 'c/2']);
    at.pin(ownerB, ['c/2', 'c/3']);
    expect(at.all(), {'c/1', 'c/2', 'c/3'});

    // Re-pinning an owner replaces its set (membership changed).
    at.pin(ownerA, ['c/1']);
    expect(at.all(), {'c/1', 'c/2', 'c/3'});

    at.unpin(ownerB);
    expect(at.all(), {'c/1'});
  });
}
