/// 后端统一响应
class ApiResponse<T> {
  final int code;
  final String message;
  final T? data;

  ApiResponse({required this.code, required this.message, this.data});

  bool get ok => code == 0;

  factory ApiResponse.fromJson(Map<String, dynamic> json, T Function(dynamic) parse) {
    return ApiResponse(
      code: (json['code'] ?? -1) as int,
      message: (json['message'] ?? '') as String,
      data: json['data'] == null ? null : parse(json['data']),
    );
  }
}

/// 兼容 num 和 String 的数值解析（Go 的 time.Time/uint64 可能序列化为字符串）
num _parseNum(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v;
  if (v is String) {
    // 先尝试纯数字
    final n = num.tryParse(v);
    if (n != null) return n;
    // 再尝试 ISO 8601 日期（Go time.Time 默认序列化格式）
    final dt = DateTime.tryParse(v);
    if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
  }
  return 0;
}

class LoginResult {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final int uid;
  final String role;
  final String nickname;
  final String avatar;
  final int? familyId;

  LoginResult({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.uid,
    required this.role,
    required this.nickname,
    required this.avatar,
    this.familyId,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) => LoginResult(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresIn: json['expiresIn'] as int,
        uid: (json['uid'] as num).toInt(),
        role: json['role'] as String,
        nickname: json['nickname'] as String? ?? '',
        avatar: json['avatar'] as String? ?? '',
        familyId: json['familyId'] == null ? null : (json['familyId'] as num).toInt(),
      );
}

class UserProfile {
  final int id;
  final String username;
  final String nickname;
  final String avatar;
  final String email;
  final String phone;
  final String role;
  final bool mfaEnabled;
  final bool disabled;

