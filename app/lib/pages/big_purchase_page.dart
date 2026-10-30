import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';

class BigPurchasePage extends StatefulWidget {
  const BigPurchasePage({super.key});
  @override
  State<BigPurchasePage> createState() => _BigPurchasePageState();
}

class _BigPurchasePageState extends State<BigPurchasePage> {
  String _scope = 'personal';
  List<PurchaseItem> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiClient.instance.purchaseList(scope: _scope);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _list = r.data ?? [];
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _showForm({PurchaseItem? initial}) async {
    final name = TextEditingController(text: initial?.name ?? '');
    final price = TextEditingController(text: initial != null ? initial.price.toString() : '');
    final priority = TextEditingController(text: '${initial?.priority ?? 1}');
    final note = TextEditingController(text: initial?.note ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(initial == null ? '新增大件' : '编辑大件'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称')),
              TextField(
                controller: price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(labelText: '预算（元）', prefixText: '¥ '),
              ),
              TextField(
                controller: priority,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '优先级（数字越小越优先）'),
              ),
              TextField(controller: note, decoration: const InputDecoration(labelText: '备注（可选）')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final body = <String, dynamic>{
      'scope': _scope,
      'name': name.text,
      'price': double.tryParse(price.text) ?? 0,
      'priority': int.tryParse(priority.text) ?? 0,
      'note': note.text,
    };
    dynamic r;
    if (initial == null) {
      r = await ApiClient.instance.createPurchase(body);
    } else {
      r = await ApiClient.instance.updatePurchasePlan(initial.id, body);
    }
    if (r.ok) {
      _load();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  Future<void> _delete(PurchaseItem p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除大件规划「${p.name}」？该操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton.tonal(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.deletePurchasePlan(p.id);
    if (r.ok) {
      _load();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat('#,##0.00');
    return Scaffold(
      appBar: AppBar(title: const Text('大件购买规划')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'personal', label: Text('个人')),
                      ButtonSegment(value: 'family', label: Text('家庭')),
                    ],
                    selected: {_scope},
                    onSelectionChanged: (s) {
                      setState(() => _scope = s.first);
                      _load();
                    },
                  ),
                ),
                Expanded(
                  child: _list.isEmpty
                      ? const Center(child: Text('暂无规划，点击右下角添加'))
                      : ListView.separated(
                          itemCount: _list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final p = _list[i];
                            return ListTile(
                              leading: CircleAvatar(child: Text('${p.priority}')),
                              title: Text(p.name),
                              subtitle: Text('${f.format(p.price)} 元${p.achieved ? " · 已达成" : ""}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    tooltip: '编辑',
                                    onPressed: () => _showForm(initial: p),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                                    tooltip: '删除',
                                    onPressed: () => _delete(p),
                                  ),
                                  Icon(
                                    p.achieved ? Icons.check_circle : Icons.flag,
                                    color: p.achieved ? Colors.green : null,
                                  ),
                                ],
                              ),
                              onTap: () => _showForm(initial: p),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showForm(),
        icon: const Icon(Icons.add),
        label: const Text('新增'),
      ),
    );
  }
}
