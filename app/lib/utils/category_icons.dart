import 'package:flutter/material.dart';

import '../models.dart';

/// 分类 → 图标映射（账单列表左侧的分类图标，非收支类型图标）。
/// key 为 TxCategory 的分类 key；同时兼容常见中文分类名。
IconData categoryIcon(String category) =>
    _categoryIcons[category] ?? Icons.receipt_long;

const Map<String, IconData> _categoryIcons = {
  // 支出子类
  TxCategory.expenseDaily: Icons.shopping_basket, // 日常消费
  TxCategory.expenseBigPurchase: Icons.shopping_cart, // 大件购物
  TxCategory.expensePension: Icons.elderly, // 养老
  TxCategory.expenseEmergency: Icons.local_hospital, // 应急
  TxCategory.expenseLoanRepay: Icons.account_balance, // 偿还贷款
  // 收入子类
  TxCategory.incomeSalary: Icons.payments, // 工资
  TxCategory.incomeHousingFund: Icons.account_balance, // 公积金
  TxCategory.incomeWindfall: Icons.card_giftcard, // 意外收入
  TxCategory.incomeInvestment: Icons.trending_up, // 投资收益
  TxCategory.incomePastHousing: Icons.history, // 过往公积金
  TxCategory.incomePastSaving: Icons.savings, // 过往存款
  // 存钱（转账）子类
  TxCategory.transferToSaving: Icons.savings,
  TxCategory.transferToInvestment: Icons.trending_up,
  TxCategory.transferToEmergency: Icons.local_hospital,
  TxCategory.transferToPension: Icons.elderly,
  // 常见中文分类名兜底
  '交通': Icons.directions_car,
  '日用': Icons.local_drink,
  '正餐': Icons.ramen_dining,
  '购物': Icons.shopping_cart,
};
