import 'dart:async';

import '../core/value_relay.dart';
import '../protocol/connection.dart';
import '../protocol/exceptions.dart';
import '../protocol/messages.dart';

part 'ws_transport.dart';

abstract interface class Transport {
  /// Sends a request frame and resolves the response `result`.
  Future<Map<String, Object?>> request(Map<String, Object?> frame);

  /// A stream of listener frames for [subscriptionId].
  Stream<ServerFrame> listenEvents(String subscriptionId);

  /// Closes and removes the listener stream for [subscriptionId].
  void releaseSubscription(String subscriptionId);

  /// The current connection state.
  ConnectionState get connectionState;

  /// A stable stream of connection-state transitions that survives a dropped
  /// and re-dialled socket (does not complete on disconnect).
  Stream<ConnectionState> get connectionStates;

  /// Drops the current socket and re-dials, re-reading the auth token.
  /// Subscriptions resume in place.
  Future<void> reconnect();

  /// Closes the transport and its underlying connection.
  ///
  /// Completes once the connection is closed and its listener streams have been
  /// completed, so callers can order teardown against it (e.g. closing the local
  /// store only after no subscription can still fire).
  Future<void> dispose();
}
