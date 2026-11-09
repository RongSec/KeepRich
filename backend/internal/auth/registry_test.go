package auth

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

const registryTestSID = "registry-idle-boundary-test"

// newRegistryTest 建独立 SQLite 会话表 + 一条 last_seen_at=dbSeen 的会话，
// 并把 database.DB / config.C 指向测试值，结束后恢复。
func newRegistryTest(t *testing.T, ttl int, dbSeen int64) *Registry {
	t.Helper()
	path := filepath.Join(t.TempDir(), "registry.db")
	db, err := gorm.Open(sqlite.Open(path), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("打开 SQLite 失败: %v", err)
	}
	if err := db.AutoMigrate(&models.AuthSession{}); err != nil {
		t.Fatalf("建 auth_sessions 表失败: %v", err)
	}
	row := models.AuthSession{
		SessionID:    registryTestSID,
		UserID:       1,
		DeviceID:     "unit-test-device",
		LastSeenAt:   dbSeen,
		IdleDeadline: dbSeen + int64(ttl),
	}
	if err := db.Create(&row).Error; err != nil {
		t.Fatalf("写入测试会话失败: %v", err)
	}

	oldDB := database.DB
	oldCfg := config.C
	database.DB = db
	config.C = &config.Config{Auth: config.AuthConfig{SessionIdleTTL: ttl}}
	t.Cleanup(func() {
		database.DB = oldDB
		config.C = oldCfg
	})
	return &Registry{m: make(map[string]*liveSession)}
}

func readDBLastSeen(t *testing.T) int64 {
	t.Helper()
	var row models.AuthSession
	if err := database.DB.Unscoped().
		Where("session_id = ?", registryTestSID).First(&row).Error; err != nil {
		t.Fatalf("回查会话失败: %v", err)
	}
	return row.LastSeenAt
}

// TestRegistryIdleDeadlineUsesLatestTouch 锁住 QA P2-1：
// 内存 touch 未刷盘时，IdleDeadline 必须按最新 touch 计算，不能只看 DB。
func TestRegistryIdleDeadlineUsesLatestTouch(t *testing.T) {
	const ttl = 10
	now := time.Now().Unix()
	dbSeen := now - 8 // DB 里这条已经接近闲置线
	r := newRegistryTest(t, ttl, dbSeen)

	// 生产顺序：每个请求先 Get 再 Touch。
	if st := r.Get(registryTestSID); !st.Found || st.Idle {
		t.Fatalf("首次 Get 应为有效会话: %+v", st)
	}
	r.Touch(registryTestSID)
	r.mu.Lock()
	dirty := r.m[registryTestSID].dirtySeen
	r.mu.Unlock()

	st := r.Get(registryTestSID)
	if st.Idle {
		t.Fatal("活跃会话被误判闲置：IdleDeadline 没有计入内存 dirtySeen")
	}
	if st.IdleDeadline != dirty+ttl {
		t.Fatalf("IdleDeadline 应为 dirtySeen+ttl=%d，实际 %d",
			dirty+ttl, st.IdleDeadline)
	}
	if st.IdleDeadline <= dbSeen+ttl {
		t.Fatalf("IdleDeadline 不应回退到 DB 值 %d", dbSeen+ttl)
	}
	// Get 只读、绝不每请求写库：60s 批量刷盘语义必须保留。
	if got := readDBLastSeen(t); got != dbSeen {
		t.Fatalf("Get 不应写库，last_seen_at 应仍为 %d，实际 %d", dbSeen, got)
	}

	// live 不存在时退回 DB 值，保持既有行为。
	fresh := &Registry{m: make(map[string]*liveSession)}
	if got := fresh.Get(registryTestSID).IdleDeadline; got != dbSeen+ttl {
		t.Fatalf("live 不存在时应回退 DB 值 %d，实际 %d", dbSeen+ttl, got)
	}
}

// TestRegistryActiveSessionNotIdleBetweenFlushes 是 QA 复现的最小化：
// TTL(10) <= flush(60)，DB last_seen 早已过线，但内存持续 touch → 不得 40110。
func TestRegistryActiveSessionNotIdleBetweenFlushes(t *testing.T) {
	const ttl = 10
	dbSeen := time.Now().Unix() - 3600 // 模拟 60s 未刷盘、DB 值早已过闲置线
	r := newRegistryTest(t, ttl, dbSeen)
	r.Get(registryTestSID)

	for i := 0; i < 10; i++ {
		r.mu.Lock()
		r.m[registryTestSID].dirtySeen = time.Now().Unix()
		r.mu.Unlock()
		st := r.Get(registryTestSID)
		if st.Idle {
			t.Fatalf("第 %d 次活跃请求被误判闲置（IdleDeadline=%d, now=%d）",
				i+1, st.IdleDeadline, time.Now().Unix())
		}
	}
}

// TestRegistryDBRollbackStillDetectedIdle 反向验证：把 last_seen_at 手工推前
// 25 小时，下一次请求仍必须判闲置，且不能让待刷盘的旧 touch 把会话救活。
func TestRegistryDBRollbackStillDetectedIdle(t *testing.T) {
	const ttl = 10
	now := time.Now().Unix()
	dbSeen := now - 8
	r := newRegistryTest(t, ttl, dbSeen)
	r.Get(registryTestSID)
	r.Touch(registryTestSID) // 内存里确实有一次新 touch

	ancient := now - 25*3600
	if err := database.DB.Model(&models.AuthSession{}).
		Where("session_id = ?", registryTestSID).
		Updates(map[string]any{
			"last_seen_at":  ancient,
			"idle_deadline": ancient + ttl,
		}).Error; err != nil {
		t.Fatalf("推前 last_seen_at 失败: %v", err)
	}

	st := r.Get(registryTestSID)
	if !st.Idle {
		t.Fatalf("真实闲置被放过：Idle=%v IdleDeadline=%d", st.Idle, st.IdleDeadline)
	}
	if st.IdleDeadline != ancient+ttl {
		t.Fatalf("DB 回拨时应以 DB 为准，IdleDeadline=%d，实际 %d",
			ancient+ttl, st.IdleDeadline)
	}

	// 回拨后待刷盘的旧 touch 必须被丢弃，Flush 不能把它写回 DB。
	r.Flush()
	if got := readDBLastSeen(t); got != ancient {
		t.Fatalf("Flush 不应把旧 touch 写回，last_seen_at=%d，实际 %d",
			ancient, got)
	}
}
