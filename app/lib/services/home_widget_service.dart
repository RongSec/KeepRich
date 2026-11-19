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
/// 卡片显示「剩余可消费 / 当月已消费」，口径（家庭/个人）可在卡片上切换
/// ——两个口径的数字都写入，切换只是换 key 读取，不依赖 App 进程存活。
///
/// 红线：本服务**永不抛异常**——卡片刷新失败绝不能影响 App 主流程。
class HomeWidgetService {
  HomeWidgetService._();

  /// Android receiver 名（与 AndroidManifest 注册、Kotlin 类对应）
  static const String androidName = 'FinanceWidgetProvider';

  // 共享存储 key：Dart 与 Kotlin 两侧必须一字不差
  static const String _kUpdatedAt = 'fw_updated_at';

  static final NumberFormat _money = NumberFormat('#,##0.00');

  /// 总览数据刷新后调用：把**两个口径**的数字都写入卡片并触发刷新。
  ///
  /// [left] 剩余可消费、[spent] 当月已消费，按 scope 分 key 存储
  /// （fw_family_left / fw_personal_left …），卡片上切换范围时
  /// 原生侧直接换 key 读取，无需 App 在跑。
  static Future<void> updateBothScopes({
    required String scope,
    required double left,
    required double spent,
    String? otherScope,
    double? otherLeft,
    double? otherSpent,
  }) async {
    try {
      await _writeScope(scope, left, spent);
      if (otherScope != null && otherLeft != null && otherSpent != null) {
        await _writeScope(otherScope, otherLeft, otherSpent);
      }
      await HomeWidget.saveWidgetData<String>(
          _kUpdatedAt, DateTime.now().millisecondsSinceEpoch.toString());
      await HomeWidget.updateWidget(androidName: androidName);
    } catch (e) {
      debugPrint('[home_widget] 更新失败（不影响主流程）: $e');
    }
  }

  static Future<void> _writeScope(
      String scope, double left, double spent) async {
    await HomeWidget.saveWidgetData<String>(
        'fw_${scope}_left', _money.format(left));
    await HomeWidget.saveWidgetData<String>(
        'fw_${scope}_spent', _money.format(spent));
  }
}
