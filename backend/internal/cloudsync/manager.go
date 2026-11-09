package cloudsync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/backup"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/version"
)

// 时间参数（DESIGN §2.B.6.3）
const (
	fallbackInterval = 60 * time.Second // 兜底扫描
	maxAttempts      = 8                // 单次推送最多尝试次数（之后交给兜底 ticker）
	kickBuffer       = 1                // kick 通道缓冲：只需要"有新写"这一个信号
	maxDebounceExtra = 5 * time.Second  // 持续写入时防抖窗口最多延长到这里，避免饿死推送
)

// backoff 指数退避（1/2/4/8/16/32/60/60 秒，封顶 60s）
var backoff = []time.Duration{
	1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second,
	16 * time.Second, 32 * time.Second, 60 * time.Second, 60 * time.Second,
}

// PullAction 拉取判定结果。
type PullAction int

const (
	PullSkipped  PullAction = iota // 不动本地
	PullReplaced                   // 云端覆盖本地
	PullNeedPush                   // 不导入，改为把本地推上去
)

func (a PullAction) String() string {
	switch a {
	case PullReplaced:
		return actionReplaced
	case PullNeedPush:
		return actionNeedPush
	default:
		return actionSkipped
	}
}

// 动作名（与接口契约 / 日志保持一致，禁止散落字面量）
const (
	actionSkipped  = "skipped"
	actionReplaced = "replaced"
	actionNeedPush = "need_push"
	actionPushed   = "pushed"
	actionFailed   = "failed"
)

// Status 同步状态的内存镜像（GET /api/sync/status 的数据源，不含密钥）。
type Status struct {
	Enabled             bool
	EndpointHost        string
	LastPullAt          int64
	LastPushAt          int64
	RemoteExportedAt    int64
	PayloadBytes        int
	Pending             bool
	ConsecutiveFailures int
	LastError           string
	LastErrorAt         int64
	RowExists           bool
}

// Result 一次同步动作的结果（handler 直接回显给运维）。
type Result struct {
	Action           string           `json:"action"`
	Reason           string           `json:"reason,omitempty"`
	Error            string           `json:"error,omitempty"`
	Inserted         map[string]int64 `json:"inserted,omitempty"`
	Deleted          map[string]int64 `json:"deleted,omitempty"`
	RemoteExportedAt int64            `json:"remoteExportedAt"`
	PayloadBytes     int              `json:"payloadBytes,omitempty"`
	ExportedAt       int64            `json:"exportedAt"`
}

// LocalState 判定表需要的本地状态快照（一次性从 sync_state + 计数读出来）。
type LocalState struct {
	Dirty                int
	LastRemoteExportedAt int64
	LastLocalWriteAt     int64
	HasBusiness          bool
}

// Manager 单例（与 database.DB / config.C 同风格）。
type Manager struct {
	cfg config.CloudSyncConfig
	cli *Client

	kick chan struct{}

	mu        sync.RWMutex
	st        Status
	pushCount int64
}

var (
	instMu sync.RWMutex
	// inst 未 Init 时的 disabled 空壳：所有方法安全 no-op（不 panic、不写库、不发请求）
	inst = &Manager{kick: make(chan struct{}, kickBuffer)}
)

// Init 构造并注册单例。必须在 database.Migrate() 之后调用。
func Init(cfg config.CloudSyncConfig) *Manager {
	m := &Manager{cfg: cfg, kick: make(chan struct{}, kickBuffer)}
	if cfg.Enabled && cfg.Endpoint != "" && cfg.APIKey != "" {
		m.cli = newClient(cfg.Endpoint, cfg.APIKey, cfg.SnapshotID, time.Duration(cfg.PushTimeoutSec)*time.Second)
		m.st.Enabled = true
		m.st.EndpointHost = endpointHost(cfg.Endpoint)
		log.Printf("[cloudsync] enabled endpoint=%s snapshotId=%d debounce=%dms timeout=%ds",
			cfg.Endpoint, cfg.SnapshotID, cfg.DebounceMS, cfg.PushTimeoutSec)
	} else {
		// 降级而不是 fatal：配错密钥绝不能让服务起不来（DESIGN §6.4）
		log.Printf("[cloudsync] disabled (enabled=%v, endpoint=%v, apiKey 已配置=%v) —— 数据不会持久化",
			cfg.Enabled, cfg.Endpoint != "", cfg.APIKey != "")
	}
	instMu.Lock()
	inst = m
	instMu.Unlock()
	return m
}

