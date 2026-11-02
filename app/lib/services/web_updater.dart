import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config.dart';
import 'api.dart';
import 'web_reload_stub.dart' if (dart.library.js_interop) 'web_reload_web.dart'
    as reloader;

/// Web 端新版本信息
class WebUpdateInfo {
  final String version;
  final int buildNumber;
  final String notes;

  const WebUpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.notes,
  });
}

/// Web 端在线更新
///
/// 与 App（APK 整体替换）不同，Web 的"更新"= 部署新的构建产物后，
/// 让已经打开页面的用户拿到最新代码。流程：
///   1. 页面启动后 / 每 10 分钟 / 回到前台时，请求后端 `/api/app/web-version`
///   2. 服务端返回当前部署的 Web 版本（管理员在后台维护）
///   3. 与当前运行中的构建版本（编译期注入的 APP_VERSION）比较
///   4. 有更新 → UI 顶部出现"有新版本，点此刷新"，点击后清缓存 + 硬刷新
class WebUpdater {
  WebUpdater._();
  static final WebUpdater instance = WebUpdater._();

  /// 有新版本时非空，UI 监听它来显示提示条
  final ValueNotifier<WebUpdateInfo?> available = ValueNotifier(null);

  Timer? _timer;
  bool _started = false;
  bool _checking = false;

  /// 当前运行的构建版本
  String get currentVersion => AppConfig.appVersion;

  /// 用户手动忽略的版本（避免反复弹）
  String? _dismissed;

  Future<void> start({Duration interval = const Duration(minutes: 10)}) async {
    if (!kIsWeb || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(_LifecycleWatcher(this));
    await check();
    _timer = Timer.periodic(interval, (_) => check());
  }

  Future<WebUpdateInfo?> check({bool force = false}) async {
    if (!kIsWeb || _checking) return available.value;
    _checking = true;
    try {
      final r = await ApiClient.instance.checkWebVersion(
        buildNumber: AppConfig.envBuildNumber,
      );
      if (!r.ok || r.data == null) return available.value;
      final d = r.data!;
      final version = (d['version'] as String?) ?? '';
      final build = ((d['buildNumber'] as num?) ?? 0).toInt();
      final notes = (d['notes'] as String?) ?? '';
      if (version.isEmpty) return available.value;

      final newer = compareVersion(currentVersion, version) < 0 ||
          (build > AppConfig.envBuildNumber && AppConfig.envBuildNumber > 0);

      if (!newer) {
        available.value = null;
        return null;
      }
      if (!force && _dismissed == version) return available.value;
      final info =
          WebUpdateInfo(version: version, buildNumber: build, notes: notes);
      available.value = info;
      return info;
    } catch (_) {
      return available.value;
    } finally {
      _checking = false;
    }
  }

  /// 本次会话内忽略该版本
  void dismiss() {
    _dismissed = available.value?.version;
    available.value = null;
  }

  /// 立即刷新到最新版本
  Future<void> applyUpdate() async {
    await reloader.hardReload();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    available.dispose();
  }

  /// 语义化版本比较：a < b 返回 -1
  static int compareVersion(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    for (var i = 0; i < 3; i++) {
      final va = i < pa.length ? (int.tryParse(pa[i].trim()) ?? 0) : 0;
      final vb = i < pb.length ? (int.tryParse(pb[i].trim()) ?? 0) : 0;
      if (va != vb) return va < vb ? -1 : 1;
    }
    return 0;
  }
}

/// 回到前台时补一次检查（用户切回标签页时就能看到更新提示）
class _LifecycleWatcher with WidgetsBindingObserver {
  _LifecycleWatcher(this._owner);
  final WebUpdater _owner;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _owner.check();
  }
}
