package handlers

import (
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// 注册限流参数（DESIGN §2.C.5）：IP 维度 1 小时 20 次。
// 比登录宽松 —— 注册低频、没有账号枚举风险（邮箱存在即 409 本就是公开信息），
// 20/小时足够家庭场景，也能挡住脚本批量建号。
const (
	registerIPWindow = time.Hour
	registerIPLimit  = 20
	nicknameMaxRunes = 32
)

// RegisterReq POST /api/auth/register 请求体。
//
// 注意：这里**不用** gin binding tag —— 校验失败的英文文案（"failed on the 'min' tag"）
// 会被 App 原样弹给用户，违反 §6.3「错误文案禁止改写成英文/异常类名」。
type RegisterReq struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Nickname string `json:"nickname"`
}

// Register 邮箱注册（R-05）。公开接口，成功后**直接签发 access+refresh**，
// 不需要二次登录。
//
// 唯一性方案（DESIGN §2.C.2）：`username = email`（小写归一化），由 username 的
// 唯一索引承担唯一性 —— 不给 email 加唯一索引，因为历史数据有大量空字符串，
// 唯一索引会把多行空串视为重复，AutoMigrate 直接失败、生产起不来。
func Register(c *gin.Context) {
	var req RegisterReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "请求格式不正确")
		return
	}

	// ---- 1. 邮箱校验（顺序与文案见 §2.C.1 错误码表）----
	rawEmail := strings.TrimSpace(req.Email)
	if rawEmail == "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "请输入邮箱")
		return
	}
	email := utils.NormalizeEmail(rawEmail) // trim + 全小写
	if len(email) > 128 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "邮箱长度不能超过 128 个字符")
		return
	}
	if !utils.IsValidEmail(email) {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "邮箱格式不正确")
		return
	}

	// ---- 2. 密码强度（复用 utils，注册/改密/重置共用一份实现）----
	if msg := utils.ValidatePasswordStrength(req.Password); msg != "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, msg)
		return
	}

	// ---- 3. 注册 IP 限流（防脚本批量建号）----
	if !middleware.Allow("register-ip:"+c.ClientIP(), registerIPWindow, registerIPLimit) {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, "注册过于频繁，请稍后再试")
		return
	}

	// ---- 4. 昵称：留空取 email @ 前部分，再截断 32 rune ----
	nickname := strings.TrimSpace(req.Nickname)
	if nickname == "" {
		nickname = defaultNickname(email)
	} else if utf8.RuneCountInString(nickname) > nicknameMaxRunes {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "昵称不能超过 32 个字符")
		return
	}

	// ---- 5. 查重（username 或 email 命中即 409）----
	var cnt int64
	if err := database.DB.Model(&models.User{}).Unscoped().
		Where("username = ? OR (email <> '' AND email = ?)", email, email).
		Count(&cnt).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "注册失败，请稍后重试")
		return
	}
	if cnt > 0 {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "该邮箱已注册")
		return
	}

	// ---- 6. 建账号（role=user，不自建家庭 → familyId=null）----
	hash, err := utils.HashPassword(req.Password)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "注册失败，请稍后重试")
		return
	}
	u := models.User{
		Username:     email, // ← 唯一性的载体
		PasswordHash: hash,
		Nickname:     nickname,
		Email:        email,
		Role:         models.RoleUser,
	}
	if err := database.DB.Create(&u).Error; err != nil {
		// DB 层兜底：并发注册同一邮箱时由 username 唯一索引挡住
		if isUniqueViolation(err) {
			utils.Fail(c, http.StatusConflict, utils.CodeConflict, "该邮箱已注册")
			return
		}
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "注册失败，请稍后重试")
		return
	}

	// ---- 7. 直接签发 token（复用登录的 issueTokens）----
	resp, err := issueTokens(&u)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "注册失败，请稍后重试")
		return
	}
	utils.OK(c, resp)
}

// defaultNickname 从邮箱取默认昵称（@ 之前的部分，截断 32 rune）。
func defaultNickname(email string) string {
	local := email
	if i := strings.Index(email, "@"); i > 0 {
		local = email[:i]
	}
	if utf8.RuneCountInString(local) <= nicknameMaxRunes {
		return local
	}
	out := make([]rune, 0, nicknameMaxRunes)
	for _, r := range local {
		if len(out) >= nicknameMaxRunes {
			break
		}
		out = append(out, r)
	}
	return string(out)
}

// isUniqueViolation 判断错误是否为唯一键冲突（SQLite / MySQL 两种文案）。
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "unique constraint failed") ||
		strings.Contains(msg, "duplicate entry") || // MySQL 1062
		strings.Contains(msg, "unique violation")
}
