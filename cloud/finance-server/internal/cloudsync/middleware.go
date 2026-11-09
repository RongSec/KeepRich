package cloudsync

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// excludedWritePushPaths 写操作里**完全不触发**快照推送的路径前缀。
//
// 这些要么是纯日志、要么是"丢了无所谓"的状态位、要么会自激（sync 接口自己管推送）。
// 注意：/api/admin/backup/restore 是**真正的数据写入**，必须触发推送，不能排除；
// /api/admin/backup 的导出是 GET，已被 method 判断挡掉，不需要在这里列。
var excludedWritePushPaths = []string{
	"/api/errors",        // 纯日志上报
	"/api/notifications", // 已读状态，丢了无所谓；避免"读一条通知推一次全量"
	"/api/admin/sync",    // 防自激（sync/push、sync/pull 自己会管推送）
}

// softWritePushPaths 登录/刷新类写：只影响会话与设备表，走 MarkDirtySoft 节流推送。
//
// v0.5.0 起 access 15 分钟过期会静默 refresh，若按 hard 走就会出现
// 「每天 ~96 次 200KB 全量 PATCH」的推送风暴（DESIGN F10 / §A.6）。
// ⚠️ /api/auth/register **不在此列**：新用户行 + 邀请码 used_count 必须 hard 落云，
// 否则重启后配额回退、一次性邀请码可被复用。
var softWritePushPaths = []string{
	"/api/auth/login",
	"/api/auth/refresh",
	"/api/auth/device-login",
	"/api/auth/logout",
}

// Middleware 捕获业务写操作 → MarkDirty（hard）或 MarkDirtySoft（节流）。
//
// 判定：method 不是 GET/HEAD/OPTIONS + 状态码 < 400 + 路径以 /api/ 开头 + 不在排除清单。
// 只打一个内存标记（非阻塞），真正的序列化与网络全在后台 goroutine 里做。
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
		normalized := strings.TrimSuffix(path, "/")
		for _, p := range softWritePushPaths {
			if normalized == p {
				m.MarkDirtySoft(c.Request.Method + " " + path)
				return
			}
		}
		m.MarkDirty(c.Request.Method + " " + path)
	}
}
