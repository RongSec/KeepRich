// FCM 推送服务（占位实现）
//
// 启用步骤：
// 1. 在 pubspec.yaml 添加 firebase_core 与 firebase_messaging
// 2. 把 android/app/google-services.json 放好（Firebase 控制台下载）
// 3. 填写真实配置到 lib/firebase_options.dart
// 4. 在 main.dart 中启动时调用 PushService.instance.init()
// 5. 后端推送：使用 Firebase Admin SDK 向 device token 发送
// 6. 用户登录后通过 _sendTokenToServer 把 token 报到后端

import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

class PushService {
  static final PushService instance = PushService._();
  PushService._();

  String? _token;
  String? get token => _token;

  bool get enabled => PushConfig.isConfigured;

  // 初始化（需要 Firebase 真实配置）
  Future<void> init() async {
    if (kIsWeb) {
      debugPrint('PushService: Web 平台暂未启用');
      return;
    }
    if (!enabled) {
      debugPrint('PushService: PushConfig 未配置，跳过 FCM 初始化');
      return;
    }
    try {
      // 真实启用时取消以下注释并添加 firebase_* 依赖
      // await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      // final messaging = FirebaseMessaging.instance;
      // await messaging.requestPermission(alert: true, badge: true, sound: true);
      // _token = await messaging.getToken();
      // messaging.onTokenRefresh.listen(_sendTokenToServer);
      // FirebaseMessaging.onMessage.listen(_onForeground);
      debugPrint('PushService.init: 启用 FCM（在配置好 Firebase 后）');
    } catch (e) {
      debugPrint('PushService init 失败: $e');
    }
  }

  // 发送 token 到后端
  // ignore: unused_element
  Future<void> _sendTokenToServer(String token) async {
    _token = token;
    // TODO: 调用后端 API
    // await ApiClient.instance.registerPushToken(token);
    debugPrint('Would register push token: $token');
  }
}
