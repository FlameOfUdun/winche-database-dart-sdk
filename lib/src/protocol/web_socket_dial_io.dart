import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Whether a WebSocket here can send headers when it opens.
const bool webSocketHeadersSupported = true;

/// Opens [uri], sending [headers].
WebSocketChannel connectWebSocket(Uri uri, Map<String, String> headers) =>
    IOWebSocketChannel.connect(uri, headers: headers.isEmpty ? null : headers);
