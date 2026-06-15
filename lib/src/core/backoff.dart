import 'dart:math';

/// Linear backoff: `stepMs * (attempt + 1)` plus up to [jitterMs] random ms.
Duration linearBackoff(
  int attempt, {
  required int stepMs,
  required int jitterMs,
  required Random rng,
}) {
  return Duration(milliseconds: stepMs * (attempt + 1) + rng.nextInt(jitterMs));
}
