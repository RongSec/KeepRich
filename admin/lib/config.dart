import 'package:flutter/foundation.dart';

class AppConfig {
  /// 云托管分享码：从当前页面 URL 里解析（/admin/?sharecode=XXX）
  static String? get shareCode {
    if (!kIsWeb) return null;
    final c = Uri.base.queryParameters['sharecode'];
    return (c == null || c.isEmpty) ? null : c;
  }

  static String get apiBaseUrl => kIsWeb ? '/api' : 'http://10.0.2.2:8080/api';
}
