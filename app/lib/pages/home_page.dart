import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'bookkeeping_page.dart';
import 'future_finance_page.dart';
import 'overview_page.dart';
import 'settings_page.dart';
import '../services/api.dart';
import '../services/notify.dart';

class HomePage extends StatefulWidget {
  final int tab;
  const HomePage({super.key, this.tab = 0});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late int _index = widget.tab;
  double _worryFreePersonal = 0;
  double _worryFreeFamily = 0;
  bool _loadingWorry = true;

  @override
  void initState() {
    super.initState();
    _loadWorryFree();
  }

  @override
  void didUpdateWidget(covariant HomePage old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      _index = widget.tab;
      // tab 切换时刷新无顾虑单笔
      _loadWorryFree();
    }
  }

  /// 刷新无顾虑单笔（供外部调用）
  void refreshWorryFree() {
    _loadWorryFree();
  }

  Future<void> _loadWorryFree() async {
    setState(() => _loadingWorry = true);
    try {
      final p = await ApiClient.instance.overview(scope: 'personal');
      double personal = 0;
      double family = 0;
      if (p.ok && p.data != null) {
        personal = p.data!.worryFreePerBuy;
      }
      // 尝试加载家庭数据
      try {
        final f = await ApiClient.instance.overview(scope: 'family');
        if (f.ok && f.data != null) {
          family = f.data!.worryFreePerBuy;
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _worryFreePersonal = personal;
          _worryFreeFamily = family;
          _loadingWorry = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingWorry = false);
    }
  }

  static const _pages = [
    OverviewPage(),
    FutureFinancePage(),
    BookkeepingPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final isWide = c.maxWidth >= 720;
        if (isWide) {
          return _wideLayout(context, c);
        }
        return _narrowLayout(context);
      },
    );
  }

  // ===== 宽屏：侧边栏 =====
  Widget _wideLayout(BuildContext context, BoxConstraints c) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: c.maxWidth >= 1024,
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: c.maxWidth >= 1024
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: Text('总览')),
              NavigationRailDestination(icon: Icon(Icons.savings_outlined), selectedIcon: Icon(Icons.savings), label: Text('未来')),
              NavigationRailDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: Text('记账')),
              NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('设置')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _pages[_index]),
        ],
      ),
    );
  }

  // ===== 窄屏：底部导航 + 中心球 =====
  Widget _narrowLayout(BuildContext context) {
    final unreadCount = context.watch<NotifyService>().unreadCount;
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: _BottomNavWithBall(
        index: _index,
        worryFreePersonal: _worryFreePersonal,
        worryFreeFamily: _worryFreeFamily,
        loading: _loadingWorry,
        unreadCount: unreadCount,
        onTap: (i) {
          setState(() => _index = i);
          // 切换到任何 tab 时都刷新无顾虑单笔
          _loadWorryFree();
        },
        onBallTap: () {
          // 点击无顾虑单笔球跳转总览
          setState(() => _index = 0);
          _loadWorryFree();
        },
      ),
    );
  }
}

/// 自定义底部导航 + 中心凸起的无顾虑单笔"球"
class _BottomNavWithBall extends StatelessWidget {
  final int index;
  final double worryFreePersonal;
  final double worryFreeFamily;
  final bool loading;
  final int unreadCount;
  final ValueChanged<int> onTap;
  final VoidCallback onBallTap;
  const _BottomNavWithBall({
    required this.index,
    required this.worryFreePersonal,
    required this.worryFreeFamily,
    required this.loading,
    required this.unreadCount,
    required this.onTap,
    required this.onBallTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 80,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 底部栏
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3))),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // 左 2 项：总览、未来
                  Expanded(child: _navItem(context, 0, Icons.dashboard_outlined, Icons.dashboard, '总览')),
                  Expanded(child: _navItem(context, 1, Icons.savings_outlined, Icons.savings, '未来')),
                  const SizedBox(width: 80), // 中间球占位
                  // 右 2 项：记账、设置
                  Expanded(child: _navItem(context, 2, Icons.receipt_long_outlined, Icons.receipt_long, '记账')),
                  Expanded(child: _navItem(context, 3, Icons.settings_outlined, Icons.settings, '设置', badge: unreadCount)),
                ],
              ),
            ),
          ),
          // 中心球
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: onBallTap,
                child: _Ball(worryFreePersonal: worryFreePersonal, worryFreeFamily: worryFreeFamily, loading: loading),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(BuildContext context, int i, IconData icon, IconData activeIcon, String label, {int badge = 0}) {
    final selected = index == i;
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onTap(i),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(selected ? activeIcon : icon, color: selected ? theme.colorScheme.primary : theme.colorScheme.outline),
              if (badge > 0)
                Positioned(
                  right: -8,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(minWidth: 14),
                    child: Text(
                      badge > 99 ? '99+' : '$badge',
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// 中心圆球 - 显示无顾虑单笔（个人+家庭）
class _Ball extends StatelessWidget {
  final double worryFreePersonal;
  final double worryFreeFamily;
  final bool loading;
  const _Ball({required this.worryFreePersonal, required this.worryFreeFamily, required this.loading});

  String _formatAmount(double v) {
    if (v >= 100000000) {
      return '${(v / 100000000).toStringAsFixed(v >= 1000000000 ? 0 : 1)}亿';
    } else if (v >= 10000) {
      return '${(v / 10000).toStringAsFixed(v >= 100000 ? 0 : 1)}万';
    }
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '个人：${NumberFormat('#,##0.00').format(worryFreePersonal)} 元/笔\n'
          '家庭：${NumberFormat('#,##0.00').format(worryFreeFamily)} 元/笔\n点击进入总览',
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
              blurRadius: 14,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: loading
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.flash_on, color: Colors.white, size: 18),
                  SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white)),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 个人
                  Text(
                    _formatAmount(worryFreePersonal),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  // 分隔线
                  Container(
                    width: 28,
                    height: 1,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                  // 家庭
                  Text(
                    _formatAmount(worryFreeFamily),
                    style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                  const Text(
                    '元/笔',
                    style: TextStyle(color: Colors.white54, fontSize: 7),
                  ),
                ],
              ),
      ),
    );
  }
}
