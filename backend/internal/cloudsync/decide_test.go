package cloudsync

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/backup"
)

// 本文件是"数据不丢"核心逻辑的回归保护：
//   - decide()              判定表 P0–P9（谁覆盖谁）
//   - parseSnapshotPayload 云端 payload 的合法/损坏判定（红线 5.3.3）
//   - Middleware()         写操作 → MarkDirty 的边界
//   - Client               PostgREST 只 GET/POST/PATCH、只发 x-wb-webapp-access-key、不发 Origin
//
// 全部用例都不访问真实网络：需要 endpoint 的地方一律指向 httptest。

// newTestManager 造一个 Manager：enabled=true 时带一个指向 httptest 的客户端。
//
// 用 httptest 而不是 example.invalid 的原因：任何代码路径若真的发起请求，
// 只会打到本机测试服务器，不会在 CI 里卡 DNS 超时、也绝不会碰到线上 id=1。
func newTestManager(t *testing.T, enabled bool) *Manager {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, "[]")
	}))
	t.Cleanup(srv.Close)

	cfg := config.CloudSyncConfig{
		Enabled:        enabled,
		Endpoint:       srv.URL + "/.cloud/database/rest/finance_snapshot",
		APIKey:         "test-key",
		SnapshotID:     1,
		DebounceMS:     1500,
		PushTimeoutSec: 1,
		ExcludeTables:  []string{"audit_logs", "error_reports"},
	}
	m := &Manager{cfg: cfg, kick: make(chan struct{}, kickBuffer)}
	if enabled {
		m.cli = newClient(cfg.Endpoint, cfg.APIKey, cfg.SnapshotID, time.Second)
		m.st.Enabled = true
	}
	return m
}

// snapOf 造一个快照：counts 与 tables 保持自洽（usersRowCount 两条来源都要对）。
func snapOf(exportedAt, users, txs int64) *backup.Snapshot {
	usersRaw := json.RawMessage(`[]`)
	if users > 0 {
		usersRaw = json.RawMessage(`[{"id":1,"username":"alice","passwordHash":"` + strings.Repeat("x", 60) + `"}]`)
	}
	txsRaw := json.RawMessage(`[]`)
	if txs > 0 {
		txsRaw = json.RawMessage(`[{"id":1,"amount":12.34}]`)
	}
	return &backup.Snapshot{
		SchemaVersion: backup.SchemaVersion,
		ExportedAt:    exportedAt,
		Counts:        map[string]int64{"users": users, "transactions": txs},
		Tables: map[string]json.RawMessage{
			"users":        usersRaw,
			"transactions": txsRaw,
		},
	}
}

// TestDecide 判定表 P0–P9：**顺序命中即返回**，顺序错了就是数据被覆盖。
func TestDecide(t *testing.T) {
	healthy := snapOf(300, 2, 10)

	cases := []struct {
		name       string
		enabled    bool
		snap       *backup.Snapshot
		local      LocalState
		wantAction PullAction
		wantReason string
	}{
		{
			name:    "P0 未启用 → 不动本地",
			enabled: false, snap: healthy,
			local:      LocalState{HasBusiness: true, LastLocalWriteAt: 100},
			wantAction: PullSkipped, wantReason: "disabled",
		},
		{
			name:    "P5 dirty=1 优先于云端更新",
			enabled: true, snap: healthy,
			local:      LocalState{Dirty: 1, HasBusiness: true, LastLocalWriteAt: 100},
			wantAction: PullNeedPush, wantReason: "local dirty",
		},
		{
			name:    "P5 dirty=1 且快照损坏也先推本地（不被覆盖）",
			enabled: true, snap: nil,
			local:      LocalState{Dirty: 1, HasBusiness: true},
			wantAction: PullNeedPush, wantReason: "local dirty",
		},
		{
			name:    "P5 dirty=1 且本地为空也先推本地（落盘标记不可越过）",
			enabled: true, snap: healthy,
			local:      LocalState{Dirty: 1},
			wantAction: PullNeedPush, wantReason: "local dirty",
		},
		{
			name:    "P3 快照为 nil → corrupt，不动本地",
			enabled: true, snap: nil,
			local:      LocalState{HasBusiness: true},
			wantAction: PullSkipped, wantReason: "snapshot corrupt",
		},
		{
			name:       "P3 快照 tables 为空 → corrupt，不动本地",
			enabled:    true,
			snap:       &backup.Snapshot{ExportedAt: 300, Counts: map[string]int64{"users": 5}},
			local:      LocalState{HasBusiness: true},
			wantAction: PullSkipped, wantReason: "snapshot corrupt",
		},
		{
			name:    "P4 快照没有 users → 不覆盖（否则谁都登不进）",
			enabled: true, snap: snapOf(300, 0, 10),
			local:      LocalState{HasBusiness: true},
			wantAction: PullSkipped, wantReason: "snapshot has no users",
		},
		{
			name:    "P6 本地没有业务数据 → 云端覆盖（首次部署/空库）",
			enabled: true, snap: healthy,
			local:      LocalState{HasBusiness: false},
			wantAction: PullReplaced, wantReason: "local empty",
		},
		{
			name:    "P7 exportedAt 相同 → 已同步，不动本地",
			enabled: true, snap: healthy,
			local:      LocalState{HasBusiness: true, LastRemoteExportedAt: 300, LastLocalWriteAt: 100},
			wantAction: PullSkipped, wantReason: "already in sync",
		},
		{
			name:    "P8 云端比本地写更旧 → 推本地",
			enabled: true, snap: snapOf(100, 2, 10),
			local:      LocalState{HasBusiness: true, LastLocalWriteAt: 200},
			wantAction: PullNeedPush, wantReason: "remote older than local write",
		},
		{
			name:    "P9 云端更新 → 覆盖本地",
			enabled: true, snap: snapOf(300, 2, 10),
			local:      LocalState{HasBusiness: true, LastRemoteExportedAt: 100, LastLocalWriteAt: 200},
			wantAction: PullReplaced, wantReason: "remote newer",
		},
		{
			name:    "P9 last_local_write_at==0 → 云端为准（部署快照库场景）",
			enabled: true, snap: snapOf(300, 2, 10),
			local:      LocalState{HasBusiness: true, LastLocalWriteAt: 0},
			wantAction: PullReplaced, wantReason: "remote newer",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestManager(t, tc.enabled)
			gotAction, gotReason := m.decide(tc.snap, tc.local)
			if gotAction != tc.wantAction || gotReason != tc.wantReason {
				t.Fatalf("decide() = (%s, %q)，期望 (%s, %q)",
					gotAction, gotReason, tc.wantAction, tc.wantReason)
			}
		})
	}
}

