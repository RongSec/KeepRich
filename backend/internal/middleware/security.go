package middleware

import (
	"github.com/gin-gonic/gin"
)

// SecurityHeaders 安全响应头：防止 MIME 嗅探、点击劫持、信息泄露
// Web 端（admin / Flutter Web）与移动端 API 都经过这里
func SecurityHeaders() gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("X-XSS-Protection", "0") // 现代浏览器不再需要，反而会引入问题
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "geolocation=(), microphone=(), camera=(), payment=()")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")

		// CSP 不在响应头里发：Flutter Web 的资源策略（canvaskit 引擎从 gstatic
		// 加载、wasm 编译需要 'wasm-unsafe-eval'、flutter_bootstrap 内联脚本需要
		// 'unsafe-inline'）会随构建变化，写死在响应头里必然过严，曾把整个 Web
		// 卡死在加载占位上。CSP 交给 Web 入口页的 <meta> 按需声明。

		// 仅在 HTTPS 下声明 HSTS，避免本地 http 调试被误伤
		if c.Request.TLS != nil || c.GetHeader("X-Forwarded-Proto") == "https" {
			h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		c.Next()
	}
}
