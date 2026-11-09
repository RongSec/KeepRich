import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../config.dart';
import '../services/api.dart';
import '../theme.dart';

/// 打开扫码页，返回扫到的字符串（取消/失败返回 null）。仅移动端可用。
Future<String?> scanServerQr(BuildContext context) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const QrScanPage()),
  );
}

/// 扫码失败的四级分类（R-10）
///
/// 只有这 4 个出口 —— UI 里禁止再出现 `switch (err.errorCode)` 之类的散落判断。
enum ScanFailure {
  /// 相机权限被拒（或用户在系统弹窗里点了"拒绝"）
  permissionDenied,

  /// 设备不支持相机 / 无相机硬件
  unsupported,

  /// 相机被其它 App 占用（Android 上很常见：CameraDevice 被独占）
  cameraInUse,

  /// 初始化失败（含 R8 把 MLKit 内部类改名这类兜底情形）
  initFailed,
}

/// `MobileScannerException` → [ScanFailure] 的唯一映射出口。
///
/// mobile_scanner 5.2.3 的 `MobileScannerErrorCode` 只有
/// `controllerAlreadyInitialized / controllerDisposed / controllerUninitialized /
/// genericError / permissionDenied / unsupported` 六个值，
/// **没有** `controllerInitializationError`（设计文档里假设的那个值在本版本不存在），
/// 所以"相机被占用"只能靠 `errorDetails` 的文案细分。
ScanFailure mapScanError(MobileScannerException e) {
  switch (e.errorCode) {
    case MobileScannerErrorCode.permissionDenied:
      return ScanFailure.permissionDenied;
    case MobileScannerErrorCode.unsupported:
      return ScanFailure.unsupported;
    case MobileScannerErrorCode.genericError:
    case MobileScannerErrorCode.controllerAlreadyInitialized:
    case MobileScannerErrorCode.controllerDisposed:
    case MobileScannerErrorCode.controllerUninitialized:
      return _isCameraInUse(e) ? ScanFailure.cameraInUse : ScanFailure.initFailed;
  }
}

/// CameraX 在"相机被占用"时抛的也是初始化/通用错误，只能靠 message 细分
bool _isCameraInUse(MobileScannerException e) {
  final d = e.errorDetails;
  final msg = '${d?.message ?? ''} ${d?.code ?? ''} ${d?.details ?? ''}'
      .toLowerCase();
  return msg.contains('in use') ||
      msg.contains('inuse') ||
      msg.contains('disconnected') ||
      msg.contains('camerasource') ||
      msg.contains('camera device') ||
      msg.contains('open camera');
}

/// 失败分级 → 图标 / 文案 / 按钮 的唯一来源（R-10 的验收口径就落在这里）
class _FailureCopy {
  const _FailureCopy({
    required this.icon,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.secondaryLabel,
  });

  final IconData icon;
  final String title;

  /// 中文原因。**不得**出现任何 exception 类名 / 堆栈字符串。
  final String message;
  final String primaryLabel;
  final String secondaryLabel;
}

const Map<ScanFailure, _FailureCopy> _copy = {
  ScanFailure.permissionDenied: _FailureCopy(
    icon: Icons.no_photography_outlined,
    title: '相机权限未开启',
    message: '请在「系统设置 → 应用 → 永远富裕 → 权限」中允许使用相机，然后重试。',
    primaryLabel: '重新申请权限',
    secondaryLabel: '手动输入服务端地址',
  ),
  ScanFailure.unsupported: _FailureCopy(
    icon: Icons.videocam_off_outlined,
    title: '当前设备不支持相机扫码',
    message: '当前设备不支持相机扫码，请手动输入服务端地址。',
    primaryLabel: '手动输入服务端地址',
    secondaryLabel: '返回',
  ),
  ScanFailure.cameraInUse: _FailureCopy(
    icon: Icons.phonelink_erase_outlined,
    title: '相机被占用',
    message: '相机被其他应用占用，请关闭后重试。',
    primaryLabel: '重试',
    secondaryLabel: '手动输入服务端地址',
  ),
  ScanFailure.initFailed: _FailureCopy(
    icon: Icons.error_outline,
    title: '相机启动失败',
    message: '相机启动失败，请重试或手动输入服务端地址。',
    primaryLabel: '重试',
    secondaryLabel: '手动输入服务端地址',
  ),
};