// TestDecideDirtyBeatsCorruptAndNewerExplicitly 单独强调一次最容易写反的一条：
// dirty 闸门必须在 P3（损坏）与 P7/P8/P9（新旧比较）之前。
func TestDecideDirtyBeatsCorruptAndNewerExplicitly(t *testing.T) {
	m := newTestManager(t, true)

	if a, r := m.decide(snapOf(999999, 2, 10), LocalState{Dirty: 1, HasBusiness: true}); a != PullNeedPush {
		t.Fatalf("云端更新但本地 dirty → 必须 need_push，实际 %s/%s", a, r)
	}
	if a, r := m.decide(nil, LocalState{Dirty: 1}); a != PullNeedPush {
		t.Fatalf("快照损坏但本地 dirty → 必须 need_push，实际 %s/%s", a, r)
	}
}

// TestParseSnapshotPayload 云端 payload 的合法/损坏判定。
// 关键口径（主理人确认）：空 payload / 没有 tables → 视为"无快照"，绝不能当"空库"导入。
func TestParseSnapshotPayload(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantErr bool
		wantTS  int64
	}{
		{name: "空字节 → 无快照", raw: ``, wantErr: true},
		{name: "空白字符 → 无快照", raw: "  \n\t ", wantErr: true},
		{name: "null → 无快照", raw: `null`, wantErr: true},
		{name: "空对象 {} → 无快照", raw: `{}`, wantErr: true},
		{name: "没有 tables 字段 → 无快照", raw: `{"exportedAt":123,"counts":{"users":2}}`, wantErr: true},
		{name: "tables 为空对象 → 无快照", raw: `{"exportedAt":123,"tables":{}}`, wantErr: true},
		{name: "损坏 JSON（截断）→ 错误", raw: `{"tables":`, wantErr: true},
		{name: "损坏 JSON（tables 不是对象）→ 错误", raw: `{"tables":[1,2,3]}`, wantErr: true},
		{
			name:   "合法快照 → 解析成功",
			raw:    `{"schemaVersion":2,"exportedAt":1794193712,"counts":{"users":5},"tables":{"users":[{"id":1}]}}`,
			wantTS: 1794193712,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			snap, err := parseSnapshotPayload(json.RawMessage(tc.raw))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("期望返回错误，实际成功且 snap=%+v", snap)
				}
				if snap != nil {
					t.Fatalf("出错时不应返回半截快照，实际 %+v", snap)
				}
				return
			}
			if err != nil {
				t.Fatalf("期望成功，实际错误: %v", err)
			}
			if snap == nil || snap.ExportedAt != tc.wantTS {
				t.Fatalf("exportedAt = %v，期望 %d", snap, tc.wantTS)
			}
		})
	}
}

