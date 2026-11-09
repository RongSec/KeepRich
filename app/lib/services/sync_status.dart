import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models.dart';
import 'api.dart';

/// 云端快照同步状态轮询服务（R-11）
///
/// 职责很窄：登录后每 [pollInterval] 拉一次 `GET /api/sync/status`，把"现在
/// 云端备份是不是不健康"这个布尔值给顶部横条用。**不做任何写操作、不打扰用户**
/// （不弹窗、不打断请求）。
///
/// 判定为"不健康"（[failing]）的两种情形：
/// 1. **连续 [failureThreshold] 次请求失败**（断网 / 服务端 5xx / 超时）——
///    此时数据只在本机，正是需要提示用户的时刻；
/// 2. 服务端自己报告了 `lastError`，并且距上次成功推送超过 [staleSeconds]
///    （从未推送成功也算）——即"推送一直失败，云端快照已经落后了"。
///
/// 恢复（下一次轮询成功且不再满足上面两条）时 [failing] 自动变回 false，
/// 横条随之消失，无需用户操作。
class SyncStatusService extends ChangeNotifier {
  SyncStatusService._();

  static final SyncStatusService instance = SyncStatusService._();

  /// 轮询间隔（设计 §2.F：60s）
  static const Duration pollInterval = Duration(seconds: 60);

  /// 连续失败多少次后开始提示
  static const int failureThreshold = 3;

  /// 距上次成功推送超过这么多秒 + 有 lastError → 视为不健康
  static const int staleSeconds = 120;

  Timer? _timer;
  bool _busy = false;
  bool _failing = false;
  int _consecutiveFailures = 0;
  SyncStatusData? _status;

  /// 最近一次成功拿到的状态（失败时保留旧值，横条文案不需要它）
  SyncStatusData? get status => _status;

  /// 是否应显示"云端同步暂时失败"横条
  bool get failing => _failing;

  /// 连续失败次数（调试/验收用）
  int get consecutiveFailures => _consecutiveFailures;

  /// 登录后调用（幂等）
  void start() {
    if (_timer != null) return;
    _consecutiveFailures = 0;
    // 登录后先等一个间隔再拉：避免和登录后的首屏请求抢带宽
    unawaited(refresh());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  /// 退出登录 / 会话失效时调用
  void stop() {
    _timer?.cancel();
    _timer = null;
    _busy = false;
    _consecutiveFailures = 0;
    _status = null;
    if (_failing) {
      _failing = false;
      notifyListeners();
    }
  }

  /// 立即拉一次（外部也可手动触发，例如恢复网络后）
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await ApiClient.instance
          .syncStatus()
          .timeout(const Duration(seconds: 12));
      if (r.ok && r.data != null) {
        _status = r.data;
        _consecutiveFailures = 0;
        _apply(_isUnhealthy(r.data!));
      } else {
        // 401 不计数：会话过期会由 ApiClient 统一处理并跳登录页
        if (r.code != 401) _onFailure();
      }
    } catch (_) {
      _onFailure();
    } finally {
      _busy = false;
    }
  }

  void _onFailure() {
    _consecutiveFailures++;
    _apply(_consecutiveFailures >= failureThreshold);
  }

  /// 服务端自述的失败信号 + 陈旧度
  bool _isUnhealthy(SyncStatusData d) {
    if (!d.enabled) return false; // 未启用云同步：不是"失败"，不打扰用户
    if (d.lastError.isEmpty) return false;
    if (d.lastPushAt <= 0) return true; // 从未推送成功却有错误 → 一定有问题
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return nowSec - d.lastPushAt > staleSeconds;
  }

  void _apply(bool failing) {
    if (_failing == failing) return;
    _failing = failing;
    notifyListeners();
  }

  /// 仅供测试：直接把"是否失败"置位，避免测试必须依赖真实网络
  @visibleForTesting
  void debugSetFailing(bool value) => _apply(value);
}
