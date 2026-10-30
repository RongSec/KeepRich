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
func JWT() gin.HandlerFunc {
	return func(c *gin.Context) {
		auth := c.GetHeader("Authorization")
		if auth == "" {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "missing authorization")
			c.Abort()
			return
		}
		parts := strings.SplitN(auth, " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "invalid authorization format")
			c.Abort()
			return
		}
		claims, err := utils.ParseToken(parts[1], config.C.JWT.AccessSecret)
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
