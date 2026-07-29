import 'dart:async';

/// A broadcast stream that outlives the source it forwards.
///
/// Status streams — connection state, sync events, reconnects — are read off
/// components a session owns, so they end every time the signed-in user
/// changes. A `StreamBuilder` that receives `done` never updates again, so
/// forwarding it would freeze an offline banner on its last value for the rest
/// of the app's life.
///
/// This sits in between: [attach] swaps the upstream, and the downstream ends
/// only when the facade itself is disposed.
final class StatusRelay<T> {
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
  Future<void> close() async {
    await _in?.cancel();
    _in = null;
    await _out.close();
  }
}
