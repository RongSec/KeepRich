package handlers

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/auth"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// 注册限流：同 IP 每小时 10 次**提交尝试**（PRD R-08 ⑦ / DESIGN §C.4）。
const registerIPWindow = time.Hour

// RegisterReq v0.5.0 契约（与 v0.4.1 **有意不兼容**）：
// 邀请码 + 用户名 + 密码 + 昵称 + 邮箱(选填，不验证、不唯一、不发信)。
// deviceId/deviceName/platform 为可选增量字段，注册成功即直接签发会话。
type RegisterReq struct {
	InviteCode      string `json:"inviteCode"`
	Username        string `json:"username"`
	Password        string `json:"password"`
	ConfirmPassword string `json:"confirmPassword"`
	Nickname        string `json:"nickname"`
	Email           string `json:"email"`
	DeviceID        string `json:"deviceId"`
	DeviceName      string `json:"deviceName"`
	Platform        string `json:"platform"`
}

// Register 邀请码注册：单事务抢配额 + 建用户 + 记 usage + 自动加入家庭，成功后直接登录。
//
// 校验顺序按 DESIGN §C.4（一次只提示一个字段的错误，全中文）。
// 邮箱选填：留空跳过；非空只校验格式与长度，**不查重、不验证、不发信**。
func Register(c *gin.Context) {
	var req RegisterReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgRequestFormat)
		return
	}

	// ---- 0. 同 IP 注册尝试频控（每次提交都计数，包括校验失败的尝试）----
	if !middleware.Allow("register-ip:"+c.ClientIP(), registerIPWindow, config.AuthParams().RegisterIPLimit) {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, utils.MsgTooFrequent)
		return
	}

	// ---- 1~2. 邀请码非空 + 归一化格式 ----
	code := utils.NormalizeInviteCode(req.InviteCode)
	if code == "" {
		// v0.4.1 老客户端走「仅邮箱注册」会落到这里，中文引导升级、不致误导
		utils.Fail(c, http.StatusBadRequest, utils.CodeInviteInvalid, utils.MsgInviteEmpty)
		return
	}
	if !utils.IsValidInviteCodeFormat(code) {
		utils.Fail(c, http.StatusBadRequest, utils.CodeInviteInvalid, utils.MsgInviteFormat)
		return
	}

	// ---- 3~6. 邀请码只读预检（真正的并发判定在 ConsumeTx 的条件 UPDATE）----
	if _, err := auth.Invites().Precheck(code); err != nil {
		failRegister(c, err)
		return
	}

	// ---- 7. 用户名：归一化小写 + 规则校验 ----
	username := utils.NormalizeUsername(req.Username)
	if msg := utils.ValidateUsername(username); msg != "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, msg)
		return
	}

	// ---- 8. 密码强度 + 两次一致 ----
	if req.Password == "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgPasswordEmpty)
		return
	}
	if msg := utils.ValidatePasswordStrength(req.Password); msg != "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, msg)
		return
	}
	if req.ConfirmPassword != "" && req.ConfirmPassword != req.Password {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgPasswordMismatch)
		return
	}

	// ---- 9. 昵称（必填、1~16 字、不唯一）----
	// 先对**原始输入**校验（"   " 必须拿到「昵称不能只包含空格」而不是「请输入昵称」），
	// 通过后再 trim 落库。
	if msg := utils.ValidateNickname(req.Nickname); msg != "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, msg)
		return
	}
	nickname := strings.TrimSpace(req.Nickname)

	// ---- 10. 邮箱选填：不验证、不查重，仅格式/长度 ----
	email := utils.NormalizeEmail(req.Email)
	if email != "" {
		if len(email) > 128 {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgEmailTooLong)
			return
		}
		if !utils.IsValidEmail(email) {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgEmailFormat)
			return
		}
	}

	// ---- 12. 单事务：抢配额 + 查重 + 建用户 + 记 usage + 自动加入家庭 ----
	now := time.Now().Unix()
	ip, ua := c.ClientIP(), c.Request.UserAgent()
	if len(ip) > 64 {
		ip = ip[:64]
	}
	if len(ua) > 255 {
		ua = ua[:255]
	}
	var created models.User
	err := auth.Invites().ConsumeTx(code, func(tx *gorm.DB, inv *models.InviteCode) error {
		// Unscoped：软删除的用户名也不能被复用（与 v0.4.0 口径一致）。
		// 冲突时直接 return err → 事务回滚，已抢到的配额自动归还。
		var cnt int64
		if err := tx.Unscoped().Model(&models.User{}).
			Where("username = ?", username).Count(&cnt).Error; err != nil {
			return err
		}
		if cnt > 0 {
			return auth.ErrUsernameTaken
		}
		hash, err := utils.HashPassword(req.Password)
		if err != nil {
			return err
		}
		created = models.User{
			Username:     username, // 小写归一，由 users.username 唯一索引承担唯一性
			PasswordHash: hash,
			Nickname:     nickname,
			Email:        email,
			Role:         models.RoleUser,
		}
		if err := tx.Create(&created).Error; err != nil {
			if isUniqueViolation(err) {
				return auth.ErrUsernameTaken
			}
			return err
		}
		usage := models.InviteCodeUsage{
			InviteCodeID: inv.ID,
			Code:         inv.Code,
			UserID:       created.ID,
			UsedAt:       now,
			IP:           ip,
			UserAgent:    ua,
		}
		if err := tx.Create(&usage).Error; err != nil {
			return err
		}
		// 邀请码不携带家庭信息：新账号默认「无家庭」，加入家庭走既有申请/审批流程。
		return nil
	})
	if err != nil {
		failRegister(c, err)
		return
	}

	// ---- 注册成功即登录：建会话 + 可选签发设备凭据（事务外，避免 SQLite 单连接自锁）----
	dev := deviceOf(req.DeviceID, req.DeviceName, req.Platform)
	bundle, err := auth.Sessions().Issue(&created, dev, ip, ua, true)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgRegisterFailed)
		return
	}
	resp, err := buildLoginResp(&created, bundle)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgRegisterFailed)
		return
	}
	utils.OK(c, resp)
}

// failRegister 领域错误 → 中文响应（不回显任何其他邀请码信息，防枚举）。
func failRegister(c *gin.Context, err error) {
	switch {
	case errors.Is(err, auth.ErrInviteNotFound):
		utils.Fail(c, http.StatusBadRequest, utils.CodeInviteInvalid, utils.MsgInviteNotFound)
	case errors.Is(err, auth.ErrInviteRevoked):
		utils.Fail(c, http.StatusBadRequest, utils.CodeInviteInvalid, utils.MsgInviteRevoked)
	case errors.Is(err, auth.ErrInviteExpired):
		utils.Fail(c, http.StatusBadRequest, utils.CodeInviteInvalid, utils.MsgInviteExpired)
	case errors.Is(err, auth.ErrInviteExhausted):
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, utils.MsgInviteExhausted)
	case errors.Is(err, auth.ErrUsernameTaken):
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, utils.MsgUsernameTaken)
	default:
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgRegisterFailed)
	}
}

// isUniqueViolation 判断错误是否为唯一键冲突（SQLite / MySQL 两种文案）。
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "unique constraint failed") ||
		strings.Contains(msg, "duplicate entry") ||
		strings.Contains(msg, "unique violation")
}
