// Package cloudsync 云端快照同步（有状态服务层）。
//
// 数据流：云 PostgREST finance_snapshot(id=1) ⇄ 本包 ⇄ internal/backup ⇄ SQLite。
//
// 5 条不可动摇的客户端约束（都是实测得来的，不是"最佳实践"）：
//
//	C1 只设两个头：x-wb-webapp-access-key、Content-Type。apikey / Authorization 实测 401。
//	C2 **绝不设置 Origin / Referer** —— 带不匹配 Origin 会被网关 403。Go 默认不发，别手贱。
//	C3 **绝不做 DELETE** —— 网关拒绝（401）。逻辑上是 id=1 单行 upsert（POST 首建 / PATCH 后续）。
//	C4 updated_at 由客户端显式写入 RFC3339 UTC —— 表上没有触发器，不写就永远是旧值。
//	C5 PATCH 返回 204（无 body），只看状态码，不要去解析 body（EOF 会被误判成失败）。
package cloudsync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// maxResponseBytes 单次响应读取上限（快照 200KB~2MB，32MB 足够且能防打爆内存）
const maxResponseBytes = 32 << 20

// Row finance_snapshot 的一行。
type Row struct {
	ID        int64           `json:"id"`
	Payload   json.RawMessage `json:"payload"`
	UpdatedAt string          `json:"updated_at,omitempty"`
}

// HTTPError 带状态码的错误，便于上层用 isStatus 判断 409 / 404。
type HTTPError struct {
	Status int
	Body   string
}

func (e *HTTPError) Error() string {
	body := e.Body
	if len(body) > 200 {
		body = body[:200] + "…"
	}
	return fmt.Sprintf("cloudsync: http %d: %s", e.Status, body)
}

// isStatus 判断 err 是否为指定 HTTP 状态码。
func isStatus(err error, status int) bool {
	var he *HTTPError
	if errors.As(err, &he) {
		return he.Status == status
	}
	return false
}

// Client PostgREST 客户端（只做 GET / POST / PATCH）。
type Client struct {
	endpoint   string // .../rest/finance_snapshot（已含表名，不含 query）
	apiKey     string
	snapshotID int64
	http       *http.Client
}

// newClient 构造客户端。timeout 为整次请求的超时（单次推送 5s 上限）。
func newClient(endpoint, apiKey string, snapshotID int64, timeout time.Duration) *Client {
	if snapshotID <= 0 {
		snapshotID = 1
	}
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Client{
		endpoint:   endpoint,
		apiKey:     apiKey,
		snapshotID: snapshotID,
		http:       &http.Client{Timeout: timeout},
	}
}

// applyHeaders 只设 C1 允许的两个头（+ Accept，便于拿到 JSON 错误体做诊断）。
// 注意这里**没有** Origin / Referer / apikey / Authorization，都是故意的。
func (c *Client) applyHeaders(req *http.Request) {
	req.Header.Set("x-wb-webapp-access-key", c.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
}

// Get 读单行。返回 (nil, nil, nil) 表示远端不存在（404 / 空数组）。
func (c *Client) Get(ctx context.Context) (*Row, []byte, error) {
	url := fmt.Sprintf("%s?id=eq.%d&select=id,payload,updated_at", c.endpoint, c.snapshotID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, nil, err
	}
	c.applyHeaders(req)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, nil, err
	}
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, nil, &HTTPError{Status: resp.StatusCode, Body: string(body)}
	}

	var rows []Row
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, nil, fmt.Errorf("cloudsync: 解析 GET 响应失败: %w", err)
	}
	if len(rows) == 0 {
		return nil, nil, nil
	}
	return &rows[0], rows[0].Payload, nil
}

// createBody POST 请求体（id 显式指定，便于测试用 snapshotId=999 而不污染线上）。
type createBody struct {
	ID        int64           `json:"id"`
	Payload   json.RawMessage `json:"payload"`
	UpdatedAt string          `json:"updated_at"`
}

// updateBody PATCH 请求体（不写 id：id 在 URL 过滤条件里）。
type updateBody struct {
	Payload   json.RawMessage `json:"payload"`
	UpdatedAt string          `json:"updated_at"`
}

// Create POST 首建。行已存在时 PostgREST 返回 409（由上层转 PATCH）。
func (c *Client) Create(ctx context.Context, payload []byte, now time.Time) error {
	body, err := json.Marshal(createBody{
		ID:        c.snapshotID,
		Payload:   json.RawMessage(payload),
		UpdatedAt: now.UTC().Format(time.RFC3339), // C4：客户端显式写
	})
	if err != nil {
		return fmt.Errorf("cloudsync: 序列化 POST body 失败: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	c.applyHeaders(req)
	// Prefer: return=minimal —— 不要求回传整行，响应更小
	req.Header.Set("Prefer", "return=minimal")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &HTTPError{Status: resp.StatusCode, Body: string(respBody)}
	}
	return nil
}

// Update PATCH ?id=eq.N，成功返回 204（无 body）。C5：只认状态码。
func (c *Client) Update(ctx context.Context, payload []byte, now time.Time) error {
	url := fmt.Sprintf("%s?id=eq.%d", c.endpoint, c.snapshotID)
	body, err := json.Marshal(updateBody{
		Payload:   json.RawMessage(payload),
		UpdatedAt: now.UTC().Format(time.RFC3339), // C4
	})
	if err != nil {
		return fmt.Errorf("cloudsync: 序列化 PATCH body 失败: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPatch, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	c.applyHeaders(req)
	req.Header.Set("Prefer", "return=minimal")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	// 204 无 body；即便有也读掉以便连接复用，但不解析（C5）
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &HTTPError{Status: resp.StatusCode, Body: string(respBody)}
	}
	return nil
}