// M 返回单例；未 Init 时返回 disabled 空壳。
func M() *Manager {
	instMu.RLock()
	m := inst
	instMu.RUnlock()
	if m == nil {
		instMu.Lock()
		if inst == nil {
			inst = &Manager{kick: make(chan struct{}, kickBuffer)}
		}
		m = inst
		instMu.Unlock()
	}
	return m
}

// Enabled 是否真正可用（配置齐全且客户端已构造）。
func (m *Manager) Enabled() bool {
	return m != nil && m.cfg.Enabled && m.cli != nil
}

// Status 返回当前状态快照（副本，调用方随意读）。
func (m *Manager) Status() Status {
	m.mu.RLock()
	st := m.st
	m.mu.RUnlock()
	st.Enabled = m.Enabled()
	return st
}

// ---------------------------------------------------------------------------
// 拉取（判定表 P0–P9）
// ---------------------------------------------------------------------------

// StartupPull 启动时阻塞拉取（调用方给 8s 超时）。
// 失败只记日志与 lastError，**绝不 fatal、绝不清空本地**。
func (m *Manager) StartupPull(ctx context.Context) Result { return m.pull(ctx, false) }

// PullNow 供管理员接口调用；force=true 时无视 P5/P8（仍拒绝 P3/P4 损坏快照）。
func (m *Manager) PullNow(ctx context.Context, force bool) Result { return m.pull(ctx, force) }

func (m *Manager) pull(ctx context.Context, force bool) Result {
	res := Result{Action: actionSkipped}
	if !m.Enabled() {
		res.Reason = "disabled"
		return res
	}
	local := m.loadLocalState()

	row, raw, err := m.cli.Get(ctx)
	if err != nil {
		// P1：网络错误 / 超时 / 5xx → 不导入，也**不推送**（拉不到 ≠ 可以拿本地覆盖云端）
		res.Reason = "remote unreachable"
		res.Error = err.Error()
		m.recordError(err)
		log.Printf("[cloudsync] pull: GET 失败（不导入、不回写）: %v", err)
		return res
	}

	// P2：远端不存在（404 / 空数组 / 空 payload / payload 无 tables）→ 视为"无快照"
	if row == nil {
		m.setRowExists(false)
		return m.handleNoSnapshot(local, "remote row absent")
	}
	snap, perr := parseSnapshotPayload(raw)
	if perr != nil {
		m.setRowExists(true)
		return m.handleNoSnapshot(local, "payload has no snapshot content: "+perr.Error())
	}
	m.setRowExists(true)

	var action PullAction
	var reason string
	if force {
		// 管理员强制拉取：仍拒绝"洗库"的坏快照（P3/P4 不可被 force 越过）
		if len(snap.Tables) == 0 {
			res.Reason = "snapshot corrupt"
			m.recordError(errors.New("snapshot corrupt"))
			return res
		}
		if usersRowCount(snap) == 0 {
			res.Reason = "snapshot has no users"
			m.recordError(errors.New("snapshot has no users"))
			return res
		}
		action, reason = PullReplaced, "forced"
	} else {
		action, reason = m.decide(snap, local)
	}

	res.Action = action.String()
	res.Reason = reason
	res.RemoteExportedAt = snap.ExportedAt

	switch action {
	case PullNeedPush:
		log.Printf("[cloudsync] pull: need push (%s) → 把本地推上去", reason)
		m.asyncPush()
	case PullReplaced:
		ir, ierr := backup.Import(database.DB, snap.Tables, backup.ImportOptions{Mode: backup.ImportReplace})
		if ierr != nil {
			res.Action = actionSkipped
			res.Reason = "import failed"
			res.Error = ierr.Error()
			m.recordError(ierr)
			log.Printf("[cloudsync] pull: 导入失败（事务已回滚，本地数据保持原样）: %v", ierr)
			return res
		}
		res.Inserted = ir.Inserted
		res.Deleted = ir.Deleted
		now := time.Now().Unix()
		stateSetLogged(keyDirty, "0")
		stateSetIntLogged(keyLastRemoteExportedAt, snap.ExportedAt)
		stateSetIntLogged(keyLastPullAt, now)
		m.mu.Lock()
		m.st.RemoteExportedAt = snap.ExportedAt
		m.st.LastPullAt = now
		m.st.Pending = false
		m.st.LastError = ""
		m.st.LastErrorAt = 0
		m.mu.Unlock()
		log.Printf("[cloudsync] pull: replaced local with remote (exportedAt=%d, 导入表数=%d)",
			snap.ExportedAt, len(ir.Inserted))
	default:
		log.Printf("[cloudsync] pull: skipped (%s)", reason)
	}
	return res
}