// TestCorruptPayloadNeverClearsLocal 损坏/空 payload 在 pull 链路上**绝不能**走到 replaced，
// 只能"什么都不做"或"把本地推上去"（红线 5.3.3 / 5.3.4）。
func TestCorruptPayloadNeverClearsLocal(t *testing.T) {
	m := newTestManager(t, true)

	snap, err := parseSnapshotPayload(json.RawMessage(`{"tables":`))
	if err == nil || snap != nil {
		t.Fatalf("损坏 payload 必须解析失败，实际 snap=%+v err=%v", snap, err)
	}

	// 本地为空：不导入、不推送
	if r := m.handleNoSnapshot(LocalState{HasBusiness: false}, "payload has no snapshot content"); r.Action != actionSkipped {
		t.Fatalf("本地为空时应 skipped，实际 %s", r.Action)
	}
	// 本地有数据：改为推本地（绝不覆盖）
	if r := m.handleNoSnapshot(LocalState{HasBusiness: true}, "payload has no snapshot content"); r.Action != actionNeedPush {
		t.Fatalf("本地有数据时应 need_push，实际 %s", r.Action)
	}
}

// TestMiddlewareMarksDirty 中间件边界：只有"非幂等方法 + 成功(<400) + /api/ 前缀 + 不在排除清单"
// 才 MarkDirty；否则会为纯日志/已读状态反复推 200KB，甚至自激。
func TestMiddlewareMarksDirty(t *testing.T) {
	gin.SetMode(gin.TestMode)

	cases := []struct {
		name        string
		method      string
		path        string
		status      int
		wantPending bool
	}{
		{"POST 成功写 → dirty", http.MethodPost, "/api/transactions", 200, true},
		{"PUT 成功写 → dirty", http.MethodPut, "/api/transactions/1", 200, true},
		{"DELETE 成功 → dirty", http.MethodDelete, "/api/transactions/1", 200, true},
		{"POST restore 成功 → dirty（必须推）", http.MethodPost, "/api/admin/backup/restore", 200, true},
		{"POST 失败 400 → 不 dirty", http.MethodPost, "/api/transactions", 400, false},
		{"POST 失败 500 → 不 dirty", http.MethodPost, "/api/transactions", 500, false},
		{"GET → 不 dirty", http.MethodGet, "/api/transactions", 200, false},
		{"HEAD → 不 dirty", http.MethodHead, "/api/transactions", 200, false},
		{"POST /api/errors 排除（纯日志）", http.MethodPost, "/api/errors", 200, false},
		{"POST /api/auth/login 排除（只改 last_login_at）", http.MethodPost, "/api/auth/login", 200, false},
		{"POST /api/notifications 排除（已读状态）", http.MethodPost, "/api/notifications/1/read", 200, false},
		{"POST /api/admin/sync/push 排除（防自激）", http.MethodPost, "/api/admin/sync/push", 200, false},
		{"非 /api 路径（/healthz）→ 不 dirty", http.MethodPost, "/healthz", 200, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestManager(t, true)
			r := gin.New()
			r.Use(m.Middleware())
			r.Handle(tc.method, tc.path, func(c *gin.Context) { c.Status(tc.status) })

			rec := httptest.NewRecorder()
			req := httptest.NewRequest(tc.method, tc.path, nil)
			r.ServeHTTP(rec, req)

			if got := m.Status().Pending; got != tc.wantPending {
				t.Fatalf("Pending = %v，期望 %v（%s %s → %d）",
					got, tc.wantPending, tc.method, tc.path, tc.status)
			}
		})
	}
}

// TestMiddlewareDisabledNoop 未启用同步时中间件必须是纯 no-op（不能有副作用、不能 panic）。
func TestMiddlewareDisabledNoop(t *testing.T) {
	gin.SetMode(gin.TestMode)
	m := newTestManager(t, false)

	r := gin.New()
	r.Use(m.Middleware())
	r.POST("/api/transactions", func(c *gin.Context) { c.Status(http.StatusOK) })

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/transactions", nil))

	if m.Status().Pending {
		t.Fatal("未启用同步时不应 MarkDirty")
	}
}

