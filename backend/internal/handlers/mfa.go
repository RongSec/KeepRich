package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

type SetupMFAReq struct {
	Code string `json:"code"`
}

// MFASetup 初始化 MFA：返回 otpauth 二维码内容
func MFASetup(c *gin.Context) {
	uid := middleware.MustUID(c)
	var u models.User
	if err := database.DB.First(&u, uid).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	secret, _ := utils.GenerateMFASecret()
	uri := utils.BuildOTPAuthURI(secret, u.Username, "FamilyFinance")
	// 暂存 secret 等待用户验证（未持久化）
	c.SetCookie("mfa_tmp", secret, 600, "/", "", false, true)
	utils.OK(c, gin.H{"secret": secret, "otpauth": uri})
}

// MFAEnable 提交验证码，启用 MFA
func MFAEnable(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req SetupMFAReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	secret, err := c.Cookie("mfa_tmp")
	if err != nil || secret == "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "请先调用 /mfa/setup")
		return
	}
	if !utils.VerifyMFACode(secret, req.Code) {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "验证码错误")
		return
	}
	if err := database.DB.Model(&models.User{}).Where("id = ?", uid).Updates(map[string]interface{}{
		"mfa_enabled": true,
		"mfa_secret":  secret,
	}).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	c.SetCookie("mfa_tmp", "", -1, "/", "", false, true)
	utils.OK(c, gin.H{"ok": true})
}

// MFADisable 关闭 MFA（需要再次验证）
func MFADisable(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req SetupMFAReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var u models.User
	if err := database.DB.First(&u, uid).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	if !utils.VerifyMFACode(u.MFASecret, req.Code) {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "验证码错误")
		return
	}
	database.DB.Model(&u).Updates(map[string]interface{}{"mfa_enabled": false, "mfa_secret": ""})
	utils.OK(c, gin.H{"ok": true})
}
