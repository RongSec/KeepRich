import 'package:flutter/material.dart';

import '../api.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});
  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<dynamic> _users = [];
  bool _loading = true;
  String? _error;
  String _filter = '';

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
      final r = await ApiClient.instance.get('/admin/users');
      if (!mounted) return;
      if (r['code'] != 0) {
        setState(() {
          _error = r['message'] ?? '加载失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        _users = (r['data'] as List? ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败: $e';
        _loading = false;
      });
    }
  }

  void _showCreateDialog() {
    final u = TextEditingController();
    final p = TextEditingController();
    final n = TextEditingController();
    final e = TextEditingController();
    final ph = TextEditingController();
    String role = 'user';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建账号'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: u, decoration: const InputDecoration(labelText: '账号 (必填)')),
                const SizedBox(height: 8),
                TextField(controller: p, decoration: const InputDecoration(labelText: '初始密码 (至少 6 位)'), obscureText: true),
                const SizedBox(height: 8),
                TextField(controller: n, decoration: const InputDecoration(labelText: '昵称')),
                const SizedBox(height: 8),
                TextField(controller: e, decoration: const InputDecoration(labelText: '邮箱')),
                const SizedBox(height: 8),
                TextField(controller: ph, decoration: const InputDecoration(labelText: '手机号')),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'user', label: Text('普通用户')),
                    ButtonSegment(value: 'admin', label: Text('管理员')),
                  ],
                  selected: {role},
                  onSelectionChanged: (s) => setDialogState(() => role = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                // 验证
                if (u.text.trim().isEmpty) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('请输入账号')),
                  );
                  return;
                }
                if (p.text.length < 6) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('密码至少 6 位')),
                  );
                  return;
                }
                // 关闭对话框
                Navigator.of(dialogContext).pop();
                // 调用 API
                await _doCreate(
                  u.text.trim(),
                  p.text,
                  n.text.trim(),
                  e.text.trim(),
                  ph.text.trim(),
                  role,
                );
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doCreate(String username, String password, String nickname, String email, String phone, String role) async {
    try {
      final r = await ApiClient.instance.post('/admin/users', data: {
        'username': username,
        'password': password,
        'nickname': nickname,
        'email': email,
        'phone': phone,
        'role': role,
      });
      if (!mounted) return;
      if (r['code'] == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('用户创建成功')));
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '创建失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败: $e')));
    }
  }

  Future<void> _toggle(dynamic u) async {
    try {
      final r = await ApiClient.instance.post('/admin/users/${u['id']}/toggle');
      if (!mounted) return;
      if (r['code'] == 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '操作成功')));
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '操作失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失败: $e')));
    }
  }

  Future<void> _delete(dynamic u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除用户'),
        content: Text('确定要删除用户「${u['username']}」吗？此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await ApiClient.instance.delete('/admin/users/${u['id']}');
      if (!mounted) return;
      if (r['code'] == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除')));
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '删除失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  Future<void> _resetPwd(dynamic u) async {
    final pwd = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('重置 ${u['username']} 的密码'),
        content: TextField(
          controller: pwd,
          obscureText: true,
          decoration: const InputDecoration(labelText: '新密码 (至少 6 位)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (pwd.text.length < 6) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('密码至少 6 位')));
                return;
              }
              Navigator.of(ctx).pop(true);
            },
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await ApiClient.instance.post('/admin/users/${u['id']}/reset-password', data: {'newPassword': pwd.text});
      if (!mounted) return;
      if (r['code'] == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码已重置')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message'] ?? '重置失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重置失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? _users
        : _users.where((u) => (u['username'] ?? '').toString().toLowerCase().contains(_filter.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('用户管理'),
        actions: [
          IconButton(
            tooltip: '新建账号',
            onPressed: _showCreateDialog,
            icon: const Icon(Icons.person_add),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.red),
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('重试')),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              labelText: '搜索',
                              prefixIcon: Icon(Icons.search),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (v) => setState(() => _filter = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _showCreateDialog,
                          icon: const Icon(Icons.person_add),
                          label: const Text('新建账号'),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        Text('共 ${filtered.length} 个用户', style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: const [
                              DataColumn(label: Text('ID')),
                              DataColumn(label: Text('账号')),
                              DataColumn(label: Text('昵称')),
                              DataColumn(label: Text('角色')),
                              DataColumn(label: Text('状态')),
                              DataColumn(label: Text('最近登录')),
                              DataColumn(label: Text('操作')),
                            ],
                            rows: filtered.map((u) {
                              final isAdmin = u['role'] == 'admin';
                              final disabled = u['disabled'] == true;
                              return DataRow(cells: [
                                DataCell(Text('${u['id']}')),
                                DataCell(Text(u['username'] ?? '-', style: const TextStyle(fontWeight: FontWeight.w600))),
                                DataCell(Text(u['nickname'] ?? '-')),
                                DataCell(Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isAdmin ? Colors.amber.shade100 : Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(isAdmin ? '管理员' : '普通用户',
                                      style: TextStyle(fontSize: 12, color: isAdmin ? Colors.amber.shade900 : Colors.blue.shade700)),
                                )),
                                DataCell(Text(disabled ? '已停用' : '正常',
                                    style: TextStyle(color: disabled ? Colors.red : Colors.green))),
                                DataCell(Text(u['lastLoginAt'] != null ? u['lastLoginAt'].toString().substring(0, 19) : '-')),
                                DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                                  TextButton(onPressed: () => _resetPwd(u), child: const Text('重置密码')),
                                  TextButton(
                                    onPressed: () => _toggle(u),
                                    child: Text(disabled ? '启用' : '停用',
                                        style: TextStyle(color: disabled ? Colors.green : Colors.orange)),
                                  ),
                                  TextButton(
                                    onPressed: () => _delete(u),
                                    child: const Text('删除', style: TextStyle(color: Colors.red)),
                                  ),
                                ])),
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
}
