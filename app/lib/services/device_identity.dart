import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

/// 设备标识 / 设备名 / 平台的唯一来源。
///
/// v0.4.1 的 `device_id` 原本散落在 `updater.dart`（灰度哈希用），v0.5.0
/// 抽到这里共用：登录、注册、设备凭据、版本检查必须拿到**同一个** id，
/// 否则服务端会认为是两台设备，指纹凭据与会话对不上。
class DeviceIdentity {
  DeviceIdentity._();

  /// SharedPreferences 中沿用 v0.4.1 的键，保证升级后设备 ID 不漂移。
  static const String storageKey = 'device_id';

  static String? _cachedId;

  /// 读取（没有则生成并落盘）设备 ID。格式 `d<时间戳36进制><随机36进制>`。
  static Future<String> id() async {
    final cached = _cachedId;
    if (cached != null && cached.isNotEmpty) return cached;
    final prefs = await SharedPreferences.getInstance();
    var did = prefs.getString(storageKey);
    if (did == null || did.isEmpty) {
      final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final suffix = (1000 + Random().nextInt(9000)).toRadixString(36);
      did = 'd$now$suffix';
      await prefs.setString(storageKey, did);
    }
    _cachedId = did;
    return did;
  }

  /// 平台标识，与后端 `auth.NormalizeDevice` 的取值一致。
  static String platform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  /// 展示用设备名；插件不可用 / 取不到时一律回退「我的手机」，绝不抛异常。
  static Future<String> name() async {
    if (kIsWeb) return '浏览器';
    try {
      final plugin = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await plugin.androidInfo;
        final parts = <String>[
          info.manufacturer.trim(),
          info.model.trim(),
        ].where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) return _shorten(parts.join(' '));
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final info = await plugin.iosInfo;
        final value = info.name.trim();
        if (value.isNotEmpty) return _shorten(value);
      }
    } catch (_) {
      // 模拟器 / 桌面 / 单测环境没有对应插件实现，走兜底即可。
    }
    return '我的手机';
  }

  static String _shorten(String value) {
    final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    return text.length > 48 ? text.substring(0, 48) : text;
  }
}