// decide 判定表（附录 A 的可执行版本，顺序命中即返回）。
//
// 注意顺序：dirty 闸门（P5）在"快照损坏"（P3）之前 —— 本地有未推送的写时，
// 无论云端是什么状态都不允许被覆盖（红线 5.3.4）。
func (m *Manager) decide(snap *backup.Snapshot, local LocalState) (PullAction, string) {
	if !m.Enabled() {
		return PullSkipped, "disabled" // P0
	}
	if local.Dirty == 1 {
		return PullNeedPush, "local dirty" // P5（最高优先）
	}
	if snap == nil || len(snap.Tables) == 0 {
		return PullSkipped, "snapshot corrupt" // P3
	}
	if usersRowCount(snap) == 0 {
		return PullSkipped, "snapshot has no users" // P4
	}
	if !local.HasBusiness {
		return PullReplaced, "local empty" // P6
	}
	if snap.ExportedAt == local.LastRemoteExportedAt {
		return PullSkipped, "already in sync" // P7
	}
	if snap.ExportedAt < local.LastLocalWriteAt {
		return PullNeedPush, "remote older than local write" // P8
	}
	return PullReplaced, "remote newer" // P9（含 last_local_write_at==0：本地是部署快照库，云端为真源）
}

// handleNoSnapshot 远端没有可用快照时的分支（P2）。
func (m *Manager) handleNoSnapshot(local LocalState, reason string) Result {
	res := Result{Action: actionSkipped, Reason: reason}
	if local.HasBusiness {
		res.Action = actionNeedPush
		res.Reason = reason + " → 本地有数据，推送本地"
		log.Printf("[cloudsync] pull: %s；本地有数据 → 推送本地", reason)
		m.asyncPush()
		return res
	}
	log.Printf("[cloudsync] pull: %s；本地也为空 → 无动作", reason)
	return res
}

// loadLocalState 读判定表需要的本地状态，并顺带把落盘的观测值灌回内存镜像。
func (m *Manager) loadLocalState() LocalState {
	ls := LocalState{
		Dirty:                int(stateGetInt(keyDirty)),
		LastRemoteExportedAt: stateGetInt(keyLastRemoteExportedAt),
		LastLocalWriteAt:     stateGetInt(keyLastLocalWriteAt),
	}
	ls.HasBusiness = localHasBusiness()

	m.mu.Lock()
	m.st.LastPushAt = stateGetInt(keyLastPushAt)
	m.st.LastPullAt = stateGetInt(keyLastPullAt)
	m.st.RemoteExportedAt = ls.LastRemoteExportedAt
	m.st.LastError = stateGet(keyLastError)
	m.st.LastErrorAt = stateGetInt(keyLastErrorAt)
	m.st.Pending = ls.Dirty == 1
	m.st.RowExists = stateGet(keyRowExists) == "1"
	m.mu.Unlock()
	return ls
}

