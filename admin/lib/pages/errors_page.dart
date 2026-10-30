import 'package:flutter/material.dart';

import '../api.dart';

class ErrorsPage extends StatefulWidget {
  const ErrorsPage({super.key});
  @override
  State<ErrorsPage> createState() => _ErrorsPageState();
}

class _ErrorsPageState extends State<ErrorsPage> {
  List<dynamic> _list = [];
  bool _loading = true;
  String _keyword = '';
  String? _platform;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await ApiClient.instance.get('/admin/errors', query: {
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        if (_platform != null && _platform!.isNotEmpty) 'platform': _platform,
        'page': '1',
        'size': '200',
      });
      if (!mounted) return;
      if (r['code'] != 0) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '加载失败')));
        return;
      }
      final data = r['data'] as Map<String, dynamic>? ?? {};
      setState(() {
        _list = (data['list'] as List? ?? []);
        _total = (data['total'] as num? ?? 0).toInt();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  Future<void> _delete(int id) async {
    final r = await ApiClient.instance.delete('/admin/errors/$id');
    if (!mounted) return;
    if (r['code'] == 0) {
      _load();
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空所有错误报告'),
        content: const Text('确定要清空所有错误报告吗？此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ApiClient.instance.delete('/admin/errors');
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('错误报告'),
        actions: [
          if (_list.isNotEmpty)
            TextButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep, color: Colors.red),
              label: const Text('清空', style: TextStyle(color: Colors.red)),
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          // 筛选栏
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                flex: 2,
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: '搜索',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    _keyword = v;
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _platform ?? '',
                  decoration: const InputDecoration(
                    labelText: '平台',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'web', child: Text('Web', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'android', child: Text('Android', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'ios', child: Text('iOS', style: TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) {
                    setState(() => _platform = v);
                    _load();
                  },
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Text('共 $_total 条错误报告', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          const SizedBox(height: 4),
          // 列表
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _list.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                            SizedBox(height: 8),
                            Text('暂无错误报告', style: TextStyle(color: Colors.black54)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final e = _list[i] as Map<String, dynamic>;
                          return _ErrorTile(
                            error: e,
                            onDelete: () => _delete((e['id'] as num).toInt()),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  final Map<String, dynamic> error;
  final VoidCallback onDelete;
  const _ErrorTile({required this.error, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final platform = error['platform'] ?? '-';
    final app = error['app'] ?? '-';
    final message = error['message'] ?? '-';
    final url = error['url'] ?? '';
    final stack = error['stack'] ?? '';
    final time = error['createdAt'] ?? error['created_at'] ?? '';

    IconData platformIcon;
    Color platformColor;
    switch (platform) {
      case 'android':
        platformIcon = Icons.android;
        platformColor = Colors.green;
        break;
      case 'ios':
        platformIcon = Icons.phone_iphone;
        platformColor = Colors.blue;
        break;
      default:
        platformIcon = Icons.language;
        platformColor = Colors.indigo;
    }

    return ExpansionTile(
      leading: CircleAvatar(
        backgroundColor: platformColor.withOpacity(0.15),
        child: Icon(platformIcon, color: platformColor, size: 20),
      ),
      title: Text(
        message.toString().length > 100 ? '${message.toString().substring(0, 100)}...' : message.toString(),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      subtitle: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: platformColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('$platform · $app', style: TextStyle(fontSize: 10, color: platformColor)),
        ),
        const SizedBox(width: 8),
        Text(_formatTime(time), style: const TextStyle(fontSize: 11, color: Colors.black45)),
      ]),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
        onPressed: onDelete,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (url.toString().isNotEmpty) ...[
                Text('URL: $url', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 4),
              ],
              if (error['uid'] != null) ...[
                Text('用户 ID: ${error['uid']}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 4),
              ],
              if (error['version'] != null && error['version'].toString().isNotEmpty) ...[
                Text('版本: ${error['version']}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 4),
              ],
              if (stack.toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    stack.toString(),
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black87),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _formatTime(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    if (s.length >= 19) return s.substring(0, 19);
    return s;
  }
}
