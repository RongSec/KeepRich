import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';
import '../theme.dart';

class BookkeepingPage extends StatefulWidget {
  const BookkeepingPage({super.key});
  @override
  State<BookkeepingPage> createState() => _BookkeepingPageState();
}

class _BookkeepingPageState extends State<BookkeepingPage> {
  List<TxRecord> _list = [];
  bool _loading = true;
  String _scope = 'personal';
  String _tabType = TxType.expense; // 当前 tab：默认支出
  String? _category;
  String? _recorder;
  int? _startAt;
  int? _endAt;
  String? _exceedWorry;
  int _page = 1;
  int _total = 0;
  double _worryPerBuy = 0;
  double _sumIncome = 0;
  double _sumExpense = 0;
  double _sumTransfer = 0;
  List<FamilyMember> _members = [];

  static const Map<String, IconData> _typeIcons = {
    TxType.income: Icons.south_west,
    TxType.expense: Icons.north_east,
    TxType.transfer: Icons.savings,
  };
  static const Map<String, Color> _typeColors = {
    TxType.income: Colors.green,
    TxType.expense: Colors.redAccent,
    TxType.transfer: Colors.indigo,
  };

  static IconData iconOf(String t) =>
      _typeIcons[t] ?? Icons.account_balance_wallet;
  static Color colorOf(String t) => _typeColors[t] ?? AppTheme.textDim;

  String get _filterLabel {
    if (_startAt == null && _endAt == null) return '全部时间';
    final start = _startAt == null
        ? ''
        : DateFormat('MM-dd')
            .format(DateTime.fromMillisecondsSinceEpoch(_startAt! * 1000));
    final end = _endAt == null
        ? ''
        : DateFormat('MM-dd')
            .format(DateTime.fromMillisecondsSinceEpoch(_endAt! * 1000));
    if (start.isNotEmpty && end.isNotEmpty) return '$start 至 $end';
    if (start.isNotEmpty) return '从 $start';
    return '至 $end';
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadMembers();
  }

