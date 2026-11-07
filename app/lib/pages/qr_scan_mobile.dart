import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// 打开扫码页，返回扫到的字符串（取消返回 null）。仅移动端可用。
Future<String?> scanServerQr(BuildContext context) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const QrScanPage()),
  );
}

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
  late final MobileScannerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.normal,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A10),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppTheme.text,
        title: const Text('扫描服务端二维码'),
        actions: [
          IconButton(
            onPressed: _toggleTorch,
            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            tooltip: '手电筒',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (ctx, err, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '相机不可用：$err\n\n请检查是否已授予相机权限',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 14),
                ),
              ),
            ),
          ),
          // 取景框：纯装饰，不参与手势
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
