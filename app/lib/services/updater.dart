import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

import 'api.dart';

/// 版本检查结果
class AppUpdateInfo {
  final String version;
  final int buildNumber;
  final String notes;
  final String apkUrl;
  /// 云服务代理下载地址（GitHub 直连失败时的兜底，设备只需能访问服务端）
  final String fallbackUrl;
  final String sha256;
  final int sizeBytes;
  final bool updateAvailable;
  final bool forceUpdate;

  const AppUpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.notes,
    required this.apkUrl,
    this.fallbackUrl = '',
    required this.sha256,
    required this.sizeBytes,
    required this.updateAvailable,
    required this.forceUpdate,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> j) => AppUpdateInfo(
        version: (j['version'] as String?) ?? '',
        buildNumber: ((j['buildNumber'] as num?) ?? 0).toInt(),
        notes: (j['notes'] as String?) ?? '',
        apkUrl: (j['apkUrl'] as String?) ?? '',
        fallbackUrl: (() {
          final dl = (j['downloadUrl'] as String?) ?? '';
          if (dl.isEmpty) return '';
          return dl.startsWith('/') ? '${AppConfig.serverHost}$dl' : dl;
        })(),
        sha256: (j['sha256'] as String?) ?? '',
        sizeBytes: ((j['sizeBytes'] as num?) ?? 0).toInt(),
        updateAvailable: (j['updateAvailable'] as bool?) ?? false,
        forceUpdate: (j['forceUpdate'] as bool?) ?? false,
      );
}

/// 在线更新服务（GitHub Releases 分发 + 后端灰度/强更控制）
class UpdaterService {
  /// 生成/读取设备 ID（灰度哈希用，非敏感）
  static Future<String> _deviceId() async {
    final p = await SharedPreferences.getInstance();
    var did = p.getString('device_id');
    if (did == null || did.isEmpty) {
      final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final r = (1000 + DateTime.now().millisecond).toRadixString(36);
      did = 'd$t$r';
      await p.setString('device_id', did);
    }
    return did;
  }

  /// 检查更新；无更新/非 Android 平台返回 null
  static Future<AppUpdateInfo?> check() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final pkg = await PackageInfo.fromPlatform();
      final did = await _deviceId();
      // 设备 ABI：GitHub Release 按架构分发包（arm64-v8a / armeabi-v7a / x86_64）
      String? abi;
      try {
        final dev = await DeviceInfoPlugin().androidInfo;
        abi = dev.supportedAbis.isNotEmpty ? dev.supportedAbis.first : null;
      } catch (_) {}