  Future<void> _load({bool reset = true}) async {
    if (reset) {
      _page = 1;
      _list = [];
    }
    setState(() => _loading = true);
    // 当前 tab 类型作为过滤条件
    final r = await ApiClient.instance.txPage(
      scope: _scope,
      type: _tabType,
      category: _category,
      recorder: _recorder,
      startAt: _startAt,
      endAt: _endAt,
      exceedWorry: _exceedWorry,
      page: _page,
      size: 30,
    );
    if (!mounted) return;
    if (r.ok && r.data != null) {
      final raw = r.data!['list'] as List;
      final list =
          raw.map((e) => TxRecord.fromJson(e as Map<String, dynamic>)).toList();
      setState(() {
        _list.addAll(list);
        _total = (r.data!['total'] as num).toInt();
        _worryPerBuy = (r.data!['worryPerBuy'] as num? ?? 0).toDouble();
        _sumIncome = (r.data!['sumIncome'] as num? ?? 0).toDouble();
        _sumExpense = (r.data!['sumExpense'] as num? ?? 0).toDouble();
        _sumTransfer = (r.data!['sumTransfer'] as num? ?? 0).toDouble();
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMembers() async {
    if (_scope != 'family') return;
    final r = await ApiClient.instance.familyMembers();
    if (r.ok && r.data != null && mounted) {
      setState(() => _members = r.data!);
    }
  }

  Future<void> _add(String type) async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _AddTxSheet(scope: _scope, type: type, currentUid: _currentUid),
    );
    if (created == true) _load();
  }

  int? get _currentUid => null;

  @override
  Widget build(BuildContext context) {
    // 选中当前 tab 的账单/合计
    final selectedType = _tabType;
    final selectedList = _list.where((t) => t.type == selectedType).toList();
    final selectedSum = selectedType == TxType.income
        ? _sumIncome
        : selectedType == TxType.expense
            ? _sumExpense
            : _sumTransfer;

    return Scaffold(
      appBar: AppBar(
        title: const Text('记账'),
        actions: [
          IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: '筛选',
              onPressed: _showFilter),
        ],
      ),
      body: Column(
        children: [
          // scope 切换
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'personal', label: Text('个人')),
                ButtonSegment(value: 'family', label: Text('家庭')),
              ],
              selected: {_scope},
              onSelectionChanged: (s) {
                setState(() => _scope = s.first);
                _load();
                _loadMembers();
              },
            ),
          ),
          // 顶部统计
          _statsBar(),
          // 已应用筛选条件
          if (_category != null ||
              (_recorder != null && _recorder != 'all') ||
              _exceedWorry != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                if (_category != null)
                  Chip(
                      label: Text(TxCategory.labelOf(_category!)),
                      onDeleted: () {
                        setState(() => _category = null);
                        _load();
                      }),
                if (_recorder != null && _recorder != 'all')
                  Chip(
                      label: Text('记账人 $_recorder'),
                      onDeleted: () {
                        setState(() => _recorder = null);
                        _load();
                      }),
                if (_exceedWorry != null)
                  Chip(
                      label: Text(_exceedWorry == '1' ? '超无顾虑单笔' : '未超无顾虑单笔'),
                      onDeleted: () {
                        setState(() => _exceedWorry = null);
                        _load();
                      }),
              ]),
            ),
          // 当前 tab 的小头部
          _selectedTabHeader(selectedType, selectedList.length, selectedSum),
          // 列表
          Expanded(
            child: _loading && _list.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => _load(),
                    child: _listForTab(selectedType, selectedList),
                  ),
          ),
        ],
      ),
      // 底部 1 行 3 列导航栏
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // 底部 1 行 3 列导航栏
  Widget _buildBottomNav() {
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF20C0C12),
          border: Border(
              top: BorderSide(
                  color: AppTheme.gold.withValues(alpha: 0.16), width: 1)),
        ),
        child: Row(children: [
          _navItem(TxType.income, Colors.green, Icons.south_west, '收入'),
          _navItem(TxType.expense, Colors.redAccent, Icons.north_east, '支出'),
          _navItem(TxType.transfer, Colors.indigo, Icons.savings, '存钱'),
        ]),
      ),
    );
  }

  // 单个 nav 单元格：颜色 + 图标 + 名称，激活态有顶部 3px 色条
  Widget _navItem(String type, Color color, IconData icon, String label) {
    final selected = _tabType == type;
    return Expanded(
      child: InkWell(
        onTap: () {
          if (_tabType == type) return;
          setState(() {
            _tabType = type;
            _category = null; // 切换 tab 清空分类筛选
          });
          _load();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 3,
                width: 32,
                decoration: BoxDecoration(
                  color: selected ? color : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon,
                    color: selected ? color : AppTheme.textDim, size: 18),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? color : AppTheme.textDim,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  // 当前 tab 的小头部
  Widget _selectedTabHeader(String type, int count, double amount) {
    final f = NumberFormat('#,##0.00');
    final color = _BookkeepingPageState.colorOf(type);
    final label = TxType.labels[type] ?? type;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.12),
            color.withValues(alpha: 0.04)
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(8)),
          child: Icon(_BookkeepingPageState.iconOf(type),
              color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$label · $count 笔',
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w600)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomLeft,
              child: Text(
                '${type == TxType.expense ? '-' : '+'}${f.format(amount)} 元',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800, color: color),
              ),
            ),
          ]),
        ),
        FilledButton.tonalIcon(
          onPressed: () => _add(type),
          style: FilledButton.styleFrom(
              backgroundColor: color, foregroundColor: Colors.white),
          icon: const Icon(Icons.add, size: 18),
          label: Text('记$label'),
        ),
      ]),
    );
  }

  // 当前 tab 的列表
  Widget _listForTab(String type, List<TxRecord> list) {
    if (list.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 60),
          Center(
            child: Text(
              type == TxType.transfer
                  ? '暂无存钱记录（不影响家庭总财富）'
                  : '暂无${TxType.labels[type]}记录',
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        ...list.map((tx) => _TxTile(
              tx: tx,
              worryPerBuy: _worryPerBuy,
              onTap: () => _editTx(tx),
              onDelete: () => _deleteTx(tx),
            )),
        if (_list.length < _total)
          TextButton(
            onPressed: () {
              _page += 1;
              _load(reset: false);
            },
            child: const Text('加载更多'),
          )
        else
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('没有更多了')),
          ),
      ],
    );
  }

  // 按 type 分组显示（已改为底部 tab 栏）
  // _groupedList / _divider / _moduleHeader 已废弃

  Widget _statsBar() {
    final f = NumberFormat('#,##0.00');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.indigo.withValues(alpha: 0.18),
            Colors.blue.withValues(alpha: 0.14)
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.indigo.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Row(children: [
            Expanded(
                child: _statItem('收入', f.format(_sumIncome), Colors.green,
                    Icons.south_west)),
            Container(
                width: 1,
                height: 32,
                color: Colors.white.withValues(alpha: 0.10)),
            Expanded(
                child: _statItem('支出', f.format(_sumExpense), Colors.redAccent,
                    Icons.north_east)),
            Container(
                width: 1,
                height: 32,
                color: Colors.white.withValues(alpha: 0.10)),
            Expanded(
                child: _statItem('存钱', f.format(_sumTransfer), Colors.indigo,
                    Icons.savings)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.event, size: 14, color: AppTheme.textDim),
            const SizedBox(width: 4),
            Text(_filterLabel,
                style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
            const Spacer(),
            Text('共 $_total 条',
                style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
          ]),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, Color color, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
        ]),
        const SizedBox(height: 2),
        FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: color))),
      ],
    );
  }

  void _showFilter() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return _FilterSheet(
          currentType: _tabType,
          initialCategory: _category,
          initialRecorder: _recorder,
          initialStartAt: _startAt,
          initialEndAt: _endAt,
          initialExceedWorry: _exceedWorry,
          members: _members,
          isFamily: _scope == 'family',
          onApply: (s) {
            setState(() {
              _category = s.category;
              _recorder = s.recorder;
              _startAt = s.startAt;
              _endAt = s.endAt;
              _exceedWorry = s.exceedWorry;
            });
            _load();
          },
        );
      },
    );
  }

  Future<void> _editTx(TxRecord tx) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddTxSheet(
          scope: _scope, type: tx.type, currentUid: _currentUid, existing: tx),
    );
    if (updated == true) _load();
  }

  Future<void> _deleteTx(TxRecord tx) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账单'),
        content: Text(
            '确认删除 ${TxCategory.labelOf(tx.category)} ${tx.amount.toStringAsFixed(2)} 元？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.deleteTxFallback(tx.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(
        content: Text(r.ok ? '已删除' : r.message),
        duration: const Duration(milliseconds: 1100),
      ));
    if (r.ok) _load();
  }
}

class _FilterResult {
  String? type;
  String? category;
  String? recorder;
  int? startAt;
  int? endAt;
  String? exceedWorry;
  _FilterResult(
      {this.type,
      this.category,
      this.recorder,
      this.startAt,
      this.endAt,
      this.exceedWorry});
}

