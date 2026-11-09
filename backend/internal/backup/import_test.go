package backup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// testDB 新建一个内存 SQLite 并建好 users 表（Import 的 users 路径专用）。
func testDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file::memory:?cache=shared"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if sqlDB, err := db.DB(); err == nil {
		sqlDB.SetMaxOpenConns(1)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Transaction{}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	// 每个用例都从空表开始（file::memory:?cache=shared 在同一进程内是共享的）
	if err := db.Unscoped().Where("1 = 1").Delete(&models.User{}).Error; err != nil {
		t.Fatalf("clean users: %v", err)
	}
	return db
}

// migrationUsersRaw 读取真实的接续包（docs/backups/finance-migration-restore.json）里的 users 数组。
//
// 用它做输入的意义：这份文件里的 passwordHash 是线上真实 bcrypt 哈希，
// 能一次性证明「导出侧/导入侧都没有把哈希丢掉」——这是本任务最大的陷阱。
func migrationUsersRaw(t *testing.T) json.RawMessage {
	t.Helper()
	path := filepath.Join("..", "..", "..", "docs", "backups", "finance-migration-restore.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("跳过：接续包不存在（%s）: %v", path, err)
	}
	var doc struct {
		Tables map[string]json.RawMessage `json:"tables"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("解析接续包失败: %v", err)
	}
	raw, ok := doc.Tables["users"]
	if !ok {
		t.Fatalf("接续包缺少 tables.users")
	}
	return raw
}

// TestImportMergeKeepsPasswordHash 验收 ⑨（哈希侧）：
// 用真实接续包的 users 行导入空库后，库里的 hash 必须是 60 字符的 $2a$ 串，
// 且用错误口令校验返回 false —— 证明哈希真的进库了，不是空串。
func TestImportMergeKeepsPasswordHash(t *testing.T) {
	db := testDB(t)
	raw := migrationUsersRaw(t)

	res, err := Import(db, map[string]json.RawMessage{"users": raw}, ImportOptions{Mode: ImportMerge})
	if err != nil {
		t.Fatalf("Import(merge) 失败: %v", err)
	}
	if got, want := res.Inserted["users"], int64(5); got != want {
		t.Fatalf("inserted[users] = %d, 期望 %d", got, want)
	}

	var users []models.User
	if err := db.Order("id ASC").Find(&users).Error; err != nil {
		t.Fatalf("查询 users: %v", err)
	}
	if len(users) != 5 {
		t.Fatalf("库中 users = %d 行，期望 5 行", len(users))
	}

	withHash := 0
	for _, u := range users {
		if u.PasswordHash == "" {
			continue // webuser 在接续包里本来就没有哈希，属于已知情况
		}
		withHash++
		if len(u.PasswordHash) != 60 {
			t.Errorf("用户 %s 的 hash 长度 = %d，期望 60", u.Username, len(u.PasswordHash))
		}
		if !strings.HasPrefix(u.PasswordHash, "$2a$") {
			t.Errorf("用户 %s 的 hash 前缀不对（应为 $2a$）", u.Username)
		}
		// 用"随便"当口令必须校验失败（bcrypt 不会对空 hash 返回 true，
		// 但真正要证明的是 hash 不是空串 —— 空串时 CheckPassword 也返回 false，
		// 所以长度与前缀断言才是关键证据）
		if utils.CheckPassword(u.PasswordHash, "随便") {
			t.Errorf("用户 %s 用任意口令校验居然通过，hash 可疑", u.Username)
		}
	}
	if withHash != 4 {
		t.Fatalf("带哈希的用户数 = %d，期望 4（admin/alice/bob/test）", withHash)
	}

	// 幂等：再跑一次应全部 skipped、零 inserted
	res2, err := Import(db, map[string]json.RawMessage{"users": raw}, ImportOptions{Mode: ImportMerge})
	if err != nil {
		t.Fatalf("第二次 Import(merge) 失败: %v", err)
	}
	if res2.Inserted["users"] != 0 || res2.Skipped["users"] != 5 {
		t.Fatalf("幂等校验失败: inserted=%d skipped=%d（期望 0 / 5）",
			res2.Inserted["users"], res2.Skipped["users"])
	}
}

// TestImportReplaceKeepsPasswordHash replace 模式同样必须走 userImportRow：
// 只在 replace 分支做 toModel() 是常见错误，这里显式覆盖两种模式。
func TestImportReplaceKeepsPasswordHash(t *testing.T) {
	db := testDB(t)
	raw := migrationUsersRaw(t)

	res, err := Import(db, map[string]json.RawMessage{"users": raw}, ImportOptions{Mode: ImportReplace})
	if err != nil {
		t.Fatalf("Import(replace) 失败: %v", err)
	}
	if !res.Replaced {
		t.Fatal("res.Replaced 应为 true")
	}
	if res.Inserted["users"] != 5 {
		t.Fatalf("inserted[users] = %d, 期望 5", res.Inserted["users"])
	}

	var alice models.User
	if err := db.Where("username = ?", "alice").First(&alice).Error; err != nil {
		t.Fatalf("查询 alice: %v", err)
	}
	if alice.PasswordHash == "" || len(alice.PasswordHash) != 60 {
		t.Fatalf("replace 模式把 alice 的哈希丢了: %q", alice.PasswordHash)
	}
}

// TestImportRejectsEmptyInput 红线：空输入必须拒绝，绝不能"猜"成清库。
func TestImportRejectsEmptyInput(t *testing.T) {
	db := testDB(t)
	if _, err := Import(db, nil, ImportOptions{Mode: ImportReplace}); err == nil {
		t.Fatal("空 tables 应该返回错误")
	}
	if _, err := Import(db, map[string]json.RawMessage{}, ImportOptions{Mode: ImportReplace}); err == nil {
		t.Fatal("空 map 应该返回错误")
	}
}

// TestImportReplaceKeepsLocalUsersWhenSnapshotHasNoUsers
// 快照 users 为 0 行时必须保留本地 users（否则导入后谁都登不进）。
func TestImportReplaceKeepsLocalUsersWhenSnapshotHasNoUsers(t *testing.T) {
	db := testDB(t)
	seed := models.User{Username: "local", PasswordHash: "x", Role: models.RoleAdmin}
	if err := db.Create(&seed).Error; err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, err := Import(db, map[string]json.RawMessage{
		"users":        json.RawMessage(`[]`),
		"transactions": json.RawMessage(`[]`),
	}, ImportOptions{Mode: ImportReplace})
	if err != nil {
		t.Fatalf("Import 失败: %v", err)
	}

	var cnt int64
	if err := db.Model(&models.User{}).Where("username = ?", "local").Count(&cnt).Error; err != nil {
		t.Fatalf("count: %v", err)
	}
	if cnt != 1 {
		t.Fatal("users 为空的快照不应该清掉本地 users")
	}
}

// TestGateExportTs 时间闸门四种判定。
func TestGateExportTs(t *testing.T) {
	cases := []struct {
		name       string
		req        int64
		remote     int64
		force      bool
		wantAllow  bool
		wantDecide string
	}{
		{"force 放行", 100, 200, true, true, "forced"},
		{"缺时间戳拒绝", 0, 200, false, false, "rejected_no_ts"},
		{"较旧拒绝", 100, 200, false, false, "rejected_older"},
		{"同等放行", 200, 200, false, true, "allowed"},
		{"更新放行", 300, 200, false, true, "allowed"},
		{"无云端时间戳放行", 100, 0, false, true, "allowed"},
	}
	for _, c := range cases {
		allow, decision, reason := GateExportTs(c.req, c.remote, c.force)
		if allow != c.wantAllow || decision != c.wantDecide {
			t.Errorf("%s: got (allow=%v, decision=%s), want (allow=%v, decision=%s)",
				c.name, allow, decision, c.wantAllow, c.wantDecide)
		}
		if !allow && reason == "" {
			t.Errorf("%s: 拒绝时必须给中文文案", c.name)
		}
	}
}
