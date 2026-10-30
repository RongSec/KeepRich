import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api.dart';
import '../services/auth.dart';
import '../services/biometric.dart';
import '../services/notify.dart';
import '../services/updater.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthState>().user;
    final notify = context.watch<NotifyService>();
    final unreadCount = notify.unreadCount;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    (user?.nickname.isNotEmpty == true) ? user!.nickname.characters.first : 'U',
                    style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 24),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user?.nickname.isNotEmpty == true ? user!.nickname : (user?.username ?? ''), style: Theme.of(context).textTheme.titleMedium),
                      Text(user?.email ?? user?.phone ?? '', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.edit), onPressed: () {}),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (unreadCount > 0)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
                      constraints: const BoxConstraints(minWidth: 14),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            title: const Text('通知中心'),
            subtitle: const Text('查看超支提醒、大件可购买、家庭申请等通知'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsPage()));
              if (mounted) notify.loadUnreadCount();
            },
          ),
          ListTile(
            leading: const Icon(Icons.family_restroom),
            title: const Text('家庭管理'),
            subtitle: const Text('创建/加入家庭、家庭码、终身绑定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/family'),
          ),
          ListTile(
            leading: const Icon(Icons.people, color: Colors.blue),
            title: const Text('用户管理'),
            subtitle: const Text('查看家庭成员、调整管理员、移除成员'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UserManagementPage())),
          ),
          ListTile(
            leading: const Icon(Icons.assignment),
            title: const Text('财务预规划'),
            subtitle: const Text('收入分配比例、储蓄目标、投资参数'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/plan'),
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('账号安全'),
            subtitle: const Text('修改密码、MFA 多因子认证'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/security'),
          ),
          // 在线更新
          ListTile(
            leading: const Icon(Icons.system_update, color: Colors.teal),
            title: const Text('检查更新'),
            subtitle: const Text('查看新版本并在线升级'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final info = await UpdaterService.check();
              if (!context.mounted) return;
              if (info != null) {
                UpdaterService.checkAndPrompt(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('当前已是最新版本')),
                );
              }
            },
          ),
          // 生物识别设置
          Consumer<BiometricService>(
            builder: (ctx, biometric, _) {
              // 显示生物识别状态（即使不可用也显示，让用户知道原因）
              return ListTile(
                leading: Icon(
                  Icons.fingerprint,
                  color: biometric.canCheckBiometrics ? Colors.deepPurple : Colors.grey,
                ),
                title: const Text('生物识别登录'),
                subtitle: Text(biometric.getStatusDescription()),
                trailing: biometric.canCheckBiometrics
                    ? Switch(
                        value: biometric.isBiometricEnabled,
                        onChanged: (v) async {
                          if (v) {
                            final auth = ctx.read<AuthState>();
                            final user = auth.user;
                            if (user == null) return;
                            // 需要用户输入密码来启用
                            final pwd = TextEditingController();
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (_) => AlertDialog(
                                title: const Text('启用生物识别'),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('请输入密码以启用生物识别登录'),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: pwd,
                                      obscureText: true,
                                      decoration: const InputDecoration(labelText: '密码'),
                                    ),
                                  ],
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('启用')),
                                ],
                              ),
                            );
                            final pwdText = pwd.text;
                            pwd.dispose();
                            if (ok == true && pwdText.isNotEmpty) {
                              final success = await biometric.enable(user.username, pwdText);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(
                                    success ? '生物识别已启用' : (biometric.errorMessage.isNotEmpty ? biometric.errorMessage : '启用失败'),
                                  )),
                                );
                              }
                            }
                          } else {
                            await biometric.disable();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('生物识别已关闭')),
                              );
                            }
                          }
                        },
                      )
                    : null, // 不可用时不显示开关
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            onTap: () async {
              await context.read<AuthState>().logout();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
    );
  }
}

