import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api.dart';
import '../services/auth.dart';
import '../services/notify.dart';
import '../utils/display_name.dart';

/// 通知设置页：5 类通知各一个开关，可展开编辑标题/内容文案模板（支持 {占位符}）。
///
/// 权限口径：普通成员只编辑自己的；家庭管理员可带 [member] 编辑
/// 同家庭成员的设置（复用同一 UI，后端二次校验 is_admin + 同家庭）。
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({
    super.key,
    this.member,
    this.initialSettings,
  });

  /// 非空 = 家庭管理员编辑该成员的通知设置
  final FamilyMember? member;

  /// 仅供 widget 测试注入（生产路径恒 null，走接口加载）
  final List<NotificationSetting>? initialSettings;

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  List<NotificationSetting> _items = [];
  final Map<String, TextEditingController> _titleCtrls = {};
  final Map<String, TextEditingController> _contentCtrls = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;
  bool? _sysNotify; // 系统通知是否允许（null=未知/平台不支持）

  bool get _isForMember => widget.member != null;

  @override
  void initState() {
    super.initState();
    _load();
    _checkSysNotification();
  }

  @override
  void dispose() {
    for (final c in _titleCtrls.values) {
      c.dispose();
    }
    for (final c in _contentCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _adopt(List<NotificationSetting> settings) {
    // 固定 5 类顺序；接口已保证 5 项，兜底按 type 对齐
    final byType = {for (final s in settings) s.type: s};
    _items = [
      for (final t in NotifyType.all)
        byType[t] ??
            NotificationSetting(
                type: t,
                enabled: true,
                titleTemplate: '',
                contentTemplate: '')
    ];
    for (final c in _titleCtrls.values) {
      c.dispose();
    }
    for (final c in _contentCtrls.values) {
      c.dispose();
    }
    _titleCtrls.clear();
    _contentCtrls.clear();
    for (final s in _items) {
      _titleCtrls[s.type] = TextEditingController(text: s.titleTemplate);
      _contentCtrls[s.type] = TextEditingController(text: s.contentTemplate);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final injected = widget.initialSettings;
      if (injected != null) {
        // 测试注入：跳过网络
        _adopt(injected);
        setState(() => _loading = false);
        return;
      }
      final r = _isForMember
          ? await ApiClient.instance
              .getMemberNotificationSettings(widget.member!.userId)
          : await ApiClient.instance.getNotificationSettings();
      if (!mounted) return;
      if (r.ok && r.data != null) {
        _adopt(r.data!);
        setState(() => _loading = false);
      } else {
        setState(() {
          _error = r.message.isNotEmpty ? r.message : '加载失败';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '网络错误，请稍后再试';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    // 把输入框文案收进设置项
    for (var i = 0; i < _items.length; i++) {
      final s = _items[i];
      _items[i] = NotificationSetting(
        type: s.type,
        enabled: s.enabled,
        titleTemplate: _titleCtrls[s.type]?.text ?? '',
        contentTemplate: _contentCtrls[s.type]?.text ?? '',
        defaultTitleTemplate: s.defaultTitleTemplate,
        defaultContentTemplate: s.defaultContentTemplate,
      );
    }
    setState(() => _saving = true);
    try {
      final r = _isForMember
          ? await ApiClient.instance.updateMemberNotificationSettings(
              widget.member!.userId, _items)
          : await ApiClient.instance.updateNotificationSettings(_items);
      if (!mounted) return;
      if (r.ok && r.data != null) {
        _adopt(r.data!);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('通知设置已保存')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r.message.isNotEmpty ? r.message : '保存失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('网络错误，保存失败')));
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _checkSysNotification() async {
    try {
      final ok = await context.read<NotifyService>().systemNotificationsEnabled();
      if (mounted) setState(() => _sysNotify = ok);
    } catch (_) {}
  }

  Future<void> _sendTestNotification() async {
    bool ok = false;
    try {
      ok = await context.read<NotifyService>().showTestNotification();
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已发送，请下拉通知栏查看' : '发送失败，请检查系统通知权限'),
    ));
    await _checkSysNotification();
  }

  String _memberLabel() {
    final m = widget.member!;
    final me = context.read<AuthState>().user;
    return displayName(m.nickname, m.username) +
        (m.userId == me?.id ? '（我）' : '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isForMember ? '成员通知设置' : '通知设置'),
        actions: [
          TextButton(
            onPressed: _loading || _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
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
                      const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: const TextStyle(color: Colors.grey)),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(
                                  _sysNotify == false
                                      ? Icons.notifications_off_outlined
                                      : Icons.notifications_active_outlined,
                                  size: 20,
                                  color: _sysNotify == false
                                      ? Colors.orange
                                      : const Color(0xFF2E7D32),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _sysNotify == false
                                        ? '系统通知已被关闭，手机通知栏不会提醒（仅 App 内可见）'
                                        : '系统通知已开启，新通知会推到手机通知栏',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton.icon(
                                  onPressed: _sendTestNotification,
                                  icon: const Icon(Icons.send_outlined, size: 16),
                                  label: const Text('发一条测试通知'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_isForMember)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Card(
                          color: Colors.amber.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(children: [
                              const Icon(Icons.admin_panel_settings,
                                  color: Color(0xFFB8860B)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '家庭管理员：正在编辑 ${_memberLabel()} 的通知格式与开关',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF6B4A00)),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '关闭某类通知后，将不再收到该类提醒（不生成通知也不弹系统通知）；'
                        '文案模板留空则使用默认模板。',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                    ..._items.map(_buildTypeCard),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: const Text('保存'),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildTypeCard(NotificationSetting s) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        children: [
          SwitchListTile(
            title: Text(NotifyType.labelOf(s.type)),
            subtitle: Text(
              '可用占位符：${NotifyType.placeholdersOf(s.type)}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            value: s.enabled,
            onChanged: (v) {
              setState(() {
                final i = _items.indexOf(s);
                _items[i] = NotificationSetting(
                  type: s.type,
                  enabled: v,
                  titleTemplate: s.titleTemplate,
                  contentTemplate: s.contentTemplate,
                  defaultTitleTemplate: s.defaultTitleTemplate,
                  defaultContentTemplate: s.defaultContentTemplate,
                );
              });
            },
          ),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            title: Text('编辑文案格式',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary)),
            children: [
              TextField(
                controller: _titleCtrls[s.type],
                maxLength: 256,
                decoration: InputDecoration(
                  labelText: '标题模板',
                  helperText: s.defaultTitleTemplate.isEmpty
                      ? '留空使用默认模板'
                      : '留空使用默认：${s.defaultTitleTemplate}',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _contentCtrls[s.type],
                maxLength: 512,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: '内容模板',
                  helperText: s.defaultContentTemplate.isEmpty
                      ? '留空使用默认模板'
                      : '留空使用默认：${s.defaultContentTemplate}',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ),
              Text(
                '占位符在推送时自动填充，如 {金额}、{分类}；缺失的占位符保留原文。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