// localHasBusiness 业务表的总行数是否 > 0（排除 users 与两张日志表，
// 分类口径由 backup.IsBusinessTable 单点维护，避免两处字符串漂移）。
func localHasBusiness() bool {
	if database.DB == nil {
		return false
	}
	var total int64
	for _, t := range backup.Tables() {
		if !backup.IsBusinessTable(t.Name) {
			continue
		}
		var c int64
		if err := database.DB.Unscoped().Model(t.Model).Count(&c).Error; err != nil {
			log.Printf("[cloudsync] count %s: %v", t.Name, err)
			continue
		}
		total += c
	}
	return total > 0
}

// usersRowCount 快照里的 users 行数（counts 缺失时退化为数数组长度）。
func usersRowCount(snap *backup.Snapshot) int64 {
	if snap == nil {
		return 0
	}
	if c, ok := snap.Counts["users"]; ok {
		return c
	}
	raw, ok := snap.Tables["users"]
	if !ok {
		return 0
	}
	n, err := backup.CountRows(raw)
	if err != nil {
		return 0
	}
	return n
}

// parseSnapshotPayload 解析云端 payload；空内容 / 无 tables 视为"无快照"（返回错误由上层降级）。
func parseSnapshotPayload(raw json.RawMessage) (*backup.Snapshot, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return nil, errors.New("payload 为空")
	}
	if bytes.Equal(trimmed, []byte("null")) || bytes.Equal(trimmed, []byte("{}")) {
		return nil, errors.New("payload 为空对象")
	}
	var snap backup.Snapshot
	if err := json.Unmarshal(trimmed, &snap); err != nil {
		return nil, err
	}
	if len(snap.Tables) == 0 {
		return nil, errors.New("payload 无 tables")
	}
	return &snap, nil
}

// ---------------------------------------------------------------------------
// 推送
// ---------------------------------------------------------------------------

// MarkDirty 业务写操作成功后调用（中间件）。非阻塞：只打标记 + 落盘 + kick。
func (m *Manager) MarkDirty(reason string) {
	if !m.Enabled() {
		return
	}
	now := time.Now().Unix()
	m.mu.Lock()
	wasPending := m.st.Pending
	m.st.Pending = true
	m.mu.Unlock()

	// 非阻塞 kick：缓冲 1，写满了说明 Run 循环已收到信号，丢掉这次即可
	select {
	case m.kick <- struct{}{}:
	default:
	}

	// dirty 必须**落盘**：沙箱可能在刚写完账就被重启，进程内标记会丢
	go func(ts int64) {
		stateSetIntLogged(keyLastLocalWriteAt, ts)
		stateSetLogged(keyDirty, "1")
	}(now)

	if !wasPending {
		log.Printf("[cloudsync] dirty ← %s", reason)
	}
}

