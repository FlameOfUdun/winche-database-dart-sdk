import 'package:web_socket_channel/web_socket_channel.dart';

/// Whether a WebSocket here can send headers when it opens (not in a browser).
const bool webSocketHeadersSupported = false;

/// Opens [uri]; a browser can't send [headers].
WebSocketChannel connectWebSocket(Uri uri, Map<String, String> headers) => WebSocketChannel.connect(uri);
