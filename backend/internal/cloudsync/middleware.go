package cloudsync

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// excludedWritePushPaths 写操作里**不触发**快照推送的路径前缀。
//
// 这些要么是纯日志、要么是"丢了无所谓"的状态位、要么会自激（sync 接口自己管推送）。
// 注意：/api/admin/backup/restore 是**真正的数据写入**，必须触发推送，不能排除；
// /api/admin/backup 的导出是 GET，已被 method 判断挡掉，不需要在这里列。
var excludedWritePushPaths = []string{
	"/api/errors",        // 纯日志上报
	"/api/auth/login",    // 只更新 last_login_at，不必为它推 200KB
	"/api/auth/refresh",  // 同上
	"/api/notifications", // 已读状态，丢了无所谓；避免"读一条通知推一次全量"
	"/api/admin/sync",    // 防自激（sync/push、sync/pull 自己会管推送）
}

// Middleware 捕获业务写操作 → MarkDirty。
//
// 判定：method 不是 GET/HEAD/OPTIONS + 状态码 < 400 + 路径以 /api/ 开头 + 不在排除清单。
// 只打一个内存标记（非阻塞），真正的序列化与网络全在后台 goroutine 里做 ——
// 绝不能让 200KB 序列化 + 0.4s 网络拖慢用户请求（DESIGN §1.1 D2）。
func (m *Manager) Middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()

		if !m.Enabled() {
			return
		}
		switch c.Request.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			return
		}
		if c.Writer.Status() >= 400 {
			return // 失败的写没有落到库里，不该推
		}
		path := c.Request.URL.Path
		if !strings.HasPrefix(path, "/api/") {
			return
		}
		for _, p := range excludedWritePushPaths {
			if strings.HasPrefix(path, p) {
				return
			}
		}
		m.MarkDirty(c.Request.Method + " " + path)
	}
}
