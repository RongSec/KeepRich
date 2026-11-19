import 'package:flutter/services.dart';

/// 桌面小卡片 → App 的深链通道。
///
/// 冷启动：intent 由 SplashPage 读 HomeWidget.initiallyLaunchedFromHomeWidget()
/// 处理；热启动（App 还在后台）只能走 MainActivity.onNewIntent，再由这里
/// 通过 EventChannel 送到 Dart —— 之前热启动点加号进不去记账页就是缺了这条链路。
class WidgetLinkService {
  WidgetLinkService._();

  static const _channel = EventChannel('foreverrich/widget_link');

  /// 收到深链时的回调（由 App 注册，负责路由跳转）
  static void Function(String uri)? onLink;

  static bool _listening = false;

  static void start() {
    if (_listening) return;
    _listening = true;
    _channel.receiveBroadcastStream().listen((event) {
      if (event is String && event.isNotEmpty) {
        onLink?.call(event);
      }
    }, onError: (_) {});
  }
}