class _FilterSheet extends StatefulWidget {
  final String currentType; // 当前 tab 类型（不可改）
  final String? initialCategory;
  final String? initialRecorder;
  final int? initialStartAt;
  final int? initialEndAt;
  final String? initialExceedWorry;
  final List<FamilyMember> members;
  final bool isFamily;
  final void Function(_FilterResult) onApply;

  const _FilterSheet({
    required this.currentType,
    required this.initialCategory,
    required this.initialRecorder,
    required this.initialStartAt,
    required this.initialEndAt,
    required this.initialExceedWorry,
    required this.members,
    required this.isFamily,
    required this.onApply,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  String? _category;
  String? _recorder;
  int? _startAt;
  int? _endAt;
  String? _exceedWorry;
  int _dateRange = 0;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _recorder = widget.initialRecorder;
    _startAt = widget.initialStartAt;
    _endAt = widget.initialEndAt;
    _exceedWorry = widget.initialExceedWorry;
    _dateRange = _inferDateRange(_startAt, _endAt);
  }

  int _inferDateRange(int? s, int? e) {
    if (s == null && e == null) return 0;
    final now = DateTime.now();
    final monthStart =
        DateTime(now.year, now.month, 1).millisecondsSinceEpoch ~/ 1000;
    final days30 =
        now.subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
    if (s == monthStart) return 1;
    if (s == days30) return 2;
    return 3;
  }

  void _pickCustomRange() async {
    final now = DateTime.now();
    final initStart = _startAt == null
        ? now
        : DateTime.fromMillisecondsSinceEpoch(_startAt! * 1000);
    final initEnd = _endAt == null
        ? now
        : DateTime.fromMillisecondsSinceEpoch(_endAt! * 1000);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: DateTimeRange(start: initStart, end: initEnd),
    );
    if (picked == null) return;
    setState(() {
      _dateRange = 3;
      _startAt =
          DateTime(picked.start.year, picked.start.month, picked.start.day)
                  .millisecondsSinceEpoch ~/
              1000;
      _endAt = DateTime(
                  picked.end.year, picked.end.month, picked.end.day, 23, 59, 59)
              .millisecondsSinceEpoch ~/
          1000;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.currentType == TxType.income
        ? TxCategory.incomeCategories
        : widget.currentType == TxType.expense
            ? TxCategory.expenseCategories
            : TxCategory.transferCategories;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 12),
            Text('高级筛选 · ${TxType.labels[widget.currentType] ?? ""}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text('分类', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ChoiceChip(
                  label: const Text('全部'),
                  selected: _category == null,
                  onSelected: (_) => setState(() => _category = null)),
              ...cats.map((c) => ChoiceChip(
                    label: Text(TxCategory.labelOf(c)),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                  )),
            ]),
            const SizedBox(height: 12),
            if (widget.isFamily) ...[
              Text('记账人', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: [
                ChoiceChip(
                    label: const Text('全部'),
                    selected: _recorder == null,
                    onSelected: (_) => setState(() => _recorder = null)),
                ...widget.members.map((m) => ChoiceChip(
                      label:
                          Text(m.nickname.isNotEmpty ? m.nickname : m.username),
                      selected: _recorder == m.userId.toString(),
                      onSelected: (_) =>
                          setState(() => _recorder = m.userId.toString()),
                    )),
              ]),
              const SizedBox(height: 12),
            ],
            Text('时间范围', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ChoiceChip(
                  label: const Text('全部时间'),
                  selected: _dateRange == 0,
                  onSelected: (_) => setState(() {
                        _dateRange = 0;
                        _startAt = null;
                        _endAt = null;
                      })),
              ChoiceChip(
                  label: const Text('本月'),
                  selected: _dateRange == 1,
                  onSelected: (_) => setState(() {
                        _dateRange = 1;
                        final now = DateTime.now();
                        _startAt = DateTime(now.year, now.month, 1)
                                .millisecondsSinceEpoch ~/
                            1000;
                        _endAt = null;
                      })),
              ChoiceChip(
                  label: const Text('近 30 天'),
                  selected: _dateRange == 2,
                  onSelected: (_) => setState(() {
                        _dateRange = 2;
                        final now = DateTime.now();
                        _startAt = now
                                .subtract(const Duration(days: 30))
                                .millisecondsSinceEpoch ~/
                            1000;
                        _endAt = null;
                      })),
              ChoiceChip(
                label: Text(_dateRange == 3 && _startAt != null
                    ? '${DateFormat('MM-dd').format(DateTime.fromMillisecondsSinceEpoch(_startAt! * 1000))} ~ ${_endAt == null ? '' : DateFormat('MM-dd').format(DateTime.fromMillisecondsSinceEpoch(_endAt! * 1000))}'
                    : '自定义'),
                selected: _dateRange == 3,
                onSelected: (_) {
                  setState(() => _dateRange = 3);
                  _pickCustomRange();
                },
              ),
            ]),
            if (_dateRange == 3 && _startAt != null) ...[
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: Colors.indigo.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.calendar_today,
                      size: 14, color: Colors.indigo),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(_startAt! * 1000))}'
                      ' 至 '
                      '${_endAt == null ? '今天' : DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(_endAt! * 1000))}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.indigo),
                    ),
                  ),
                  TextButton(
                      onPressed: _pickCustomRange, child: const Text('修改')),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            Text('无顾虑单笔', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              ChoiceChip(
                  label: const Text('全部'),
                  selected: _exceedWorry == null,
                  onSelected: (_) => setState(() => _exceedWorry = null)),
              ChoiceChip(
                  label: const Text('未超过'),
                  selected: _exceedWorry == '0',
                  onSelected: (_) => setState(() => _exceedWorry = '0')),
              ChoiceChip(
                  label: const Text('已超过'),
                  selected: _exceedWorry == '1',
                  onSelected: (_) => setState(() => _exceedWorry = '1')),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _category = null;
                      _recorder = null;
                      _startAt = null;
                      _endAt = null;
                      _exceedWorry = null;
                      _dateRange = 0;
                    });
                  },
                  child: const Text('重置'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    widget.onApply(_FilterResult(
                      type: widget.currentType,
                      category: _category,
                      recorder: _recorder,
                      startAt: _startAt,
                      endAt: _endAt,
                      exceedWorry: _exceedWorry,
                    ));
                    Navigator.pop(context);
                  },
                  child: const Text('应用'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _TxTile extends StatelessWidget {
  final TxRecord tx;
  final double worryPerBuy;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _TxTile(
      {required this.tx,
      required this.worryPerBuy,
      required this.onTap,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat('#,##0.00');
    final color = _BookkeepingPageState.colorOf(tx.type);
    final icon = _BookkeepingPageState.iconOf(tx.type);
    final typeLabel = TxType.labels[tx.type] ?? tx.type;
    final recorder = tx.nickname.isNotEmpty ? tx.nickname : tx.username;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(icon, color: color),
      ),
      title: Row(children: [
        Flexible(
          child: Text(TxCategory.labelOf(tx.category),
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
        ),
        if (tx.targetBucket.isNotEmpty) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(4)),
            child: Text('→${_bucketShort(tx.targetBucket)}',
                style: const TextStyle(fontSize: 10, color: Colors.brown)),
          ),
        ],
        if (tx.loanName.isNotEmpty) ...[
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('偿还：${tx.loanName}',
              style: const TextStyle(fontSize: 10, color: Color(0xFFFFB86B))),
        ),
      ],
      if (tx.type == TxType.expense && tx.sourceBucket.isNotEmpty) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(4)),
            child: Text(
                '←${TxCategory.sourceBucketLabels[tx.sourceBucket] ?? tx.sourceBucket}',
                style: const TextStyle(fontSize: 10, color: Colors.blueGrey)),
          ),
        ],
        if (tx.overWorry && tx.type == TxType.expense) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: '超过无顾虑单笔 (${f.format(worryPerBuy)} 元)',
            child: const Icon(Icons.warning_amber_rounded,
                size: 16, color: Colors.deepOrange),
          ),
        ],
      ]),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          const Icon(Icons.access_time, size: 12, color: AppTheme.textDim),
          const SizedBox(width: 3),
          Text(
              DateFormat('MM-dd HH:mm').format(
                  DateTime.fromMillisecondsSinceEpoch(tx.occurredAt * 1000)),
              style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(typeLabel,
                style: TextStyle(
                    fontSize: 11, color: color, fontWeight: FontWeight.w600)),
          ),
          if (recorder.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('·$recorder',
                style: const TextStyle(fontSize: 12, color: AppTheme.textDim)),
          ],
          if (tx.note.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
                child: Text('·${tx.note}',
                    style:
                        const TextStyle(fontSize: 12, color: AppTheme.textDim),
                    overflow: TextOverflow.ellipsis)),
          ],
        ]),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(
          '${tx.type == TxType.expense ? '-' : '+'}${f.format(tx.amount)}',
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
          tooltip: '删除',
          onPressed: onDelete,
        ),
      ]),
    );
  }

  String _bucketShort(String b) {
    switch (b) {
      case 'saving':
        return '储蓄';
      case 'investment':
        return '投资';
      case 'emergency':
        return '应急';
      case 'pension':
        return '养老';
    }
    return b;
  }
}