/// 通知中心页面
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<NotificationItem> _list = [];
  int _unreadCount = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  final Set<int> _pendingRead = {};

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
      final r = await ApiClient.instance.listNotifications(page: 1, size: 100);
      if (!mounted) return;
      if (r.ok && r.data != null) {
        final raw = r.data!['list'] as List? ?? [];
        setState(() {
          _list = raw.map((e) => NotificationItem.fromJson(e as Map<String, dynamic>)).toList();
          _unreadCount = (r.data!['unreadCount'] as num? ?? 0).toInt();
          _loading = false;
        });
      } else {
        setState(() {
          _error = r.message.isNotEmpty ? r.message : '加载失败';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '网络错误：$e';
        _loading = false;
      });
    }
  }

  Future<void> _markRead(NotificationItem n) async {
    if (n.read || _pendingRead.contains(n.id)) return;
    setState(() => _pendingRead.add(n.id));
    try {
      final r = await ApiClient.instance.markNotificationRead(n.id);
      if (!mounted) return;
      setState(() {
        _pendingRead.remove(n.id);
        if (r.ok) {
          final idx = _list.indexWhere((e) => e.id == n.id);
          if (idx >= 0) {
            final updated = NotificationItem(
              id: n.id,
              uid: n.uid,
              type: n.type,
              title: n.title,
              content: n.content,
              data: n.data,
              read: true,
              createdAt: n.createdAt,
            );
            _list[idx] = updated;
            if (_unreadCount > 0) _unreadCount--;
          }
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _pendingRead.remove(n.id));
    }
  }

  Future<void> _markAllRead() async {
    if (_busy || _unreadCount == 0) return;
    setState(() => _busy = true);
    try {
      final r = await ApiClient.instance.markAllNotificationsRead();
      if (!mounted) return;
      if (r.ok) {
        setState(() {
          _list = _list
              .map((n) => NotificationItem(
                    id: n.id,
                    uid: n.uid,
                    type: n.type,
                    title: n.title,
                    content: n.content,
                    data: n.data,
                    read: true,
                    createdAt: n.createdAt,
                  ))
              .toList();
          _unreadCount = 0;
        });
      }
    } catch (_) {}
    setState(() => _busy = false);
  }

  IconData _iconOf(String t) {
    switch (t) {
      case NotifyType.overSpend:
        return Icons.warning_amber_rounded;
      case NotifyType.bigPurchase:
        return Icons.shopping_bag_outlined;
      case NotifyType.familyApply:
        return Icons.family_restroom;
      case NotifyType.familyResult:
        return Icons.verified_outlined;
      default:
        return Icons.notifications_outlined;
    }
  }

  Color _colorOf(String t) {
    switch (t) {
      case NotifyType.overSpend:
        return Colors.redAccent;
      case NotifyType.bigPurchase:
        return Colors.deepOrange;
      case NotifyType.familyApply:
        return Colors.blue;
      case NotifyType.familyResult:
        return Colors.green;
      default:
        return Colors.indigo;
    }
  }

  String _timeStr(int unix) {
    if (unix == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}-${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知中心'),
        actions: [
          if (_unreadCount > 0)
            TextButton.icon(
              onPressed: _busy ? null : _markAllRead,
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text('全部已读'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 48, color: Colors.black26),
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: Colors.black54, fontSize: 13)),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _list.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_off_outlined, size: 64, color: Colors.black26),
                      SizedBox(height: 8),
                      Text('暂无通知', style: TextStyle(color: Colors.black45)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                    itemBuilder: (_, i) {
                      final n = _list[i];
                      final color = _colorOf(n.type);
                      final isPending = _pendingRead.contains(n.id);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: 0.12),
                          child: Icon(_iconOf(n.type), color: color, size: 20),
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                n.title.isEmpty ? NotifyType.labelOf(n.type) : n.title,
                                style: TextStyle(
                                  fontWeight: n.read ? FontWeight.w400 : FontWeight.w700,
                                ),
                              ),
                            ),
                            if (!n.read)
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(left: 6),
                                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (n.content.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(n.content, style: const TextStyle(fontSize: 13)),
                              ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    NotifyType.labelOf(n.type),
                                    style: TextStyle(fontSize: 10, color: color),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _timeStr(n.createdAt),
                                  style: const TextStyle(fontSize: 11, color: Colors.black45),
                                ),
                              ],
                            ),
                          ],
                        ),
                        trailing: n.read
                            ? null
                            : (isPending
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.chevron_right, size: 20)),
                        onTap: n.read ? null : () => _markRead(n),
                      );
                    },
                  ),
                ),
    );
  }
}

