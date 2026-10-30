package handlers

import (
	"net/http"
	"net/url"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"github.com/yourname/family-finance/backend/internal/utils"
)

var wsUpgrader = websocket.Upgrader{
	// 只允许同源 / 无 Origin（原生 App 不发 Origin），防跨站 WebSocket 劫持（CSWSH）
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true // 原生客户端
		}
		u, err := url.Parse(origin)
		if err != nil {
			return false
		}
		return u.Host == r.Host
	},
}

// WS WebSocket 入口（支持 ?token= 查询参数鉴权，浏览器 WS 无法带 Authorization 头）
func WS(c *gin.Context) {
	if !config.C.Notify.WSEnabled {
		utils.Fail(c, http.StatusServiceUnavailable, utils.CodeServer, "ws disabled")
		return
	}
	uid := middleware.MustUID(c)
	if uid == 0 {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "unauthorized")
		return
	}
	conn, err := wsUpgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	client := services.Hub.Register(uid, conn)
	defer services.Hub.Unregister(uid, client)
	// 阻塞保持连接；客户端断开后退出
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			return
		}
	}
}

// ListNotifications 查询当前用户的通知列表
func ListNotifications(c *gin.Context) {
	uid := middleware.MustUID(c)
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("size", "50"))
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 200 {
		size = 50
	}
	onlyUnread := c.Query("unread") == "1"

	q := database.DB.Model(&models.Notification{}).Where("uid = ?", uid)
	if onlyUnread {
		q = q.Where("is_read = ?", false)
	}
	var total int64
	q.Count(&total)

	var list []models.Notification
	if err := q.Order("created_at DESC").Offset((page - 1) * size).Limit(size).Find(&list).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}

	// 未读总数
	var unreadCount int64
	database.DB.Model(&models.Notification{}).Where("uid = ? AND is_read = ?", uid, false).Count(&unreadCount)

	utils.OK(c, gin.H{
		"list":        list,
		"total":       total,
		"page":        page,
		"size":        size,
		"unreadCount": unreadCount,
	})
}

// MarkNotificationRead 标记单条通知为已读
func MarkNotificationRead(c *gin.Context) {
	uid := middleware.MustUID(c)
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "invalid id")
		return
	}
	res := database.DB.Model(&models.Notification{}).
		Where("id = ? AND uid = ?", id, uid).
		Update("is_read", true)
	if res.Error != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, res.Error.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true, "affected": res.RowsAffected})
}

// MarkAllNotificationsRead 标记当前用户所有通知为已读
func MarkAllNotificationsRead(c *gin.Context) {
	uid := middleware.MustUID(c)
	res := database.DB.Model(&models.Notification{}).
		Where("uid = ? AND is_read = ?", uid, false).
		Update("is_read", true)
	if res.Error != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, res.Error.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true, "affected": res.RowsAffected})
}
