import 'package:flutter/foundation.dart';

/// 运行环境配置
class AppConfig {
  /// 后端服务器地址
  /// 本地开发（Android 模拟器）：http://10.0.2.2:28080
  /// 本地开发（真机/浏览器）：http://localhost:28080
  /// 公网部署：http://103.236.92.33:28080
  static const String serverHost = 'http://10.0.2.2:28080'; // 本地开发
  // static const String serverHost = 'http://103.236.92.33:28080'; // 公网部署

  static String get apiBaseUrl {
    if (kIsWeb) return '/api';
    return '$serverHost/api';
  }

  /// WebSocket 地址
  static String get wsUrl {
    if (kIsWeb) {
      final scheme = kReleaseMode ? 'wss' : 'ws';
      return '$scheme://${Uri.base.host}/api/ws';
    }
    final wsScheme = serverHost.startsWith('https') ? 'wss' : 'ws';
    final host = serverHost.replaceFirst(RegExp(r'https?://'), '');
    return '$wsScheme://$host/api/ws';
  }
}
