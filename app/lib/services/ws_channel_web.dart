import 'package:web_socket_channel/web_socket_channel.dart';

/// Web：浏览器不允许给 WebSocket 握手加自定义头，只能把 token 放 URL。
WebSocketChannel openAuthedWs(Uri uri, String token) => WebSocketChannel.connect(
      uri.replace(queryParameters: {
        ...uri.queryParameters,
        'token': token,
      }),
    );
