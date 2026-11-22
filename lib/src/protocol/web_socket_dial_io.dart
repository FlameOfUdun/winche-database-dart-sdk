import 'dart:io' as io;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens [uri].
WebSocketChannel connectWebSocket(Uri uri) => IOWebSocketChannel.connect(uri);

/// The HTTP status the server answered a refused WebSocket upgrade with (401
/// for a bad token, 403 when it is not allowed), or null when [error] is not
/// a refused upgrade. dart:io reports it as a `WebSocketException` with an
/// `httpStatusCode`, which web_socket_channel wraps.
int? refusedUpgradeStatus(Object error) {
  final inner = error is WebSocketChannelException ? error.inner : error;
  return inner is io.WebSocketException ? inner.httpStatusCode : null;
}
