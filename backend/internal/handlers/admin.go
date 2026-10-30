package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// AdminListFamiliesWithStats 简易统计
func AdminListFamiliesWithStats(c *gin.Context) {
	type row struct {
		models.Family
		MemberCount int64 `json:"memberCount"`
	}
	var rows []row
	database.DB.Table("families").
		Select("families.*, (SELECT COUNT(*) FROM family_members WHERE family_members.family_id = families.id AND status = 'active') AS member_count").
		Where("families.deleted_at IS NULL").
		Order("families.id DESC").Limit(500).Scan(&rows)
	utils.OK(c, rows)
}

type ReportErrorReq struct {
	Platform string `json:"platform"`
	App      string `json:"app"`
	Version  string `json:"version"`
	URL      string `json:"url"`
	Message  string `json:"message"`
	Stack    string `json:"stack"`
	Extra    string `json:"extra"`
}

// ReportError 客户端错误上报（任意登录用户可调用）
func ReportError(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req ReportErrorReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	if req.Message == "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "message required")
		return
	}
	if req.Platform == "" {
		req.Platform = "web"
	}
	if req.App == "" {
		req.App = "client"
	}
	e := models.ErrorReport{
		UID:      uid,
		Platform: req.Platform,
		App:      req.App,
		Version:  req.Version,
		URL:      req.URL,
		Message:  req.Message,
		Stack:    req.Stack,
		Extra:    req.Extra,
	}
	if err := database.DB.Create(&e).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"id": e.ID, "ok": true})
}

// AdminListAudit 审计日志列表
func AdminListAudit(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("size", "50"))
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 500 {
		size = 50
	}
	action := c.Query("action")
	status := c.Query("status")
	keyword := c.Query("keyword")

	q := database.DB.Model(&models.AuditLog{})
	if action != "" {
		q = q.Where("action = ?", action)
	}
	if status != "" {
		q = q.Where("status = ?", status)
	}
	if keyword != "" {
		q = q.Where("username LIKE ? OR target LIKE ? OR detail LIKE ?", "%"+keyword+"%", "%"+keyword+"%", "%"+keyword+"%")
	}
	var total int64
	q.Count(&total)
	var list []models.AuditLog
	q.Order("id DESC").Offset((page - 1) * size).Limit(size).Find(&list)
	utils.OK(c, gin.H{"list": list, "total": total, "page": page, "size": size})
}

// AdminListErrors 错误报告列表
func AdminListErrors(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("size", "50"))
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 500 {
		size = 50
	}
	platform := c.Query("platform")
	app := c.Query("app")
	keyword := c.Query("keyword")

	q := database.DB.Model(&models.ErrorReport{})
	if platform != "" {
		q = q.Where("platform = ?", platform)
	}
	if app != "" {
		q = q.Where("app = ?", app)
	}
	if keyword != "" {
		q = q.Where("message LIKE ? OR url LIKE ?", "%"+keyword+"%", "%"+keyword+"%")
	}
	var total int64
	q.Count(&total)
	var list []models.ErrorReport
	q.Order("id DESC").Offset((page - 1) * size).Limit(size).Find(&list)
	utils.OK(c, gin.H{"list": list, "total": total, "page": page, "size": size})
}

// AdminDeleteError 删除单条错误
func AdminDeleteError(c *gin.Context) {
	id := c.Param("id")
	if err := database.DB.Delete(&models.ErrorReport{}, id).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true})
}

// AdminClearErrors 清空错误
func AdminClearErrors(c *gin.Context) {
	if err := database.DB.Where("1 = 1").Delete(&models.ErrorReport{}).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true})
}

type AdminResetPasswordReq struct {
	NewPassword string `json:"newPassword" binding:"required,min=8"`
}

// AdminResetPassword 重置用户密码
func AdminResetPassword(c *gin.Context) {
	id := c.Param("id")
	var req AdminResetPasswordReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var u models.User
	if err := database.DB.First(&u, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	hash, err := utils.HashPassword(req.NewPassword)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	if err := database.DB.Model(&u).Updates(map[string]interface{}{
		"password_hash": hash,
		"token_version": gorm.Expr("token_version + 1"),
	}).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true})
}

// AdminResetMFA 重置用户 MFA
func AdminResetMFA(c *gin.Context) {
	id := c.Param("id")
	var u models.User
	if err := database.DB.First(&u, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	if err := database.DB.Model(&u).Updates(map[string]interface{}{
		"mfa_enabled":    false,
		"mfa_secret":     "",
		"mfa_backup_codes": "",
	}).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true})
}

// AdminFamilyStats 家庭统计
func AdminFamilyStats(c *gin.Context) {
	id := c.Param("id")
	var f models.Family
	if err := database.DB.First(&f, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "family not found")
		return
	}
	type countRow struct{ C int64 }
	var memberCount countRow
	database.DB.Model(&models.FamilyMember{}).
		Where("family_id = ? AND status = ?", f.ID, models.MemberStatusActive).
		Count(&memberCount.C)

	var txCount int64
	database.DB.Model(&models.Transaction{}).Where("family_id = ?", f.ID).Count(&txCount)

	var totalIncome, totalExpense float64
	database.DB.Model(&models.Transaction{}).
		Where("family_id = ? AND type = ?", f.ID, models.TxTypeIncome).
		Select("COALESCE(SUM(amount),0)").Scan(&totalIncome)
	database.DB.Model(&models.Transaction{}).
		Where("family_id = ? AND type = ?", f.ID, models.TxTypeExpense).
		Select("COALESCE(SUM(amount),0)").Scan(&totalExpense)

	utils.OK(c, gin.H{
		"family":       f,
		"memberCount":  memberCount.C,
		"txCount":      txCount,
		"totalIncome":  totalIncome,
		"totalExpense": totalExpense,
	})
}

// AdminDeleteFamily 强制删除家庭（含所有成员、记账等）
func AdminDeleteFamily(c *gin.Context) {
	id := c.Param("id")
	var f models.Family
	if err := database.DB.First(&f, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "family not found")
		return
	}
	// 启动事务删除关联数据
	err := database.DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.FamilyMember{}).Error; err != nil {
			return err
		}
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.FamilyJoinRequest{}).Error; err != nil {
			return err
		}
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.Transaction{}).Error; err != nil {
			return err
		}
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.FinancialPlan{}).Error; err != nil {
			return err
		}
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.PurchasePlan{}).Error; err != nil {
			return err
		}
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.InvestmentRecord{}).Error; err != nil {
			return err
		}
		if err := tx.Where("family_id = ?", f.ID).Delete(&models.DeleteFamilyRequest{}).Error; err != nil {
			return err
		}
		if err := tx.Delete(&f).Error; err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true})
}
