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
	"github.com/yourname/family-finance/backend/internal/auth"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// LoginReq 登录请求：username 语义仍是「用户名 **或** 邮箱」（老账号兼容）。
// deviceId / deviceName / platform 是纯增量可选字段：不传 = 老客户端，走 legacy 不轮换分支。
// 刻意不用 gin binding tag —— 校验失败的英文文案会直接弹给用户（DESIGN §7.3）。
type LoginReq struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	MFACode    string `json:"mfaCode"`
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	Platform   string `json:"platform"`
}

// LoginResp 登录 / 注册 / 设备登录共用响应（新增字段全部可选，老客户端忽略）。
type LoginResp struct {
	AccessToken  string  `json:"accessToken"`
	RefreshToken string  `json:"refreshToken"`
	ExpiresIn    int     `json:"expiresIn"`
	SessionID    string  `json:"sessionId,omitempty"`
	IdleExpireAt int64   `json:"idleExpireAt,omitempty"`
	DeviceToken  string  `json:"deviceToken,omitempty"`
	UID          uint64  `json:"uid"`
	Role         string  `json:"role"`
	Nickname     string  `json:"nickname"`
	Avatar       string  `json:"avatar"`
	FamilyID     *uint64 `json:"familyId,omitempty"`
}

// 登录失败锁定：同一账号/IP 5 分钟内失败 5 次即锁 15 分钟（v0.4.1 行为不变）。
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

// deviceOf 把请求里的设备字段收敛成领域结构（缺失 deviceName 自动补，G.2）。
func deviceOf(deviceID, deviceName, platform string) auth.DeviceInfo {
	return auth.NormalizeDevice(auth.DeviceInfo{
		DeviceID: deviceID, DeviceName: deviceName, Platform: platform,
	})
}

// Login 账号密码登录 → 三段查询 → 建会话 → 可选签发设备凭据。
func Login(c *gin.Context) {
	var req LoginReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgRequestFormat)
		return
	}
	ident := strings.TrimSpace(req.Username)
	lower := strings.ToLower(ident)
	if ident == "" || req.Password == "" {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgBadCredentials)
		return
	}

	failKey := loginFailKey(lower, c.ClientIP())
	if locked, d := checkLoginLocked(failKey); locked {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden,
			fmt.Sprintf("登录失败次数过多，请 %d 分钟后再试", int(d.Minutes())+1))
		return
	}
	if !middleware.Allow("login-acct:"+lower, 5*time.Minute, 10) {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, "尝试次数过多，请稍后再试")
		return
	}

	// 三段索引友好查询（DESIGN §2.D.2）：
	//   ① username = 原样输入（覆盖所有老用户名，含含大写的 v0.4.0 账号）
	//   ② username = 全小写（新注册账号写入时已归一；大小写混输也能命中）
	//   ③ email = 小写（v0.4.0「邮箱即用户名」账号兜底）
	// 不给列套 LOWER()（会放弃唯一索引），不给 email 加唯一索引（历史空串会炸），
	// 老账号用户名不合规（bob 3 位）也**不回溯校验**。
	var u models.User
	err := database.DB.Where("username = ?", ident).First(&u).Error
	if errors.Is(err, gorm.ErrRecordNotFound) && lower != ident {
		err = database.DB.Where("username = ?", lower).First(&u).Error
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		err = database.DB.Where("email = ? AND email <> ''", lower).First(&u).Error
	}
	if err != nil {
		// 不区分「账号不存在」与「密码错」—— 防账号枚举
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgBadCredentials)
		return
	}
	if u.Disabled {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, utils.MsgAccountDisabled)
		return
	}
	if !utils.CheckPassword(u.PasswordHash, req.Password) {
		recordLoginFail(failKey)
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, utils.MsgBadCredentials)
		return
	}
	clearLoginFail(failKey)
	if u.MFAEnabled && !utils.VerifyMFACode(u.MFASecret, req.MFACode) {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeUnauthorized, "MFA 校验失败")
		return
	}

	dev := deviceOf(req.DeviceID, req.DeviceName, req.Platform)
	bundle, err := auth.Sessions().Issue(&u, dev, c.ClientIP(), c.Request.UserAgent(), true)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgTokenInvalid)
		return
	}
	resp, err := buildLoginResp(&u, bundle)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgTokenInvalid)
		return
	}
	utils.OK(c, resp)
}

