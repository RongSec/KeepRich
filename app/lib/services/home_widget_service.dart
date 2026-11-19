import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';

/// 桌面小卡片（Home Screen Widget）数据同步。
///
/// 实现方式（各安卓厂商统一）：Flutter 把数据写进 SharedPreferences，
/// 调 [HomeWidget.updateWidget] 通知系统；Android 原生 AppWidgetProvider
/// 读同一份存储渲染 RemoteViews。iOS 未接入（项目 flutter_launcher_icons
/// 里 ios:false，安卓优先）。
///
/// 红线：本服务**永不抛异常**——卡片刷新失败绝不能影响 App 主流程。
class HomeWidgetService {
  HomeWidgetService._();

  /// Android receiver 名（与 AndroidManifest 注册、Kotlin 类对应）
  static const String androidName = 'FinanceWidgetProvider';

  // 共享存储 key：Dart 与 Kotlin 两侧必须一字不差
  static const String _kWealth = 'fw_total_wealth';
  static const String _kConsumable = 'fw_month_consumable';
  static const String _kRemaining = 'fw_remaining_budget';
  static const String _kScope = 'fw_scope';
  static const String _kUpdatedAt = 'fw_updated_at';

  static final NumberFormat _money = NumberFormat('#,##0.00');

  /// 总览数据加载成功后调用：写入卡片数据并触发系统刷新。
  ///
  /// [scope] 取值 'family' / 'personal'，卡片右上角显示「家庭 / 个人」。
  static Future<void> updateFromOverview({
    required double totalWealth,
    required double monthConsumableLeft,
    required double remainingBudget,
    required String scope,
  }) async {
    try {
      await HomeWidget.saveWidgetData<String>(
          _kWealth, _money.format(totalWealth));
      await HomeWidget.saveWidgetData<String>(
          _kConsumable, _money.format(monthConsumableLeft));
      await HomeWidget.saveWidgetData<String>(
          _kRemaining, _money.format(remainingBudget));
      await HomeWidget.saveWidgetData<String>(_kScope, _scopeLabel(scope));
      await HomeWidget.saveWidgetData<String>(
          _kUpdatedAt, DateTime.now().millisecondsSinceEpoch.toString());
      await HomeWidget.updateWidget(androidName: androidName);
    } catch (e) {
      debugPrint('[home_widget] 更新失败（不影响主流程）: $e');
    }
  }

  static String _scopeLabel(String scope) => scope == 'personal' ? '个人' : '家庭';
}
