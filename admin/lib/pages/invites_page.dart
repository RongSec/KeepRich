import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';

/// 邀请码管理：列表查看、筛选、批量生成、撤销、复制。
class InvitesPage extends StatefulWidget {
  const InvitesPage({super.key});
  @override
  State<InvitesPage> createState() => _InvitesPageState();
}

class _InvitesPageState extends State<InvitesPage> {
  static const int _pageSize = 20;

  List<dynamic> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = true;
  String? _error;
  String _status = 'all';
  String _keyword = '';
  final TextEditingController _keywordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.listInvites(
        status: _status,
        keyword: _keyword,
        page: _page,
        size: _pageSize,
      );
      if (!mounted) return;
      if (r['code'] != 0) {
        setState(() {
          _error = r['message']?.toString() ?? '加载失败，请稍后再试';
          _loading = false;
        });
        return;
      }
      final data = r['data'] as Map<String, dynamic>? ?? {};
      setState(() {
        _items = (data['list'] as List? ?? []);
        _total = (data['total'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '网络异常，加载失败，请稍后再试';
        _loading = false;
      });
    }
  }

  void _search() {
    _keyword = _keywordCtrl.text.trim();
    _page = 1;
    _load();
  }

  void _changeStatus(String? v) {
    if (v == null) return;
    setState(() => _status = v);
    _page = 1;
    _load();
  }

  void _goPage(int p) {
    final maxPage = ((_total - 1) / _pageSize).floor() + 1;
    if (p < 1 || p > maxPage) return;
    setState(() => _page = p);
    _load();
  }

  // ---------- 时间与状态展示 ----------

  String _fmtTime(int? seconds) {
    if (seconds == null || seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _statusBadge(String status) {
    late final String label;
    late final Color bg;
    late final Color fg;
    switch (status) {
      case 'unused':
        label = '未使用';
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        break;
      case 'partial':
        label = '部分使用';
        bg = Colors.orange.shade50;
        fg = Colors.orange.shade900;
        break;
      case 'used':
        label = '已用完';
        bg = Colors.grey.shade200;
        fg = Colors.grey.shade800;
        break;
      case 'expired':
        label = '已过期';
        bg = Colors.brown.shade50;
        fg = Colors.brown.shade800;
        break;
      case 'revoked':
        label = '已撤销';
        bg = Colors.red.shade50;
        fg = Colors.red.shade800;
        break;
      default:
        label = '未知';
        bg = Colors.grey.shade200;
        fg = Colors.grey.shade800;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: fg)),
    );
  }

  // ---------- 复制 ----------

