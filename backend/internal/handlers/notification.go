package handlers

import (
	"net/http"
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
	CheckOrigin: func(r *http.Request) bool { return true },
}

// WS WebSocket 入口
func WS(c *gin.Context) {
	if !config.C.Notify.WSEnabled {
		utils.Fail(c, http.StatusServiceUnavailable, utils.CodeServer, "ws disabled")
		return
	}
	uid := middleware.MustUID(c)
	conn, err := wsUpgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	services.Hub.Register(uid, conn)
	defer func() {
		services.Hub.Unregister(uid, conn)
		_ = conn.Close()
	}()
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
