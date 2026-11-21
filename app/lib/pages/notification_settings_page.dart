import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api.dart';
import '../services/auth.dart';
import '../services/notify.dart';
import '../services/system_channel.dart';
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
  String _vendor = '';
  bool _showTrouble = false;

  bool get _isForMember => widget.member != null;

  @override
  void initState() {
    super.initState();
    _load();
    _checkSysNotification();
    SystemChannel.vendor().then((v) {
      if (mounted) setState(() => _vendor = v);
    });
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

  Future<void> _requestPermission() async {
    try {
      await context.read<NotifyService>().requestSystemNotificationPermission();
    } catch (_) {}
    await _checkSysNotification();
    if (!mounted) return;
    if (_sysNotify == false) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('仍未开启。请到「系统设置 → 应用 → 永远富裕 → 通知」手动打开'),
      ));
    }
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

  /// 国产 ROM 额外管控指引（ColorOS / MIUI / EMUI 等）
  Widget _troubleGuide() {
    final v = _vendor;
    final steps = <String>[
      if (v.contains('oppo') || v.contains('realme') || v.contains('oneplus')) ...[
        '通知管理：长按应用图标 → 应用详情 → 通知管理 → 打开「允许通知」，并把「设为不重要通知」「移动至通知底部」关掉',
        '横幅：通知管理里打开「横幅」「锁屏」，否则只在通知栏不弹窗',
        '自启动：手机管家 → 权限隐私 → 自启动管理 → 允许「永远富裕」',
        '耗电：应用详情 → 耗电管理 → 允许自启动 / 允许唤醒前台 / 允许完全后台行为',
        '后台锁定：多任务里长按本应用卡片 → 下拉锁定，防止被清理',
      ] else if (v.contains('xiaomi') || v.contains('redmi')) ...[
        '通知管理：应用详情 → 通知管理 → 打开允许通知，关闭「不重要通知」',
        '自启动：手机管家 → 应用管理 → 权限 → 自启动',
        '省电策略：应用详情 → 省电策略 → 无限制',
      ] else if (v.contains('vivo') || v.contains('iqoo')) ...[
        '通知：设置 → 通知与状态栏 → 应用通知 → 永远富裕 → 打开允许通知',
        '自启动：i管家 → 应用管理 → 自启动',
        '后台：设置 → 电池 → 后台耗电管理 → 允许后台高耗电',
      ] else if (v.contains('huawei') || v.contains('honor')) ...[
        '通知：设置 → 通知 → 永远富裕 → 允许通知 + 横幅',
        '启动管理：设置 → 应用 → 应用启动管理 → 关闭「自动管理」，三项手动全开',
        '电池：设置 → 电池 → 更多电池设置 → 休眠保持网络连接',
      ] else ...[
        '在系统设置里允许本应用发送通知',
        '关闭系统的后台限制与省电优化',
      ],
      '以上都开了仍不弹：本应用的通知靠 WebSocket 实时接收，进程被杀后收不到（需要厂商推送通道）',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ', style: const TextStyle(fontSize: 12)),
                  Expanded(
                    child: Text(steps[i], style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            OutlinedButton.icon(
              onPressed: () => SystemChannel.openNotificationSettings(),
              icon: const Icon(Icons.tune, size: 15),
              label: const Text('打开系统通知设置'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await SystemChannel.openAutoStartSettings();
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('未找到自启动页，请在「手机管家 → 权限隐私」里手动打开'),
                  ));
                }
              },
              icon: const Icon(Icons.battery_saver_outlined, size: 15),
              label: const Text('打开自启动管理'),
            ),
          ]),
        ],
      ),
    );
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
                              if (SystemChannel.isAggressiveRom(_vendor)) ...[
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () => setState(() => _showTrouble = !_showTrouble),
                                  child: Row(children: [
                                    Icon(
                                      _showTrouble
                                          ? Icons.keyboard_arrow_up
                                          : Icons.keyboard_arrow_down,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${SystemChannel.vendorLabel(_vendor)} 还有额外管控，点此排查',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ]),
                                ),
                                if (_showTrouble) _troubleGuide(),
                              ],
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  if (_sysNotify == false)
                                    FilledButton.icon(
                                      onPressed: _requestPermission,
                                      icon: const Icon(Icons.notifications_on_outlined,
                                          size: 16),
                                      label: const Text('去开启通知权限'),
                                    ),
                                  OutlinedButton.icon(
                                    onPressed: _sendTestNotification,
                                    icon: const Icon(Icons.send_outlined, size: 16),
                                    label: const Text('发一条测试通知'),
                                  ),
                                ],
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
