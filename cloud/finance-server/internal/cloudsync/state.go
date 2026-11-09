package cloudsync

import (
	"errors"
	"log"
	"strconv"

	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm/clause"
)

// sync_state 的固定 key（全小写 + 下划线，禁止在别处散落字符串字面量）
const (
	keyLastPullAt           = "last_pull_at"
	keyLastPushAt           = "last_push_at"
	keyLastRemoteExportedAt = "last_remote_exported_at"
	keyLastLocalWriteAt     = "last_local_write_at"
	keyDirty                = "dirty"
	keyLastError            = "last_error"
	keyLastErrorAt          = "last_error_at"
	keyRowExists            = "row_exists"
)

// maxStateValueLen 与 models.SyncState.Value 的 size:512 对齐
const maxStateValueLen = 512

// errNoDB 数据库尚未初始化（启动早期或单元测试场景）
var errNoDB = errors.New("cloudsync: database 未初始化")

// stateGet 读一个 key；不存在或出错时返回空串（同步元数据缺失不应该让服务起不来）。
//
// 用 Find + RowsAffected 而不是 First：First 在缺失时返回 ErrRecordNotFound，
// GORM 会把它按 error 级别打进日志 —— 而"某个 key 还不存在"是启动时的**常态**，
// 每次读都刷一行日志会把真正的问题埋掉。
func stateGet(key string) string {
	if database.DB == nil {
		return ""
	}
	var row models.SyncState
	res := database.DB.Where("key = ?", key).Limit(1).Find(&row)
	if res.Error != nil {
		log.Printf("[cloudsync] state get %s: %v", key, res.Error)
		return ""
	}
	if res.RowsAffected == 0 {
		return ""
	}
	return row.Value
}

// stateGetInt 读一个整数 key；缺失/非法时返回 0。
func stateGetInt(key string) int64 {
	v := stateGet(key)
	if v == "" {
		return 0
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// stateSet 写一个 key（upsert）。value 超长截断，避免把 SQLite/MySQL 的 size 限制打爆。
func stateSet(key, value string) error {
	if database.DB == nil {
		return errNoDB
	}
	if len(value) > maxStateValueLen {
		value = value[:maxStateValueLen]
	}
	row := models.SyncState{Key: key, Value: value}
	return database.DB.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "key"}},
		DoUpdates: clause.AssignmentColumns([]string{"value"}),
	}).Create(&row).Error
}

// stateSetInt 写一个整数 key。
func stateSetInt(key string, v int64) error {
	return stateSet(key, strconv.FormatInt(v, 10))
}

// stateSetLogged 写 key，失败只打日志（同步元数据写失败不影响业务请求）。
func stateSetLogged(key, value string) {
	if err := stateSet(key, value); err != nil && !errors.Is(err, errNoDB) {
		log.Printf("[cloudsync] state set %s: %v", key, err)
	}
}

// stateSetIntLogged 写整数 key，失败只打日志。
func stateSetIntLogged(key string, v int64) {
	stateSetLogged(key, strconv.FormatInt(v, 10))
}
