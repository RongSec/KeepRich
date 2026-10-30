import 'package:flutter/material.dart';

import '../services/api.dart';

class FamilyManagePage extends StatefulWidget {
  const FamilyManagePage({super.key});
  @override
  State<FamilyManagePage> createState() => _FamilyManagePageState();
}

class _FamilyManagePageState extends State<FamilyManagePage> {
  Map<String, dynamic>? _family;
  List<Map<String, dynamic>> _requests = [];
  Map<String, dynamic>? _deleteVote;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final fr = await ApiClient.instance.getFamily();
    List<Map<String, dynamic>> reqs = [];
    Map<String, dynamic>? deleteVote;
    if (fr.ok && fr.data != null && fr.data!['family'] != null) {
      final rr = await ApiClient.instance.listJoinRequests();
      if (rr.ok && rr.data != null) {
        reqs = (rr.data!).map((e) => e as Map<String, dynamic>).toList();
      }
      final vr = await ApiClient.instance.listDeleteVotes();
      if (vr.ok && vr.data != null && vr.data!['request'] != null) {
        deleteVote = vr.data as Map<String, dynamic>;
      }
    }
    if (!mounted) return;
    setState(() {
      _family = fr.data == null ? null : fr.data as Map<String, dynamic>;
      _requests = reqs;
      _deleteVote = deleteVote;
      _loading = false;
    });
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final desc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('创建家庭'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: '家庭名称')),
            const SizedBox(height: 8),
            TextField(controller: desc, decoration: const InputDecoration(labelText: '描述（可选）')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('创建')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.createFamily(name.text, desc.text);
    if (r.ok) {
      _load();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  Future<void> _join() async {
    final code = TextEditingController();
    final msg = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('加入家庭'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: code, decoration: const InputDecoration(labelText: '家庭码')),
            const SizedBox(height: 8),
            TextField(controller: msg, decoration: const InputDecoration(labelText: '附言（可选）')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('申请')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.applyJoin(code.text.trim(), msg.text);
    if (!mounted) return;
    if (r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('申请已提交，等待家庭管理员审批')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  Future<void> _approve(int id, bool approve) async {
    final r = await ApiClient.instance.approveJoin(id, approve);
    if (r.ok) _load();
  }

  Future<void> _bindForever() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('终身绑定'),
        content: const Text('开启后无法恢复个人数据，删除家庭将清除所有内容。确定吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.bindForever();
    if (r.ok && mounted) {
      await showDialog(
        context: context,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 恭喜图位（占位图）
                  Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.amber.shade300, Colors.deepOrange.shade400],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(80),
                    ),
                    child: const Center(
                      child: Text('🎉', style: TextStyle(fontSize: 96)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('恭喜', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  const Text(
                    '已成功终身绑定该家庭。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('好的'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      _load();
    } else if (mounted && !r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  Future<void> _deleteFamily() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('发起解散家庭投票'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('发起后需要所有家庭成员同意才能解散。'),
            const SizedBox(height: 8),
            TextField(controller: reason, decoration: const InputDecoration(labelText: '原因（可选）')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('发起投票')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.requestDeleteFamily(reason: reason.text);
    if (r.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已发起删除投票，等待其他成员同意')));
      _load();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  Future<void> _voteDelete(int requestId, bool vote) async {
    final r = await ApiClient.instance.voteDeleteFamily(requestId, vote);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.data?['message'] ?? (r.ok ? '已投票' : r.message))));
    _load();
  }

  Future<void> _syncData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('同步个人数据'),
        content: const Text('将您的个人记账、规划、贷款等数据同步到家庭空间。\n\n已有数据不会重复，新数据会追加。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('同步')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.syncPersonalData();
    if (!mounted) return;
    if (r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('个人数据已同步到家庭')));
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('家庭管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _family == null
              ? _empty()
              : _detail(),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.family_restroom, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('尚未加入任何家庭'),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('创建家庭')),
              OutlinedButton.icon(onPressed: _join, icon: const Icon(Icons.login), label: const Text('加入家庭')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detail() {
    final fam = _family!['family'] as Map<String, dynamic>?;
    final member = _family!['member'] as Map<String, dynamic>?;
    if (fam == null) return _empty();
    final isAdmin = (member?['isAdmin'] as bool? ?? false) == true;
    final bound = fam['bound'] as bool? ?? false;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(fam['name'] as String? ?? '-', style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    if (bound) Chip(label: const Text('终身绑定'), backgroundColor: Theme.of(context).colorScheme.tertiaryContainer),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.qr_code, size: 16),
                    const SizedBox(width: 6),
                    SelectableText('家庭码：${fam['code']}', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                if ((fam['description'] as String? ?? '').isNotEmpty) Text(fam['description'] as String),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (isAdmin && _requests.isNotEmpty) ...[
          Text('待审批申请 (${_requests.length})', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ..._requests.map((r) => Card(
                child: ListTile(
                  title: Text('用户 #${r['userId']}'),
                  subtitle: Text(r['message'] as String? ?? ''),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(icon: const Icon(Icons.check, color: Colors.green), onPressed: () => _approve((r['id'] as num).toInt(), true)),
                      IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: () => _approve((r['id'] as num).toInt(), false)),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 16),
        ],
        // 同步个人数据到家庭
        OutlinedButton.icon(
          onPressed: _syncData,
          icon: const Icon(Icons.sync),
          label: const Text('同步个人数据到家庭'),
        ),
        const SizedBox(height: 8),
        if (isAdmin) ...[
          FilledButton.icon(
            onPressed: bound ? null : _bindForever,
            icon: const Icon(Icons.lock),
            label: Text(bound ? '已终身绑定' : '终身绑定'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: bound ? null : _deleteFamily,
            icon: const Icon(Icons.delete_forever, color: Colors.red),
            label: const Text('发起解散家庭投票', style: TextStyle(color: Colors.red)),
          ),
        ],
        // 删除投票状态
        if (_deleteVote != null) ...[
          const SizedBox(height: 16),
          Card(
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.how_to_vote, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Text('解散家庭投票进行中', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.red.shade700)),
                  ]),
                  const SizedBox(height: 8),
                  Text('发起人：用户 #${_deleteVote!['request']?['requestBy'] ?? '-'}'),
                  if ((_deleteVote!['request']?['reason'] ?? '').toString().isNotEmpty)
                    Text('原因：${_deleteVote!['request']['reason']}'),
                  const SizedBox(height: 8),
                  Text('投票状态：${(_deleteVote!['votes'] as List?)?.length ?? 0} 人已投票'),
                  const SizedBox(height: 8),
                  if (_deleteVote!['myVote'] == null) ...[
                    Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _voteDelete((_deleteVote!['request']['id'] as num).toInt(), true),
                          icon: const Icon(Icons.check),
                          label: const Text('同意解散'),
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _voteDelete((_deleteVote!['request']['id'] as num).toInt(), false),
                          icon: const Icon(Icons.close),
                          label: const Text('反对'),
                        ),
                      ),
                    ]),
                  ] else ...[
                    Text('你已投票：${_deleteVote!['myVote']['vote'] == true ? '同意' : '反对'}',
                        style: TextStyle(color: _deleteVote!['myVote']['vote'] == true ? Colors.red : Colors.green)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
