import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 可贷款计算模块
/// 根据用户收入情况判断是否可以承担某笔贷款
class LoanCalculatorPage extends StatefulWidget {
  final double monthlyIncome; // 月收入
  final double loanRatio; // 可用于还贷的比例（如 0.4）

  const LoanCalculatorPage({
    super.key,
    required this.monthlyIncome,
    this.loanRatio = 0.4,
  });

  @override
  State<LoanCalculatorPage> createState() => _LoanCalculatorPageState();
}

class _LoanCalculatorPageState extends State<LoanCalculatorPage> {
  final _totalAmount = TextEditingController();
  final _annualRate = TextEditingController(text: '3.5');
  final _termYears = TextEditingController(text: '30');
  String _method = 'equal_payment'; // equal_payment / equal_capital

  double _monthlyPayment = 0;
  double _totalPayment = 0;
  double _totalInterest = 0;
  double _maxLoanAmount = 0;
  bool _canAfford = false;
  double _debtRatio = 0;
  bool _calculated = false;

  @override
  void initState() {
    super.initState();
    _maxLoanAmount = _calculateMaxLoan();
  }

  /// 计算最大可贷款金额
  /// 公式：最大可贷款额 = 月可还贷额 × 贷款系数
  /// 贷款系数 = ((1+r)^n - 1) / (r × (1+r)^n)
  double _calculateMaxLoan() {
    final monthlyPayment = widget.monthlyIncome * widget.loanRatio;
    final annualRate = double.tryParse(_annualRate.text) ?? 3.5;
    final termYears = int.tryParse(_termYears.text) ?? 30;
    final r = annualRate / 12 / 100;
    final n = termYears * 12;

    if (r <= 0 || n <= 0 || monthlyPayment <= 0) return 0;

    // 等额本息：最大贷款额 = 月供 × ((1+r)^n - 1) / (r × (1+r)^n)
    final factor = (pow(1 + r, n) - 1) / (r * pow(1 + r, n));
    return monthlyPayment * factor;
  }

  /// 计算等额本息月供
  double _calculateEqualPayment(double P, double r, int n) {
    if (r <= 0) return P / n;
    return P * r * pow(1 + r, n) / (pow(1 + r, n) - 1);
  }

  /// 计算等额本金首月月供
  double _calculateEqualCapitalFirst(double P, double r, int n) {
    return P / n + P * r;
  }

  void _calculate() {
    final P = double.tryParse(_totalAmount.text) ?? 0;
    final annualRate = double.tryParse(_annualRate.text) ?? 0;
    final termYears = int.tryParse(_termYears.text) ?? 0;
    final r = annualRate / 12 / 100;
    final n = termYears * 12;

    if (P <= 0 || n <= 0) {
      setState(() => _calculated = false);
      return;
    }

    double monthly;
    double total;

    if (_method == 'equal_payment') {
      monthly = _calculateEqualPayment(P, r, n);
      total = monthly * n;
    } else {
      // 等额本金：总利息 = P × r × (n+1) / 2
      monthly = _calculateEqualCapitalFirst(P, r, n);
      total = P + P * r * (n + 1) / 2;
    }

    final maxMonthly = widget.monthlyIncome * widget.loanRatio;

    setState(() {
      _monthlyPayment = monthly;
      _totalPayment = total;
      _totalInterest = total - P;
      _canAfford = monthly <= maxMonthly;
      _debtRatio = monthly / widget.monthlyIncome;
      _calculated = true;
    });
  }

  double pow(double x, int n) {
    double result = 1;
    for (int i = 0; i < n; i++) {
      result *= x;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat('#,##0.00');

    return Scaffold(
      appBar: AppBar(title: const Text('贷款计算器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 收入信息卡片
          Card(
            color: Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.blue.shade700),
                    const SizedBox(width: 6),
                    Text('您的还款能力', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blue.shade700)),
                  ]),
                  const SizedBox(height: 8),
                  Text('月收入：¥${f.format(widget.monthlyIncome)}'),
                  Text('可用于还贷：¥${f.format(widget.monthlyIncome * widget.loanRatio)}（${(widget.loanRatio * 100).toStringAsFixed(0)}%）'),
                  const Divider(),
                  Text('最大可贷款额：¥${f.format(_maxLoanAmount)}',
                      style: TextStyle(fontWeight: FontWeight.w600, color: Colors.green.shade700, fontSize: 16)),
                  Text('基于等额本息、当前利率和期限计算', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 贷款参数输入
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('贷款参数', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _totalAmount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '贷款总额',
                      prefixText: '¥ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _annualRate,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: '年利率',
                            suffixText: '%',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _termYears,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '贷款期限',
                            suffixText: '年',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'equal_payment', label: Text('等额本息')),
                      ButtonSegment(value: 'equal_capital', label: Text('等额本金')),
                    ],
                    selected: {_method},
                    onSelectionChanged: (s) => setState(() => _method = s.first),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _calculate,
                      icon: const Icon(Icons.calculate),
                      label: const Text('计算'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 计算结果
          if (_calculated) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('计算结果', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    _resultRow('每月还款', f.format(_monthlyPayment), Colors.indigo),
                    _resultRow('还款总额', f.format(_totalPayment), Colors.black87),
                    _resultRow('总利息', f.format(_totalInterest), Colors.red),
                    _resultRow('负债比率', '${(_debtRatio * 100).toStringAsFixed(1)}%',
                        _debtRatio > 0.5 ? Colors.red : Colors.green),
                    const Divider(),
                    // 判断结果
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _canAfford ? Colors.green.shade50 : Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _canAfford ? Colors.green.shade200 : Colors.red.shade200,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            _canAfford ? Icons.check_circle : Icons.cancel,
                            color: _canAfford ? Colors.green : Colors.red,
                            size: 48,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _canAfford ? '可以承担此贷款' : '不建议承担此贷款',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: _canAfford ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _canAfford
                                ? '月供占收入${(_debtRatio * 100).toStringAsFixed(1)}%，在可承受范围内'
                                : '月供占收入${(_debtRatio * 100).toStringAsFixed(1)}%，超过50%警戒线',
                            style: TextStyle(
                              fontSize: 13,
                              color: _canAfford ? Colors.green.shade600 : Colors.red.shade600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color, fontSize: 16)),
        ],
      ),
    );
  }
}
