import 'dart:math' as math;

/// 金额精度约定（与 docs/ESTIMATION_ALGORITHMS.md §13 一致）：
/// 金额最小单位为「分」，累加/比较/分配一律在整数分上进行，杜绝浮点误差。
/// 展示层统一 toStringAsFixed(2) / NumberFormat('#,##0.00')。

/// 元 → 分（四舍五入到整数分）
int toCents(double yuan) => (yuan * 100).round();

/// 分 → 元
double fromCents(int cents) => cents / 100.0;

/// 将金额规范化到分（2 位小数）
double round2(double yuan) => fromCents(toCents(yuan));

/// 在整数分上求和后返回元
double sumYuan(Iterable<double> values) {
  var total = 0;
  for (final v in values) {
    total += toCents(v);
  }
  return fromCents(total);
}

/// 金额相等比较（精确到分）
bool equalMoney(double a, double b) => toCents(a) == toCents(b);

/// 保守取 min，避免浮点毛刺
double minMoney(double a, double b) => math.min(a, b);