class _AddTxSheet extends StatefulWidget {
  final String scope;
  final String type; // income/expense/transfer
  final int? currentUid;
  final TxRecord? existing;
  const _AddTxSheet(
      {required this.scope,
      required this.type,
      this.currentUid,
      this.existing});
  @override
  State<_AddTxSheet> createState() => _AddTxSheetState();
}

class _AddTxSheetState extends State<_AddTxSheet> {
  late String _type;
  late String _category;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  bool _busy = false;
  /// 表单内联错误提示（余额不足、未选贷款等）
  String? _formError;
  String? _loanRef;
  _LoanOption? _loanOption;
  // 偿还贷款三字段：总金额 / 本金 / 利息（可修改，选贷款后按方式自动拆分）
  final _repayTotal = TextEditingController();
  final _repayPrincipal = TextEditingController();
  final _repayInterest = TextEditingController();
  String? _targetBucket; // 收入目标桶
  // 多来源支持：key=来源桶名, value=金额控制器
  final Map<String, TextEditingController> _sourceControllers = {};
  Set<String> _selectedSources = {'cash'}; // 当前选中的来源桶
  FutureFinanceData? _futureData;
  bool _loadingLoans = false;
  double _monthlyIncome = 0; // 本月收入（非意外收入），存钱快捷比例的基数
  ({double saving, double investment, double emergency, double pension}) _planRatios =
      (saving: 0, investment: 0, emergency: 0, pension: 0);
  Map<String, double> _bucketBalances = {}; // 各桶当前余额，来源选择器上显示