/// 服务端地址二维码扫描页
///
/// Web 端登录页会展示一张包含服务端地址（含分享码）的二维码，
/// App 在这里扫码后回传字符串，由调用方解析并填入。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  /// 防止同一帧重复回调
  bool _done = false;

  bool _torchOn = false;

  /// 重建控制器用的 key（重试时自增）
  int _attempt = 0;

  /// 当前失败分级；null = 相机工作正常
  ScanFailure? _failure;

  /// 同一页面生命周期只上报一次（避免每次 rebuild 都刷一条）
  bool _reported = false;

  String _deviceModel = '';
  int _sdkInt = 0;

  late MobileScannerController _controller;

  MobileScannerController _newController() => MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.normal,
      );

  @override
  void initState() {
    super.initState();
    _controller = _newController();
    _collectDeviceInfo();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 机型 / SDK 版本：只用于错误上报的可诊断信息，取不到就留空
  Future<void> _collectDeviceInfo() async {
    if (kIsWeb) return;
    try {
      final info = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.android) {
        final a = await info.androidInfo;
        _deviceModel = '${a.manufacturer} ${a.model}';
        _sdkInt = a.version.sdkInt;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final i = await info.iosInfo;
        _deviceModel = i.utsname.machine;
      }
    } catch (_) {
      // 拿不到机型不影响主流程
    }
  }

  /// 权限被拒 / 相机异常后重建控制器并重新申请权限
  void _retry() {
    _controller.dispose();
    _controller = _newController();
    setState(() {
      _failure = null;
      _attempt++;
    });
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final v = barcode.rawValue;
      if (v == null || v.isEmpty) continue;
      _done = true;
      Navigator.pop(context, v.trim());
      return;
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (!mounted) return;
      setState(() => _torchOn = !_torchOn);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前设备不支持手电筒')),
      );
    }
  }

  /// 扫码失败上报（`scan_failed:<code>` + 机型/SDK/错误码）
  ///
  /// 上报失败必须完全静默：这条链路本身在"相机坏了"的场景里跑，
  /// 不能再往上抛异常（`/api/errors` 还需要登录态，未登录时会 401）。
  Future<void> _reportFailure(ScanFailure failure, MobileScannerException e) async {
    if (_reported) return;
    _reported = true;
    final details = e.errorDetails;
    final detail = <String>[
      if (details?.message != null) details!.message!,
      if (details?.code != null) 'code=${details!.code}',
    ].join(' | ');
    try {
      await ApiClient.instance.reportError(
        message: 'scan_failed:${failure.name}',
        errorCode: e.errorCode.name,
        extra: jsonEncode({
          'errorCode': e.errorCode.name,
          'failure': failure.name,
          'detail': detail,
          'model': _deviceModel,
          'sdkInt': _sdkInt,
        }),
        platform: defaultTargetPlatform.name,
        app: 'client',
        version: AppConfig.appVersion,
      );
    } catch (_) {
      // 静默：上报失败不影响用户看到可读文案 + 重试按钮
    }
  }

  void _onCameraError(MobileScannerException e) {
    final failure = mapScanError(e);
    if (_failure == failure) return;
    _failure = failure;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
    });
    _reportFailure(failure, e);
  }
  /// 手动输入：回到上一页（服务端地址对话框），输入框仍是用户手上的焦点
  void _manualInput() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final copy = failure == null ? null : _copy[failure]!;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A10),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppTheme.text,
        title: const Text('扫描服务端二维码'),
        actions: [
          IconButton(
            onPressed: failure == null ? _toggleTorch : null,
            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            tooltip: '手电筒',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            key: ValueKey(_attempt),
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (ctx, err, _) {
              _onCameraError(err);
              if (copy == null) return const SizedBox.shrink();
              // 不支持相机的设备上"重试"没有意义 → 主按钮直接给手动输入
              final primary =
                  failure == ScanFailure.unsupported ? _manualInput : _retry;
              return _FailureView(
                copy: copy,
                onPrimary: primary,
                // 次按钮对四级失败都是"退回手动输入"（unsupported 下文案是「返回」）
                onSecondary: _manualInput,
              );
            },
          ),
          // 取景框：纯装饰，不参与手势；相机报错时隐藏以免压住提示文字
          if (failure == null)
            const IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: 240,
                  height: 240,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.fromBorderSide(
                        BorderSide(color: AppTheme.gold, width: 2),
                      ),
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                  ),
                ),
              ),
            ),
          if (failure == null)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: Text(
                '对准 Web 端登录页上的「App 扫码连接」二维码',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

/// 失败态：图标 + 中文原因 + 主/次按钮（三段式，纵向居中）
class _FailureView extends StatelessWidget {
  const _FailureView({
    required this.copy,
    required this.onPrimary,
    required this.onSecondary,
  });

  final _FailureCopy copy;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    // 覆盖住 MobileScanner 自己的黑底，避免文案与取景残留叠在一起
    return ColoredBox(
      color: const Color(0xFF0A0A10),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(copy.icon, size: 48, color: AppTheme.goldDeep),
              const SizedBox(height: 16),
              Text(
                copy.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                copy.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textDim, fontSize: 14),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onPrimary,
                  child: Text(copy.primaryLabel),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: onSecondary,
                  child: Text(copy.secondaryLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
