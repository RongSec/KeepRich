package services

import (
	"time"

	"gorm.io/gorm"
)

// CountDistinctMonths 统计查询结果里出现过的自然月数。
//
// 原实现用 MySQL 方言 `COUNT(DISTINCT DATE_FORMAT(FROM_UNIXTIME(occurred_at), '%Y-%m'))`，
// SQLite（云托管构建）没有这两个函数。这里改成取出去重的时间戳，
// 在 Go 里按 `2006-01` 归并 —— 任何数据库都能跑。
// 注意按服务器本地时区归月，与记账时写入的本地时间语义一致。
func CountDistinctMonths(q *gorm.DB) int {
	var stamps []int64
	_ = q.Distinct("occurred_at").Pluck("occurred_at", &stamps).Error
	seen := make(map[string]bool, len(stamps))
	for _, t := range stamps {
		seen[time.Unix(t, 0).Format("2006-01")] = true
	}
	return len(seen)
}
