import 'dart:async';

import '../protocol/connection.dart';
import '../protocol/messages.dart';

part 'ws_transport.dart';

abstract interface class Transport {
  /// Sends a request frame and resolves the response `result`.
  Future<Map<String, Object?>> request(Map<String, Object?> frame);

  /// A stream of listener frames for [subscriptionId].
  Stream<ServerFrame> listenEvents(String subscriptionId);

  /// Closes and removes the listener stream for [subscriptionId].
  void releaseSubscription(String subscriptionId);

  /// Emits each time the underlying connection reconnects.
  Stream<void> get reconnects;

  /// The current connection state.
  ConnectionState get connectionState;

  /// A stable stream of connection-state transitions that survives socket
  /// reconnects (does not complete on disconnect).
  Stream<ConnectionState> get connectionStates;

  /// Closes the transport and its underlying connection.
  void dispose();
}
