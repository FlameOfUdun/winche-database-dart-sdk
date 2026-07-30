import 'dart:async';

import '../core/value_relay.dart';

/// A broadcast stream that outlives the source it forwards, and hands every
/// subscriber the current value.
///
/// Status streams — connection state, sync events — are read off components a
/// session owns, so they end every time the signed-in user changes. A
/// `StreamBuilder` that receives `done` never updates again, so forwarding it
/// would freeze an offline banner on its last value for the rest of the app's
/// life.
///
/// This sits in between: [attach] swaps the upstream, and the downstream ends
/// only when the facade itself is disposed. Because it carries the current
/// value, a widget built at any moment — including after a user swap — renders
/// the truth immediately instead of waiting for the next change.
final class StatusRelay<T> {
  StatusRelay(T initialValue) : _relay = ValueRelay<T>(initialValue);

  final ValueRelay<T> _relay;
  StreamSubscription<T>? _in;

  /// The facade-lifetime stream consumers listen to: current value, then changes.
  Stream<T> get stream => _relay.stream;

  /// The latest value, readable without subscribing.
  T get value => _relay.value;

  /// Forwards [source], replacing any previous one.
  ///
  /// Deliberately does not forward `onDone`: the source ending is one session's
  /// business, not the consumer's.
  void attach(Stream<T> source) {
    _in?.cancel();
    // ValueRelay has no addError — a level has no meaningful error value.
    // Safe here: the only level source is the transport's connection state,
    // and nothing ever calls addError on it. Swallowing is a decision, not
    // an oversight.
    _in = source.listen(_relay.add, onError: (Object e, StackTrace s) {});
  }

  /// Stops forwarding, optionally emitting [finalValue] first.
  ///
  /// Supply one whenever going quiet would otherwise leave consumers on a stale
  /// value — signing out while connected must not leave a banner reading
  /// "connected" forever.
  void detach({T? finalValue}) {
    _in?.cancel();
    _in = null;
    if (finalValue != null) _relay.add(finalValue);
  }

  /// Ends the stream. Call only when the facade is disposed.
  ///
  /// **Cancel before close, in that order.** Cancelling first detaches the
  /// upstream synchronously, so no event can arrive after the relay shuts.
  /// Reversing these two lines reopens that race.
  Future<void> close() async {
    await _in?.cancel();
    _in = null;
    await _relay.close();
  }
}
