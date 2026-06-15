import 'dart:async';

/// A broadcast signal fired whenever the local cache or write queue mutates
/// (a write is enqueued, a write is acked, or a conflict is resolved). Live
/// cache-backed listeners subscribe to recompute their effective snapshot.
class LocalChangeNotifier {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  Stream<void> get stream => _controller.stream;

  void notify() {
    if (!_controller.isClosed) _controller.add(null);
  }

  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
