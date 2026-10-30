import 'package:flutter/material.dart';

import '../services/api.dart';

class PlanPage extends StatefulWidget {
  const PlanPage({super.key});
  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  String _scope = 'personal';
  // 基础参数
  final _emergencyTarget = TextEditingController(text: '100000');
  final _pensionTarget = TextEditingController(text: '500000');
  final _survival = TextEditingController(text: '3000');
  final _bigPurchase = TextEditingController(text: '0.5');
  final _annualRate = TextEditingController(text: '0.05');
  // 寿命规划
  final _currentAge = TextEditingController(text: '30');
  final _lifeExpectancy = TextEditingController(text: '80');
  // 6 大分配桶占比（新默认值）
  final _loan = TextEditingController(text: '0.4');
  final _saving = TextEditingController(text: '0.2');
  final _investment = TextEditingController(text: '0.05');
  final _emergency = TextEditingController(text: '0.05');
  final _pension = TextEditingController(text: '0.05');
  final _consumption = TextEditingController(text: '0.25');
  bool _loading = false;

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiClient.instance.getPlan(scope: _scope);
    if (r.ok && r.data != null) {
      final d = r.data!;
      _emergencyTarget.text = (d['emergencyTarget'] ?? 100000).toString();
      _pensionTarget.text = (d['pensionTarget'] ?? 500000).toString();
      _survival.text = (d['monthlySurvivalCost'] ?? 0).toString();
      _bigPurchase.text = (d['bigPurchaseRatio'] ?? 0.5).toString();
      _annualRate.text = (d['investAnnualRate'] ?? 0.05).toString();
      _currentAge.text = (d['currentAge'] ?? 30).toString();
      _lifeExpectancy.text = (d['lifeExpectancy'] ?? 80).toString();
      _loan.text = (d['loanRatio'] ?? 0.4).toString();
      _saving.text = (d['savingRatio'] ?? 0.2).toString();
      _investment.text = (d['investmentRatio'] ?? 0.05).toString();
      _emergency.text = (d['emergencyRatio'] ?? 0.05).toString();
      _pension.text = (d['pensionRatio'] ?? 0.05).toString();
      _consumption.text = (d['consumptionRatio'] ?? 0.25).toString();
    }
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final sum = _sum();
    if ((sum - 1).abs() > 0.001) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('收入占比合计必须等于 1，当前=${sum.toStringAsFixed(2)}')));
      return;
    }
    setState(() => _loading = true);
    final r = await ApiClient.instance.savePlan({
      'scope': _scope,
      'emergencyTarget': double.tryParse(_emergencyTarget.text) ?? 0,
      'pensionTarget': double.tryParse(_pensionTarget.text) ?? 0,
      'monthlySurvivalCost': double.tryParse(_survival.text) ?? 0,
      'bigPurchaseRatio': double.tryParse(_bigPurchase.text) ?? 0.5,
      'investAnnualRate': double.tryParse(_annualRate.text) ?? 0.05,
      'currentAge': int.tryParse(_currentAge.text) ?? 30,
      'lifeExpectancy': int.tryParse(_lifeExpectancy.text) ?? 80,
      'loanRatio': double.tryParse(_loan.text) ?? 0,
      'savingRatio': double.tryParse(_saving.text) ?? 0,
      'investmentRatio': double.tryParse(_investment.text) ?? 0,
      'emergencyRatio': double.tryParse(_emergency.text) ?? 0,
      'pensionRatio': double.tryParse(_pension.text) ?? 0,
      'consumptionRatio': double.tryParse(_consumption.text) ?? 0,
    });
    setState(() => _loading = false);
    if (r.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  double _sum() {
    return [_loan, _saving, _investment, _emergency, _pension, _consumption]
        .fold<double>(0, (s, c) => s + (double.tryParse(c.text) ?? 0));
  }

  void _resetDefaults() {
    setState(() {
      _loan.text = '0.4';
      _saving.text = '0.2';
      _investment.text = '0.05';
      _emergency.text = '0.05';
      _pension.text = '0.05';
      _consumption.text = '0.25';
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('财务预规划'),
        actions: [
          TextButton(onPressed: _resetDefaults, child: const Text('恢复默认')),
          IconButton(onPressed: _save, icon: const Icon(Icons.save)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<String>(
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
                const SizedBox(height: 16),
                _section('基础参数', [
                  _field(_emergencyTarget, '应急备用金目标', suffix: '元'),
                  _field(_pensionTarget, '养老金目标', suffix: '元'),
                  _field(_survival, '每月最低生存成本', suffix: '元'),
                  _field(_bigPurchase, '大件可占用储蓄比例', suffix: '0~1'),
                  _field(_annualRate, '投资规划年收益率', suffix: '0~1'),
                ]),
                const SizedBox(height: 16),
                _section('寿命规划', [
                  _field(_currentAge, '当前年龄', suffix: '岁'),
                  _field(_lifeExpectancy, '预期寿命', suffix: '岁'),
                ]),
                const SizedBox(height: 16),
                _section('收入分配占比（合计=1，当前=${_sum().toStringAsFixed(2)}）', [
                  _field(_loan, '贷款还款', hint: '默认 40%'),
                  _field(_saving, '硬性储蓄', hint: '默认 20%'),
                  _field(_investment, '投资', hint: '默认 5%'),
                  _field(_emergency, '应急备用金', hint: '默认 5%'),
                  _field(_pension, '养老金', hint: '默认 5%'),
                  _field(_consumption, '消费支出', hint: '默认 25%'),
                ]),
              ],
            ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {String? suffix, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
    );
  }
}
