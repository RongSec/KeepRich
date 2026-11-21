package handlers

import (
	"errors"
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
	"gorm.io/gorm"
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
		utils.Fail(c, http.StatusServiceUnavailable, utils.CodeServer, "实时通知未启用")
		return
	}
	uid := middleware.MustUID(c)
	if uid == 0 {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgTokenInvalid)
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
		failInternal(c)
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
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "参数不正确")
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

// ===== 通知设置（类型开关 + 文案模板）=====

// notificationSettingReq 设置项入参（enabled 缺省视为 true）
type notificationSettingReq struct {
	Type            string `json:"type"`
	Enabled         *bool  `json:"enabled"`
	TitleTemplate   string `json:"titleTemplate"`
	ContentTemplate string `json:"contentTemplate"`
}

type updateNotificationSettingsReq struct {
	Settings []notificationSettingReq `json:"settings"`
}

// notificationSettingView 设置项出参（附默认模板，前端展示"留空即用默认"）
type notificationSettingView struct {
	Type                   string `json:"type"`
	Enabled                bool   `json:"enabled"`
	TitleTemplate          string `json:"titleTemplate"`
	ContentTemplate        string `json:"contentTemplate"`
	DefaultTitleTemplate   string `json:"defaultTitleTemplate"`
	DefaultContentTemplate string `json:"defaultContentTemplate"`
}

// loadSettingViews 读取某用户 5 类设置（无记录=默认开启/空模板），按 NotifyTypes 固定顺序返回
func loadSettingViews(uid uint64) []notificationSettingView {
	var rows []models.NotificationSetting
	database.DB.Where("user_id = ?", uid).Find(&rows)
	byType := make(map[string]models.NotificationSetting, len(rows))
	for _, r := range rows {
		byType[r.Type] = r
	}
	out := make([]notificationSettingView, 0, len(models.NotifyTypes))
	for _, t := range models.NotifyTypes {
		tpl := models.DefaultNotifyTemplates[t]
		v := notificationSettingView{
			Type:                   t,
			Enabled:                true,
			DefaultTitleTemplate:   tpl.Title,
			DefaultContentTemplate: tpl.Content,
		}
		if r, ok := byType[t]; ok {
			v.Enabled = r.Enabled
			v.TitleTemplate = r.TitleTemplate
			v.ContentTemplate = r.ContentTemplate
		}
		out = append(out, v)
	}
	return out
}

// saveNotificationSettings 校验并保存（upsert）某用户的设置；成功回显最新设置
func saveNotificationSettings(c *gin.Context, uid uint64) {
	var req updateNotificationSettingsReq
	if !bindJSON(c, &req) {
		return
	}
	if len(req.Settings) == 0 {
		failBadRequest(c, "请提交通知设置")
		return
	}
	for _, item := range req.Settings {
		if !models.NotifyValidType(item.Type) {
			failBadRequest(c, "未知的通知类型")
			return
		}
		if len([]rune(item.TitleTemplate)) > 256 {
			failBadRequest(c, "标题模板最多 256 字")
			return
		}
		if len([]rune(item.ContentTemplate)) > 512 {
			failBadRequest(c, "内容模板最多 512 字")
			return
		}
		enabled := true
		if item.Enabled != nil {
			enabled = *item.Enabled
		}
		var row models.NotificationSetting
		err := database.DB.Where("user_id = ? AND type = ?", uid, item.Type).First(&row).Error
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			row = models.NotificationSetting{
				UserID:          uid,
				Type:            item.Type,
				Enabled:         enabled,
				TitleTemplate:   item.TitleTemplate,
				ContentTemplate: item.ContentTemplate,
			}
			if err := database.DB.Create(&row).Error; err != nil {
				failSave(c)
				return
			}
		case err != nil:
			failInternal(c)
			return
		default:
			row.Enabled = enabled
			row.TitleTemplate = item.TitleTemplate
			row.ContentTemplate = item.ContentTemplate
			if err := database.DB.Save(&row).Error; err != nil {
				failSave(c)
				return
			}
		}
	}
	utils.OK(c, gin.H{"settings": loadSettingViews(uid)})
}

// parseTargetUID 解析路径参数 :uid
func parseTargetUID(c *gin.Context) (uint64, bool) {
	id, err := strconv.ParseUint(c.Param("uid"), 10, 64)
	if err != nil || id == 0 {
		failBadRequest(c, "参数不正确")
		return 0, false
	}
	return id, true
}

// requireFamilyAdminFor 校验操作者是同家庭管理员、目标是同家庭活跃成员。
// action 只进错误文案（查看/修改），口径：普通成员只能改自己；
// 家庭管理员可改家庭内其他成员；跨家庭一律 403 中文。
func requireFamilyAdminFor(c *gin.Context, uid, target uint64, action string) bool {
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil || !m.IsAdmin {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "仅家庭管理员可"+action+"他人通知设置")
		return false
	}
	var t models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", target, models.MemberStatusActive).First(&t).Error; err != nil || t.FamilyID != m.FamilyID {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "仅可"+action+"同一家庭成员的通知设置")
		return false
	}
	return true
}

// GetNotificationSettings 查询当前用户的通知设置
func GetNotificationSettings(c *gin.Context) {
	uid := middleware.MustUID(c)
	utils.OK(c, gin.H{"settings": loadSettingViews(uid)})
}

// UpdateNotificationSettings 更新当前用户的通知设置
func UpdateNotificationSettings(c *gin.Context) {
	uid := middleware.MustUID(c)
	saveNotificationSettings(c, uid)
}

// GetMemberNotificationSettings 家庭管理员查看某成员的通知设置（查自己不限权限）
func GetMemberNotificationSettings(c *gin.Context) {
	uid := middleware.MustUID(c)
	target, ok := parseTargetUID(c)
	if !ok {
		return
	}
	if target != uid && !requireFamilyAdminFor(c, uid, target, "查看") {
		return
	}
	utils.OK(c, gin.H{"settings": loadSettingViews(target), "uid": target})
}

// UpdateMemberNotificationSettings 家庭管理员修改某成员的通知设置（改自己不限权限）
func UpdateMemberNotificationSettings(c *gin.Context) {
	uid := middleware.MustUID(c)
	target, ok := parseTargetUID(c)
	if !ok {
		return
	}
	if target != uid && !requireFamilyAdminFor(c, uid, target, "修改") {
		return
	}
	saveNotificationSettings(c, target)
}
