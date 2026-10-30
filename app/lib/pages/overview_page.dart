import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  bool _loading = true;
  OverviewData? _ov;
  ChartData? _chart;
  String _scope = 'personal';
  String _chartPeriod = 'month'; // month 或 year
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
    final r = await ApiClient.instance.overview(scope: _scope);
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _error = r.message;
        _loading = false;
      });
      return;
    }
    final cr = await ApiClient.instance.overviewChart(scope: _scope, period: _chartPeriod);
    if (!mounted) return;
    setState(() {
      _ov = r.data;
      _chart = cr.ok ? cr.data : null;
      _loading = false;
    });
  }

  Future<void> _reloadChart() async {
    final cr = await ApiClient.instance.overviewChart(scope: _scope, period: _chartPeriod);
    if (!mounted) return;
    setState(() {
      _chart = cr.ok ? cr.data : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('总览'),
        actions: [
          if (_ov != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'personal', label: Text('个人')),
                  ButtonSegment(value: 'family', label: Text('家庭')),
                ],
                selected: {_scope},
                onSelectionChanged: (s) {
                  setState(() => _scope = s.first);
                  _load();
                },
              ),
            ),
          const SizedBox(width: 8),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // 顶部 2x2 卡片阵列：家庭总财富 / 公积金总额 / 本月剩余消费 / 未来财富
                      _cardsGrid(theme),
                      const SizedBox(height: 12),
                      // 财务统筹
                      _bucketsCard(theme),
                      const SizedBox(height: 12),
                      _topPurchasesCard(theme),
                      const SizedBox(height: 12),
                      _trendChartCard(theme),
                    ],
                  ),
                ),
    );
  }

  // 2x2 卡片阵列：4 个关键指标（手机系统小卡片风格）
  Widget _cardsGrid(ThemeData theme) {
    final f = NumberFormat('#,##0.00');
    final ov = _ov!;
    final cards = <Widget>[
      _miniCard(
        theme: theme,
        icon: Icons.account_balance,
        iconColor: theme.colorScheme.primary,
        bg: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        title: _scope == 'personal' ? '个人总财富' : '家庭总财富',
        value: f.format(ov.totalWealth),
        unit: ov.totalHousingFund > 0 ? '含公积金 ${f.format(ov.totalHousingFund)} 元' : '元',
        onTap: () => _showWealthDetail(context),
      ),
      _miniCard(
        theme: theme,
        icon: Icons.work_outline,
        iconColor: Colors.indigo,
        bg: Colors.indigo.shade50,
        title: '年薪',
        value: f.format(ov.annualIncome),
        unit: '元/年',
        onTap: () {},
      ),
      _miniCard(
        theme: theme,
        icon: Icons.account_balance_wallet_outlined,
        iconColor: Colors.green.shade700,
        bg: Colors.green.shade50,
        title: '本月剩余消费',
        value: f.format(ov.monthConsumableLeft),
        unit: '元',
        onTap: () => _showConsumptionDetail(context),
      ),
      _miniCard(
        theme: theme,
        icon: Icons.savings_outlined,
        iconColor: Colors.deepOrange,
        bg: Colors.deepOrange.shade50,
        title: '未来财富',
        value: f.format(ov.futureWealth),
        unit: '元（折现）',
        onTap: () => context.push('/future'),
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        // 2 列；横屏/宽屏可加到 4 列
        final cols = w > 900 ? 4 : 2;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: cols == 2 ? 1.5 : 1.3,
          children: cards,
        );
      },
    );
  }

  // 通用小卡片
  Widget _miniCard({
    required ThemeData theme,
    required IconData icon,
    required Color iconColor,
    required Color bg,
    required String title,
    required String value,
    required String unit,
    required VoidCallback onTap,
  }) {
    return Card(
      color: bg,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Icon(icon, color: iconColor, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: iconColor, fontWeight: FontWeight.w600)),
                ),
              ]),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Text(value,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.black87)),
              ),
              Text(unit, style: const TextStyle(fontSize: 10, color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }

  // 财务统筹（去除日常消费）— 4 大存储桶 + 本月分配进度
  Widget _bucketsCard(ThemeData theme) {
    final f = NumberFormat('#,##0.00');
    final ov = _ov!;
    final a = ov.allocation;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.pie_chart_outline, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 6),
              Text('财务统筹', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text('月收入 ${f.format(a.monthlyIncome)} 元', style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: 8),
            // 储蓄 + 长远投资（一行 2 列）
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _bucketTile(
                  name: '储蓄',
                  icon: Icons.savings,
                  color: theme.colorScheme.primary,
                  balance: ov.savingBalance,
                  thisMonth: a.savingThisMonth,
                  thisMonthTarget: a.savingTarget,
                  f: f,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _bucketTile(
                  name: '长远投资',
                  icon: Icons.trending_up,
                  color: Colors.indigo,
                  balance: ov.investmentBalance,
                  thisMonth: a.investmentThisMonth,
                  thisMonthTarget: a.investmentTarget,
                  f: f,
                  onTap: () => _showInvestmentDetail(context),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            // 应急备用金 + 养老金（一行 2 列，含预估剩余月数）
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _bucketTile(
                  name: '应急备用金',
                  icon: Icons.local_hospital,
                  color: Colors.deepOrange,
                  balance: ov.emergencyBalance,
                  target: ov.emergencyTarget,
                  pct: ov.emergencyPct,
                  monthsLeft: ov.emergencyMonthsLeft,
                  thisMonth: a.emergencyThisMonth,
                  thisMonthTarget: a.emergencyTarget,
                  f: f,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _bucketTile(
                  name: '养老金',
                  icon: Icons.elderly,
                  color: Colors.teal,
                  balance: ov.pensionBalance,
                  target: ov.pensionTarget,
                  pct: ov.pensionPct,
                  monthsLeft: ov.pensionMonthsLeft,
                  thisMonth: a.pensionThisMonth,
                  thisMonthTarget: a.pensionTarget,
                  f: f,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // 单个存储桶瓷砖（双进度条 + 预估月数）
  Widget _bucketTile({
    required String name,
    required IconData icon,
    required Color color,
    required double balance,
    double? target,
    double? pct,
    int? monthsLeft,
    required double thisMonth,
    required double thisMonthTarget,
    required NumberFormat f,
    VoidCallback? onTap,
  }) {
    final hasTarget = target != null && target > 0;
    final pctClamped = (pct ?? 0).clamp(0.0, 1.0);
    final pctStr = (pctClamped * 100).toStringAsFixed(0);
    final monthPct = thisMonthTarget > 0 ? (thisMonth / thisMonthTarget).clamp(0.0, 1.0) : 0.0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 4),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ),
          ]),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.bottomLeft,
            child: Text('${f.format(balance)} 元',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black87)),
          ),
          if (hasTarget) ...[
            const SizedBox(height: 4),
            Row(children: [
              Text('总进度', style: TextStyle(fontSize: 10, color: color)),
              const SizedBox(width: 4),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: pctClamped,
                    minHeight: 4,
                    backgroundColor: color.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text('$pctStr%', style: TextStyle(fontSize: 10, color: color)),
            ]),
            if (monthsLeft != null) ...[
              const SizedBox(height: 2),
              Text(
                monthsLeft == 0 ? '已达成' : '预估还需 $monthsLeft 个月',
                style: TextStyle(fontSize: 10, color: monthsLeft == 0 ? Colors.green : Colors.black54),
              ),
            ],
          ],
          const SizedBox(height: 4),
          Row(children: [
            Text('本月', style: const TextStyle(fontSize: 10, color: Colors.black54)),
            const SizedBox(width: 4),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: monthPct,
                  minHeight: 4,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(monthPct >= 1.0 ? Colors.green : color),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text('${(monthPct * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 10, color: Colors.black54)),
          ]),
          // 本月剩余应存入量
          if (thisMonthTarget > 0) ...[
            const SizedBox(height: 2),
            Builder(builder: (_) {
              final remaining = thisMonthTarget - thisMonth;
              if (remaining <= 0) {
                return Text('本月已完成', style: TextStyle(fontSize: 10, color: Colors.green.shade600));
              }
              return Text('本月剩余 ${f.format(remaining)} 待转入',
                  style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.7)));
            }),
          ],
        ],
      ),
    ),
    );
  }

  // 大件前 5 + 预估月数
  Widget _topPurchasesCard(ThemeData theme) {
    final f = NumberFormat('#,##0.00');
    final list = _ov!.topPurchases;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('大件购买规划（前 5 优先级）', style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton(
                onPressed: () => context.push('/big-purchase'),
                child: const Text('查看全部'),
              ),
            ]),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无大件规划'),
              )
            else
              ...list.map((p) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(child: Text('P${p.priority + 1}')),
                    title: Text(p.name),
                    subtitle: Text('${f.format(p.price)} 元'),
                    trailing: Text(
                      p.achievable
                          ? '可购买'
                          : (p.estimatedMonths < 0
                              ? '需配置'
                              : '约 ${p.estimatedMonths} 个月'),
                      style: TextStyle(
                        color: p.achievable
                            ? Colors.green
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  // 家庭总财富趋势
  Widget _trendChartCard(ThemeData theme) {
    final w = _chart?.wealth ?? [];
    if (w.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('暂无财富数据', style: theme.textTheme.titleMedium),
        ),
      );
    }
    double maxV = 0;
    double minV = double.infinity;
    for (final p in w) {
      if (p.totalWealth > maxV) maxV = p.totalWealth;
      if (p.totalWealth < minV) minV = p.totalWealth;
    }
    if (maxV == 0) maxV = 1;
    if (minV == double.infinity) minV = 0;
    final spots = <FlSpot>[];
    for (var i = 0; i < w.length; i++) {
      spots.add(FlSpot(i.toDouble(), w[i].totalWealth));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('家庭总财富曲线', style: theme.textTheme.titleMedium),
              const Spacer(),
              _legendDot(theme.colorScheme.primary, '总财富'),
              const SizedBox(width: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'month', label: Text('月', style: TextStyle(fontSize: 12))),
                  ButtonSegment(value: 'year', label: Text('年', style: TextStyle(fontSize: 12))),
                ],
                selected: {_chartPeriod},
                onSelectionChanged: (s) {
                  setState(() => _chartPeriod = s.first);
                  _reloadChart();
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  minY: minV < 0 ? minV * 1.1 : 0,
                  maxY: maxV * 1.1,
                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (v, _) => Text(
                          v.abs() >= 1000 ? '${(v / 1000).toStringAsFixed(0)}k' : v.toStringAsFixed(0),
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 || i >= w.length) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(w[i].month.substring(5),
                                style: const TextStyle(fontSize: 10)),
                          );
                        },
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      barWidth: 2,
                      color: theme.colorScheme.primary,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      ),
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

  Widget _legendDot(Color c, String text) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 12)),
    ]);
  }

  // 投资年度汇算细则弹窗
  Future<void> _showInvestmentDetail(BuildContext context) async {
    final f = NumberFormat('#,##0.00');
    showDialog(
      context: context,
      builder: (_) => const Center(child: CircularProgressIndicator()),
      barrierDismissible: false,
    );
    final r = await ApiClient.instance.investmentSettlement(scope: _scope);
    if (!mounted) return;
    Navigator.pop(context); // 关闭 loading

    if (!r.ok || r.data == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('加载投资汇算数据失败')));
      return;
    }
    final d = r.data!;
    final lastYear = d['lastYear'] ?? 0;
    final targetRate = (d['targetRate'] as num? ?? 0).toDouble();
    final actualRate = (d['actualRate'] as num? ?? 0).toDouble();
    final totalPrincipal = (d['totalPrincipal'] as num? ?? 0).toDouble();
    final totalProfit = (d['totalProfit'] as num? ?? 0).toDouble();
    final expectedProfit = (d['expectedProfit'] as num? ?? 0).toDouble();
    final deficit = (d['deficit'] as num? ?? 0).toDouble();
    final monthlyDeduction = (d['monthlyDeduction'] as num? ?? 0).toDouble();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.trending_up, color: Colors.indigo),
          const SizedBox(width: 8),
          Text('${lastYear}年投资汇算'),
        ]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow('投入本金', f.format(totalPrincipal), Colors.indigo),
              _detailRow('实际收益', f.format(totalProfit), totalProfit >= 0 ? Colors.green : Colors.red),
              _detailRow('实际年化', '${(actualRate * 100).toStringAsFixed(2)}%', actualRate >= targetRate ? Colors.green : Colors.red),
              const Divider(),
              _detailRow('预期年化', '${(targetRate * 100).toStringAsFixed(2)}%', Colors.grey),
              _detailRow('预期收益', f.format(expectedProfit), Colors.grey),
              const Divider(),
              if (deficit > 0) ...[
                _detailRow('缺失收益', f.format(deficit), Colors.red),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
                        const SizedBox(width: 6),
                        Text('补差方案', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.orange.shade700)),
                      ]),
                      const SizedBox(height: 4),
                      Text('${lastYear + 1}年每月从消费桶扣除 ${f.format(monthlyDeduction)} 元，自动转入投资桶',
                          style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    Text('收益达标，无需补差', style: TextStyle(color: Colors.green.shade700)),
                  ]),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  // 消费细则弹窗
  Future<void> _showConsumptionDetail(BuildContext context) async {
    final f = NumberFormat('#,##0.00');
    final ov = _ov!;
    final a = ov.allocation;

    // 计算投资补差扣除
    final r = await ApiClient.instance.investmentSettlement(scope: _scope);
    double monthlyDeduction = 0;
    if (r.ok && r.data != null) {
      monthlyDeduction = (r.data!['monthlyDeduction'] as num? ?? 0).toDouble();
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Icon(Icons.account_balance_wallet, color: Colors.green.shade700),
          const SizedBox(width: 8),
          const Text('本月消费明细'),
        ]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow('月收入', f.format(a.monthlyIncome), Colors.indigo),
              const Divider(),
              Text('硬性扣除', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
              _detailRow('  储蓄 (${a.monthlyIncome > 0 ? (a.savingTarget / a.monthlyIncome * 100).toStringAsFixed(0) : '0'}%)', '- ${f.format(a.savingTarget)}', Colors.orange),
              _detailRow('  投资 (${a.monthlyIncome > 0 ? (a.investmentTarget / a.monthlyIncome * 100).toStringAsFixed(0) : '0'}%)', '- ${f.format(a.investmentTarget)}', Colors.indigo),
              _detailRow('  应急 (${a.monthlyIncome > 0 ? (a.emergencyTarget / a.monthlyIncome * 100).toStringAsFixed(0) : '0'}%)', '- ${f.format(a.emergencyTarget)}', Colors.deepOrange),
              _detailRow('  养老 (${a.monthlyIncome > 0 ? (a.pensionTarget / a.monthlyIncome * 100).toStringAsFixed(0) : '0'}%)', '- ${f.format(a.pensionTarget)}', Colors.teal),
              if (monthlyDeduction > 0) ...[
                const Divider(),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    Icon(Icons.trending_down, size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 6),
                    Expanded(child: Text('投资补差扣除：- ${f.format(monthlyDeduction)}', style: TextStyle(fontSize: 12, color: Colors.orange.shade700))),
                  ]),
                ),
              ],
              const Divider(),
              _detailRow('可消费额度', f.format(a.consumption), Colors.green),
              _detailRow('已消费', f.format(ov.dailySpent), Colors.red),
              _detailRow('剩余可消费', f.format(ov.monthConsumableLeft), ov.monthConsumableLeft >= 0 ? Colors.green : Colors.red),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          TextButton(onPressed: () {
            Navigator.pop(context);
            context.push('/bookkeeping');
          }, child: const Text('去记账')),
        ],
      ),
    );
  }

  Future<void> _showWealthDetail(BuildContext context) async {
    if (_ov == null) return;
    final ov = _ov!;
    final f = NumberFormat('#,##0.00');
    final a = ov.allocation;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Icon(Icons.account_balance, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(_scope == 'personal' ? '个人总财富明细' : '家庭总财富明细'),
        ]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('资产构成', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
              _detailRow('  现金', f.format(ov.totalCash), Colors.green),
              _detailRow('  公积金', f.format(ov.totalHousingFund), Colors.blue),
              _detailRow('  储蓄桶', f.format(ov.savingBalance), Colors.orange),
              _detailRow('  投资桶', f.format(ov.investmentBalance), Colors.indigo),
              _detailRow('  应急桶', f.format(ov.emergencyBalance), Colors.deepOrange),
              _detailRow('  养老桶', f.format(ov.pensionBalance), Colors.teal),
              const Divider(),
              _detailRow('总财富', f.format(ov.totalWealth), Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.blue.shade700),
                  const SizedBox(width: 6),
                  Expanded(child: Text(
                    '总财富 = 现金 + 公积金 + 储蓄桶 + 投资桶 + 应急桶 + 养老桶',
                    style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                  )),
                ]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}
