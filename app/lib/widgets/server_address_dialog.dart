import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../config.dart';
import '../services/api.dart';
import '../theme.dart';
import '../pages/qr_scan.dart';

/// 服务端地址设置弹窗
///
/// 登录前后都能打开：本地联调时在模拟器里填 `10.0.2.2:28080`，
/// 真机填电脑局域网 IP（如 `192.168.1.8:28080`）。
Future<void> showServerAddressDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ServerAddressDialog(),
  );
}

class _ServerAddressDialog extends StatefulWidget {
  const _ServerAddressDialog();

  @override
  State<_ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<_ServerAddressDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: AppConfig.serverHost);
  bool _busy = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final err = await AppConfig.probe(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = err == null;
      _result = err ?? '连接成功，服务可用';
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await AppConfig.setServerHost(_ctrl.text);
    ApiClient.instance.rebuild();
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('服务端已切换到 ${AppConfig.serverHost}')),
    );
  }

  Future<void> _reset() async {
    await AppConfig.setServerHost(null);
    ApiClient.instance.rebuild();
    if (!mounted) return;
    setState(() {
      _ctrl.text = AppConfig.serverHost;
      _result = '已恢复平台默认地址';
      _ok = true;
    });
  }

  /// 扫码填入：Web 登录页会展示服务端地址二维码，扫完自动填并探测
  Future<void> _scan() async {
    final value = await scanServerQr(context);
    if (value == null || value.isEmpty || !mounted) return;
    setState(() {
      _ctrl.text = value;
      _result = null;
    });
    await _test();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('服务端地址'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'API 地址',
                hintText: 'http://192.168.1.8:28080',
                prefixIcon: const Icon(Icons.dns_outlined),
                // 手机上支持扫 Web 端的服务端二维码
                suffixIcon: kIsWeb
                    ? null
                    : IconButton(
                        tooltip: '扫码',
                        icon: const Icon(Icons.qr_code_scanner),
                        onPressed: _scan,
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '当前生效：${AppConfig.serverHost}\n来源：${AppConfig.sourceLabel}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textDim),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _preset('模拟器', AppConfig.androidEmulatorHost),
                _preset('本机', AppConfig.localhostHost),
              ],
            ),
            if (_result != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: _ok
                        ? AppTheme.gold
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _result!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _ok
                            ? AppTheme.gold
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _reset,
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: _busy ? null : _test,
          child: const Text('测试连接'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _preset(String label, String host) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () => setState(() {
        _ctrl.text = host;
        _result = null;
      }),
    );
  }
}
