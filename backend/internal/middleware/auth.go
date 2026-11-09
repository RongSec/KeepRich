package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/auth"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

const (
	CtxUID  = "ctxUID"
	CtxRole = "ctxRole"
	CtxSID  = "ctxSID" // v0.5.0：会话标识，供 logout / 设备列表 / 撤销使用
)

// JWT 鉴权中间件（v0.5.0）。
//
// WebSocket 端点（/ws）额外支持 ?token= 查询参数（浏览器 WebSocket 无法设置 Authorization 头）。
//
// 两条分支（DESIGN §A.5 / §8.2 Q2）：
//   - sid == "": v0.4.1 老 access，只查 users 校验 tokenVersion，不查会话表；
//     老 token 最多 15 分钟自然消失，升级期不踢人。
//   - sid != "": 查会话态 → 撤销 40111 / 闲置 40110 / tokenVersion 失效 40111 → Touch 放行。
//
// 所有失败文案全中文，绝不出现英文/异常类名/HTTP 状态码（DESIGN §7.3）。
func JWT() gin.HandlerFunc {
	return func(c *gin.Context) {
		// 云托管网关会用自家 JWT 覆盖 Authorization 头（实测确认），
		// 所以自定义头 X-Finance-Token 优先 —— App 端两个头都发，谁真用谁。
		authHeader := c.GetHeader("X-Finance-Token")
		if authHeader == "" {
			authHeader = c.GetHeader("Authorization")
		}
		tokenStr := ""
		if authHeader == "" {
			// 仅对 WS 端点允许 query token，避免 token 进 URL 被日志记录的面扩大
			if strings.HasSuffix(c.Request.URL.Path, "/ws") {
				tokenStr = c.Query("token")
			}
			if tokenStr == "" {
				utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgTokenInvalid)
				c.Abort()
				return
			}
		} else {
			trimmed := strings.TrimSpace(authHeader)
			if len(trimmed) >= 7 && strings.EqualFold(trimmed[:7], "Bearer ") {
				tokenStr = strings.TrimSpace(trimmed[7:])
			} else {
				tokenStr = trimmed
			}
			if tokenStr == "" {
				utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgTokenInvalid)
				c.Abort()
				return
			}
		}
		claims, err := utils.ParseToken(tokenStr, config.C.JWT.AccessSecret)
		if err != nil || claims.TokenType != utils.TokenTypeAccess {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgTokenInvalid)
			c.Abort()
			return
		}

		if claims.SessionID == "" {
			// legacy：老客户端 access，保持 v0.4.1 语义（不查会话表、不轮换）
			if database.DB != nil {
				var u models.User
				if err := database.DB.First(&u, claims.UID).Error; err != nil {
					utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgTokenInvalid)
					c.Abort()
					return
				}
				if u.Disabled {
					utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, utils.MsgAccountDisabled)
					c.Abort()
					return
				}
				if u.TokenVersion != claims.TokenVersion {
					utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
					c.Abort()
					return
				}
			}
		} else {
			st := auth.R().Get(claims.SessionID)
			if !st.Found || st.Revoked {
				utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
				c.Abort()
				return
			}
			if st.Idle {
				// 24h 严格 0 容差：判闲置的同时撤销，避免同一会话反复触发
				auth.Sessions().Revoke(claims.SessionID, auth.ReasonIdle)
				utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionIdle, utils.MsgSessionIdle)
				c.Abort()
				return
			}
			if st.TokenVersion != claims.TokenVersion {
				utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
				c.Abort()
				return
			}
			// 活跃续期只改内存，60s 合并刷盘，绝不每请求写库（F8）
			auth.R().Touch(claims.SessionID)
		}

		c.Set(CtxUID, claims.UID)
		c.Set(CtxRole, claims.Role)
		c.Set(CtxSID, claims.SessionID)
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

// MustSID 当前请求的会话标识；老客户端为空串。
func MustSID(c *gin.Context) string {
	v, _ := c.Get(CtxSID)
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// AdminOnly 仅系统管理员（普通用户调 admin 邀请码接口在这里 403）。
func AdminOnly() gin.HandlerFunc {
	return func(c *gin.Context) {
		if MustRole(c) != models.RoleAdmin {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, utils.MsgNoPermission)
			c.Abort()
			return
		}
		c.Next()
	}
}
