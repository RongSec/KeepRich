package backup

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// v050TestDB 建一个独立文件 SQLite，并按 Tables() 全量建表（Export 会遍历全部表）。
func v050TestDB(t *testing.T) *gorm.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "v050-snapshot.db")
	db, err := gorm.Open(sqlite.Open(path), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("打开 SQLite 失败: %v", err)
	}
	tables := Tables()
	for _, tbl := range tables {
		if err := db.AutoMigrate(tbl.Model); err != nil {
			t.Fatalf("建表 %s 失败: %v", tbl.Name, err)
		}
	}
	for i := len(tables) - 1; i >= 0; i-- {
		if err := db.Unscoped().Where("1 = 1").Delete(tables[i].Model).Error; err != nil {
			t.Fatalf("清空 %s 失败: %v", tables[i].Name, err)
		}
	}
	return db
}

// TestV050TablesAndBusinessExclusion 锁住 R3：4 张新表必须进快照，
// 且**必须**被 IsBusinessTable 排除 —— 否则「只有会话没有账目」的库会被判成
// 有业务数据，cloudsync 的 P6 会拒绝拉云端快照，极端情况反向覆盖真实账目。
func TestV050TablesAndBusinessExclusion(t *testing.T) {
	names := make(map[string]bool)
	for _, tbl := range Tables() {
		names[tbl.Name] = true
	}
	want := []string{"auth_sessions", "device_credentials", "invite_codes", "invite_code_usages"}
	for _, n := range want {
		if !names[n] {
			t.Errorf("快照表清单缺少 %s（重启会踢人 / 邀请码配额归零）", n)
		}
		if IsBusinessTable(n) {
			t.Errorf("P0：%s 必须被 IsBusinessTable 排除，否则会污染「本地是否有业务数据」判定", n)
		}
	}
	if got, wantLen := len(Tables()), 22; got != wantLen {
		t.Errorf("快照表数 = %d，期望 %d", got, wantLen)
	}
	// 对照：真正的业务表/排除名单原有成员行为不变
	if !IsBusinessTable("transactions") || !IsBusinessTable("family_members") {
		t.Error("真正的业务表仍应返回 true")
	}
	for _, n := range []string{"users", "audit_logs", "error_reports"} {
		if IsBusinessTable(n) {
			t.Errorf("%s 应继续被排除", n)
		}
	}
}

// TestV050SnapshotRoundTripKeepsInviteQuota 验证「已发出的邀请码与 used_count 不回退」，
// 同时验证会话的 refresh 指纹能往返（不进/丢字段 = 重启全端掉线）。
func TestV050SnapshotRoundTripKeepsInviteQuota(t *testing.T) {
	db := v050TestDB(t)
	now := time.Now().Unix()

	admin := models.User{Username: "admin", PasswordHash: "bcrypt-hash-placeholder", Role: models.RoleAdmin}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("造用户失败: %v", err)
	}
	inv := models.InviteCode{
		Code: "ABCD2345", CreatedBy: admin.ID, Note: "给爸爸",
		MaxUses: 1, UsedCount: 1, ExpiresAt: now + 3600,
	}
	if err := db.Create(&inv).Error; err != nil {
		t.Fatalf("造邀请码失败: %v", err)
	}
	usage := models.InviteCodeUsage{
		InviteCodeID: inv.ID, Code: inv.Code, UserID: admin.ID, UsedAt: now, IP: "127.0.0.1",
	}
	if err := db.Create(&usage).Error; err != nil {
		t.Fatalf("造使用记录失败: %v", err)
	}
	sess := models.AuthSession{
		UserID: admin.ID, SessionID: "v050-test-session-0000000000000001",
		DeviceID: "d-test", DeviceName: "测试机", Platform: "android",
		RefreshHash: "0123456789abcdef", PrevRefreshHash: "fedcba9876543210",
		LastSeenAt: now, IdleDeadline: now + 86400, TokenVersion: 0,
	}
	if err := db.Create(&sess).Error; err != nil {
		t.Fatalf("造会话失败: %v", err)
	}

	snap, err := Export(db, ExportOptions{IncludeAudit: true})
	if err != nil {
		t.Fatalf("导出快照失败: %v", err)
	}
	for _, n := range []string{"auth_sessions", "device_credentials", "invite_codes", "invite_code_usages"} {
		if _, ok := snap.Tables[n]; !ok {
			t.Fatalf("快照 payload 缺少 %s", n)
		}
	}

	// 模拟「清空本地库 / 沙箱重启」：全表清空后用同一 payload 往返导入
	tables := Tables()
	for i := len(tables) - 1; i >= 0; i-- {
		if err := db.Unscoped().Where("1 = 1").Delete(tables[i].Model).Error; err != nil {
			t.Fatalf("清空 %s 失败: %v", tables[i].Name, err)
		}
	}
	if _, err := Import(db, snap.Tables, ImportOptions{Mode: ImportReplace}); err != nil {
		t.Fatalf("快照导入失败: %v", err)
	}

	var gotInv models.InviteCode
	if err := db.Where("code = ?", inv.Code).First(&gotInv).Error; err != nil {
		t.Fatalf("往返后邀请码丢失: %v", err)
	}
	if gotInv.UsedCount != 1 {
		t.Fatalf("往返后 used_count = %d，期望 1（一次性码会被重复使用）", gotInv.UsedCount)
	}
	var usageCount int64
	if err := db.Model(&models.InviteCodeUsage{}).Where("invite_code_id = ?", gotInv.ID).Count(&usageCount).Error; err != nil {
		t.Fatalf("统计使用记录失败: %v", err)
	}
	if usageCount != 1 {
		t.Fatalf("往返后使用记录 = %d 行，期望 1", usageCount)
	}
	var gotSess models.AuthSession
	if err := db.Where("session_id = ?", sess.SessionID).First(&gotSess).Error; err != nil {
		t.Fatalf("往返后会话丢失: %v", err)
	}
	if gotSess.RefreshHash != sess.RefreshHash || gotSess.PrevRefreshHash != sess.PrevRefreshHash {
		t.Fatal("往返后 refresh 指纹丢失 → 重启后全端掉线 / 宽限状态丢失")
	}
}
