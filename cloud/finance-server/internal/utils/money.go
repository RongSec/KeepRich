package utils

import "math"

// 金额精度约定（与 docs/ESTIMATION_ALGORITHMS.md §13 一致）：
//   - 金额最小单位为「分」，所有累加/比较/分配运算在整数分上进行，杜绝浮点误差；
//   - 存储层 decimal(14,2) 精确到分；
//   - API 边界以「元」(float64) 传输，出入统一经 Round2 规范化到分。

// ToCents 元 → 分（四舍五入到整数分）
func ToCents(yuan float64) int64 {
	return int64(math.Round(yuan * 100))
}

// FromCents 分 → 元
func FromCents(cents int64) float64 {
	return float64(cents) / 100.0
}

// Round2 将金额规范化到分（2 位小数）
func Round2(yuan float64) float64 {
	return FromCents(ToCents(yuan))
}

// SumYuan 在整数分上求和后返回元
func SumYuan(values ...float64) float64 {
	var total int64
	for _, v := range values {
		total += ToCents(v)
	}
	return FromCents(total)
}

// EqualMoney 金额相等比较（精确到分）
func EqualMoney(a, b float64) bool {
	return ToCents(a) == ToCents(b)
}
