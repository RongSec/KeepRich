import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';
import '../theme.dart';

/// 已登录设备管理（R-16）：列出设备名 / 最近活跃时间，可单个撤销或
/// 一键撤销其他所有设备；所有操作都**不影响本机登录态**。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<DeviceSessionItem> _items = <DeviceSessionItem>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.listDevices();
      if (!mounted) return;
      if (r.ok && r.data != null) {
        setState(() {
          _items = r.data!.list;
          _loading = false;
        });
      } else {
        setState(() {
          _error = r.message.isNotEmpty ? r.message : '加载失败，请稍后再试';
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '网络不可用，请检查网络后重试';
        _loading = false;
      });
    }
  }

  String _timeLabel(int unixSeconds) {
    if (unixSeconds <= 0) return '暂无活跃记录';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚活跃';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前活跃';
    if (diff.inHours < 24) return '${diff.inHours} 小时前活跃';
    return '${DateFormat('MM-dd HH:mm').format(dt)} 活跃';
  }

  String _platformLabel(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return '安卓设备';
      case 'ios':
        return '苹果设备';
      case 'web':
        return '网页端';
      case 'windows':
        return '电脑端';
      case 'macos':
        return '电脑端';
      case 'linux':
        return '电脑端';
      default:
        return '其他设备';
    }
  }

  Future<void> _revokeOne(DeviceSessionItem item) async {
    if (_busy) return;
    final name = item.deviceName.isEmpty
        ? _platformLabel(item.platform)
        : item.deviceName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销该设备'),
        content: Text('撤销后「$name」需要重新登录，本机保持登录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await ApiClient.instance.revokeDevice(item.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r.ok ? '已撤销该设备' : (r.message.isEmpty ? '撤销失败' : r.message))));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('网络不可用，请检查网络后重试')));
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _revokeOthers() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销其他所有设备'),
        content: const Text('撤销后这些设备需要重新登录，本机保持登录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤销其他所有设备')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await ApiClient.instance.revokeOthers();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r.ok ? '已撤销其他设备' : (r.message.isEmpty ? '撤销失败' : r.message))));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('网络不可用，请检查网络后重试')));
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final others = _items.where((e) => !e.current).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('已登录设备'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Text(
                          '连续 24 小时未使用的设备会自动退出，可在这里提前撤销。',
                          style: TextStyle(fontSize: 12, color: AppTheme.textDim),
                        ),
                      ),
                      if (_items.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 48),
                          child: Center(
                            child: Text('暂无其他登录设备',
                                style: TextStyle(color: AppTheme.textDim)),
                          ),
                        ),
                      ..._items.map(_deviceTile),
                      if (others > 0) ...[
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 46,
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _revokeOthers,
                            icon: const Icon(Icons.logout, size: 18),
                            label: const Text('撤销其他所有设备'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _deviceTile(DeviceSessionItem item) {
    final name = item.deviceName.isEmpty
        ? _platformLabel(item.platform)
        : item.deviceName;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppTheme.gold.withValues(alpha: 0.14),
              child: Icon(
                item.platform.toLowerCase() == 'web'
                    ? Icons.language
                    : Icons.smartphone,
                color: AppTheme.gold,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (item.current) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.gold.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text('本机',
                              style: TextStyle(
                                  fontSize: 10, color: AppTheme.goldLight)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_platformLabel(item.platform)} · ${_timeLabel(item.lastSeenAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textDim),
                  ),
                ],
              ),
            ),
            if (item.current)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('保持登录',
                    style: TextStyle(fontSize: 11, color: AppTheme.textDim)),
              )
            else
              TextButton(
                onPressed: _busy ? null : () => _revokeOne(item),
                child: const Text('撤销', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48, color: AppTheme.line),
          const SizedBox(height: 10),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13)),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
