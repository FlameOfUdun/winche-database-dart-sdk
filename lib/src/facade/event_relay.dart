import 'dart:async';

/// A broadcast stream that outlives the source it forwards, for genuinely
/// event-shaped signals.
///
/// Subscribers receive only events that occur after they subscribe. Use
/// [StatusRelay] instead for anything that represents a *current condition* —
/// a subscriber that arrives late needs to learn that condition, whereas a
/// subscriber that missed a past event has genuinely missed nothing.
final class EventRelay<T> {
  final StreamController<T> _out = StreamController<T>.broadcast();
  StreamSubscription<T>? _in;

  /// The facade-lifetime stream consumers listen to.
  Stream<T> get stream => _out.stream;

  /// Forwards [source], replacing any previous one.
  ///
  /// Deliberately does not forward `onDone`: the source ending is one session's
  /// business, not the consumer's.
  void attach(Stream<T> source) {
    _in?.cancel();
    _in = source.listen(_out.add, onError: _out.addError);
  }

  /// Stops forwarding, optionally emitting [finalValue] first.
  ///
  /// Supply one whenever going quiet would otherwise leave consumers on a stale
  /// value — signing out while connected must not leave a banner reading
  /// "connected" forever.
  void detach({T? finalValue}) {
    _in?.cancel();
    _in = null;
    if (finalValue != null && !_out.isClosed) _out.add(finalValue);
  }

  /// Ends the stream. Call only when the facade is disposed.
  ///
  /// **Cancel before close, in that order.** [attach] forwards with a bare
  /// `_out.add` and no `isClosed` guard, so an event arriving after `_out`
  /// shuts would throw `StateError` from inside a listener callback, where
  /// nothing catches it. Cancelling first detaches the subscription
  /// synchronously, which is what makes that unguarded forward safe. Reversing
  /// these two lines reopens the race.
  Future<void> close() async {
    await _in?.cancel();
    _in = null;
    await _out.close();
  }
}
