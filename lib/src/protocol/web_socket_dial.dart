// Opens a WebSocket with headers where the platform can (dart:io); a browser
// can't set a WebSocket's headers.
export 'web_socket_dial_web.dart' if (dart.library.io) 'web_socket_dial_io.dart';
