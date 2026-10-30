import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// 版本检查结果
class AppUpdateInfo {
  final String version;
  final int buildNumber;
  final String notes;
  final String apkUrl;
  final String sha256;
  final int sizeBytes;
  final bool updateAvailable;
  final bool forceUpdate;

  const AppUpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.notes,
    required this.apkUrl,
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
      final r = await ApiClient.instance.checkAppVersion(
        platform: 'android',
        current: pkg.version,
        did: did,
      );
      if (!r.ok || r.data == null) return null;
      final info = AppUpdateInfo.fromJson(r.data!);
      return info.updateAvailable ? info : null;
    } catch (e) {
      debugPrint('[updater] check failed: $e');
      return null;
    }
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
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
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
  static Future<void> _downloadAndInstall(BuildContext context, AppUpdateInfo info) async {
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
      await dio.download(
        info.apkUrl,
        savePath,
        onReceiveProgress: (rec, total) {
          if (total > 0) {
            progress = rec / total;
            dlg.value = progress;
          }
        },
      );

      // sha256 校验（服务端提供时必检）
      if (info.sha256.isNotEmpty) {
        final bytes = await File(savePath).readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest.toLowerCase() != info.sha256.toLowerCase()) {
          throw Exception('安装包校验失败（sha256 不匹配），已中止安装');
        }
      }

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop(); // 关进度框
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