  UserProfile({
    required this.id,
    required this.username,
    required this.nickname,
    required this.avatar,
    required this.email,
    required this.phone,
    required this.role,
    required this.mfaEnabled,
    this.disabled = false,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: (json['id'] as num).toInt(),
        username: json['username'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        avatar: json['avatar'] as String? ?? '',
        email: json['email'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        role: json['role'] as String? ?? 'user',
        mfaEnabled: json['mfaEnabled'] as bool? ?? false,
        disabled: json['disabled'] as bool? ?? false,
      );
}

class FamilyInfo {
  final int? id;
  final String? name;
  final String? code;
  final int? adminId;
  final bool? bound;
  final String? description;

  FamilyInfo({this.id, this.name, this.code, this.adminId, this.bound, this.description});

  factory FamilyInfo.fromJson(Map<String, dynamic> json) => FamilyInfo(
        id: json['id'] == null ? null : (json['id'] as num).toInt(),
        name: json['name'] as String?,
        code: json['code'] as String?,
        adminId: json['adminId'] == null ? null : (json['adminId'] as num).toInt(),
        bound: json['bound'] as bool?,
        description: json['description'] as String?,
      );
}

class FamilyMember {
  final int id;
  final int familyId;
  final int userId;
  final bool isAdmin;
  final String status;
  final String username;
  final String nickname;
  final String avatar;

  FamilyMember({
    required this.id,
    required this.familyId,
    required this.userId,
    required this.isAdmin,
    required this.status,
    required this.username,
    required this.nickname,
    required this.avatar,
  });

  factory FamilyMember.fromJson(Map<String, dynamic> json) => FamilyMember(
        id: (json['id'] as num).toInt(),
        familyId: (json['familyId'] as num).toInt(),
        userId: (json['userId'] as num).toInt(),
        isAdmin: json['isAdmin'] as bool? ?? false,
        status: json['status'] as String? ?? 'active',
        username: json['username'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        avatar: json['avatar'] as String? ?? '',
      );
}

/// 总览数据
class OverviewData {
  // 三大资产
  final double totalCash;
  final double totalHousingFund;
  final double totalWealthProduct;

  // 5 大桶余额
  final double savingBalance;
  final double investmentBalance;
  final double emergencyBalance;
  final double pensionBalance;
  final double dailySpent;

  // 目标
  final double emergencyTarget;
  final double pensionTarget;

  // 完成度与预估月数
  final double emergencyPct;
  final int emergencyMonthsLeft;
  final double pensionPct;
  final int pensionMonthsLeft;

  // 关键指标
  final double worryFreePerBuy;
  final double annualIncome; // 年薪
  final double monthlyConsumable;
  final double monthConsumableLeft; // 本月剩余可消费
  final double savingCarryOver;
  final double remainingBudget;

  // 未来财富（不含债务，仅未来利益折现）— 用于 2x2 卡片阵列
  final double futureWealth;

  // 家庭总财富
  final double totalWealth;
  // 累计（用于家庭总财富）
  final double cumulativeIncome;
  final double cumulativeDaily;
  // 总还进度
  final double totalPending;
  final double totalProgressPct;
  final int totalRemainingMonths;
  final int estimatedPayoffAt;

  final Allocation allocation;
  final List<PurchaseProjection> topPurchases;

  OverviewData({
    required this.totalCash,
    required this.totalHousingFund,
    required this.totalWealthProduct,
    required this.savingBalance,
    required this.investmentBalance,
    required this.emergencyBalance,
    required this.pensionBalance,
    required this.dailySpent,
    required this.emergencyTarget,
    required this.pensionTarget,
    required this.emergencyPct,
    required this.emergencyMonthsLeft,
    required this.pensionPct,
    required this.pensionMonthsLeft,
    required this.worryFreePerBuy,
    this.annualIncome = 0,
    required this.monthlyConsumable,
    required this.savingCarryOver,
    required this.remainingBudget,
    required this.allocation,
    required this.topPurchases,
    this.monthConsumableLeft = 0,
    this.futureWealth = 0,
    this.totalWealth = 0,
    this.cumulativeIncome = 0,
    this.cumulativeDaily = 0,
    this.totalPending = 0,
    this.totalProgressPct = 0,
    this.totalRemainingMonths = 0,
    this.estimatedPayoffAt = 0,
  });

  factory OverviewData.fromJson(Map<String, dynamic> json) => OverviewData(
        totalCash: (json['totalCash'] as num? ?? 0).toDouble(),
        totalHousingFund: (json['totalHousingFund'] as num? ?? 0).toDouble(),
        totalWealthProduct: (json['totalWealthProduct'] as num? ?? 0).toDouble(),
        savingBalance: (json['savingBalance'] as num? ?? 0).toDouble(),
        investmentBalance: (json['investmentBalance'] as num? ?? 0).toDouble(),
        emergencyBalance: (json['emergencyBalance'] as num? ?? 0).toDouble(),
        pensionBalance: (json['pensionBalance'] as num? ?? 0).toDouble(),
        dailySpent: (json['dailySpent'] as num? ?? 0).toDouble(),
        emergencyTarget: (json['emergencyTarget'] as num? ?? 0).toDouble(),
        pensionTarget: (json['pensionTarget'] as num? ?? 0).toDouble(),
        emergencyPct: (json['emergencyPct'] as num? ?? 0).toDouble(),
        emergencyMonthsLeft: (json['emergencyMonthsLeft'] as num? ?? 0).toInt(),
        pensionPct: (json['pensionPct'] as num? ?? 0).toDouble(),
        pensionMonthsLeft: (json['pensionMonthsLeft'] as num? ?? 0).toInt(),
        worryFreePerBuy: (json['worryFreePerBuy'] as num? ?? 0).toDouble(),
        annualIncome: (json['annualIncome'] as num? ?? 0).toDouble(),
        monthlyConsumable: (json['monthlyConsumable'] as num? ?? 0).toDouble(),
        monthConsumableLeft: (json['monthConsumableLeft'] as num? ?? 0).toDouble(),
        savingCarryOver: (json['savingCarryOver'] as num? ?? 0).toDouble(),
        remainingBudget: (json['remainingBudget'] as num? ?? 0).toDouble(),
        futureWealth: (json['futureWealth'] as num? ?? 0).toDouble(),
        allocation: Allocation.fromJson(json['allocation'] as Map<String, dynamic>? ?? {}),
        topPurchases: ((json['topPurchases'] as List?) ?? [])
            .map((e) => PurchaseProjection.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalWealth: (json['totalWealth'] as num? ?? 0).toDouble(),
        cumulativeIncome: (json['cumulativeIncome'] as num? ?? 0).toDouble(),
        cumulativeDaily: (json['cumulativeDaily'] as num? ?? 0).toDouble(),
        totalPending: (json['totalPending'] as num? ?? 0).toDouble(),
        totalProgressPct: (json['totalProgressPct'] as num? ?? 0).toDouble(),
        totalRemainingMonths: (json['totalRemainingMonths'] as num? ?? 0).toInt(),
        estimatedPayoffAt: (json['estimatedPayoffAt'] as num? ?? 0).toInt(),
      );
}

class Allocation {
  final double monthlyIncome;
  final double saving;
  final double investment;
  final double emergency;
  final double pension;
  final double consumption;
  final double overspend;
  final double investmentGap;
  final double investmentExcess;

  // 本月已入桶金额（按 category 累计）
  final double savingThisMonth;
  final double investmentThisMonth;
  final double emergencyThisMonth;
  final double pensionThisMonth;
  final double consumptionThisMonth;
  // 本月应入桶金额（按 plan.pct 计算）
  final double savingTarget;
  final double investmentTarget;
  final double emergencyTarget;
  final double pensionTarget;
  final double consumptionTarget;

  Allocation({
    required this.monthlyIncome,
    required this.saving,
    required this.investment,
    required this.emergency,
    required this.pension,
    required this.consumption,
    required this.overspend,
    required this.investmentGap,
    required this.investmentExcess,
    required this.savingThisMonth,
    required this.investmentThisMonth,
    required this.emergencyThisMonth,
    required this.pensionThisMonth,
    required this.consumptionThisMonth,
    required this.savingTarget,
    required this.investmentTarget,
    required this.emergencyTarget,
    required this.pensionTarget,
    required this.consumptionTarget,
  });

  factory Allocation.fromJson(Map<String, dynamic> json) => Allocation(
        monthlyIncome: (json['monthlyIncome'] as num? ?? 0).toDouble(),
        saving: (json['saving'] as num? ?? 0).toDouble(),
        investment: (json['investment'] as num? ?? 0).toDouble(),
        emergency: (json['emergency'] as num? ?? 0).toDouble(),
        pension: (json['pension'] as num? ?? 0).toDouble(),
        consumption: (json['consumption'] as num? ?? 0).toDouble(),
        overspend: (json['overspend'] as num? ?? 0).toDouble(),
        investmentGap: (json['investmentGap'] as num? ?? 0).toDouble(),
        investmentExcess: (json['investmentExcess'] as num? ?? 0).toDouble(),
        savingThisMonth: (json['savingThisMonth'] as num? ?? 0).toDouble(),
        investmentThisMonth: (json['investmentThisMonth'] as num? ?? 0).toDouble(),
        emergencyThisMonth: (json['emergencyThisMonth'] as num? ?? 0).toDouble(),
        pensionThisMonth: (json['pensionThisMonth'] as num? ?? 0).toDouble(),
        consumptionThisMonth: (json['consumptionThisMonth'] as num? ?? 0).toDouble(),
        savingTarget: (json['savingTarget'] as num? ?? 0).toDouble(),
        investmentTarget: (json['investmentTarget'] as num? ?? 0).toDouble(),
        emergencyTarget: (json['emergencyTarget'] as num? ?? 0).toDouble(),
        pensionTarget: (json['pensionTarget'] as num? ?? 0).toDouble(),
        consumptionTarget: (json['consumptionTarget'] as num? ?? 0).toDouble(),
      );
}

class PurchaseProjection {
  final int id;
  final String name;
  final double price;
  final int priority;
  final int estimatedMonths;
  final bool achievable;

  PurchaseProjection({
    required this.id,
    required this.name,
    required this.price,
    required this.priority,
    required this.estimatedMonths,
    required this.achievable,
  });

  factory PurchaseProjection.fromJson(Map<String, dynamic> json) => PurchaseProjection(
        id: (json['id'] as num).toInt(),
        name: json['name'] as String? ?? '',
        price: (json['price'] as num? ?? 0).toDouble(),
        priority: (json['priority'] as num? ?? 0).toInt(),
        estimatedMonths: (json['estimatedMonths'] as num? ?? 0).toInt(),
        achievable: json['achievable'] as bool? ?? false,
      );
}

/// 图表数据
class ChartData {
  final List<WealthPoint> wealth;
  final List<CategorySlice> categoryPie;

  ChartData({required this.wealth, required this.categoryPie});

  factory ChartData.fromJson(Map<String, dynamic> json) => ChartData(
        wealth: ((json['wealth'] as List?) ?? [])
            .map((e) => WealthPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        categoryPie: ((json['categoryPie'] as List?) ?? [])
            .map((e) => CategorySlice.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class WealthPoint {
  final String month;
  final double totalWealth;
  final double saving;
  final double investment;
  final double emergency;
  final double pension;
  final double wealthProduct;
  final double pending;

  WealthPoint({
    required this.month,
    required this.totalWealth,
    required this.saving,
    required this.investment,
    required this.emergency,
    required this.pension,
    required this.wealthProduct,
    required this.pending,
  });

  factory WealthPoint.fromJson(Map<String, dynamic> json) => WealthPoint(
        month: json['month'] as String? ?? '',
        totalWealth: (json['totalWealth'] as num? ?? 0).toDouble(),
        saving: (json['saving'] as num? ?? 0).toDouble(),
        investment: (json['investment'] as num? ?? 0).toDouble(),
        emergency: (json['emergency'] as num? ?? 0).toDouble(),
        pension: (json['pension'] as num? ?? 0).toDouble(),
        wealthProduct: (json['wealthProduct'] as num? ?? 0).toDouble(),
        pending: (json['pending'] as num? ?? 0).toDouble(),
      );
}

class CategorySlice {
  final String category;
  final String label;
  final double amount;

  CategorySlice({required this.category, required this.label, required this.amount});

  factory CategorySlice.fromJson(Map<String, dynamic> json) => CategorySlice(
        category: json['category'] as String? ?? '',
        label: json['label'] as String? ?? '',
        amount: (json['amount'] as num? ?? 0).toDouble(),
      );
}

class TxRecord {
  final int id;
  final int uid;
  final int? familyId;
  final String scope;
  final String type; // income/expense/transfer
  final String category;
  final double amount;
  final String note;
  final int occurredAt;
  final String username;
  final String nickname;
  final bool overWorry;
  final String loanRef;            // 偿还贷款关联
  final String targetBucket;       // 收入目标桶
  final String sourceBucket;       // 支出来源桶（单来源兼容）
  final String sourceDetails;      // 多来源 JSON

  TxRecord({
    required this.id,
    required this.uid,
    this.familyId,
    required this.scope,
    required this.type,
    required this.category,
    required this.amount,
    required this.note,
    required this.occurredAt,
    this.username = '',
    this.nickname = '',
    this.overWorry = false,
    this.loanRef = '',
    this.targetBucket = '',
    this.sourceBucket = '',
    this.sourceDetails = '',
  });

  factory TxRecord.fromJson(Map<String, dynamic> json) => TxRecord(
        id: (json['id'] as num).toInt(),
        uid: (json['uid'] as num).toInt(),
        familyId: (json['familyId'] as num?)?.toInt(),
        scope: json['scope'] as String? ?? 'personal',
        type: json['type'] as String? ?? 'expense',
        category: json['category'] as String? ?? '',
        amount: (json['amount'] as num? ?? 0).toDouble(),
        note: json['note'] as String? ?? '',
        occurredAt: (json['occurredAt'] as num).toInt(),
        username: json['username'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        overWorry: json['overWorry'] as bool? ?? false,
        loanRef: json['loanRef'] as String? ?? '',
        targetBucket: json['targetBucket'] as String? ?? '',
        sourceBucket: json['sourceBucket'] as String? ?? '',
        sourceDetails: json['sourceDetails'] as String? ?? '',
      );
}

class PurchaseItem {
  final int id;
  final String scope;
  final String name;
  final double price;
  final int priority;
  final int targetDate;
  final String note;
  final bool achieved;

  PurchaseItem({
    required this.id,
    required this.scope,
    required this.name,
    required this.price,
    required this.priority,
    required this.targetDate,
    required this.note,
    required this.achieved,
  });

  factory PurchaseItem.fromJson(Map<String, dynamic> json) => PurchaseItem(
        id: (json['id'] as num).toInt(),
        scope: json['scope'] as String? ?? 'personal',
        name: json['name'] as String? ?? '',
        price: (json['price'] as num? ?? 0).toDouble(),
        priority: (json['priority'] as num? ?? 0).toInt(),
        targetDate: (json['targetDate'] as num? ?? 0).toInt(),
        note: json['note'] as String? ?? '',
        achieved: json['achieved'] as bool? ?? false,
      );
}

class InvestmentRecord {
  final int id;
  final String scope;
  final int year;
  final int month;
  final double monthlyRate;
  final double amount; // 实际收益额，可正可负
  final String note;

  InvestmentRecord({
    required this.id,
    required this.scope,
    required this.year,
    required this.month,
    required this.monthlyRate,
    required this.amount,
    required this.note,
  });

  factory InvestmentRecord.fromJson(Map<String, dynamic> json) => InvestmentRecord(
        id: (json['id'] as num).toInt(),
        scope: json['scope'] as String? ?? 'personal',
        year: (json['year'] as num? ?? 0).toInt(),
        month: (json['month'] as num? ?? 0).toInt(),
        monthlyRate: (json['monthlyRate'] as num? ?? 0).toDouble(),
        amount: (json['amount'] as num? ?? 0).toDouble(),
        note: json['note'] as String? ?? '',
      );
}

/// 交易分类（与后端 CategoryLabel 对应）
class TxCategory {
  // ===== 收入子类 =====
  static const String incomeSalary = 'salary';
  static const String incomeHousingFund = 'housing_fund';
  static const String incomeWindfall = 'windfall';
  static const String incomeInvestment = 'investment_return'; // 投资收益+息金（合并）
  static const String incomePastHousing = 'past_housing';
  static const String incomePastSaving = 'past_saving';

  // ===== 支出子类（钱花到哪里去）=====
  static const String expenseDaily = 'daily';
  static const String expenseBigPurchase = 'big_purchase';
  static const String expensePension = 'pension';
  static const String expenseEmergency = 'emergency';
  static const String expenseLoanRepay = 'loan_repay';

  // ===== 存钱（转账）子类 =====
  static const String transferToSaving = 'transfer_saving';
  static const String transferToInvestment = 'transfer_investment';
  static const String transferToEmergency = 'transfer_emergency';
  static const String transferToPension = 'transfer_pension';

  static const Map<String, String> labels = {
    incomeSalary: '工资',
    incomeHousingFund: '公积金',
    incomeWindfall: '意外收入',
    incomeInvestment: '投资收益',
    incomePastHousing: '过往公积金',
    incomePastSaving: '过往存款',
    expenseDaily: '日常消费',
    expenseBigPurchase: '大件购物',
    expensePension: '养老',
    expenseEmergency: '应急',
    expenseLoanRepay: '偿还贷款',
    transferToSaving: '存入储蓄桶',
    transferToInvestment: '存入投资桶',
    transferToEmergency: '存入应急桶',
    transferToPension: '存入养老桶',
  };

  static const List<String> incomeCategories = [
    incomeSalary,
    incomeHousingFund,
    incomeWindfall,
    incomeInvestment,
    incomePastHousing,
    incomePastSaving,
  ];
  static const List<String> expenseCategories = [
    expenseDaily,
    expenseBigPurchase,
    expensePension,
    expenseEmergency,
    expenseLoanRepay,
  ];
  static const List<String> transferCategories = [
    transferToSaving,
    transferToInvestment,
    transferToEmergency,
    transferToPension,
  ];

  static String labelOf(String c) => labels[c] ?? c;

  static const Map<String, String> bucketFromTransfer = {
    transferToSaving: 'saving',
    transferToInvestment: 'investment',
    transferToEmergency: 'emergency',
    transferToPension: 'pension',
  };

  // 各支出类别允许的来源桶
  static const Map<String, List<String>> allowedSourceBuckets = {
    expenseDaily: ['cash'],                                // 日常消费：仅现金
    expenseBigPurchase: ['cash', 'saving'],                // 大件购物：现金、储蓄桶
    expensePension: ['pension'],                           // 养老：仅养老桶
    expenseEmergency: ['emergency'],                       // 应急：仅应急桶
    expenseLoanRepay: ['cash', 'saving', 'housing_fund'],  // 偿还贷款：现金、储蓄桶、公积金
  };

  // 来源桶显示名
  static const Map<String, String> sourceBucketLabels = {
    'cash': '现金',
    'saving': '储蓄桶',
    'housing_fund': '公积金',
    'emergency': '应急桶',
    'pension': '养老桶',
  };

  // 不计入年薪的收入分类
  static const List<String> nonSalaryCategories = [
    incomeHousingFund,
    incomePastHousing,
    incomePastSaving,
    incomeWindfall,
  ];
}

class TxType {
  static const String income = 'income';
  static const String expense = 'expense';
  static const String transfer = 'transfer';
  static const Map<String, String> labels = {
    income: '收入',
    expense: '支出',
    transfer: '存钱',
  };
}

// ===== 未来财务相关模型 =====

class LoanSummary {
  final double monthlyPayment;
  final double totalPayment;
  final double paidAmount;
  final double remainingAmount;
  final double progressPct;
  final int remainingMonths;
  LoanSummary({
    required this.monthlyPayment,
    required this.totalPayment,
    required this.paidAmount,
    required this.remainingAmount,
    required this.progressPct,
    required this.remainingMonths,
  });
  factory LoanSummary.fromJson(Map<String, dynamic> json) => LoanSummary(
        monthlyPayment: (json['monthlyPayment'] as num? ?? 0).toDouble(),
        totalPayment: (json['totalPayment'] as num? ?? 0).toDouble(),
        paidAmount: (json['paidAmount'] as num? ?? 0).toDouble(),
        remainingAmount: (json['remainingAmount'] as num? ?? 0).toDouble(),
        progressPct: (json['progressPct'] as num? ?? 0).toDouble(),
        remainingMonths: (json['remainingMonths'] as num? ?? 0).toInt(),
      );
}

class HousingFundLoan {
  final int id;
  final String scope;
  final String name;
  final double total;
  final double annualRate;
  final int termMonths;
  final String method;
  final int startMonth;
  final int paidMonths;
  final String note;
  final LoanSummary summary;
  HousingFundLoan({
    required this.id,
    required this.scope,
    required this.name,
    required this.total,
    required this.annualRate,
    required this.termMonths,
    required this.method,
    required this.startMonth,
    required this.paidMonths,
    required this.note,
    required this.summary,
  });
  factory HousingFundLoan.fromJson(Map<String, dynamic> json) => HousingFundLoan(
        id: (json['id'] as num).toInt(),
        scope: json['scope'] as String? ?? 'personal',
        name: json['name'] as String? ?? '',
        total: (json['total'] as num? ?? 0).toDouble(),
        annualRate: (json['annualRate'] as num? ?? 0).toDouble(),
        termMonths: (json['termMonths'] as num? ?? 0).toInt(),
        method: json['method'] as String? ?? 'equal_payment',
        startMonth: (json['startMonth'] as num? ?? 0).toInt(),
        paidMonths: (json['paidMonths'] as num? ?? 0).toInt(),
        note: json['note'] as String? ?? '',
        summary: LoanSummary.fromJson(json['summary'] as Map<String, dynamic>? ?? {}),
      );
}

class CommercialLoan {
  final int id;
  final String scope;
  final String name;
  final double total;
  final double annualRate;
  final int termMonths;
  final String method;
  final int startMonth;
  final int paidMonths;
  final String note;
  final LoanSummary summary;
  CommercialLoan({
    required this.id,
    required this.scope,
    required this.name,
    required this.total,
    required this.annualRate,
    required this.termMonths,
    required this.method,
    required this.startMonth,
    required this.paidMonths,
    required this.note,
    required this.summary,
  });
  factory CommercialLoan.fromJson(Map<String, dynamic> json) => CommercialLoan(
        id: (json['id'] as num).toInt(),
        scope: json['scope'] as String? ?? 'personal',
        name: json['name'] as String? ?? '',
        total: (json['total'] as num? ?? 0).toDouble(),
        annualRate: (json['annualRate'] as num? ?? 0).toDouble(),
        termMonths: (json['termMonths'] as num? ?? 0).toInt(),
        method: json['method'] as String? ?? 'equal_payment',
        startMonth: (json['startMonth'] as num? ?? 0).toInt(),
        paidMonths: (json['paidMonths'] as num? ?? 0).toInt(),
        note: json['note'] as String? ?? '',
        summary: LoanSummary.fromJson(json['summary'] as Map<String, dynamic>? ?? {}),
      );
}

class BorrowedMoney {
  final int id;
  final String scope;
  final String name;
  final double total;
  final double annualRate;
  final int termMonths;
  final String method;
  final int startMonth;
  final int paidMonths;
  final String note;
  final LoanSummary summary;
  BorrowedMoney({
    required this.id,
    required this.scope,
    required this.name,
    required this.total,
    required this.annualRate,
    required this.termMonths,
    required this.method,
    required this.startMonth,
    required this.paidMonths,
    required this.note,
    required this.summary,
  });
  factory BorrowedMoney.fromJson(Map<String, dynamic> json) => BorrowedMoney(
        id: (json['id'] as num).toInt(),
        scope: json['scope'] as String? ?? 'personal',
        name: json['name'] as String? ?? '',
        total: (json['total'] as num? ?? 0).toDouble(),
        annualRate: (json['annualRate'] as num? ?? 0).toDouble(),
        termMonths: (json['termMonths'] as num? ?? 0).toInt(),
        method: json['method'] as String? ?? 'equal_payment',
        startMonth: (json['startMonth'] as num? ?? 0).toInt(),
        paidMonths: (json['paidMonths'] as num? ?? 0).toInt(),
        note: json['note'] as String? ?? '',
        summary: LoanSummary.fromJson(json['summary'] as Map<String, dynamic>? ?? {}),
      );
}

class BenefitSummary {
  final int payoutDate;        // 一次性：发放日期；逐月/年/终身/自定义：开始发放时间
  final double payoutAmount;   // 一次性：发放额；逐月：每月发放额；按年：每年发放额；终身/自定义：每月发放额
  final double yearsLeft;
  final double presentValue;    // 折现到当下的总价值
  final String description;
  BenefitSummary({
    required this.payoutDate,
    required this.payoutAmount,
    required this.yearsLeft,
    required this.presentValue,
    required this.description,
  });
  factory BenefitSummary.fromJson(Map<String, dynamic> json) => BenefitSummary(
        payoutDate: (json['payoutDate'] as num? ?? 0).toInt(),
        payoutAmount: (json['payoutAmount'] as num? ?? 0).toDouble(),
        yearsLeft: (json['yearsLeft'] as num? ?? 0).toDouble(),
        presentValue: (json['presentValue'] as num? ?? 0).toDouble(),
        description: json['description'] as String? ?? '',
      );
}

class FutureBenefit {
  final int id;
  final String scope;
  final String name;
  final String type; // monthly/yearly/lump_sum/lifetime/custom_years
  final int payoutDate;
  final double payoutAmount;
  final int customYears;     // 自定义年限（仅 type=custom_years 用）
  final String note;
  final BenefitSummary summary;
  FutureBenefit({
    required this.id,
    required this.scope,
    required this.name,
    required this.type,
    required this.payoutDate,
    required this.payoutAmount,
    this.customYears = 0,
    required this.note,
    required this.summary,
  });
  factory FutureBenefit.fromJson(Map<String, dynamic> json) => FutureBenefit(
        id: (json['id'] as num).toInt(),
        scope: json['scope'] as String? ?? 'personal',
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? 'lump_sum',
        payoutDate: (json['payoutDate'] as num? ?? 0).toInt(),
        payoutAmount: (json['payoutAmount'] as num? ?? 0).toDouble(),
        customYears: (json['customYears'] as num? ?? 0).toInt(),
        note: json['note'] as String? ?? '',
        summary: BenefitSummary.fromJson(json['summary'] as Map<String, dynamic>? ?? {}),
      );
}

class InvestmentSummary {
  final double currentMonthRate;
  final int currentYear;
  final int currentMonth;
  final double targetRate;
  final double excess;
  final double hardSavingTransfer;
  final double deficit;
  InvestmentSummary({
    required this.currentMonthRate,
    required this.currentYear,
    required this.currentMonth,
    required this.targetRate,
    required this.excess,
    required this.hardSavingTransfer,
    required this.deficit,
  });
  factory InvestmentSummary.fromJson(Map<String, dynamic> json) => InvestmentSummary(
        currentMonthRate: (json['currentMonthRate'] as num? ?? 0).toDouble(),
        currentYear: (json['currentYear'] as num? ?? 0).toInt(),
        currentMonth: (json['currentMonth'] as num? ?? 0).toInt(),
        targetRate: (json['targetRate'] as num? ?? 0).toDouble(),
        excess: (json['excess'] as num? ?? 0).toDouble(),
        hardSavingTransfer: (json['hardSavingTransfer'] as num? ?? 0).toDouble(),
        deficit: (json['deficit'] as num? ?? 0).toDouble(),
      );
}

class FutureFinanceData {
  final double totalPending;
  final double totalProgressPct;
  final int totalRemainingMonths;
  final int estimatedPayoffAt;
  final List<HousingFundLoan> housingFundLoans;
  final List<CommercialLoan> commercialLoans;
  final List<BorrowedMoney> borrowedMoneys;
  final List<FutureBenefit> futureBenefits;
  final InvestmentSummary investment;
  FutureFinanceData({
    required this.totalPending,
    required this.totalProgressPct,
    required this.totalRemainingMonths,
    required this.estimatedPayoffAt,
    required this.housingFundLoans,
    required this.commercialLoans,
    required this.borrowedMoneys,
    required this.futureBenefits,
    required this.investment,
  });
  factory FutureFinanceData.fromJson(Map<String, dynamic> json) => FutureFinanceData(
        totalPending: (json['totalPending'] as num? ?? 0).toDouble(),
        totalProgressPct: (json['totalProgressPct'] as num? ?? 0).toDouble(),
        totalRemainingMonths: (json['totalRemainingMonths'] as num? ?? 0).toInt(),
        estimatedPayoffAt: (json['estimatedPayoffAt'] as num? ?? 0).toInt(),
        housingFundLoans: ((json['housingFundLoans'] as List?) ?? [])
            .map((e) => HousingFundLoan.fromJson(e as Map<String, dynamic>))
            .toList(),
        commercialLoans: ((json['commercialLoans'] as List?) ?? [])
            .map((e) => CommercialLoan.fromJson(e as Map<String, dynamic>))
            .toList(),
        borrowedMoneys: ((json['borrowedMoneys'] as List?) ?? [])
            .map((e) => BorrowedMoney.fromJson(e as Map<String, dynamic>))
            .toList(),
        futureBenefits: ((json['futureBenefits'] as List?) ?? [])
            .map((e) => FutureBenefit.fromJson(e as Map<String, dynamic>))
            .toList(),
        investment: InvestmentSummary.fromJson(json['investment'] as Map<String, dynamic>? ?? {}),
      );
}

class LoanMethod {
  static const String equalPayment = 'equal_payment';
  static const String equalCapital = 'equal_capital';
  static const String interestFree = 'interest_free';
  static const Map<String, String> labels = {
    equalPayment: '等额本息',
    equalCapital: '等额本金',
    interestFree: '无息（按月等额）',
  };
}

class BenefitType {
  static const String monthly = 'monthly';           // 按月发放至预期寿命
  static const String yearly = 'yearly';             // 按年发放至预期寿命
  static const String lumpSum = 'lump_sum';          // 一次性发放
  static const String lifetime = 'lifetime';         // 终身按月
  static const String customYears = 'custom_years';  // 自定义年限
  static const Map<String, String> labels = {
    monthly: '按月发放',
    yearly: '按年发放',
    lumpSum: '一次性发放',
    lifetime: '终身按月',
    customYears: '自定义年限',
  };
}

/// 通知项
class NotificationItem {
  final int id;
  final int uid;
  final String type;     // overspend/big_purchase/family_apply/family_result/system
  final String title;
  final String content;
  final String data;
  final bool read;
  final int createdAt;   // unix 秒

  NotificationItem({
    required this.id,
    required this.uid,
    required this.type,
    required this.title,
    required this.content,
    required this.data,
    required this.read,
    required this.createdAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) => NotificationItem(
        id: _parseNum(json['id']).toInt(),
        uid: _parseNum(json['uid']).toInt(),
        type: json['type'] as String? ?? 'system',
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        data: json['data'] as String? ?? '',
        read: json['read'] as bool? ?? false,
        createdAt: _parseNum(json['createdAt']).toInt(),
      );
}

class NotifyType {
  static const String overSpend = 'overspend';
  static const String bigPurchase = 'big_purchase';
  static const String familyApply = 'family_apply';
  static const String familyResult = 'family_result';
  static const String system = 'system';

  static const Map<String, String> labels = {
    overSpend: '超支提醒',
    bigPurchase: '大件可购买',
    familyApply: '家庭申请',
    familyResult: '申请结果',
    system: '系统通知',
  };
  static String labelOf(String t) => labels[t] ?? '通知';
}
