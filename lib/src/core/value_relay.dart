import 'dart:async';

/// A broadcast stream that hands every new subscriber the current value before
/// forwarding subsequent ones.
///
/// Connectivity is a *level* — "a socket is up right now" — not an event. A
/// plain broadcast controller can only deliver events that happen after you
/// subscribe, which forces every consumer to seed itself from a separate
/// getter and leaves a window where the seed and the subscription disagree.
/// This type removes that burden: subscribe, and the first thing you receive is
/// the truth as of that moment.
final class ValueRelay<T> {
  ValueRelay(this._value);

  T _value;
  final StreamController<T> _out = StreamController<T>.broadcast();

  /// The latest value, readable without subscribing.
  T get value => _value;

  /// Publishes [next], updating [value] first so a subscriber that arrives
  /// during delivery is seeded with the newer value rather than the older one.
  void add(T next) {
    _value = next;
    if (!_out.isClosed) _out.add(next);
  }

  /// The current value, then every subsequent change, with consecutive
  /// duplicates suppressed.
  ///
  /// `Stream.multi` runs the body once per listener, which is what makes
  /// per-subscriber seeding possible — a broadcast controller's `onListen`
  /// fires only for the *first* listener, so everyone after it would get no
  /// seed. The seed and the subscribe sit in one synchronous block, so nothing
  /// can run between them and no value is dropped or reordered.
  ///
  /// De-duplication is load-bearing for consumers that react to a transition
  /// by rebuilding state: a repeated `ready` must not be mistaken for a new
  /// one.
  Stream<T> get stream => Stream<T>.multi((controller) {
        controller.add(_value);
        final sub = _out.stream.listen(
          controller.add,
          onError: controller.addError,
        );
        controller.onCancel = sub.cancel;
      }, isBroadcast: true).distinct();

  /// Ends the stream. Later [add] calls are silently ignored.
  Future<void> close() => _out.close();
}
