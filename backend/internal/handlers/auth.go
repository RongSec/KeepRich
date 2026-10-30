package handlers

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

type LoginReq struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
	MFACode  string `json:"mfaCode"`
}

type LoginResp struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	ExpiresIn    int    `json:"expiresIn"`
	UID          uint64 `json:"uid"`
	Role         string `json:"role"`
	Nickname     string `json:"nickname"`
	Avatar       string `json:"avatar"`
	FamilyID     *uint64 `json:"familyId,omitempty"`
}

// Login godoc
// @Summary 账号密码登录
// @Tags auth
// @Accept json
// @Produce json
// @Param body body LoginReq true "登录参数"
// @Success 200 {object} utils.Response{data=LoginResp}
// @Router /api/auth/login [post]
func Login(c *gin.Context) {
	var req LoginReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	// 账号维度限流：单账号 5 分钟最多 10 次尝试（防 TOTP/密码暴力破解）
	if !middleware.Allow("login-acct:"+req.Username, 5*time.Minute, 10) {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, "尝试次数过多，请稍后再试")
		return
	}
	var u models.User
	if err := database.DB.Where("username = ?", req.Username).First(&u).Error; err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "账号或密码错误")
		return
	}
	if u.Disabled {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "账号已停用")
		return
	}
	if !utils.CheckPassword(u.PasswordHash, req.Password) {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "账号或密码错误")
		return
	}
	if u.MFAEnabled {
		if !utils.VerifyMFACode(u.MFASecret, req.MFACode) {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "MFA 校验失败")
			return
		}
	}
	access, err := utils.GenerateToken(u.ID, u.Role, utils.TokenTypeAccess, config.C.JWT.AccessSecret, config.C.JWT.AccessTTL, u.TokenVersion)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "签发 access token 失败")
		return
	}
	refresh, err := utils.GenerateToken(u.ID, u.Role, utils.TokenTypeRefresh, config.C.JWT.RefreshSecret, config.C.JWT.RefreshTTL, u.TokenVersion)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "签发 refresh token 失败")
		return
	}
	now := time.Now()
	database.DB.Model(&u).Update("last_login_at", &now)

	// 查询当前所在家庭（仅取一个 active 家庭）
	var member models.FamilyMember
	var familyID *uint64
	if err := database.DB.Where("user_id = ? AND status = ?", u.ID, models.MemberStatusActive).First(&member).Error; err == nil {
		familyID = &member.FamilyID
	}

	utils.OK(c, LoginResp{
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    config.C.JWT.AccessTTL,
		UID:          u.ID,
		Role:         u.Role,
		Nickname:     u.Nickname,
		Avatar:       u.Avatar,
		FamilyID:     familyID,
	})
}

type RefreshReq struct {
	RefreshToken string `json:"refreshToken" binding:"required"`
}

func Refresh(c *gin.Context) {
	var req RefreshReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	claims, err := utils.ParseToken(req.RefreshToken, config.C.JWT.RefreshSecret)
	if err != nil || claims.TokenType != utils.TokenTypeRefresh {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "invalid refresh token")
		return
	}
	// 查库校验：账号存在、未停用、token 版本未失效（改密后旧 token 作废）
	var u models.User
	if err := database.DB.First(&u, claims.UID).Error; err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "账号不存在")
		return
	}
	if u.Disabled {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "账号已停用")
		return
	}
	if u.TokenVersion != claims.TokenVersion {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "登录已失效，请重新登录")
		return
	}
	// 使用库中最新角色签发（降权立即生效）
	access, err := utils.GenerateToken(u.ID, u.Role, utils.TokenTypeAccess, config.C.JWT.AccessSecret, config.C.JWT.AccessTTL, u.TokenVersion)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"accessToken": access, "expiresIn": config.C.JWT.AccessTTL})
}

// Me 获取当前登录用户信息
func Me(c *gin.Context) {
	uid := middleware.MustUID(c)
	var u models.User
	if err := database.DB.First(&u, uid).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	utils.OK(c, u)
}
