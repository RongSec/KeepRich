import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 原生平台：握手时用 header 传 token。
///
/// 云托管网关会丢弃 URL 里的 token 查询参数（实测：`?token=` 一律 401，
/// 放 `X-Finance-Token` 头才 101），所以原生端必须走 header。
WebSocketChannel openAuthedWs(Uri uri, String token) =>
    IOWebSocketChannel.connect(uri, headers: {'X-Finance-Token': token});
