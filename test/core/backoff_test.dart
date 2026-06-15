import 'dart:math';
import 'package:test/test.dart';
import 'package:winche_database/src/core/backoff.dart';

void main() {
  test('linearBackoff grows with attempt and stays within jitter band', () {
    final rng = Random(1);
    for (var attempt = 0; attempt < 5; attempt++) {
      final d = linearBackoff(attempt, stepMs: 50, jitterMs: 50, rng: rng);
      final base = 50 * (attempt + 1);
      expect(d.inMilliseconds, greaterThanOrEqualTo(base));
      expect(d.inMilliseconds, lessThan(base + 50));
    }
  });
}
