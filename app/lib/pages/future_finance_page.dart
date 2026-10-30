import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';
import 'loan_calculator_page.dart';

class FutureFinancePage extends StatefulWidget {
  const FutureFinancePage({super.key});

  @override
  State<FutureFinancePage> createState() => _FutureFinancePageState();
}

class _FutureFinancePageState extends State<FutureFinancePage> {
  bool _loading = true;
  String _scope = 'personal';
  FutureFinanceData? _data;
  OverviewData? _overview;
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
    // 同时加载未来财务和总览数据
    final futureR = await ApiClient.instance.futureFinance(scope: _scope);
    final overviewR = await ApiClient.instance.overview(scope: _scope);
    if (!mounted) return;
    if (!futureR.ok) {
      setState(() {
        _error = futureR.message;
        _loading = false;
      });
      return;
    }
    setState(() {
      _data = futureR.data;
      _overview = overviewR.data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('未来财务'),
        actions: [
          if (_data != null)
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
                      // 第 1 行（独占）：待还款总额
                      _pendingCard(),
                      const SizedBox(height: 12),
                      // 第 2 行起：每行 2 个条目
                      _row2(
                        _loanCard(
                          title: '公积金贷款',
                          icon: Icons.account_balance,
                          color: Colors.indigo,
                          count: _data!.housingFundLoans.length,
                          onAdd: () => _editHousingLoan(null),
                          summary: _data!.housingFundLoans.isEmpty
                              ? '暂无'
                              : '已还 ${(_data!.housingFundLoans.first.summary.progressPct * 100).toStringAsFixed(1)}%',
                        ),
                        _loanCard(
                          title: '商业贷款',
                          icon: Icons.business_center,
                          color: Colors.purple,
                          count: _data!.commercialLoans.length,
                          onAdd: () => _editCommercialLoan(null),
                          summary: _data!.commercialLoans.isEmpty
                              ? '暂无'
                              : '已还 ${(_data!.commercialLoans.first.summary.progressPct * 100).toStringAsFixed(1)}%',
                        ),
                      ),
                      if (_data!.housingFundLoans.isNotEmpty || _data!.commercialLoans.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _loanListToggle(
                          showHousing: _data!.housingFundLoans,
                          showCommercial: _data!.commercialLoans,
                          onEditHousing: _editHousingLoan,
                          onDeleteHousing: _deleteHousingLoan,
                          onEditCommercial: _editCommercialLoan,
                          onDeleteCommercial: _deleteCommercialLoan,
                        ),
                      ],
                      const SizedBox(height: 12),
                      _row2(
                        _loanCard(
                          title: '借款',
                          icon: Icons.monetization_on,
                          color: Colors.deepOrange,
                          count: _data!.borrowedMoneys.length,
                          onAdd: () => _editBorrowedMoney(null),
                          summary: _data!.borrowedMoneys.isEmpty
                              ? '暂无'
                              : '已还 ${(_data!.borrowedMoneys.first.summary.progressPct * 100).toStringAsFixed(1)}%',
                        ),
                        _benefitCard(
                          count: _data!.futureBenefits.length,
                          onAdd: () => _editBenefit(null),
                          summary: _data!.futureBenefits.isEmpty
                              ? '暂无'
                              : '现值 ${NumberFormat('#,##0').format(_data!.futureBenefits.first.summary.presentValue)} 元',
                        ),
                      ),
                      // 贷款计算器入口
                      const SizedBox(height: 12),
                      Card(
                        color: Colors.teal.shade50,
                        child: ListTile(
                          leading: Icon(Icons.calculate, color: Colors.teal.shade700),
                          title: Text('贷款计算器', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.teal.shade700)),
                          subtitle: const Text('评估是否可以承担某笔贷款'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            final monthlyIncome = _overview?.allocation.monthlyIncome ?? 10000;
                            final loanRatio = 0.4; // 默认贷款比例
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => LoanCalculatorPage(
                                  monthlyIncome: monthlyIncome,
                                  loanRatio: loanRatio,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (_data!.borrowedMoneys.isNotEmpty || _data!.futureBenefits.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _mixListToggle(
                          borroweds: _data!.borrowedMoneys,
                          benefits: _data!.futureBenefits,
                          onEditBorrowed: _editBorrowedMoney,
                          onDeleteBorrowed: _deleteBorrowedMoney,
                          onEditBenefit: _editBenefit,
                          onDeleteBenefit: _deleteBenefit,
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  // ===== 待还款总额（独立一行）=====
  Widget _pendingCard() {
    final f = NumberFormat('#,##0.00');
    final d = _data!;
    final pct100 = (d.totalProgressPct * 100).clamp(0, 100).toStringAsFixed(1);
    final months = d.totalRemainingMonths;
    final monthsText = months > 0 ? '约 $months 个月' : '已全部还清';
    final payoff = DateTime.fromMillisecondsSinceEpoch(d.estimatedPayoffAt * 1000);
    final payoffText = months > 0 ? DateFormat('yyyy-MM').format(payoff) : '—';
    return Card(
      color: Colors.amber.shade50,
      child: InkWell(
        onTap: () => _showPendingDetail(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.receipt_long, color: Colors.amber),
                const SizedBox(width: 8),
                const Text('待还款总额', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('$pct100%', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: Colors.black45),
              ]),
              const SizedBox(height: 8),
              Text('${f.format(d.totalPending)} 元', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: d.totalProgressPct.clamp(0.0, 1.0),
                  minHeight: 10,
                  backgroundColor: Colors.amber.shade100,
                  valueColor: const AlwaysStoppedAnimation(Colors.amber),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.schedule, size: 14, color: Colors.black54),
                const SizedBox(width: 4),
                Text('预估还清：$monthsText（$payoffText）', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  // ===== 一行两个卡片的容器 =====
  Widget _row2(Widget a, Widget b) {
    return Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 8),
        Expanded(child: b),
      ],
    );
  }

  Widget _loanCard({
    required String title,
    required IconData icon,
    required Color color,
    required int count,
    required VoidCallback onAdd,
    required String summary,
  }) {
    return Card(
      child: InkWell(
        onTap: onAdd,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 4),
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('$count', style: TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
              const SizedBox(height: 4),
              Text(summary, style: TextStyle(fontSize: 11, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              TextButton(onPressed: onAdd, child: const Text('+ 新增', style: TextStyle(fontSize: 12))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _benefitCard({
    required int count,
    required VoidCallback onAdd,
    required String summary,
  }) {
    return Card(
      child: InkWell(
        onTap: onAdd,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.savings_outlined, color: Colors.teal, size: 18),
                const SizedBox(width: 4),
                const Text('未来利益', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('$count', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
              const SizedBox(height: 4),
              Text(summary, style: const TextStyle(fontSize: 11, color: Colors.teal), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              TextButton(onPressed: onAdd, child: const Text('+ 新增', style: TextStyle(fontSize: 12))),
            ],
          ),
        ),
      ),
    );
  }

  // ===== 展开行后显示所有明细 =====
  Widget _loanListToggle({
    required List<HousingFundLoan> showHousing,
    required List<CommercialLoan> showCommercial,
    required void Function(HousingFundLoan?) onEditHousing,
    required void Function(int) onDeleteHousing,
    required void Function(CommercialLoan?) onEditCommercial,
    required void Function(int) onDeleteCommercial,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          children: [
            for (final l in showHousing) _loanItem('公积金', l.name, l.total, l.annualRate, l.summary, l.method, l.id, () => onEditHousing(l), () => onDeleteHousing(l.id), Colors.indigo),
            for (final l in showCommercial) _loanItem('商业', l.name, l.total, l.annualRate, l.summary, l.method, l.id, () => onEditCommercial(l), () => onDeleteCommercial(l.id), Colors.purple),
          ],
        ),
      ),
    );
  }

  Widget _mixListToggle({
    required List<BorrowedMoney> borroweds,
    required List<FutureBenefit> benefits,
    required void Function(BorrowedMoney?) onEditBorrowed,
    required void Function(int) onDeleteBorrowed,
    required void Function(FutureBenefit?) onEditBenefit,
    required void Function(int) onDeleteBenefit,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          children: [
            for (final b in borroweds) _loanItem('借款', b.name, b.total, b.annualRate, b.summary, b.method, b.id, () => onEditBorrowed(b), () => onDeleteBorrowed(b.id), Colors.deepOrange),
            for (final b in benefits) _benefitItem(b, () => onEditBenefit(b), () => onDeleteBenefit(b.id)),
          ],
        ),
      ),
    );
  }

  Widget _loanItem(String category, String name, double total, double rate, LoanSummary sm, String method, int id, VoidCallback onEdit, VoidCallback onDelete, Color color) {
    final f = NumberFormat('#,##0.00');
    final pct100 = (sm.progressPct * 100).clamp(0, 100).toStringAsFixed(1);
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)), child: Text(category, style: TextStyle(fontSize: 11, color: color))),
              const SizedBox(width: 6),
              Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
              Text('${f.format(sm.remainingAmount)} 元 / ${f.format(sm.monthlyPayment)}/月', style: const TextStyle(fontSize: 11, color: Colors.black54)),
              IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red), onPressed: onDelete),
            ]),
            Row(children: [
              Text(LoanMethod.labels[method] ?? method, style: TextStyle(fontSize: 11, color: color)),
              const SizedBox(width: 6),
              Text('年利率 ${rate.toStringAsFixed(2)}%', style: const TextStyle(fontSize: 11, color: Colors.black54)),
              const SizedBox(width: 6),
              Text('已还 ${sm.paidAmount.toStringAsFixed(0)}/${sm.totalPayment.toStringAsFixed(0)}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ]),
            const SizedBox(height: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: sm.progressPct.clamp(0.0, 1.0), minHeight: 4, backgroundColor: color.withValues(alpha: 0.15), valueColor: AlwaysStoppedAnimation(color)),
            ),
            const SizedBox(height: 2),
            Text('进度 $pct100% · 剩余 ${sm.remainingMonths} 个月', style: const TextStyle(fontSize: 10, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  Widget _benefitItem(FutureBenefit b, VoidCallback onEdit, VoidCallback onDelete) {
    final f = NumberFormat('#,##0.00');
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)), child: const Text('未来利益', style: TextStyle(fontSize: 11, color: Colors.teal))),
              const SizedBox(width: 6),
              Expanded(child: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
              Text('现值 ${f.format(b.summary.presentValue)} 元', style: const TextStyle(fontSize: 11, color: Colors.teal)),
              IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red), onPressed: onDelete),
            ]),
            Text('${BenefitType.labels[b.type] ?? b.type} · 发放额 ${f.format(b.payoutAmount)} 元', style: const TextStyle(fontSize: 11, color: Colors.black54), overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }


  // ===== 弹窗 =====
  Future<void> _showPendingDetail() async {
    final f = NumberFormat('#,##0.00');
    final d = _data!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('待还款明细'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in d.housingFundLoans)
                _detailRow('公积金·${l.name}', l.summary.remainingAmount, l.summary.monthlyPayment, Colors.indigo, f),
              for (final l in d.commercialLoans)
                _detailRow('商业·${l.name}', l.summary.remainingAmount, l.summary.monthlyPayment, Colors.purple, f),
              for (final l in d.borrowedMoneys)
                _detailRow('借款·${l.name}', l.summary.remainingAmount, l.summary.monthlyPayment, Colors.deepOrange, f),
              const Divider(),
              Row(children: [
                const Text('合计', style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('${f.format(d.totalPending)} 元', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }

  Widget _detailRow(String label, double remain, double monthly, Color color, NumberFormat f) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
        Text('${f.format(remain)} / 月 ${f.format(monthly)}', style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Future<void> _editHousingLoan(HousingFundLoan? src) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LoanEditDialog(
        title: src == null ? '新增公积金贷款' : '编辑公积金贷款',
        initialName: src?.name ?? '',
        initialTotal: src?.total ?? 0,
        initialRate: src?.annualRate ?? 3.25,
        initialMonths: src?.termMonths ?? 360,
        initialPaid: src?.paidMonths ?? 0,
        initialMethod: src?.method ?? LoanMethod.equalPayment,
        initialNote: src?.note ?? '',
        allowInterestFree: false,
        scope: _scope,
      ),
    );
    if (r == null) return;
    if (src == null) {
      final resp = await ApiClient.instance.createHousingLoan(r);
      _toast(resp);
    } else {
      final resp = await ApiClient.instance.updateHousingLoan(src.id, r);
      _toast(resp);
    }
    _load();
  }

  Future<void> _deleteHousingLoan(int id) async {
    if (!await _confirm('确认删除该公积金贷款？')) return;
    final r = await ApiClient.instance.deleteHousingLoan(id);
    _toast(r);
    _load();
  }

  Future<void> _editCommercialLoan(CommercialLoan? src) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LoanEditDialog(
        title: src == null ? '新增商业贷款' : '编辑商业贷款',
        initialName: src?.name ?? '',
        initialTotal: src?.total ?? 0,
        initialRate: src?.annualRate ?? 4.5,
        initialMonths: src?.termMonths ?? 360,
        initialPaid: src?.paidMonths ?? 0,
        initialMethod: src?.method ?? LoanMethod.equalPayment,
        initialNote: src?.note ?? '',
        allowInterestFree: false,
        scope: _scope,
      ),
    );
    if (r == null) return;
    if (src == null) {
      final resp = await ApiClient.instance.createCommercialLoan(r);
      _toast(resp);
    } else {
      final resp = await ApiClient.instance.updateCommercialLoan(src.id, r);
      _toast(resp);
    }
    _load();
  }

  Future<void> _deleteCommercialLoan(int id) async {
    if (!await _confirm('确认删除该商业贷款？')) return;
    final r = await ApiClient.instance.deleteCommercialLoan(id);
    _toast(r);
    _load();
  }

  Future<void> _editBorrowedMoney(BorrowedMoney? src) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LoanEditDialog(
        title: src == null ? '新增借款' : '编辑借款',
        initialName: src?.name ?? '',
        initialTotal: src?.total ?? 0,
        initialRate: src?.annualRate ?? 0,
        initialMonths: src?.termMonths ?? 12,
        initialPaid: src?.paidMonths ?? 0,
        initialMethod: src?.method ?? LoanMethod.interestFree,
        initialNote: src?.note ?? '',
        allowInterestFree: true,
        scope: _scope,
      ),
    );
    if (r == null) return;
    if (src == null) {
      final resp = await ApiClient.instance.createBorrowedMoney(r);
      _toast(resp);
    } else {
      final resp = await ApiClient.instance.updateBorrowedMoney(src.id, r);
      _toast(resp);
    }
    _load();
  }

  Future<void> _deleteBorrowedMoney(int id) async {
    if (!await _confirm('确认删除该借款？')) return;
    final r = await ApiClient.instance.deleteBorrowedMoney(id);
    _toast(r);
    _load();
  }

  Future<void> _editBenefit(FutureBenefit? src) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _BenefitEditDialog(
        title: src == null ? '新增未来利益' : '编辑未来利益',
        initial: src,
        scope: _scope,
      ),
    );
    if (r == null) return;
    if (src == null) {
      final resp = await ApiClient.instance.createBenefit(r);
      _toast(resp);
    } else {
      final resp = await ApiClient.instance.updateBenefit(src.id, r);
      _toast(resp);
    }
    _load();
  }

  Future<void> _deleteBenefit(int id) async {
    if (!await _confirm('确认删除该未来利益？')) return;
    final r = await ApiClient.instance.deleteBenefit(id);
    _toast(r);
    _load();
  }


  Future<bool> _confirm(String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    return r == true;
  }

  void _toast(dynamic resp) {
    if (!mounted) return;
    final ok = (resp.ok == true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '操作成功' : (resp.message ?? '失败')), duration: const Duration(seconds: 2)),
    );
  }
}