  @override
  void initState() {
    super.initState();
    _type = widget.type;
    // 存钱与支出都需要余额（快捷比例 + 来源标签显示）
    if (_type == TxType.transfer || _type == TxType.expense) {
      _loadMonthlyIncome();
    }
    if (widget.existing != null) {
      _category = widget.existing!.category;
      _amount = TextEditingController(text: widget.existing!.amount.toString());
      _note = TextEditingController(text: widget.existing!.note);
      _loanRef = widget.existing!.loanRef;
      _targetBucket = widget.existing!.targetBucket.isNotEmpty
          ? widget.existing!.targetBucket
          : null;
      // 解析多来源明细
      if (widget.existing!.sourceDetails.isNotEmpty) {
        _parseSourceDetails(widget.existing!.sourceDetails);
      } else if (widget.existing!.sourceBucket.isNotEmpty) {
        _selectedSources = {widget.existing!.sourceBucket};
        _sourceControllers[widget.existing!.sourceBucket] =
            TextEditingController(text: widget.existing!.amount.toString());
      }
    } else {
      _category = _defaultCategory(_type);
      _amount = TextEditingController();
      _note = TextEditingController();
      // 默认选中第一个允许的来源
      final allowed = TxCategory.allowedSourceBuckets[_category] ?? ['cash'];
      _selectedSources = {allowed.first};
    }
    if (_category == TxCategory.expenseLoanRepay && _loanRef == null) {
      _loadLoans();
    }
  }

  // 自动计算各来源金额之和
  double _computeSourceTotal() {
    var total = 0.0;
    for (final src in _selectedSources) {
      total += double.tryParse(_sourceControllers[src]?.text ?? '') ?? 0;
    }
    return total;
  }

  void _parseSourceDetails(String jsonStr) {
    if (jsonStr.isEmpty) return;
    try {
      final List<dynamic> details = jsonDecode(jsonStr) as List<dynamic>;
      for (final item in details) {
        final map = item as Map<String, dynamic>;
        final bucket = map['bucket'] as String? ?? '';
        final amount = map['amount'];
        if (bucket.isNotEmpty && amount != null) {
          _selectedSources.add(bucket);
          _sourceControllers[bucket] =
              TextEditingController(text: amount.toString());
        }
      }
    } catch (_) {}
  }