// TestClientGetAndRequestShape 客户端契约：GET 的三种结果 + 请求头/动词硬约束。
//
//   - 200 空数组 / 404 → (nil, nil, nil)，表示"远端没有快照"
//   - 200 有行 → 返回 payload
//   - 5xx → 带状态码的 HTTPError（上层据此不导入、不回写）
//   - **绝不发 Origin**（带不匹配 Origin 会被网关 403）、只发 x-wb-webapp-access-key
//   - **绝不做 DELETE**
func TestClientGetAndRequestShape(t *testing.T) {
	type serverReply struct {
		status int
		body   string
	}
	cases := []struct {
		name     string
		reply    serverReply
		wantNil  bool
		wantErr  bool
		wantTS   int64
		wantCode int
	}{
		{name: "200 空数组 → 远端没有快照", reply: serverReply{200, `[]`}, wantNil: true},
		{name: "404 → 远端没有快照", reply: serverReply{404, `{}`}, wantNil: true},
		{name: "200 有一行 → 返回 payload", reply: serverReply{200, `[{"id":1,"payload":{"exportedAt":1794193712}}]`}, wantTS: 1794193712},
		{name: "500 → 错误（不导入、不回写）", reply: serverReply{500, `{"message":"boom"}`}, wantNil: true, wantErr: true, wantCode: 500},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var (
				sawKey    string
				sawOrigin string
				sawMethod string
				sawPath   string
				sawQuery  string
			)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				sawKey = r.Header.Get("x-wb-webapp-access-key")
				sawOrigin = r.Header.Get("Origin")
				sawMethod = r.Method
				sawPath = r.URL.Path
				sawQuery = r.URL.RawQuery
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.reply.status)
				_, _ = io.WriteString(w, tc.reply.body)
			}))
			defer srv.Close()

			c := newClient(srv.URL+"/.cloud/database/rest/finance_snapshot", "test-key", 7, 2*time.Second)
			row, raw, err := c.Get(context.Background())

			if sawMethod != http.MethodGet {
				t.Fatalf("Get 必须用 GET，实际 %s", sawMethod)
			}
			if sawKey != "test-key" {
				t.Fatalf("必须带 x-wb-webapp-access-key，实际 %q", sawKey)
			}
			if sawOrigin != "" {
				t.Fatalf("绝不能发 Origin（会被网关 403），实际 %q", sawOrigin)
			}
			if !strings.Contains(sawQuery, "id=eq.7") {
				t.Fatalf("query 必须按 snapshotId 过滤，实际 %q", sawQuery)
			}
			if sawPath != "/.cloud/database/rest/finance_snapshot" {
				t.Fatalf("路径不对: %s", sawPath)
			}

			if tc.wantErr {
				if err == nil {
					t.Fatal("期望返回错误")
				}
				if tc.wantCode != 0 && !isStatus(err, tc.wantCode) {
					t.Fatalf("期望 HTTP %d 的 HTTPError，实际 %v", tc.wantCode, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("期望成功，实际错误: %v", err)
			}
			if tc.wantNil {
				if row != nil || raw != nil {
					t.Fatalf("期望 (nil, nil)，实际 row=%+v raw=%s", row, string(raw))
				}
				return
			}
			if row == nil || len(raw) == 0 {
				t.Fatal("期望返回 payload")
			}
			var snap backup.Snapshot
			if err := json.Unmarshal(raw, &snap); err != nil {
				t.Fatalf("payload 不是合法 JSON: %v", err)
			}
			if snap.ExportedAt != tc.wantTS {
				t.Fatalf("exportedAt = %d，期望 %d", snap.ExportedAt, tc.wantTS)
			}
		})
	}
}

// TestClientWriteVerbs Create=POST / Update=PATCH，且从不 DELETE（网关拒绝 DELETE）。
func TestClientWriteVerbs(t *testing.T) {
	var methods []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		if r.Header.Get("Origin") != "" {
			t.Errorf("写请求也不能带 Origin，实际 %q", r.Header.Get("Origin"))
		}
		if r.Header.Get("x-wb-webapp-access-key") != "test-key" {
			t.Errorf("写请求缺少 x-wb-webapp-access-key")
		}
		body, _ := io.ReadAll(r.Body)
		var payload struct {
			ID        int64           `json:"id"`
			Payload   json.RawMessage `json:"payload"`
			UpdatedAt string          `json:"updated_at"`
		}
		if len(body) > 0 {
			if err := json.Unmarshal(body, &payload); err != nil {
				t.Errorf("请求体不是合法 JSON: %v", err)
			}
			// C4：updated_at 必须由客户端显式写入（表上没有触发器）
			if payload.UpdatedAt == "" {
				t.Errorf("请求体缺少 updated_at（会造成 updated_at 永远是旧值）")
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := newClient(srv.URL+"/snapshot", "test-key", 1, 2*time.Second)
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	if err := c.Create(context.Background(), []byte(`{"exportedAt":1}`), now); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := c.Update(context.Background(), []byte(`{"exportedAt":2}`), now); err != nil {
		t.Fatalf("Update: %v", err)
	}

	want := []string{http.MethodPost, http.MethodPatch}
	if len(methods) != len(want) {
		t.Fatalf("请求次数 = %d，期望 %d（methods=%v）", len(methods), len(want), methods)
	}
	for i := range want {
		if methods[i] != want[i] {
			t.Fatalf("第 %d 个请求方法 = %s，期望 %s", i+1, methods[i], want[i])
		}
	}
	for _, m := range methods {
		if m == http.MethodDelete {
			t.Fatal("客户端绝不能发 DELETE（网关 401）")
		}
	}
}
