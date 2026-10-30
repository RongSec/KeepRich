import 'package:flutter/material.dart';

import '../api.dart';

class AuditPage extends StatefulWidget {
  const AuditPage({super.key});
  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  List<dynamic> _list = [];
  bool _loading = true;
  String _keyword = '';
  String? _action;
  String? _status;
  int _page = 1;
  int _total = 0;

  static const _actionOptions = [
    {'value': '', 'label': '全部操作'},
    {'value': 'auth.login', 'label': '登录'},
    {'value': 'tx.create', 'label': '记账'},
    {'value': 'family.create', 'label': '创建家庭'},
    {'value': 'family.apply_join', 'label': '申请加入'},
    {'value': 'family.approve', 'label': '审批'},
    {'value': 'plan.save', 'label': '保存规划'},
    {'value': 'admin.create_user', 'label': '创建用户'},
    {'value': 'admin.reset_password', 'label': '重置密码'},
    {'value': 'admin.toggle_user', 'label': '启停用户'},
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await ApiClient.instance.get('/admin/audit', query: {
        if (_keyword.isNotEmpty) 'keyword': _keyword,
        if (_action != null && _action!.isNotEmpty) 'action': _action,
        if (_status != null && _status!.isNotEmpty) 'status': _status,
        'page': _page.toString(),
        'size': '50',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('审计日志'),
        actions: [
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
                    _page = 1;
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _action ?? '',
                  decoration: const InputDecoration(
                    labelText: '操作类型',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _actionOptions
                      .map((e) => DropdownMenuItem(
                            value: e['value']!,
                            child: Text(e['label']!, style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    setState(() => _action = v);
                    _page = 1;
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _status ?? '',
                  decoration: const InputDecoration(
                    labelText: '状态',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'ok', child: Text('成功', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'fail', child: Text('失败', style: TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) {
                    setState(() => _status = v);
                    _page = 1;
                    _load();
                  },
                ),
              ),
            ]),
          ),
          // 统计
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Text('共 $_total 条记录', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              if (_total > 50)
                Row(children: [
                  TextButton(
                    onPressed: _page > 1
                        ? () {
                            _page--;
                            _load();
                          }
                        : null,
                    child: const Text('上一页'),
                  ),
                  Text('$_page / ${(_total / 50).ceil()}'),
                  TextButton(
                    onPressed: _page < (_total / 50).ceil()
                        ? () {
                            _page++;
                            _load();
                          }
                        : null,
                    child: const Text('下一页'),
                  ),
                ]),
            ]),
          ),
          const SizedBox(height: 4),
          // 列表
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _list.isEmpty
                    ? const Center(child: Text('暂无日志'))
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: DataTable(
                            columnSpacing: 16,
                            columns: const [
                              DataColumn(label: Text('ID'), numeric: true),
                              DataColumn(label: Text('时间')),
                              DataColumn(label: Text('用户')),
                              DataColumn(label: Text('操作')),
                              DataColumn(label: Text('目标')),
                              DataColumn(label: Text('IP')),
                              DataColumn(label: Text('状态')),
                              DataColumn(label: Text('详情')),
                            ],
                            rows: _list.map((e) {
                              final isOk = e['status'] == 'ok';
                              return DataRow(cells: [
                                DataCell(Text('${e['id'] ?? ''}')),
                                DataCell(Text(_formatTime(e['created_at'] ?? ''), style: const TextStyle(fontSize: 12))),
                                DataCell(Text('${e['username'] ?? e['uid'] ?? '-'}')),
                                DataCell(Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.indigo.shade50,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text('${e['action'] ?? '-'}', style: const TextStyle(fontSize: 11)),
                                )),
                                DataCell(
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 200),
                                    child: Text('${e['target'] ?? '-'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                  ),
                                ),
                                DataCell(Text('${e['ip'] ?? '-'}', style: const TextStyle(fontSize: 12))),
                                DataCell(Text(
                                  isOk ? '成功' : '失败',
                                  style: TextStyle(color: isOk ? Colors.green : Colors.red, fontSize: 12),
                                )),
                                DataCell(
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 200),
                                    child: Text('${e['detail'] ?? ''}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                                  ),
                                ),
                              ]);
                            }).toList(),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  String _formatTime(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    if (s.length >= 19) return s.substring(0, 19);
    return s;
  }
}