  String _defaultCategory(String type) {
    if (type == TxType.income) return TxCategory.incomeSalary;
    if (type == TxType.expense) return TxCategory.expenseDaily;
    if (type == TxType.transfer) return TxCategory.transferToSaving;
    return TxCategory.expenseDaily;
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _repayTotal.dispose();
    _repayPrincipal.dispose();
    _repayInterest.dispose();
    for (final c in _sourceControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTypeChanged(String t) {
    setState(() {
      _type = t;
      _category = _defaultCategory(t);
      _loanRef = null;
      _targetBucket = null;
    });
  }

  void _onCategoryChanged(String c) {
    setState(() {
      _category = c;
      _loanRef = null;
      // 支出类别变更时重置来源选择
      if (_type == TxType.expense) {
        for (final c in _sourceControllers.values) {
          c.dispose();
        }
        _sourceControllers.clear();
        final allowed = TxCategory.allowedSourceBuckets[c] ?? ['cash'];
        _selectedSources = {allowed.first};
      }
      // 息金需要 targetBucket
      if (c == TxCategory.incomeInvestment) {
        _targetBucket ??= 'saving';
      }
      // 存钱分类自动填 targetBucket
      if (TxCategory.transferCategories.contains(c)) {
        _targetBucket = TxCategory.bucketFromTransfer[c];
      } else {
        // 切换为非存钱分类时清空
        if (_type == TxType.transfer) {
          _category = _defaultCategory(_type);
        }
      }
      if (c == TxCategory.expenseLoanRepay) {
        _loadLoans();
      }
    });
  }

  /// 表单内联错误条。
  ///
  /// 不再用 SnackBar：底表（modal bottom sheet）是独立路由，SnackBar 渲染在
  /// 它下面的 Scaffold 里，会被整块表格挡住；往屏幕顶部推又会被状态栏截断。
  /// 直接画在保存按钮上方，位置永远可见。
  void _showTopSnack(String msg) {
    if (!mounted) return;
    setState(() => _formError = msg);
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted && _formError == msg) setState(() => _formError = null);
    });
  }

  Future<void> _loadMonthlyIncome() async {
    try {
      final r = await ApiClient.instance.overview(scope: widget.scope);
      if (!mounted) return;
      final data = r.data;
      if (data != null) {
        setState(() {
          _monthlyIncome = data.allocation.monthlyIncome;
          _bucketBalances = {
            'cash': data.remainingBudget,
            'saving': data.savingBalance,
            'investment': data.investmentBalance,
            'emergency': data.emergencyBalance,
            'pension': data.pensionBalance,
            'housing_fund': data.totalHousingFund,
          };
        });
      }
    } catch (_) {}
    try {
      final pr = await ApiClient.instance.getPlan(scope: widget.scope);
      if (!mounted) return;
      final plan = pr.data;
      if (plan != null) {
        setState(() {
          _planRatios = (
            saving: (plan['savingRatio'] as num? ?? 0).toDouble(),
            investment: (plan['investmentRatio'] as num? ?? 0).toDouble(),
            emergency: (plan['emergencyRatio'] as num? ?? 0).toDouble(),
            pension: (plan['pensionRatio'] as num? ?? 0).toDouble(),
          );
        });
      }
    } catch (_) {}
  }

  /// 存钱快捷比例：只用财务预规划中设置好的比例，取整到十位
  Widget _savingQuickPicks() {
    final f = NumberFormat('#,##0');
    final plan = _planRatios;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_monthlyIncome > 0)
          Text('本月收入 ${f.format(_monthlyIncome)} 元（按预规划比例计算）',
              style: const TextStyle(fontSize: 11, color: AppTheme.textDim)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (plan.saving > 0)
              _ratioChip('储蓄 ${(plan.saving * 100).round()}%', plan.saving),
            if (plan.investment > 0)
              _ratioChip('投资 ${(plan.investment * 100).round()}%', plan.investment),
            if (plan.emergency > 0)
              _ratioChip('应急 ${(plan.emergency * 100).round()}%', plan.emergency),
            if (plan.pension > 0)
              _ratioChip('养老 ${(plan.pension * 100).round()}%', plan.pension),
          ],
        ),
      ],
    );
  }

  Widget _ratioChip(String label, double ratio) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        // 按比例计算，取整到十位
        final v = (_monthlyIncome * ratio / 10).roundToDouble() * 10;
        _amount.text = v.toStringAsFixed(0);
      },
    );
  }

  Future<void> _loadLoans() async {
    if (_loadingLoans) return;
    setState(() => _loadingLoans = true);
    final r = await ApiClient.instance.futureFinance(scope: widget.scope);
    if (!mounted) return;
    setState(() {
      _loadingLoans = false;
      if (r.ok && r.data != null) {
        _futureData = r.data!;
        // 编辑已有还贷账单：匹配贷款并按方式自动拆分本金/利息
        if (_loanRef != null && _loanOption == null) {
          _loanOption = _buildLoanOptions().where((e) => e.ref == _loanRef).firstOrNull;
          _applyLoanSplit(initialTotal: widget.existing?.amount);
        }
      }
    });
  }

  /// 按贷款方式自动拆分本期还款的本金 / 利息。
  /// 输入本金（如年底冲本）后用户可手动修改任意一项。
  void _applyLoanSplit({double? initialTotal}) {
    final o = _loanOption;
    if (o == null) return;
    final r = o.annualRate / 100 / 12; // 月利率
    final remain = o.summary.remainingAmount; // 剩余本金
    final m = o.summary.monthlyPayment; // 本期月供
    double principal, interest;
    switch (o.method) {
      case 'equal_payment': // 等额本息：利息 = 剩余本金 × 月利率
        interest = remain * r;
        principal = (m > 0 ? m : remain) - interest;
      case 'equal_capital': // 等额本金：每期固定本金 + 剩余本金利息
        interest = remain * r;
        principal = o.termMonths > 0 ? o.totalPrincipal / o.termMonths : remain;
      case 'interest_free': // 先息后本/无息：只还本金
        interest = 0;
        principal = m > 0 ? m : remain;
      default:
        interest = 0;
        principal = m > 0 ? m : remain;
    }
    if (principal < 0) principal = 0;
    if (m <= 0) {
      principal = remain;
      interest = 0;
    }
    _repayPrincipal.text = principal.toStringAsFixed(2);
    _repayInterest.text = interest.toStringAsFixed(2);
    _repayTotal.text =
        (initialTotal ?? (principal + interest)).toStringAsFixed(2);
  }

  Future<void> _submit() async {
    // 多来源支出时，金额由各来源自动求和
    final isMultiSource =
        _type == TxType.expense && _selectedSources.length > 1;
    // 偿还贷款：金额 = 总金额（本金 + 利息）
    final v = _category == TxCategory.expenseLoanRepay
        ? double.tryParse(_repayTotal.text)
        : isMultiSource
            ? _computeSourceTotal()
            : double.tryParse(_amount.text);
    if (v == null || v <= 0) {
      _showTopSnack('请输入有效金额');
      return;
    }
    if (_category == TxCategory.expenseLoanRepay &&
        (_loanRef == null || _loanRef!.isEmpty)) {
      _showTopSnack('请选择要偿还的贷款');
      return;
    }
    if (_category == TxCategory.incomeInvestment &&
        (_targetBucket == null || _targetBucket!.isEmpty)) {
      _showTopSnack('投资收益请选择目标桶');
      return;
    }

    setState(() {
      _busy = true;
      _formError = null; // 每次提交先清掉上一次的报错
    });

    final body = <String, dynamic>{
      'scope': widget.scope,
      'type': _type,
      'category': _category,
      'amount': v,
      'note': _note.text,
    };
    if (_loanRef != null && _loanRef!.isNotEmpty) body['loanRef'] = _loanRef;
    if (_targetBucket != null && _targetBucket!.isNotEmpty)
      body['targetBucket'] = _targetBucket;
    // 支出时添加来源桶（支持多来源）
    if (_type == TxType.expense) {
      if (_selectedSources.length > 1) {
        // 多来源模式：各来源金额已在上面自动求和为 v
        final details = <Map<String, dynamic>>[];
        for (final src in _selectedSources) {
          final amt = double.tryParse(_sourceControllers[src]?.text ?? '') ?? 0;
          if (amt <= 0) {
            _showTopSnack(
                '${TxCategory.sourceBucketLabels[src] ?? src} 的金额必须大于 0');
            setState(() => _busy = false);
            return;
          }
          details.add({'bucket': src, 'amount': amt});
        }
        body['sourceDetails'] = details;
        // 多来源时不设置 sourceBucket，避免后端双重扣减
      } else {
        // 单来源模式
        body['sourceBucket'] = _selectedSources.first;
      }
    }
    dynamic r;
    if (widget.existing != null) {
      r = await ApiClient.instance.updateTx(widget.existing!.id, body);
    } else {
      r = await ApiClient.instance.createTx(body);
    }
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
    } else {
      _showTopSnack(r.message);
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final cats = _type == TxType.income
        ? TxCategory.incomeCategories
        : _type == TxType.expense
            ? TxCategory.expenseCategories
            : TxCategory.transferCategories;
    final color = _BookkeepingPageState.colorOf(_type);
    final label = TxType.labels[_type] ?? _type;

    // 键盘弹起 + 多来源时表单会超过可用高度，必须可滚动，
    // 否则底部会报 "BOTTOM OVERFLOWED BY N PIXELS"（黄黑警示条）
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Center(
              child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),
          Text(widget.existing == null ? '记一笔 · $label' : '编辑账单 · $label',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          // 类型切换（仅新增时）
          if (widget.existing == null)
            SegmentedButton<String>(
              segments: [
                for (final e in TxType.labels.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => _onTypeChanged(s.first),
            ),
          const SizedBox(height: 12),
          Text('${label}类型', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: cats
                .map((c) => ChoiceChip(
                      label: Text(TxCategory.labelOf(c)),
                      selected: _category == c,
                      onSelected: (_) => _onCategoryChanged(c),
                    ))
                .toList(),
          ),
          // 支出来源桶选择（按类别过滤 + 多来源支持）
          if (_type == TxType.expense) ...[
            const SizedBox(height: 12),
            Text('支出来源', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Builder(
              builder: (ctx) {
                final allowed =
                    TxCategory.allowedSourceBuckets[_category] ?? ['cash'];
                // 每行两个来源；卡片内分两行显示"名称 / 余额"，
                // 用标签把名字和余额塞成一行会被省略号截掉数字
                final bal = _bucketBalances;
                final items = allowed.map((src) {
                  final selected = _selectedSources.contains(src);
                  final label = TxCategory.sourceBucketLabels[src] ?? src;
                  final b = bal[src];
                  final balText = b == null
                      ? '—'
                      : '${NumberFormat('#,##0.00').format(b)} 元';
                  return SizedBox(
                    width: (MediaQuery.of(ctx).size.width - 64) / 2,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() {
                          if (_selectedSources.contains(src)) {
                            // 至少保留一个来源，否则无法确定从哪里扣钱
                            if (_selectedSources.length > 1) {
                              _selectedSources.remove(src);
                              _sourceControllers[src]?.dispose();
                              _sourceControllers.remove(src);
                            }
                          } else {
                            _selectedSources.add(src);
                            _sourceControllers[src] ??= TextEditingController();
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppTheme.gold.withValues(alpha: 0.16)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? AppTheme.gold
                                : Colors.white.withValues(alpha: 0.14),
                            width: selected ? 1.2 : 1,
                          ),
                        ),
                        child: Row(children: [
                          if (selected) ...[
                            const Icon(Icons.check,
                                size: 13, color: AppTheme.gold),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 1),
                                Text('余额 $balText',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: selected
                                          ? AppTheme.gold
                                          : AppTheme.textDim,
                                    )),
                              ],
                            ),
                          ),
                        ]),
                      ),
                    ),
                  );
                }).toList();
                return Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: items,
                );
              },
            ),
            // 多来源时显示各来源金额输入框 + 自动求和
            if (_selectedSources.length > 1) ...[
              const SizedBox(height: 8),
              ..._selectedSources.map((src) {
                _sourceControllers[src] ??= TextEditingController();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _sourceControllers[src],
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                    ],
                    decoration: InputDecoration(
                      labelText:
                          '${TxCategory.sourceBucketLabels[src] ?? src} 金额',
                      prefixText: '¥ ',
                      prefixStyle: const TextStyle(
                          color: Colors.redAccent, fontWeight: FontWeight.w700),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                );
              }),
              // 自动求和显示
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.green.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('合计',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, color: Colors.green)),
                    Text(
                      '¥ ${_computeSourceTotal().toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF7EE0A6),
                          fontSize: 16),
                    ),
                  ],
                ),
              ),
            ],
          ],
          // 偿还贷款：选择贷款
          if (_category == TxCategory.expenseLoanRepay) ...[
            const SizedBox(height: 12),
            Text('选择要偿还的贷款', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            if (_loadingLoans)
              const Padding(
                  padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else if (_futureData == null)
              const Text('暂无贷款数据')
            else
              _buildLoanPicker(),
          ],
          // 息金：选择目标桶
          if (_category == TxCategory.incomeInvestment) ...[
            const SizedBox(height: 12),
            Text('息金目标桶', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              ChoiceChip(
                  label: const Text('储蓄桶'),
                  selected: _targetBucket == 'saving',
                  onSelected: (_) => setState(() => _targetBucket = 'saving')),
              ChoiceChip(
                  label: const Text('投资桶'),
                  selected: _targetBucket == 'investment',
                  onSelected: (_) =>
                      setState(() => _targetBucket = 'investment')),
              ChoiceChip(
                  label: const Text('应急桶'),
                  selected: _targetBucket == 'emergency',
                  onSelected: (_) =>
                      setState(() => _targetBucket = 'emergency')),
              ChoiceChip(
                  label: const Text('养老桶'),
                  selected: _targetBucket == 'pension',
                  onSelected: (_) => setState(() => _targetBucket = 'pension')),
            ]),
          ],
          // 存钱：显示提示
          if (_type == TxType.transfer) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.indigo.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(children: [
                Icon(Icons.info_outline, size: 14, color: Colors.indigo),
                SizedBox(width: 6),
                Expanded(
                  child: Text('存钱模块的转账不影响家庭总财富',
                      style: TextStyle(fontSize: 11, color: Colors.indigo)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          // 偿还贷款：三字段（总金额/本金/利息），按贷款方式自动拆分后可修改
          if (_category == TxCategory.expenseLoanRepay) ...[
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _repayTotal,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                  ],
                  onChanged: (_) {
                    // 改总金额：保持利息不变，本金 = 总金额 − 利息
                    final t = double.tryParse(_repayTotal.text) ?? 0;
                    final i = double.tryParse(_repayInterest.text) ?? 0;
                    final p = (t - i) > 0 ? t - i : 0;
                    _repayPrincipal.text = p.toStringAsFixed(2);
                  },
                  decoration: const InputDecoration(
                    labelText: '总金额',
                    prefixText: '¥ ',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _repayPrincipal,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                  ],
                  onChanged: (_) {
                    // 改本金：总金额 = 本金 + 利息
                    final p = double.tryParse(_repayPrincipal.text) ?? 0;
                    final i = double.tryParse(_repayInterest.text) ?? 0;
                    _repayTotal.text = (p + i).toStringAsFixed(2);
                  },
                  decoration: const InputDecoration(
                    labelText: '本金',
                    prefixText: '¥ ',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _repayInterest,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                  ],
                  onChanged: (_) {
                    // 改利息：总金额 = 本金 + 利息
                    final p = double.tryParse(_repayPrincipal.text) ?? 0;
                    final i = double.tryParse(_repayInterest.text) ?? 0;
                    _repayTotal.text = (p + i).toStringAsFixed(2);
                  },
                  decoration: const InputDecoration(
                    labelText: '利息',
                    prefixText: '¥ ',
                  ),
                ),
              ),
            ],
            ),
          ]
          // 多来源支出时金额由各来源自动求和，不显示手动输入
          else if (!(_type == TxType.expense && _selectedSources.length > 1) &&
              _category != TxCategory.expenseLoanRepay)
            TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
              ],
              decoration: InputDecoration(
                labelText: '金额',
                prefixText: '¥ ',
                prefixStyle:
                    TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            ),
          // 存钱快捷比例：按月收入（非意外收入）自动计算并取整到十位
          if (_type == TxType.transfer) ...[
            const SizedBox(height: 8),
            _savingQuickPicks(),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: '备注（可选）'),
          ),
          // 内联错误条：放在保存上方，键盘弹起时也一定可见
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFB3261E).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: const Color(0xFFB3261E).withValues(alpha: 0.55)),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline,
                    size: 16, color: Color(0xFFFF8A80)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_formError!,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFFFFB4AB))),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(backgroundColor: color),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('保存', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(height: 16),
        ],
        ),
      ),
    );
  }

  Widget _buildLoanPicker() {
    final items = _buildLoanOptions();
    if (items.isEmpty) return const Text('暂无可偿还贷款，请先在【未来财务】中添加');
    return SizedBox(
      height: 180,
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i];
          return RadioListTile<String>(
            value: it.ref,
            groupValue: _loanRef,
            title: Text(it.label),
            subtitle: Text(it.sub),
            dense: true,
            onChanged: (v) => setState(() {
              _loanRef = v;
              _loanOption = items.where((e) => e.ref == v).firstOrNull;
              // 选定贷款后按还款方式自动拆分本期本金/利息（均可手动修改）
              _applyLoanSplit();
            }),
          );
        },
      ),
    );
  }

  List<_LoanOption> _buildLoanOptions() {
    final data = _futureData;
    if (data == null) return [];
    return <_LoanOption>[
      ...data.housingFundLoans.map((l) => _LoanOption(
            ref: 'hf:${l.id}',
            label: '公积金：${l.name}',
            sub:
                '总额 ¥${l.total.toStringAsFixed(0)} / 剩余 ¥${l.summary.remainingAmount.toStringAsFixed(0)}',
            annualRate: l.annualRate,
            method: l.method,
            termMonths: l.termMonths,
            totalPrincipal: l.total,
            summary: l.summary,
          )),
      ...data.commercialLoans.map((l) => _LoanOption(
            ref: 'cl:${l.id}',
            label: '商业：${l.name}',
            sub:
                '总额 ¥${l.total.toStringAsFixed(0)} / 剩余 ¥${l.summary.remainingAmount.toStringAsFixed(0)}',
            annualRate: l.annualRate,
            method: l.method,
            termMonths: l.termMonths,
            totalPrincipal: l.total,
            summary: l.summary,
          )),
      ...data.borrowedMoneys.map((l) => _LoanOption(
            ref: 'bm:${l.id}',
            label: '借款：${l.name}',
            sub:
                '本金 ¥${l.total.toStringAsFixed(0)} / 剩余 ¥${l.summary.remainingAmount.toStringAsFixed(0)}',
            annualRate: l.annualRate,
            method: l.method,
            termMonths: l.termMonths,
            totalPrincipal: l.total,
            summary: l.summary,
          )),
    ];
  }
}

class _LoanOption {
  final String ref;
  final String label;
  final String sub;
  final double annualRate;
  final String method;
  final int termMonths;
  final double totalPrincipal;
  final LoanSummary summary;
  _LoanOption({
    required this.ref,
    required this.label,
    required this.sub,
    this.annualRate = 0,
    this.method = 'equal_payment',
    this.termMonths = 0,
    this.totalPrincipal = 0,
    required this.summary,
  });
}