  Future<void> _copyText(String text, String tip) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tip)));
  }

  // ---------- 生成 ----------

  void _showGenerateDialog() {
    final countCtrl = TextEditingController(text: '1');
    final maxUsesCtrl = TextEditingController(text: '1');
    final noteCtrl = TextEditingController();
    int days = 7;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('批量生成邀请码'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: countCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '生成数量（1 ~ 20）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: maxUsesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每个码可用次数（1 ~ 50）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: days,
                  decoration: const InputDecoration(
                    labelText: '有效期',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 天')),
                    DropdownMenuItem(value: 7, child: Text('7 天')),
                    DropdownMenuItem(value: 30, child: Text('30 天')),
                  ],
                  onChanged: (v) => setDialogState(() => days = v ?? 7),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLength: 32,
                  decoration: const InputDecoration(
                    labelText: '备注（可选，最多 32 字）',
                    border: OutlineInputBorder(),
                    isDense: true,
                    counterText: '',
                  ),
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
                final count = int.tryParse(countCtrl.text.trim()) ?? 0;
                final maxUses = int.tryParse(maxUsesCtrl.text.trim()) ?? 0;
                if (count < 1 || count > 20) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('生成数量须为 1 ~ 20')),
                  );
                  return;
                }
                if (maxUses < 1 || maxUses > 50) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('可用次数须为 1 ~ 50')),
                  );
                  return;
                }
                Navigator.of(dialogContext).pop();
                await _doGenerate(count, maxUses, days, noteCtrl.text.trim());
              },
              child: const Text('生成'),
            ),
          ],
        ),
      ),
    ).then((_) {
      countCtrl.dispose();
      maxUsesCtrl.dispose();
      noteCtrl.dispose();
    });
  }

  Future<void> _doGenerate(int count, int maxUses, int days, String note) async {
    try {
      final r = await ApiClient.instance.generateInvites(
        count: count,
        maxUses: maxUses,
        expiresInDays: days,
        note: note,
      );
      if (!mounted) return;
      if (r['code'] != 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['message']?.toString() ?? '生成失败，请稍后再试')),
        );
        return;
      }
      final data = r['data'] as Map<String, dynamic>? ?? {};
      final codes = (data['codes'] as List? ?? [])
          .map((e) => (e as Map)['code']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      _showCodesDialog(codes);
      _page = 1;
      _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('网络异常，生成失败，请稍后再试')),
      );
    }
  }

  void _showCodesDialog(List<String> codes) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('已生成 ${codes.length} 个邀请码'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请复制后发给家人，关闭后可在列表中查看。'),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: codes.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => Row(
                    children: [
                      Expanded(
                        child: Text(
                          codes[i],
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => _copyText(codes[i], '已复制邀请码'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _copyText(codes.join('\n'), '已复制全部邀请码'),
            child: const Text('全部复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---------- 撤销 ----------

  Future<void> _revoke(dynamic inv) async {
    final code = inv['code']?.toString() ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销邀请码'),
        content: Text('确定要撤销邀请码「$code」吗？撤销后不能再用于注册。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final id = (inv['id'] as num).toInt();
      final r = await ApiClient.instance.revokeInvite(id);
      if (!mounted) return;
      if (r['code'] == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['message']?.toString() ?? '邀请码已撤销')),
        );
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['message']?.toString() ?? '撤销失败，请稍后再试')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('网络异常，撤销失败，请稍后再试')),
      );
    }
  }

  // ---------- 卡片 ----------

  Widget _usages(List<dynamic> usages) {
    if (usages.isEmpty) {
      return const Text('暂无使用记录', style: TextStyle(fontSize: 12, color: Colors.grey));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: usages.map((u) {
        final name = (u['nickname']?.toString().isNotEmpty ?? false)
            ? u['nickname'].toString()
            : (u['username']?.toString() ?? '-');
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            '$name 于 ${_fmtTime((u['usedAt'] as num?)?.toInt())} 使用',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        );
      }).toList(),
    );
  }

  Widget _inviteCard(dynamic inv) {
    final code = inv['code']?.toString() ?? '';
    final status = inv['status']?.toString() ?? '';
    final usedCount = (inv['usedCount'] as num?)?.toInt() ?? 0;
    final maxUses = (inv['maxUses'] as num?)?.toInt() ?? 0;
    final expiresAt = (inv['expiresAt'] as num?)?.toInt() ?? 0;
    final note = inv['note']?.toString() ?? '';
    final usages = (inv['usages'] as List? ?? []);
    final canRevoke = status == 'unused' || status == 'partial';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  code,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
                IconButton(
                  tooltip: '复制邀请码',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => _copyText(code, '已复制邀请码'),
                ),
                const SizedBox(width: 8),
                _statusBadge(status),
                const Spacer(),
                Text('使用 $usedCount / $maxUses 次',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 16),
                if (canRevoke)
                  TextButton(
                    onPressed: () => _revoke(inv),
                    child: const Text('撤销', style: TextStyle(color: Colors.red)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 24,
              runSpacing: 4,
              children: [
                Text(
                  expiresAt > 0 ? '有效期至 ${_fmtTime(expiresAt)}' : '永久有效',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                Text(
                  note.isEmpty ? '无备注' : '备注：$note',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                Text(
                  '创建于 ${_fmtTime((inv['createdAt'] as num?)?.toInt())}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _usages(usages),
          ],
        ),
      ),
    );
  }

  // ---------- 页面 ----------

  @override
  Widget build(BuildContext context) {
    final maxPage = _total == 0 ? 1 : ((_total - 1) / _pageSize).floor() + 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('邀请码管理'),
        actions: [
          IconButton(
            tooltip: '批量生成',
            onPressed: _showGenerateDialog,
            icon: const Icon(Icons.add_circle_outline),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    decoration: const InputDecoration(
                      labelText: '状态',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部')),
                      DropdownMenuItem(value: 'unused', child: Text('未使用')),
                      DropdownMenuItem(value: 'partial', child: Text('部分使用')),
                      DropdownMenuItem(value: 'used', child: Text('已用完')),
                      DropdownMenuItem(value: 'expired', child: Text('已过期')),
                      DropdownMenuItem(value: 'revoked', child: Text('已撤销')),
                    ],
                    onChanged: _changeStatus,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _keywordCtrl,
                    decoration: const InputDecoration(
                      labelText: '搜索邀请码 / 备注',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                  label: const Text('搜索'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _showGenerateDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('批量生成'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('共 $_total 个邀请码', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                IconButton(
                  tooltip: '上一页',
                  onPressed: _page > 1 ? () => _goPage(_page - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('第 $_page / $maxPage 页', style: Theme.of(context).textTheme.bodySmall),
                IconButton(
                  tooltip: '下一页',
                  onPressed: _page < maxPage ? () => _goPage(_page + 1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
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
                            OutlinedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : _items.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.confirmation_number_outlined,
                                    size: 48, color: Colors.grey),
                                const SizedBox(height: 8),
                                const Text('暂无邀请码', style: TextStyle(color: Colors.grey)),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed: _showGenerateDialog,
                                  icon: const Icon(Icons.add),
                                  label: const Text('批量生成邀请码'),
                                ),
                              ],
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            children: _items.map(_inviteCard).toList(),
                          ),
          ),
        ],
      ),
    );
  }
}