// Run 后台循环：防抖合并 + 指数退避 + 60s 兜底扫描（由 main.go `go` 起）。
func (m *Manager) Run(ctx context.Context) {
	if !m.Enabled() {
		return
	}
	ticker := time.NewTicker(fallbackInterval)
	defer ticker.Stop()
	log.Printf("[cloudsync] run loop started (debounce=%dms, fallback=%s)", m.debounceMS(), fallbackInterval)

	// 启动时若还有未推送的写（落盘 dirty==1），先补一刀
	if stateGetInt(keyDirty) == 1 {
		go m.pushWithRetry(ctx)
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("[cloudsync] run loop stopped")
			return
		case <-m.kick:
			// 收集防抖窗口内的所有 kick，合并成一次推送
			deadline := time.Now().Add(m.debounce() + maxDebounceExtra)
			timer := time.NewTimer(m.debounce())
		drain:
			for {
				select {
				case <-m.kick:
					// 窗口内有新写：重置计时（但整体不超过 deadline，防止持续写入饿死推送）
					remain := time.Until(deadline)
					if remain <= 0 {
						break drain
					}
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					d := m.debounce()
					if d > remain {
						d = remain
					}
					timer.Reset(d)
				case <-timer.C:
					break drain
				case <-ctx.Done():
					timer.Stop()
					log.Printf("[cloudsync] run loop stopped")
					return
				}
			}
			m.pushWithRetry(ctx)
		case <-ticker.C:
			m.mu.RLock()
			pending := m.st.Pending
			failures := m.st.ConsecutiveFailures
			m.mu.RUnlock()
			if pending || failures > 0 || stateGetInt(keyDirty) == 1 {
				m.pushWithRetry(ctx)
			}
		}
	}
}

// pushWithRetry 指数退避重试；8 次都失败则置 Pending=true 交给 60s 兜底 ticker。
func (m *Manager) pushWithRetry(ctx context.Context) {
	for attempt := 0; attempt < maxAttempts; attempt++ {
		err := m.pushOnce(ctx)
		if err == nil {
			m.mu.Lock()
			m.st.ConsecutiveFailures = 0
			m.st.LastError = ""
			m.st.LastErrorAt = 0
			m.mu.Unlock()
			return
		}
		m.recordError(err)
		m.mu.Lock()
		m.st.ConsecutiveFailures++
		m.st.Pending = true
		failures := m.st.ConsecutiveFailures
		m.mu.Unlock()
		log.Printf("[cloudsync] push 失败（第 %d 次）: %v", failures, err)

		delay := backoff[len(backoff)-1]
		if attempt < len(backoff) {
			delay = backoff[attempt]
		}
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return
		}
	}
	log.Printf("[cloudsync] push 连续 %d 次失败 → 交给 60s 兜底扫描（本地数据完整保留）", maxAttempts)
	m.mu.Lock()
	m.st.Pending = true
	m.mu.Unlock()
}

// pushOnce 真正的一次推送（红线 5.3.4 的落实点）。
//
// ① 必须重新 Export **最新**本地状态 —— 绝不复用上一次的 payload；
// ② POST 首建 / PATCH 后续（row_exists 落盘，避免每次都先 POST 撞 409）；
// ③ 成功后落 dirty=0 / last_push_at / last_remote_exported_at。
func (m *Manager) pushOnce(ctx context.Context) error {
	if !m.Enabled() {
		return errors.New("cloudsync: 未启用")
	}
	if database.DB == nil {
		return errors.New("cloudsync: database 未初始化")
	}

	snap, err := backup.Export(database.DB, backup.ExportOptions{
		Exclude:    m.cfg.ExcludeTables,
		AppVersion: version.App,
	})
	if err != nil {
		return fmt.Errorf("cloudsync: export: %w", err)
	}
	body, err := json.Marshal(snap)
	if err != nil {
		return fmt.Errorf("cloudsync: marshal snapshot: %w", err)
	}

	now := time.Now()
	m.mu.RLock()
	exists := m.st.RowExists
	m.mu.RUnlock()

	if !exists {
		err = m.cli.Create(ctx, body, now)
		if isStatus(err, 409) {
			m.setRowExists(true)
			err = m.cli.Update(ctx, body, now)
		}
	} else {
		err = m.cli.Update(ctx, body, now)
		if isStatus(err, 404) {
			m.setRowExists(false)
			err = m.cli.Create(ctx, body, now)
		}
	}
	if err != nil {
		return err
	}
	m.setRowExists(true)

	// ③ 成功后落状态
	stateSetLogged(keyDirty, "0")
	stateSetIntLogged(keyLastPushAt, now.Unix())
	stateSetIntLogged(keyLastRemoteExportedAt, snap.ExportedAt)

	m.mu.Lock()
	m.pushCount++
	count := m.pushCount
	m.st.PayloadBytes = len(body)
	m.st.LastPushAt = now.Unix()
	m.st.RemoteExportedAt = snap.ExportedAt
	m.st.Pending = false
	m.mu.Unlock()

	log.Printf("[cloudsync] push #%d ok bytes=%d exportedAt=%d", count, len(body), snap.ExportedAt)
	return nil
}

