import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 运行环境配置
///
/// 服务端地址优先级（从高到低）：
///   1. App 内「设置 → 服务端地址」手动填写（存本地，重启保留）
///   2. 构建时注入：--dart-define=API_BASE_URL=http://192.168.1.10:28080
///   3. 平台默认值：
///        Android 模拟器 → http://10.0.2.2:28080（10.0.2.2 即宿主机回环地址）
///        Web / iOS 模拟器 / 桌面 → http://127.0.0.1:28080
///
/// 真机调试时手机访问不到电脑的 127.0.0.1，请用「设置 → 服务端地址」填电脑的局域网 IP。
class AppConfig {
  AppConfig._();

  static const String _kServerHostKey = 'server_host_override';
  static const String _kShareCodeKey = 'server_share_code';

  /// 构建注入的服务端地址（不含 /api 后缀）
  static const String _envServerHost = String.fromEnvironment('API_BASE_URL');

  /// 构建注入的 build 号（Web 端判断"是否需要刷新"时用）
  static const int envBuildNumber =
      int.fromEnvironment('APP_BUILD_NUMBER', defaultValue: 0);

  /// 应用版本号（与 pubspec.yaml 保持一致；构建脚本会用 --dart-define 覆盖）
  static const String appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '0.3.0');

  /// Android 模拟器映射到宿主机
  static const String androidEmulatorHost = 'http://10.0.2.2:28080';

  /// 本机 / Web 默认
  static const String localhostHost = 'http://127.0.0.1:28080';

  static String? _overrideHost;

  /// 云托管分享码：平台要求每个请求带 sharecode（?sharecode= 或 X-Share-Code 头），
  /// 否则一律 403。从服务端地址里解析出来，如
  /// `https://xxx.app.workbuddy.host/?sharecode=VAUEWKAZSR` → `VAUEWKAZSR`
  static String? _shareCode;
  static bool _inited = false;

  /// 当前解析到的分享码（无则为 null）
  static String? get shareCode => _shareCode;

  /// 平台默认服务端地址
  static String get defaultServerHost {
    if (kIsWeb) return Uri.base.origin;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return androidEmulatorHost;
    }
    return localhostHost;
  }

  /// 当前生效的服务端地址（不含 /api）
  static String get serverHost {
    final o = _overrideHost;
    if (o != null && o.isNotEmpty) return _normalize(o);
    if (_envServerHost.isNotEmpty) return _normalize(_envServerHost);
    return defaultServerHost;
  }

  /// 用户是否手动指定过地址
  static bool get hasOverride => (_overrideHost ?? '').isNotEmpty;

  /// 当前地址来源（设置页展示用）
  static String get sourceLabel {
    if (hasOverride) return '手动设置';
    if (_envServerHost.isNotEmpty) return '构建注入';
    if (kIsWeb) return '当前站点';
    return '平台默认';
  }

  /// 应用启动时调用：读取本地保存的地址
  static Future<void> init() async {
    if (_inited) return;
    try {
      final p = await SharedPreferences.getInstance();
      _overrideHost = p.getString(_kServerHostKey);
      _shareCode = p.getString(_kShareCodeKey);
    } catch (_) {
      _overrideHost = null;
      _shareCode = null;
    }
    _inited = true;
  }

  /// 设置/清除自定义地址（传 null 或空串表示恢复默认）
  static Future<void> setServerHost(String? host) async {
    final p = await SharedPreferences.getInstance();
    final v = (host ?? '').trim();
    if (v.isEmpty) {
      await p.remove(_kServerHostKey);
      await p.remove(_kShareCodeKey);
      _overrideHost = null;
      _shareCode = null;
      return;
    }
    final n = _normalize(v);
    await p.setString(_kServerHostKey, n);
    final code = _extractShareCode(v);
    if (code != null) {
      await p.setString(_kShareCodeKey, code);
    } else {
      await p.remove(_kShareCodeKey);
    }
    _overrideHost = n;
    _shareCode = code;
  }

  /// 从地址里提取 sharecode
  static String? _extractShareCode(String host) {
    final uri = Uri.tryParse(host.trim());
    if (uri == null) return null;
    return uri.queryParameters['sharecode'];
  }

  /// 去掉尾部斜杠、多余的 /api 与查询参数（sharecode 单独存）
  static String _normalize(String host) {
    var h = host.trim();
    final q = h.indexOf('?');
    if (q >= 0) h = h.substring(0, q);
    while (h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    if (h.endsWith('/api')) h = h.substring(0, h.length - 4);
    return h;
  }

  /// 探测地址是否可用（GET /healthz）：成功返回 null，失败返回错误描述
  static Future<String?> probe(
    String rawHost, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    var host = _normalize(rawHost);
    if (host.isEmpty) return '地址不能为空';
    // 允许用户只填 IP:端口
    if (!host.startsWith('http://') && !host.startsWith('https://')) {
      host = 'http://$host';
    }
    final uri = Uri.tryParse(host);
    if (uri == null || uri.host.isEmpty) {
      return '格式应为 http://192.168.1.10:28080';
    }
    try {
      var probeUrl = Uri.parse('$host/healthz');
      // 云托管域名需要 sharecode 才放行，探测时也要带上
      if (_shareCode != null && _shareCode!.isNotEmpty) {
        probeUrl = probeUrl.replace(queryParameters: {
          ...probeUrl.queryParameters,
          'sharecode': _shareCode!,
        });
      }
      final resp =
          await http.get(probeUrl).timeout(timeout);
      if (resp.statusCode == 200) return null;
      return '服务返回 HTTP ${resp.statusCode}';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  static String get apiBaseUrl {
    // 未显式指定地址时，Web 走同源相对路径（部署到任意域名都不用改配置）
    if (kIsWeb && !hasOverride && _envServerHost.isEmpty) return '/api';
    return '$serverHost/api';
  }

  /// WebSocket 地址
  static String get wsUrl {
    if (kIsWeb && !hasOverride && _envServerHost.isEmpty) {
      final scheme = Uri.base.scheme == 'https' ? 'wss' : 'ws';
      final port = Uri.base.hasPort ? ':${Uri.base.port}' : '';
      return '$scheme://${Uri.base.host}$port/api/ws';
    }
    final wsScheme = serverHost.startsWith('https') ? 'wss' : 'ws';
    final host = serverHost.replaceFirst(RegExp(r'https?://'), '');
    return '$wsScheme://$host/api/ws';
  }
}