      final r = await ApiClient.instance.checkAppVersion(
        platform: 'android',
        current: pkg.version,
        did: did,
        abi: abi,
      );
      if (!r.ok || r.data == null) return null;
      final data = r.data!;
      // 后端拿不到 GitHub（沙箱出网受限等）时，App 直连 GitHub 兜底
      if (data['version'] == null || (data['version'] as String).isEmpty) {
        final repo = (data['githubRepo'] as String?) ?? '';
        if (repo.isEmpty) return null;
        final direct = await _checkGitHubDirect(repo, pkg.version, abi);
        return direct;
      }
      final info = AppUpdateInfo.fromJson(data);
      // 本地防线：最新版本与当前版本相同（或后端误判）时绝不弹窗
      if (!info.updateAvailable || info.version == pkg.version) return null;
      // apkUrl 保持 GitHub 直连（优先路径），downloadUrl 作为云服务兜底
      return info;
    } catch (e) {
      debugPrint('[updater] check failed: $e');
      return null;
    }
  }

  /// 直连 GitHub Releases 查询最新版（后端出网受限时的兜底）
  static Future<AppUpdateInfo?> _checkGitHubDirect(
      String repo, String current, String? abi) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ));
      dio.options.headers['User-Agent'] = 'keeprich-app';
      final resp = await dio.get(
          'https://api.github.com/repos/$repo/releases/latest');
      final rel = resp.data as Map<String, dynamic>;
      final version =
          ((rel['tag_name'] as String?) ?? '').replaceFirst(RegExp('^v'), '');
      if (version.isEmpty) return null;

      // 按 ABI 选包，选不到回退第一个 .apk
      Map<String, dynamic>? asset;
      for (final a in (rel['assets'] as List)) {
        final m = a as Map<String, dynamic>;
        final name = (m['name'] as String).toLowerCase();
        if (!name.endsWith('.apk')) continue;
        asset ??= m;
        if (abi != null && name.contains(abi)) {
          asset = m;
          break;
        }
      }
      if (asset == null) return null;

      return AppUpdateInfo(
        version: version,
        buildNumber: 0,
        notes: (rel['body'] as String?) ?? '',
        apkUrl: asset['browser_download_url'] as String,
        sha256: '',
        sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
        updateAvailable: _versionLess(current, version),
        forceUpdate: false,
      );
    } catch (e) {
      debugPrint('[updater] direct github check failed: $e');
      return null;
    }
  }

  /// 简单语义化版本比较：current < latest 返回 true
  static bool _versionLess(String a, String b) {
    List<int> parse(String v) => v
        .replaceFirst(RegExp('^v'), '')
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final pa = parse(a), pb = parse(b);
    for (var i = 0; i < 3; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va < vb;
    }
    return false;
  }

  /// 静默检查 + 弹窗引导更新（启动后调用一次）
  static Future<void> checkAndPrompt(BuildContext context) async {
    final info = await check();
    if (info == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: !info.forceUpdate, // 强更不可取消
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes.isEmpty ? '发现新版本，请更新后使用。' : info.notes),
        ),
        actions: [
          if (!info.forceUpdate)
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadAndInstall(context, info);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  /// 下载 APK → 校验 sha256 → 调起系统安装
  static Future<void> _downloadAndInstall(
      BuildContext context, AppUpdateInfo info) async {
    if (info.apkUrl.isEmpty) {
      _toast(context, '下载地址为空，请稍后再试');
      return;
    }
    final dir = await getTemporaryDirectory();
    final savePath = '${dir.path}/keeprich-${info.version}.apk';

    // 进度弹窗
    if (!context.mounted) return;
    var progress = 0.0;
    final dlg = ValueNotifier<double>(progress);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double>(
          valueListenable: dlg,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v > 0 ? v : null),
              const SizedBox(height: 12),
              Text('${(v * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 10),
      ));
      Future<void> fetch(String url) => dio.download(
            url,
            savePath,
            onReceiveProgress: (rec, total) {
              if (total > 0) {
                progress = rec / total;
                dlg.value = progress;
              }
            },
          );

      // 优先 GitHub 直连（CDN 快、省服务端带宽）；
      // 设备访问不了 GitHub 时自动切云服务代理下载（只需能访问服务端域名）。
      try {
        await fetch(info.apkUrl);
      } catch (e) {
        if (info.fallbackUrl.isEmpty) rethrow;
        debugPrint('[updater] GitHub 直连失败，切换云服务代理下载: $e');
        dlg.value = 0;
        await fetch(info.fallbackUrl);
      }

      // sha256 校验（服务端提供时必检）
      if (info.sha256.isNotEmpty) {
        final bytes = await File(savePath).readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest.toLowerCase() != info.sha256.toLowerCase()) {
          throw Exception('安装包校验失败（sha256 不匹配），已中止安装');
        }
      }

      if (context.mounted)
        Navigator.of(context, rootNavigator: true).pop(); // 关进度框
      final result = await OpenFilex.open(savePath);
      if (result.type != ResultType.done) {
        throw Exception('调起安装失败: ${result.message}');
      }
      if (context.mounted) _toast(context, '已调起安装，请按系统提示完成升级');
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // 关进度框
        _toast(context, '更新失败：$e');
      }
    }
  }

  static void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
