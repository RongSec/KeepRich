import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 系统能力通道：厂商识别 + 跳转系统通知/自启动设置。
///
/// 国产 ROM（ColorOS / MIUI / EMUI / Funtouch）在 Android 原生权限之上还有
/// 一层自己的管控（通知管理开关、设为不重要通知、自启动、耗电管理、后台冻结），
/// App 无法直接改写，只能把用户送到正确的设置页。
class SystemChannel {
  SystemChannel._();

  static const MethodChannel _ch = MethodChannel('foreverrich/system');

  static String? _vendor;

  /// 厂商标识（小写，如 "oppo oppo" / "xiaomi redmi"）；非 Android 返回空串
  static Future<String> vendor() async {
    if (kIsWeb) return '';
    if (_vendor != null) return _vendor!;
    try {
      _vendor = (await _ch.invokeMethod<String>('vendor')) ?? '';
    } catch (_) {
      _vendor = '';
    }
    return _vendor!;
  }

  static Future<bool> openNotificationSettings() async {
    if (kIsWeb) return false;
    try {
      return (await _ch.invokeMethod<bool>('openNotificationSettings')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openAutoStartSettings() async {
    if (kIsWeb) return false;
    try {
      return (await _ch.invokeMethod<bool>('openAutoStartSettings')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 是否为国产管控较重的 ROM
  static bool isAggressiveRom(String v) {
    const keys = ['oppo', 'realme', 'oneplus', 'xiaomi', 'redmi', 'vivo', 'iqoo', 'huawei', 'honor', 'meizu'];
    return keys.any(v.contains);
  }

  /// 厂商显示名
  static String vendorLabel(String v) {
    if (v.contains('oppo') || v.contains('realme') || v.contains('oneplus')) return 'OPPO / ColorOS';
    if (v.contains('xiaomi') || v.contains('redmi')) return '小米 / MIUI';
    if (v.contains('vivo') || v.contains('iqoo')) return 'vivo / OriginOS';
    if (v.contains('huawei') || v.contains('honor')) return '华为 / 荣耀';
    return v.isEmpty ? '当前设备' : v;
  }
}
