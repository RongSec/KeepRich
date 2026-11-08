import 'package:flutter/foundation.dart';

/// 全局数据版本号：任意写操作（记账/存钱/还贷/家庭/计划等）成功后自增，
/// 所有展示财务数据的页面监听它并自动重新拉取，用户无需手动点刷新。
final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

void markDataChanged() => dataVersion.value++;
