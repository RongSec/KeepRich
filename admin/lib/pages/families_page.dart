import 'package:flutter/material.dart';

import '../api.dart';

class FamiliesPage extends StatefulWidget {
  const FamiliesPage({super.key});
  @override
  State<FamiliesPage> createState() => _FamiliesPageState();
}

class _FamiliesPageState extends State<FamiliesPage> {
  List<dynamic> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await ApiClient.instance.get('/admin/families');
      if (!mounted) return;
      if (r['code'] != 0) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '加载失败')));
        return;
      }
      setState(() {
        _list = (r['data'] as List? ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  void _viewStats(dynamic f) async {
    final id = f['id'];
    try {
      final r = await ApiClient.instance.get('/admin/families/$id/stats');
      if (!mounted) return;
      if (r['code'] != 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '加载失败')));
        return;
      }
      final data = r['data'] as Map<String, dynamic>;
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('家庭统计 - ${f['name'] ?? ''}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _statRow('成员数', '${data['memberCount'] ?? 0}'),
                _statRow('记账条数', '${data['txCount'] ?? 0}'),
                _statRow('总收入', '¥${(data['totalIncome'] as num? ?? 0).toStringAsFixed(2)}'),
                _statRow('总支出', '¥${(data['totalExpense'] as num? ?? 0).toStringAsFixed(2)}'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载统计失败: $e')));
    }
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  void _showDeleteDialog(dynamic f) {
    final id = f['id'];
    final name = f['name'] ?? '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除家庭'),
        content: Text('确定要删除家庭「$name」吗？\n\n此操作将删除该家庭的所有成员关系、记账记录、财务规划等数据，且不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _doDelete(id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _doDelete(int id) async {
    try {
      final r = await ApiClient.instance.delete('/admin/families/$id');
      if (!mounted) return;
      if (r['code'] == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('家庭已删除')));
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '删除失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('家庭管理'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.family_restroom, size: 64, color: Colors.black26),
                      SizedBox(height: 8),
                      Text('暂无家庭', style: TextStyle(color: Colors.black45)),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final f = _list[i] as Map<String, dynamic>;
                    final bound = f['bound'] == true;
                    final memberCount = f['memberCount'] ?? 0;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: bound ? Colors.amber.shade100 : Colors.blue.shade50,
                        child: Icon(
                          bound ? Icons.lock : Icons.family_restroom,
                          color: bound ? Colors.amber.shade700 : Colors.blue,
                        ),
                      ),
                      title: Row(children: [
                        Text(f['name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (bound) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('终身绑定', style: TextStyle(fontSize: 10, color: Colors.amber.shade800)),
                          ),
                        ],
                      ]),
                      subtitle: Text('码：${f['code'] ?? '-'} · $memberCount 人'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.bar_chart, size: 20),
                            tooltip: '统计',
                            onPressed: () => _viewStats(f),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                            tooltip: '删除',
                            onPressed: () => _showDeleteDialog(f),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
