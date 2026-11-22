import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens [uri].
WebSocketChannel connectWebSocket(Uri uri) => WebSocketChannel.connect(uri);

/// Always null: a browser does not say why a WebSocket failed to open.
int? refusedUpgradeStatus(Object error) => null;
