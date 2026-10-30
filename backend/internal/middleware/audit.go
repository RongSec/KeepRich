package middleware

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
)

// sensitiveKeys 审计日志中必须脱敏的 JSON 字段（大小写不敏感子串匹配）
var sensitiveKeys = []string{"password", "secret", "token", "code", "otp", "backup"}

// sanitizeDetail 脱敏审计详情：JSON 中的敏感字段值替换为 "***"
func sanitizeDetail(raw []byte) string {
	detail := string(raw)
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err == nil {
		for k := range m {
			lk := strings.ToLower(k)
			for _, s := range sensitiveKeys {
				if strings.Contains(lk, s) {
					m[k] = "***"
					break
				}
			}
		}
		if b, err := json.Marshal(m); err == nil {
			detail = string(b)
		}
	}
	if len(detail) > 1000 {
		detail = detail[:1000]
	}
	return detail
}

// bodyWriter 包装 ResponseWriter 以便在 c.Next() 后读取响应
type bodyWriter struct {
	gin.ResponseWriter
	buf *bytes.Buffer
}

func (w *bodyWriter) Write(b []byte) (int, error) {
	w.buf.Write(b)
	return w.ResponseWriter.Write(b)
}

// 简化结构：path + 可选 suffix
type rule struct {
	path   string
	suffix string
	action string
}

var rules = []rule{
	{"/api/auth/login", "", "auth.login"},
	{"/api/auth/refresh", "", "auth.refresh"},
	{"/api/mfa/enable", "", "mfa.enable"},
	{"/api/mfa/disable", "", "mfa.disable"},
	{"/api/family", "", "family.create"},
	{"/api/family/join", "", "family.apply_join"},
	{"/api/family/approve", "", "family.approve"},
	{"/api/family/transfer", "", "family.transfer_admin"},
	{"/api/family/bind-forever", "", "family.bind_forever"},
	{"/api/family/delete/", "", "family.cancel_delete"}, // /api/family/delete/:id/cancel
	{"/api/family/delete", "", "family.request_delete"},
	{"/api/transactions", "", "tx.create"},
	{"/api/transactions/", "", "tx.delete"},
	{"/api/purchase-plans/check", "", "purchase.check"},
	{"/api/purchase-plans", "", "purchase.create"},
	{"/api/purchase-plans/", "", "purchase.delete"},
	{"/api/plan", "", "plan.save"},
	{"/api/investments", "", "investment.upsert"},
	{"/api/profile/password", "", "profile.change_password"},
	{"/api/profile", "", "profile.update"},
	{"/api/errors", "", "client.report_error"},
	{"/api/admin/users", "/reset-password", "admin.reset_password"},
	{"/api/admin/users", "/reset-mfa", "admin.reset_mfa"},
	{"/api/admin/users", "/toggle", "admin.toggle_user"},
	{"/api/admin/users", "", "admin.create_user"},
	{"/api/admin/families", "", "admin.delete_family"}, // /api/admin/families/:id
}

// Audit 通用审计中间件
func Audit() gin.HandlerFunc {
	return func(c *gin.Context) {
		// 读取 body 但不消费下游（限 1MB，防止超大 body 打爆内存）
		var bodyBytes []byte
		if c.Request.Body != nil {
			bodyBytes, _ = io.ReadAll(io.LimitReader(c.Request.Body, 1<<20))
			c.Request.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		}

		bw := &bodyWriter{ResponseWriter: c.Writer, buf: &bytes.Buffer{}}
		c.Writer = bw

		start := time.Now()
		c.Next()
		_ = time.Since(start)

		method := c.Request.Method
		path := c.Request.URL.Path
		uid := MustUID(c)
		role := MustRole(c)

		// 跳过 GET / OPTIONS / HEAD
		if method == "GET" || method == "OPTIONS" || method == "HEAD" {
			return
		}

		// 命中规则
		action := matchAction(path)
		if action == "" {
			return
		}

		username := ""
		if uid > 0 {
			var u models.User
			if err := database.DB.Select("username").First(&u, uid).Error; err == nil {
				username = u.Username
			}
		}

		status := "ok"
		if c.Writer.Status() >= 400 {
			status = "fail"
		}
		_ = role

		detail := sanitizeDetail(bodyBytes)

		entry := models.AuditLog{
			UID:       uid,
			Username:  username,
			Action:    action,
			Target:    path,
			IP:        c.ClientIP(),
			UserAgent: c.Request.UserAgent(),
			Status:    status,
			Detail:    detail,
		}
		// 异步写入，避免影响主流程
		go func(l models.AuditLog) {
			database.DB.Create(&l)
		}(entry)
	}
}

func matchAction(path string) string {
	// 精确匹配优先
	for _, r := range rules {
		if r.suffix == "" && r.path == path {
			return r.action
		}
	}
	// 后缀匹配：path 开头 == r.path && path 结尾 == r.suffix
	for _, r := range rules {
		if r.suffix == "" {
			continue
		}
		if strings.HasPrefix(path, r.path) && strings.HasSuffix(path, r.suffix) {
			return r.action
		}
	}
	// 前缀匹配：path 开头 == r.path 且为完整段
	for _, r := range rules {
		if r.suffix != "" {
			continue
		}
		if strings.HasPrefix(path, r.path+"/") {
			return r.action
		}
	}
	return ""
}
