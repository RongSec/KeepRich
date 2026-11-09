package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

type LoginReq struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
	MFACode  string `json:"mfaCode"`
}

type LoginResp struct {
	AccessToken  string  `json:"accessToken"`
	RefreshToken string  `json:"refreshToken"`
	ExpiresIn    int     `json:"expiresIn"`
	UID          uint64  `json:"uid"`
	Role         string  `json:"role"`
	Nickname     string  `json:"nickname"`
	Avatar       string  `json:"avatar"`
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
// 登录失败锁定：同一账号/ IP 5 分钟内失败 5 次即锁 15 分钟
var (
	loginFailsMu sync.Mutex
	loginFails   = map[string]*loginFailState{}
)

type loginFailState struct {
	Count     int
	FirstFail time.Time
	LockedTil time.Time
}

func loginFailKey(u string, ip string) string { return u + "|" + ip }

func checkLoginLocked(key string) (bool, time.Duration) {
	loginFailsMu.Lock()
	defer loginFailsMu.Unlock()
	st, ok := loginFails[key]
	if !ok {
		return false, 0
	}
	if time.Now().Before(st.LockedTil) {
		return true, time.Until(st.LockedTil)
	}
	return false, 0
}

func recordLoginFail(key string) {
	loginFailsMu.Lock()
	defer loginFailsMu.Unlock()
	st, ok := loginFails[key]
	if !ok || time.Since(st.FirstFail) > 5*time.Minute {
		loginFails[key] = &loginFailState{Count: 1, FirstFail: time.Now()}
		return
	}
	st.Count++
	if st.Count >= 5 {
		st.LockedTil = time.Now().Add(15 * time.Minute)
		st.Count = 0
		st.FirstFail = time.Now()
	}
}

func clearLoginFail(key string) {
	loginFailsMu.Lock()
	defer loginFailsMu.Unlock()
	delete(loginFails, key)
}

func Login(c *gin.Context) {
	var req LoginReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	// 归一化输入：`username` 字段语义已扩为「用户名 **或** 邮箱」，大小写不敏感。
	// 限流键必须用归一化后的值 —— 否则 A@B.com 与 a@b.com 各占一个额度，
	// 锁定形同虚设（DESIGN §2.C.4）。
	ident := strings.TrimSpace(req.Username)
	lower := strings.ToLower(ident)
	if ident == "" {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "账号或密码错误")
		return
	}

	// 登录失败锁定：同一账号+IP 5 分钟内失败 5 次锁 15 分钟
	failKey := loginFailKey(lower, c.ClientIP())
	if locked, d := checkLoginLocked(failKey); locked {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden,
			fmt.Sprintf("登录失败次数过多，请 %d 分钟后再试", int(d.Minutes())+1))
		return
	}
	// 账号维度限流：单账号 5 分钟最多 10 次尝试（防 TOTP/密码暴力破解）
	if !middleware.Allow("login-acct:"+lower, 5*time.Minute, 10) {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, "尝试次数过多，请稍后再试")
		return
	}

	// 两段式查询（索引友好，不用 LOWER(email) —— 函数包住列会放弃索引）：
	//   ① 先打 users.username 唯一索引：覆盖所有老用户名 + 所有新注册的邮箱账号
	//   ② 再按 email 精确查：覆盖"注册后被 admin 改了 email"或历史 email 账号
	var u models.User
	err := database.DB.Where("username = ?", ident).First(&u).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		err = database.DB.Where("email = ? AND email <> ''", lower).First(&u).Error
	}
	if err != nil {
		// 不区分「账号不存在」与「密码错」—— 防账号枚举（DESIGN §2.C.4）
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "账号或密码错误")
		return
	}
	if u.Disabled {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "账号已停用")
		return
	}
	if !utils.CheckPassword(u.PasswordHash, req.Password) {
		recordLoginFail(failKey)
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "账号或密码错误")
		return
	}
	clearLoginFail(failKey)
	if u.MFAEnabled {
		if !utils.VerifyMFACode(u.MFASecret, req.MFACode) {
			utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "MFA 校验失败")
			return
		}
	}
	resp, err := issueTokens(&u)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, resp)
}

// issueTokens 签发 access + refresh 并组装登录响应（Login 与 Register 共用）。
//
// 抽出来的原因：注册成功后要**直接**返回 token（R-05 ①，不需要二次登录），
// 若各自复制一份签发逻辑，token 版本号/家庭信息这些细节迟早漂移。
func issueTokens(u *models.User) (LoginResp, error) {
	var out LoginResp
	access, err := utils.GenerateToken(u.ID, u.Role, utils.TokenTypeAccess,
		config.C.JWT.AccessSecret, config.C.JWT.AccessTTL, u.TokenVersion)
	if err != nil {
		return out, errors.New("签发 access token 失败")
	}
	refresh, err := utils.GenerateToken(u.ID, u.Role, utils.TokenTypeRefresh,
		config.C.JWT.RefreshSecret, config.C.JWT.RefreshTTL, u.TokenVersion)
	if err != nil {
		return out, errors.New("签发 refresh token 失败")
	}

	now := time.Now()
	database.DB.Model(u).Update("last_login_at", &now)

	// 查询当前所在家庭（仅取一个 active 家庭）
	var member models.FamilyMember
	var familyID *uint64
	if err := database.DB.Where("user_id = ? AND status = ?", u.ID, models.MemberStatusActive).
		First(&member).Error; err == nil {
		fid := member.FamilyID
		familyID = &fid
	}

	return LoginResp{
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    config.C.JWT.AccessTTL,
		UID:          u.ID,
		Role:         u.Role,
		Nickname:     u.Nickname,
		Avatar:       u.Avatar,
		FamilyID:     familyID,
	}, nil
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
