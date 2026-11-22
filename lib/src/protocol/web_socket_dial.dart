// Opens a WebSocket with dart:io where there is one, so a refused upgrade keeps
// its HTTP status; a browser can't say why a socket failed to open.
export 'web_socket_dial_web.dart' if (dart.library.io) 'web_socket_dial_io.dart';
