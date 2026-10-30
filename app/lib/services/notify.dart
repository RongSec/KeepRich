import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models.dart';
import 'api.dart';

/// 通知服务（WebSocket + 本地通知）
class NotifyService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  bool _connected = false;
  int _unreadCount = 0;
  final List<NotificationItem> _recentNotifications = [];

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  bool get connected => _connected;
  int get unreadCount => _unreadCount;
  List<NotificationItem> get recentNotifications => List.unmodifiable(_recentNotifications);

  /// 初始化本地通知
  Future<void> initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(initSettings);
  }

  /// 显示本地通知
  Future<void> _showLocalNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'family_finance',
      '家庭财务',
      channelDescription: '家庭财务管理系统通知',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
    );
    const details = NotificationDetails(android: androidDetails);
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  /// 连接 WebSocket
  void connect() {
    if (_connected || !ApiClient.instance.hasToken) return;
    try {
      final wsUrl = AppConfig.wsUrl;
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: _onError,
      );

      _connected = true;
      _startHeartbeat();
      notifyListeners();
    } catch (e) {
      debugPrint('[notify] connect error: $e');
      _scheduleReconnect();
    }
  }

  /// 断开连接
  void disconnect() {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _connected = false;
    notifyListeners();
  }

  /// 加载未读数量
  Future<void> loadUnreadCount() async {
    try {
      final r = await ApiClient.instance.listNotifications(page: 1, size: 1);
      if (r.ok && r.data != null) {
        _unreadCount = (r.data!['unreadCount'] as num? ?? 0).toInt();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 标记单条已读
  Future<void> markRead(int id) async {
    await ApiClient.instance.markNotificationRead(id);
    _recentNotifications.removeWhere((n) => n.id == id);
    if (_unreadCount > 0) _unreadCount--;
    notifyListeners();
  }

  /// 全部已读
  Future<void> markAllRead() async {
    await ApiClient.instance.markAllNotificationsRead();
    _unreadCount = 0;
    _recentNotifications.clear();
    notifyListeners();
  }

  void _onMessage(dynamic data) {
    try {
      if (data is! String || data == 'pong') return;
      final json = jsonDecode(data) as Map<String, dynamic>;
      final notification = NotificationItem.fromJson(json);
      _recentNotifications.insert(0, notification);
      if (_recentNotifications.length > 20) {
        _recentNotifications.removeLast();
      }
      _unreadCount++;
      notifyListeners();

      // 显示本地通知
      final title = notification.title.isNotEmpty ? notification.title : NotifyType.labelOf(notification.type);
      _showLocalNotification(title, notification.content);
    } catch (e) {
      debugPrint('[notify] parse error: $e');
    }
  }

  void _onDisconnected() {
    _connected = false;
    notifyListeners();
    _scheduleReconnect();
  }

  void _onError(dynamic error) {
    debugPrint('[notify] ws error: $error');
    _connected = false;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_connected && ApiClient.instance.hasToken) {
        connect();
      }
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_connected) {
        try {
          _channel?.sink.add('ping');
        } catch (_) {}
      }
    });
  }
}
