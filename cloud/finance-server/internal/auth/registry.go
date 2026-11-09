package auth

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
)

// SessionState 中间件热路径需要的会话状态（只读快照，不含任何秘密）。
type SessionState struct {
	Found        bool
	DBID         uint64
	UserID       uint64
	DeviceID     string
	TokenVersion int
	Revoked      bool
	Idle         bool
	IdleDeadline int64
}

// liveSession 内存态：只保存「待刷盘的 last_seen」与行主键。
type liveSession struct {
	dbID      uint64
	dirtySeen int64
}

// Registry 会话热路径注册表。
//
// 设计取舍（对 DESIGN §A.4 的一处有意收紧）：Get() 每次做**一次只读** DB 复核，
// 而不是缓存 600s。原因有二：
//  1. 外部把会话手工推前 25h / 管理员撤销 / 改密撤销必须「下一请求」立即生效
//     （T01 验收 ②⑤⑥），纯内存缓存做不到；
//  2. 只读不写，SQLite MaxOpenConns(1) 下不会把请求串行化成写锁。
//
// last_seen 的**写入**仍只走 60s 单事务批量刷盘，绝不退化成每请求 UPDATE（F8 / 验收 ⑩）。
type Registry struct {
	mu sync.Mutex
	m  map[string]*liveSession
}

var (
	regOnce sync.Once
	regInst *Registry
)

// R 返回进程内单例（未显式初始化也安全）。
func R() *Registry {
	regOnce.Do(func() {
		regInst = &Registry{m: make(map[string]*liveSession)}
	})
	return regInst
}

// Get 读取会话状态并做只读 DB 复核。查不到 / 软删 / 撤销都会体现在返回值里。
func (r *Registry) Get(sid string) SessionState {
	st := SessionState{}
	if sid == "" || database.DB == nil {
		return st
	}
	var s models.AuthSession
	if err := database.DB.Unscoped().Where("session_id = ?", sid).First(&s).Error; err != nil {
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			log.Printf("[auth] 查询会话失败 sid=%s: %v", sid, err)
		}
		return st
	}
	st.Found = true
	st.DBID = s.ID
	st.UserID = s.UserID
	st.DeviceID = s.DeviceID
	st.TokenVersion = s.TokenVersion
	st.Revoked = s.RevokedAt != nil || s.DeletedAt.Valid

	ttl := int64(config.AuthParams().SessionIdleTTL)
	st.IdleDeadline = s.LastSeenAt + ttl
	st.Idle = time.Now().Unix() > st.IdleDeadline

	r.mu.Lock()
	live, ok := r.m[sid]
	if !ok {
		live = &liveSession{}
		r.m[sid] = live
	}
	live.dbID = s.ID
	r.mu.Unlock()
	return st
}

// Touch 只更新内存时间戳（**不写库**），由 Flush 合并落盘。
func (r *Registry) Touch(sid string) {
	if sid == "" {
		return
	}
	now := time.Now().Unix()
	r.mu.Lock()
	defer r.mu.Unlock()
	live, ok := r.m[sid]
	if !ok {
		live = &liveSession{}
		r.m[sid] = live
	}
	if now > live.dirtySeen {
		live.dirtySeen = now
	}
}

// Invalidate 丢弃某会话的待刷盘状态（撤销后不能把旧 touch 写回 DB）。
func (r *Registry) Invalidate(sid string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.m, sid)
}

// InvalidateAll 丢弃全部内存态；Get 会在下一次请求回查 DB 重建。
func (r *Registry) InvalidateAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.m = make(map[string]*liveSession)
}

// Flush 把积压的 last_seen 用**单事务批量 UPDATE**落库。
func (r *Registry) Flush() {
	if database.DB == nil {
		return
	}
	r.mu.Lock()
	batch := make(map[uint64]int64)
	for _, live := range r.m {
		if live.dbID == 0 || live.dirtySeen <= 0 {
			continue
		}
		batch[live.dbID] = live.dirtySeen
		live.dirtySeen = 0
	}
	r.mu.Unlock()
	if len(batch) == 0 {
		return
	}
	ttl := int64(config.AuthParams().SessionIdleTTL)
	err := database.DB.Transaction(func(tx *gorm.DB) error {
		for id, seen := range batch {
			if err := tx.Model(&models.AuthSession{}).Where("id = ?", id).
				Updates(map[string]any{
					"last_seen_at":  seen,
					"idle_deadline": seen + ttl,
				}).Error; err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		log.Printf("[auth] 批量刷盘 last_seen 失败（下次 ticker 会重试）: %v", err)
	}
}

// RunFlusher 后台刷盘循环；ctx 取消后由调用方显式 Flush 一次（优雅退出）。
func (r *Registry) RunFlusher(ctx context.Context, every time.Duration) {
	if every <= 0 {
		every = 60 * time.Second
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Printf("[auth] session flusher stopped")
			return
		case <-ticker.C:
			r.Flush()
		}
	}
}