// ====== 贷款编辑弹窗 ======
class _LoanEditDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final double initialTotal;
  final double initialRate;
  final int initialMonths;
  final int initialPaid;
  final String initialMethod;
  final String initialNote;
  final bool allowInterestFree;
  final String scope;
  const _LoanEditDialog({
    required this.title,
    required this.initialName,
    required this.initialTotal,
    required this.initialRate,
    required this.initialMonths,
    required this.initialPaid,
    required this.initialMethod,
    required this.initialNote,
    required this.allowInterestFree,
    required this.scope,
  });

  @override
  State<_LoanEditDialog> createState() => _LoanEditDialogState();
}

class _LoanEditDialogState extends State<_LoanEditDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);
  late final TextEditingController _total = TextEditingController(text: widget.initialTotal.toStringAsFixed(0));
  late final TextEditingController _rate = TextEditingController(text: widget.initialRate.toStringAsFixed(2));
  late final TextEditingController _months = TextEditingController(text: widget.initialMonths.toString());
  late final TextEditingController _paid = TextEditingController(text: widget.initialPaid.toString());
  late final TextEditingController _note = TextEditingController(text: widget.initialNote);
  late String _method = widget.initialMethod;

  @override
  void dispose() {
    _name.dispose();
    _total.dispose();
    _rate.dispose();
    _months.dispose();
    _paid.dispose();
    _note.dispose();
    super.dispose();
  }

  double? _previewMonthly;

  void _calcPreview() {
    final P = double.tryParse(_total.text) ?? 0;
    final r = double.tryParse(_rate.text) ?? 0;
    final n = int.tryParse(_months.text) ?? 0;
    if (P <= 0 || n <= 0) {
      setState(() => _previewMonthly = null);
      return;
    }
    final mr = r / 12.0 / 100.0;
    double m;
    if (_method == LoanMethod.equalPayment) {
      if (mr <= 0) {
        m = P / n;
      } else {
        final factor = _pow(1 + mr, n);
        m = P * mr * factor / (factor - 1);
      }
    } else if (_method == LoanMethod.equalCapital) {
      m = P / n + (P - 0) * mr;
    } else {
      m = P / n;
    }
    setState(() => _previewMonthly = m);
  }

  double _pow(double x, int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= x;
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final methodOptions = <String>[
      LoanMethod.equalPayment,
      LoanMethod.equalCapital,
      if (widget.allowInterestFree) LoanMethod.interestFree,
    ];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: '名称')),
              const SizedBox(height: 8),
              TextField(
                controller: _total,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (_) => _calcPreview(),
                decoration: const InputDecoration(labelText: '贷款总额 (元)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _rate,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (_) => _calcPreview(),
                decoration: const InputDecoration(labelText: '年利率 (%)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _months,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _calcPreview(),
                decoration: const InputDecoration(labelText: '总期数 (月)'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _method,
                items: [
                  for (final m in methodOptions)
                    DropdownMenuItem(value: m, child: Text(LoanMethod.labels[m] ?? m)),
                ],
                onChanged: (v) {
                  setState(() => _method = v ?? _method);
                  _calcPreview();
                },
                decoration: const InputDecoration(labelText: '还款方式'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _paid,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: '已还期数 (月)'),
              ),
              const SizedBox(height: 8),
              TextField(controller: _note, decoration: const InputDecoration(labelText: '备注')),
              if (_previewMonthly != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Text('首月应还：${_previewMonthly!.toStringAsFixed(2)} 元', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final m = {
              'scope': widget.scope,
              'name': _name.text,
              'total': double.tryParse(_total.text) ?? 0,
              'annualRate': double.tryParse(_rate.text) ?? 0,
              'termMonths': int.tryParse(_months.text) ?? 0,
              'paidMonths': int.tryParse(_paid.text) ?? 0,
              'method': _method,
              'startMonth': 0,
              'note': _note.text,
            };
            Navigator.pop(context, m);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ====== 未来利益编辑弹窗 ======
class _BenefitEditDialog extends StatefulWidget {
  final String title;
  final FutureBenefit? initial;
  final String scope;
  const _BenefitEditDialog({required this.title, required this.initial, required this.scope});
  @override
  State<_BenefitEditDialog> createState() => _BenefitEditDialogState();
}

class _BenefitEditDialogState extends State<_BenefitEditDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _amount = TextEditingController(
    text: widget.initial != null && widget.initial!.payoutAmount > 0
        ? widget.initial!.payoutAmount.toStringAsFixed(0)
        : '',
  );
  late final TextEditingController _note = TextEditingController(text: widget.initial?.note ?? '');
  late final TextEditingController _customYears = TextEditingController(
    text: widget.initial != null && widget.initial!.customYears > 0
        ? widget.initial!.customYears.toString()
        : '10',
  );
  late String _type = widget.initial?.type ?? BenefitType.lumpSum;
  DateTime? _payoutDate; // 一次性：发放日期；逐月/年/终身/自定义：开始发放日期

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    _customYears.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.initial != null && widget.initial!.payoutDate > 0) {
      _payoutDate = DateTime.fromMillisecondsSinceEpoch(widget.initial!.payoutDate * 1000);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final init = _payoutDate ?? now.add(const Duration(days: 365));
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 50),
    );
    if (d != null) {
      setState(() => _payoutDate = d);
    }
  }

  String get _dateLabel {
    if (_payoutDate == null) return '请选择日期';
    return '${_payoutDate!.year}-${_payoutDate!.month.toString().padLeft(2, '0')}-${_payoutDate!.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isLump = _type == BenefitType.lumpSum;
    final isCustom = _type == BenefitType.customYears;
    final isMonthlyLike = _type == BenefitType.monthly ||
        _type == BenefitType.yearly ||
        _type == BenefitType.lifetime;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: '名称')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _type,
                items: [
                  for (final t in BenefitType.labels.keys)
                    DropdownMenuItem(value: t, child: Text(BenefitType.labels[t] ?? t)),
                ],
                onChanged: (v) => setState(() => _type = v ?? _type),
                decoration: const InputDecoration(labelText: '发放方式'),
              ),
              const SizedBox(height: 8),
              // 日期
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: isLump ? '发放日期' : '开始发放日期',
                    suffixIcon: const Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(_dateLabel),
                ),
              ),
              const SizedBox(height: 8),
              // 金额
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: InputDecoration(
                  labelText: isLump ? '发放额 (元)' : '每月发放金额 (元)',
                  prefixText: '¥ ',
                  helperText: isLump
                      ? '到期一次性领取的总金额'
                      : isCustom
                          ? '每月发放金额（持续自定义年限）'
                          : isMonthlyLike
                              ? '每月/每年发放金额（持续到预期寿命）'
                              : '',
                ),
              ),
              // 自定义年限
              if (isCustom) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customYears,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '自定义年限 (年)',
                    suffixText: '年',
                  ),
                ),
              ],
              if (!isLump) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.info_outline, size: 14, color: Colors.blue),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _type == BenefitType.lifetime
                            ? '按当前设置终身逐月发放（折现计算）'
                            : _type == BenefitType.customYears
                                ? '按自定义年限逐月发放（折现计算）'
                                : '按月/按年发放至预期寿命（折现计算）',
                        style: const TextStyle(fontSize: 11, color: Colors.blue),
                      ),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 8),
              TextField(controller: _note, decoration: const InputDecoration(labelText: '备注')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            if (_payoutDate == null) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请选择发放时间')));
              return;
            }
            final amt = double.tryParse(_amount.text) ?? 0;
            if (amt <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写有效金额')));
              return;
            }
            final ts = DateTime(_payoutDate!.year, _payoutDate!.month, _payoutDate!.day, 0, 0, 0).millisecondsSinceEpoch ~/ 1000;
            final m = {
              'scope': widget.scope,
              'name': _name.text,
              'type': _type,
              'payoutDate': ts,
              'payoutAmount': amt,
              'customYears': int.tryParse(_customYears.text) ?? 0,
              'note': _note.text,
            };
            Navigator.pop(context, m);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