// buildLoginResp 组装登录响应：家庭信息 + 统一 token 字段（handler 不再自己算时效）。
func buildLoginResp(u *models.User, bundle *auth.LoginBundle) (LoginResp, error) {
	if u == nil || bundle == nil {
		return LoginResp{}, errors.New("buildLoginResp: 参数为空")
	}
	var member models.FamilyMember
	var familyID *uint64
	if err := database.DB.Where("user_id = ? AND status = ?", u.ID, models.MemberStatusActive).
		First(&member).Error; err == nil {
		fid := member.FamilyID
		familyID = &fid
	}
	return LoginResp{
		AccessToken:  bundle.AccessToken,
		RefreshToken: bundle.RefreshToken,
		ExpiresIn:    bundle.ExpiresIn,
		SessionID:    bundle.SessionID,
		IdleExpireAt: bundle.IdleExpireAt,
		DeviceToken:  bundle.DeviceToken,
		UID:          u.ID,
		Role:         u.Role,
		Nickname:     u.Nickname,
		Avatar:       u.Avatar,
		FamilyID:     familyID,
	}, nil
}

type RefreshReq struct {
	RefreshToken string `json:"refreshToken"`
}

// Refresh 轮换 + 120s 宽限 + 重放撤销；无 sid 的老 refresh 走 legacy 不轮换分支。
func Refresh(c *gin.Context) {
	var req RefreshReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgRequestFormat)
		return
	}
	if req.RefreshToken == "" {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
		return
	}
	claims, err := utils.ParseToken(req.RefreshToken, config.C.JWT.RefreshSecret)
	if err != nil || claims.TokenType != utils.TokenTypeRefresh {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
		return
	}
	// Q2 默认取舍：老客户端 refresh（无 sid）不强制失效，走 v0.4.1 原逻辑。
	if claims.SessionID == "" {
		legacyRefresh(c, claims)
		return
	}
	tokens, err := auth.Sessions().Rotate(claims.SessionID, req.RefreshToken)
	if err != nil {
		failRefresh(c, err)
		return
	}
	data := gin.H{
		"accessToken":  tokens.AccessToken,
		"expiresIn":    tokens.ExpiresIn,
		"idleExpireAt": tokens.IdleExpireAt,
	}
	if tokens.RefreshToken != "" {
		data["refreshToken"] = tokens.RefreshToken
	}
	utils.OK(c, data)
}

// failRefresh 领域错误 → 中文响应；**绝不**把 err.Error() / 异常类名透给客户端。
func failRefresh(c *gin.Context, err error) {
	switch {
	case errors.Is(err, auth.ErrSessionIdle):
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionIdle, utils.MsgSessionIdle)
	case errors.Is(err, auth.ErrUserDisabled):
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, utils.MsgAccountDisabled)
	default:
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
	}
}

// legacyRefresh v0.4.1 老客户端：只回 accessToken，不轮换、不查会话表。
// 旧 refresh 24h 自然过期；升级期不把用户踢下线（DESIGN §8.2 Q2）。
func legacyRefresh(c *gin.Context, claims *utils.Claims) {
	var u models.User
	if err := database.DB.First(&u, claims.UID).Error; err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
		return
	}
	if u.Disabled {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, utils.MsgAccountDisabled)
		return
	}
	if u.TokenVersion != claims.TokenVersion {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
		return
	}
	access, err := utils.GenerateToken(u.ID, u.Role, utils.TokenTypeAccess,
		config.C.JWT.AccessSecret, config.C.JWT.AccessTTL, u.TokenVersion)
	if err != nil {
		utils.Fail(c, http.StatusUnauthorized, utils.CodeSessionRevoked, utils.MsgSessionRevoked)
		return
	}
	utils.OK(c, gin.H{"accessToken": access, "expiresIn": config.C.JWT.AccessTTL})
}

// Me 获取当前登录用户信息。
func Me(c *gin.Context) {
	uid := middleware.MustUID(c)
	var u models.User
	if err := database.DB.First(&u, uid).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "账号不存在")
		return
	}
	utils.OK(c, u)
}
