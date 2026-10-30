import 'package:flutter/foundation.dart';

/// 运行环境配置
///
/// 服务端地址支持构建时注入（推荐）：
///   flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.100:28080
/// 未注入时回退到下方默认值。
class AppConfig {
  /// 构建注入的服务端地址（不含 /api 后缀），为空表示使用默认值
  static const String _envServerHost = String.fromEnvironment('API_BASE_URL');

  /// 后端服务器地址（默认值）
  /// 本地开发（Android 模拟器）：http://10.0.2.2:28080
  /// 本地开发（真机/浏览器）：http://localhost:28080
  /// 公网部署：通过 --dart-define=API_BASE_URL=https://your-domain 注入
  static const String _defaultServerHost = 'http://10.0.2.2:28080'; // 本地开发

  static String get serverHost =>
      _envServerHost.isNotEmpty ? _envServerHost : _defaultServerHost;

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
