package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/auth"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// DeviceLoginReq 设备授权凭据换取会话（能力边界：仅此一个入口）。
type DeviceLoginReq struct {
	DeviceID    string `json:"deviceId"`
	DeviceToken string `json:"deviceToken"`
	DeviceName  string `json:"deviceName"`
}

// DeviceLogin 指纹解锁后用设备凭据换会话；**不重发 deviceToken**。
// 凭据失效/过期/撤销 → 401 code=40112，客户端据此删本机凭据并降级密码表单。
func DeviceLogin(c *gin.Context) {
	var req DeviceLoginReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeDeviceCredentialInvalid, utils.MsgDeviceCredentialInvalid)
		return
	}
	deviceID := strings.TrimSpace(req.DeviceID)
	u, err := auth.Devices().Validate(req.DeviceToken, deviceID)
	if err != nil {
		if errors.Is(err, auth.ErrUserDisabled) {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, utils.MsgAccountDisabled)
		} else {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeDeviceCredentialInvalid, utils.MsgDeviceCredentialInvalid)
		}
		return
	}
	dev := deviceOf(deviceID, req.DeviceName, "")
	bundle, err := auth.Sessions().Issue(u, dev, c.ClientIP(), c.Request.UserAgent(), false)
	if err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeDeviceCredentialInvalid, utils.MsgDeviceCredentialInvalid)
		return
	}
	resp, err := buildLoginResp(u, bundle)
	if err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeDeviceCredentialInvalid, utils.MsgDeviceCredentialInvalid)
		return
	}
	utils.OK(c, resp)
}

// Logout 退出登录：撤销当前会话；revokeDevice=true 时连该设备的凭据一起撤销。
// 会话失效 ≠ 退出登录，只有这里才由客户端删本机账号卡与凭据（PRD §3.7）。
func Logout(c *gin.Context) {
	sid := middleware.MustSID(c)
	uid := middleware.MustUID(c)
	if sid != "" && c.Query("revokeDevice") == "true" {
		var row models.AuthSession
		if err := database.DB.Where("session_id = ?", sid).First(&row).Error; err == nil && row.DeviceID != "" {
			auth.Devices().RevokeByDevice(uid, row.DeviceID, auth.ReasonLogout)
		} else {
			auth.Sessions().Revoke(sid, auth.ReasonLogout)
		}
	} else {
		auth.Sessions().Revoke(sid, auth.ReasonLogout)
	}
	utils.OK(c, gin.H{"ok": true})
}

// ListDevices 已登录设备列表（同一 deviceId 多条会话按最近活跃聚合）。
// 只回展示字段，绝不回 RefreshHash / CredentialHash。
func ListDevices(c *gin.Context) {
	uid := middleware.MustUID(c)
	sid := middleware.MustSID(c)
	list := auth.Sessions().ListByUser(uid, sid)
	if list == nil {
		list = []auth.DeviceView{}
	}
	cfg := config.AuthParams()
	utils.OK(c, gin.H{
		"list":          list,
		"idleTTL":       cfg.SessionIdleTTL,
		"deviceIdleTTL": cfg.DeviceIdleTTL,
	})
}

// RevokeDevice 撤销单个设备（:id 是**会话 ID**）：会话与该设备凭据一起撤销。
func RevokeDevice(c *gin.Context) {
	uid := middleware.MustUID(c)
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "设备不存在")
		return
	}
	row, err := auth.Sessions().SessionByID(id)
	if err != nil || row.UserID != uid {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "设备不存在")
		return
	}
	revoked, credentialRevoked := int64(0), int64(0)
	if row.DeviceID != "" {
		revoked, credentialRevoked = auth.Devices().RevokeByDevice(uid, row.DeviceID, auth.ReasonDeviceRevoke)
	} else {
		auth.Sessions().Revoke(row.SessionID, auth.ReasonDeviceRevoke)
		revoked = 1
	}
	utils.OK(c, gin.H{"revoked": revoked, "deviceCredentialsRevoked": credentialRevoked})
}

// RevokeOthers 撤销其他所有设备（当前设备保留）。
func RevokeOthers(c *gin.Context) {
	uid := middleware.MustUID(c)
	sid := middleware.MustSID(c)
	keepDeviceID := ""
	if sid != "" {
		var row models.AuthSession
		if err := database.DB.Where("session_id = ?", sid).First(&row).Error; err == nil {
			keepDeviceID = row.DeviceID
		}
	}
	n := auth.Devices().RevokeOthers(uid, keepDeviceID, auth.ReasonRevokeOthers)
	utils.OK(c, gin.H{"revoked": n})
}
