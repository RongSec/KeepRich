import 'package:flutter/material.dart';

import '../api.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _userCount = 0;
  int _familyCount = 0;
  int _txCount = 0;
  bool _loading = true;
  String? _error;

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
      final u = await ApiClient.instance.get('/admin/users');
      final f = await ApiClient.instance.get('/admin/families');
      if (!mounted) return;
      // 检查响应码
      if (u['code'] != 0) {
        setState(() {
          _error = u['message'] ?? '加载用户失败';
          _loading = false;
        });
        return;
      }
      if (f['code'] != 0) {
        setState(() {
          _error = f['message'] ?? '加载家庭失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        _userCount = (u['data'] as List?)?.length ?? 0;
        _familyCount = (f['data'] as List?)?.length ?? 0;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('总览'),
        actions: [
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
                      OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      LayoutBuilder(builder: (ctx, c) {
                        final wide = c.maxWidth >= 600;
                        final cards = [
                          _StatCard(title: '用户总数', value: '$_userCount', icon: Icons.people, color: Colors.indigo),
                          _StatCard(title: '家庭总数', value: '$_familyCount', icon: Icons.family_restroom, color: Colors.teal),
                        ];
                        if (wide) {
                          return Row(children: [
                            Expanded(child: cards[0]),
                            const SizedBox(width: 16),
                            Expanded(child: cards[1]),
                          ]);
                        }
                        return Column(children: [
                          cards[0],
                          const SizedBox(height: 16),
                          cards[1],
                        ]);
                      }),
                      const SizedBox(height: 24),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('快捷操作', style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  _QuickAction(icon: Icons.person_add, label: '创建用户', color: Colors.indigo, onTap: () => Navigator.pushNamed(context, '/users')),
                                  _QuickAction(icon: Icons.family_restroom, label: '家庭管理', color: Colors.teal, onTap: () => Navigator.pushNamed(context, '/families')),
                                  _QuickAction(icon: Icons.assignment, label: '审计日志', color: Colors.orange, onTap: () => Navigator.pushNamed(context, '/audit')),
                                  _QuickAction(icon: Icons.bug_report, label: '错误报告', color: Colors.red, onTap: () => Navigator.pushNamed(context, '/errors')),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  const _StatCard({required this.title, required this.value, required this.icon, required this.color});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            CircleAvatar(radius: 28, backgroundColor: color.withOpacity(0.15), child: Icon(icon, color: color, size: 28)),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
