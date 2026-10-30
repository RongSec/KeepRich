import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/api.dart';
import '../../services/auth.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;
  final _pages = const [
    AdminUsersPage(),
    AdminFamiliesPage(),
    AdminErrorsPage(),
    AdminAuditPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    if (auth.user?.role != 'admin') {
      // 不是管理员
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/admin/login');
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理页面'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              auth.logout();
              context.go('/admin/login');
            },
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people), label: '用户'),
          NavigationDestination(icon: Icon(Icons.family_restroom), label: '家庭'),
          NavigationDestination(icon: Icon(Icons.bug_report), label: '错误'),
          NavigationDestination(icon: Icon(Icons.list_alt), label: '审计'),
        ],
      ),
    );
  }
}

class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});
  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiClient.instance.adminListUsers();
    if (!mounted) return;
    if (r.ok && r.data != null) {
      setState(() {
        _users = List<Map<String, dynamic>>.from(r.data as List);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _toggle(int id, bool disabled) async {
    final r = await ApiClient.instance.adminToggleUser(id, !disabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已更新' : r.message)));
    _load();
  }

  Future<void> _resetPassword(int id, String username) async {
    final pwd = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('重置 $username 密码'),
        content: TextField(
          controller: pwd,
          obscureText: true,
          decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    if (pwd.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码至少 8 位')));
      return;
    }
    final r = await ApiClient.instance.adminResetPassword(id, pwd.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已重置' : r.message)));
  }

  Future<void> _resetMfa(int id, String username) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('重置 $username 的 MFA？'),
        content: const Text('用户将需要重新绑定 MFA 才能登录'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
        ],
      ),
    );
    if (confirm != true) return;
    final r = await ApiClient.instance.adminResetMfa(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已重置' : r.message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _users.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final u = _users[i];
          final disabled = u['disabled'] as bool? ?? false;
          return ListTile(
            leading: CircleAvatar(child: Text(((u['nickname'] as String? ?? 'U').characters.first))),
            title: Text('${u['nickname'] ?? ''} (${u['username']})'),
            subtitle: Text('${u['role']} · MFA ${u['mfaEnabled'] == true ? '已开启' : '未开启'}'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'toggle') _toggle(u['id'] as int, disabled);
                if (v == 'reset_pwd') _resetPassword(u['id'] as int, u['username']);
                if (v == 'reset_mfa') _resetMfa(u['id'] as int, u['username']);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'toggle', child: Text(disabled ? '启用' : '停用')),
                const PopupMenuItem(value: 'reset_pwd', child: Text('重置密码')),
                const PopupMenuItem(value: 'reset_mfa', child: Text('重置 MFA')),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AdminFamiliesPage extends StatefulWidget {
  const AdminFamiliesPage({super.key});
  @override
  State<AdminFamiliesPage> createState() => _AdminFamiliesPageState();
}

class _AdminFamiliesPageState extends State<AdminFamiliesPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _families = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiClient.instance.adminListFamilies();
    if (!mounted) return;
    if (r.ok && r.data != null) {
      setState(() {
        _families = List<Map<String, dynamic>>.from(r.data as List);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _viewStats(Map<String, dynamic> f) async {
    final id = f['id'] as int;
    final r = await ApiClient.instance.adminFamilyStats(id);
    if (!mounted) return;
    if (!r.ok || r.data == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
      return;
    }
    final d = r.data!;
    final f2 = NumberFormat('#,##0.00');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${f['name']} 统计'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('家庭 ID: ${d['family']['id']}'),
            Text('家庭名: ${d['family']['name']}'),
            Text('管理员 UID: ${d['family']['adminUid']}'),
            Text('绑定状态: ${d['family']['bound'] == true ? '已终身绑定' : '未绑定'}'),
            const Divider(),
            Text('成员数: ${d['memberCount']}'),
            Text('记账笔数: ${d['txCount']}'),
            Text('总收入: ${f2.format(d['totalIncome'])} 元'),
            Text('总支出: ${f2.format(d['totalExpense'])} 元'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除家庭 "${f['name']}"？'),
        content: const Text('将一并删除所有成员、记账、规划、删除请求等，且不可恢复'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(context, true), child: const Text('强制删除')),
        ],
      ),
    );
    if (confirm != true) return;
    final r = await ApiClient.instance.adminDeleteFamily(f['id'] as int);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已删除' : r.message)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_families.isEmpty) {
      return const Center(child: Text('暂无家庭'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _families.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final f = _families[i];
          return ListTile(
            leading: CircleAvatar(child: Text(((f['name'] as String? ?? 'F').characters.first))),
            title: Text('${f['name']} (#${f['id']})'),
            subtitle: Text('成员 ${f['memberCount']} · 邀请码 ${f['code']} · 绑定 ${f['bound'] == true ? '是' : '否'}'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'stats') _viewStats(f);
                if (v == 'delete') _delete(f);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'stats', child: Text('查看统计')),
                PopupMenuItem(value: 'delete', child: Text('强制删除', style: TextStyle(color: Colors.red))),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AdminErrorsPage extends StatefulWidget {
  const AdminErrorsPage({super.key});
  @override
  State<AdminErrorsPage> createState() => _AdminErrorsPageState();
}

class _AdminErrorsPageState extends State<AdminErrorsPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _errors = [];
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiClient.instance.adminListErrors();
    if (!mounted) return;
    if (r.ok && r.data != null) {
      setState(() {
        _errors = List<Map<String, dynamic>>.from(r.data as List);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _delete(int id) async {
    final r = await ApiClient.instance.adminDeleteError(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已删除' : r.message)));
    _load();
  }

  Future<void> _clear() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空所有错误？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
        ],
      ),
    );
    if (confirm != true) return;
    final r = await ApiClient.instance.adminClearErrors();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已清空' : r.message)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    var filtered = _errors;
    if (_filter != 'all') {
      filtered = _errors.where((e) => (e['platform'] ?? '') == _filter).toList();
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          ChoiceChip(label: const Text('全部'), selected: _filter == 'all', onSelected: (_) => setState(() => _filter = 'all')),
          const SizedBox(width: 6),
          ChoiceChip(label: const Text('Web'), selected: _filter == 'web', onSelected: (_) => setState(() => _filter = 'web')),
          const SizedBox(width: 6),
          ChoiceChip(label: const Text('Android'), selected: _filter == 'android', onSelected: (_) => setState(() => _filter = 'android')),
          const Spacer(),
          OutlinedButton.icon(onPressed: _clear, icon: const Icon(Icons.delete_sweep), label: const Text('清空')),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final e = filtered[i];
                    return ExpansionTile(
                      title: Text('${e['platform']} / ${e['app']} · ${e['message']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(((e['createdAt'] ?? 0) as num).toInt() * 1000))),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SelectableText('URL: ${e['url'] ?? ''}'),
                            const SizedBox(height: 4),
                            SelectableText('版本: ${e['version'] ?? ''}'),
                            const SizedBox(height: 4),
                            const Text('Stack:', style: TextStyle(fontWeight: FontWeight.bold)),
                            SelectableText(e['stack']?.toString() ?? ''),
                            const SizedBox(height: 4),
                            SelectableText('Extra: ${e['extra'] ?? ''}'),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(onPressed: () => _delete(e['id'] as int), icon: const Icon(Icons.delete), label: const Text('删除')),
                            ),
                          ]),
                        ),
                      ],
                    );
                  },
                ),
              ),
      ),
    ]);
  }
}

class AdminAuditPage extends StatefulWidget {
  const AdminAuditPage({super.key});
  @override
  State<AdminAuditPage> createState() => _AdminAuditPageState();
}

class _AdminAuditPageState extends State<AdminAuditPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _logs = [];
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiClient.instance.adminListAudit(keyword: _search.text);
    if (!mounted) return;
    if (r.ok && r.data != null) {
      setState(() {
        _logs = List<Map<String, dynamic>>.from(r.data as List);
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
            hintText: '搜索用户名/路径/详情',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          ),
          onSubmitted: (_) => _load(),
        ),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.separated(
                itemCount: _logs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final l = _logs[i];
                  final status = l['status'] as String? ?? 'ok';
                  return ListTile(
                    leading: Icon(
                      status == 'ok' ? Icons.check_circle : Icons.error,
                      color: status == 'ok' ? Colors.green : Colors.red,
                    ),
                    title: Text('${l['action']}  · ${l['username'] ?? ''}'),
                    subtitle: Text(
                      '${l['target']}  ·  ${l['ip'] ?? ''}\n${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(((l['createdAt'] ?? 0) as num).toInt() * 1000))}',
                    ),
                    isThreeLine: true,
                  );
                },
              ),
      ),
    ]);
  }
}
