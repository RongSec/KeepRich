import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_channel_io.dart' if (dart.library.html) 'ws_channel_web.dart' as impl;

/// 建立带鉴权的 WebSocket 连接（原生走 header，Web 走 query）。
WebSocketChannel openAuthedWs(Uri uri, String token) => impl.openAuthedWs(uri, token);