/// 用户管理（家庭成员）页
class UserManagementPage extends StatefulWidget {
  const UserManagementPage({super.key});
  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage> {
  List<FamilyMember> _members = [];
  bool _loading = true;
  bool _hasFamily = false;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final fam = await ApiClient.instance.getFamily();
    if (!mounted) return;
    if (!fam.ok || fam.data == null || fam.data!['family'] == null) {
      setState(() {
        _hasFamily = false;
        _loading = false;
      });
      return;
    }
    _hasFamily = true;
    final m = await ApiClient.instance.familyMembers();
    if (!mounted) return;
    final me = context.read<AuthState>().user;
    if (m.ok && m.data != null) {
      _members = m.data!;
      _isAdmin = _members.any((mm) => mm.userId == me?.id && mm.isAdmin);
    }
    setState(() => _loading = false);
  }

  Future<void> _toggleAdmin(FamilyMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(m.isAdmin ? '取消该成员的管理员权限？' : '将该成员设为管理员？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.updateFamilyMember(m.id, !m.isAdmin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已更新' : (r.message.isEmpty ? '失败' : r.message))));
    _load();
  }

  Future<void> _removeMember(FamilyMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('确认移除 ${m.nickname.isNotEmpty ? m.nickname : m.username}？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.removeFamilyMember(m.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '已移除' : (r.message.isEmpty ? '失败' : r.message))));
    _load();
  }

  Future<void> _forceDeleteFamily() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('立即执行家庭删除'),
        content: const Text('冷静期已到期？点击确认将立即解散家庭并清除所有成员关系。\n此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.forceDeleteFamily();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.ok ? '家庭已删除' : (r.message.isEmpty ? '失败' : r.message))));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('用户管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_hasFamily
              ? const Center(child: Text('未加入家庭'))
              : ListView(
                  children: [
                    if (_isAdmin)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Card(
                          color: Colors.amber.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(children: [
                              const Icon(Icons.admin_panel_settings, color: Colors.amber),
                              const SizedBox(width: 8),
                              const Expanded(child: Text('你是家庭管理员，可管理成员角色与执行冷静期到期后的家庭删除')),
                              FilledButton.tonal(
                                onPressed: _forceDeleteFamily,
                                child: const Text('执行删除'),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ..._members.map((m) {
                      final isMe = m.userId == context.read<AuthState>().user?.id;
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text((m.nickname.isNotEmpty ? m.nickname : m.username).characters.first),
                        ),
                        title: Text((m.nickname.isNotEmpty ? m.nickname : m.username) + (isMe ? '（我）' : '')),
                        subtitle: Text(m.isAdmin ? '家庭管理员' : '成员'),
                        trailing: _isAdmin && !isMe
                            ? PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'admin') _toggleAdmin(m);
                                  if (v == 'remove') _removeMember(m);
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 'admin', child: Text(m.isAdmin ? '取消管理员' : '设为管理员')),
                                  const PopupMenuItem(value: 'remove', child: Text('移除出家庭')),
                                ],
                              )
                            : (m.isAdmin ? const Icon(Icons.star, color: Colors.amber) : null),
                      );
                    }),
                  ],
                ),
    );
  }
}
