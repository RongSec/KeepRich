package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/utils"
)

const (
	CtxUID  = "ctxUID"
	CtxRole = "ctxRole"
)

// JWT 鉴权中间件
// WebSocket 端点（/ws）额外支持 ?token= 查询参数（浏览器 WebSocket 无法设置 Authorization 头）
func JWT() gin.HandlerFunc {
	return func(c *gin.Context) {
		auth := c.GetHeader("Authorization")
		tokenStr := ""
		if auth == "" {
			// 仅对 WS 端点允许 query token，避免 token 进 URL 被日志记录的面扩大
			if strings.HasSuffix(c.Request.URL.Path, "/ws") {
				tokenStr = c.Query("token")
			}
			if tokenStr == "" {
				utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "missing authorization")
				c.Abort()
				return
			}
		} else {
			parts := strings.SplitN(auth, " ", 2)
			if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
				utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "invalid authorization format")
				c.Abort()
				return
			}
			tokenStr = parts[1]
		}
		claims, err := utils.ParseToken(tokenStr, config.C.JWT.AccessSecret)
		if err != nil {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "invalid or expired token")
			c.Abort()
			return
		}
		if claims.TokenType != utils.TokenTypeAccess {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "token type mismatch")
			c.Abort()
			return
		}
		c.Set(CtxUID, claims.UID)
		c.Set(CtxRole, claims.Role)
		c.Next()
	}
}

func MustUID(c *gin.Context) uint64 {
	v, _ := c.Get(CtxUID)
	if uid, ok := v.(uint64); ok {
		return uid
	}
	return 0
}

func MustRole(c *gin.Context) string {
	v, _ := c.Get(CtxRole)
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// AdminOnly 仅系统管理员
func AdminOnly() gin.HandlerFunc {
	return func(c *gin.Context) {
		if MustRole(c) != "admin" {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "admin only")
			c.Abort()
			return
		}
		c.Next()
	}
}