// asyncPush 异步推一次（不阻塞启动/请求路径）。
func (m *Manager) asyncPush() {
	if !m.Enabled() {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(m.cfg.PushTimeoutSec)*time.Second+5*time.Second)
		defer cancel()
		if r := m.PushNow(ctx); r.Error != "" {
			log.Printf("[cloudsync] async push failed: %s", r.Error)
		}
	}()
}

// PushNow 强制推送一次（管理员接口 / 启动 need_push 路径）。
func (m *Manager) PushNow(ctx context.Context) Result {
	res := Result{Action: actionPushed}
	if !m.Enabled() {
		res.Action = actionSkipped
		res.Reason = "disabled"
		return res
	}
	if err := m.pushOnce(ctx); err != nil {
		res.Action = actionFailed
		res.Error = err.Error()
		m.recordError(err)
		return res
	}
	m.mu.RLock()
	res.PayloadBytes = m.st.PayloadBytes
	m.mu.RUnlock()
	res.ExportedAt = stateGetInt(keyLastRemoteExportedAt)
	return res
}

// Flush 退出前最后一次推送（best-effort：只在 dirty==1 / pending 时推）。
func (m *Manager) Flush(ctx context.Context) error {
	if !m.Enabled() {
		return nil
	}
	m.mu.RLock()
	pending := m.st.Pending
	m.mu.RUnlock()
	if !pending && stateGetInt(keyDirty) != 1 {
		log.Printf("[cloudsync] flush: 无未推送的写，跳过")
		return nil
	}
	if err := m.pushOnce(ctx); err != nil {
		return err
	}
	return nil
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

// recordError 落盘 + 内存双写最近一次失败原因（≤256B）。
func (m *Manager) recordError(err error) {
	if err == nil {
		return
	}
	msg := err.Error()
	if len(msg) > 256 {
		msg = msg[:256]
	}
	now := time.Now().Unix()
	m.mu.Lock()
	m.st.LastError = msg
	m.st.LastErrorAt = now
	m.mu.Unlock()
	stateSetLogged(keyLastError, msg)
	stateSetIntLogged(keyLastErrorAt, now)
}

// setRowExists 记录"云端 id=1 行是否存在"，避免每次推送都先 POST 撞 409。
func (m *Manager) setRowExists(exists bool) {
	m.mu.Lock()
	m.st.RowExists = exists
	m.mu.Unlock()
	v := "0"
	if exists {
		v = "1"
	}
	stateSetLogged(keyRowExists, v)
}

// debounce 防抖窗口（配置缺失时回退 1500ms）。
func (m *Manager) debounce() time.Duration {
	return time.Duration(m.debounceMS()) * time.Millisecond
}

func (m *Manager) debounceMS() int {
	if m.cfg.DebounceMS <= 0 {
		return 1500
	}
	return m.cfg.DebounceMS
}

// endpointHost 只取主机名（状态接口不回完整 URL / key）。
func endpointHost(endpoint string) string {
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" {
		// 退化处理：取 "://" 之后到第一个 "/" 之前
		s := strings.TrimSpace(endpoint)
		if i := strings.Index(s, "://"); i >= 0 {
			s = s[i+3:]
		}
		if i := strings.Index(s, "/"); i >= 0 {
			s = s[:i]
		}
		return s
	}
	return u.Host
}
