package handlers

import (
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"github.com/yourname/family-finance/backend/internal/utils"
)

type CreatePurchaseReq struct {
	Scope      string  `json:"scope" binding:"required,oneof=personal family"`
	Name       string  `json:"name" binding:"required"`
	Price      float64 `json:"price" binding:"required,gt=0"`
	Priority   int     `json:"priority"`
	TargetDate int64   `json:"targetDate"`
	Note       string  `json:"note"`
}

// ListPurchasePlans 大件规划
func ListPurchasePlans(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var targetID uint64
	if scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		targetID = m.FamilyID
	}
	var list []models.PurchasePlan
	database.DB.Where("scope = ? AND target_id = ?", scope, targetID).Order("priority ASC, id ASC").Find(&list)
	utils.OK(c, list)
}

func CreatePurchasePlan(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req CreatePurchaseReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var targetID uint64
	var familyID *uint64
	if req.Scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		targetID = m.FamilyID
		familyID = &m.FamilyID
	}
	p := models.PurchasePlan{
		Scope:      req.Scope,
		UID:        uid,
		FamilyID:   familyID,
		TargetID:   targetID,
		Name:       req.Name,
		Price:      req.Price,
		Priority:   req.Priority,
		TargetDate: req.TargetDate,
		Note:       req.Note,
	}
	database.DB.Create(&p)
	utils.OK(c, p)
}

func DeletePurchasePlan(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var p models.PurchasePlan
	if err := database.DB.First(&p, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if p.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	database.DB.Delete(&p)
	utils.OK(c, gin.H{"ok": true})
}

type UpdatePurchaseReq struct {
	Name       *string  `json:"name"`
	Price      *float64 `json:"price"`
	Priority   *int     `json:"priority"`
	TargetDate *int64   `json:"targetDate"`
	Note       *string  `json:"note"`
}

func UpdatePurchasePlan(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var p models.PurchasePlan
	if err := database.DB.First(&p, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "大件规划不存在")
		return
	}
	if p.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权修改")
		return
	}
	var req UpdatePurchaseReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	if req.Name != nil {
		p.Name = *req.Name
	}
	if req.Price != nil && *req.Price > 0 {
		p.Price = *req.Price
	}
	if req.Priority != nil {
		p.Priority = *req.Priority
	}
	if req.TargetDate != nil {
		p.TargetDate = *req.TargetDate
	}
	if req.Note != nil {
		p.Note = *req.Note
	}
	database.DB.Save(&p)
	utils.OK(c, p)
}

type UpsertInvestmentReq struct {
	Scope   string  `json:"scope" binding:"required,oneof=personal family"`
	Year    int     `json:"year" binding:"required"`
	Month   int     `json:"month" binding:"required,min=1,max=12"`
	Amount  float64 `json:"amount"`  // 实际收益额（元），可正可负。前端用 amount 算出 monthlyRate 同步提交。
	MonthlyRate float64 `json:"monthlyRate" binding:"required"`
	Note    string  `json:"note"`
}

func UpsertInvestment(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req UpsertInvestmentReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var targetID uint64
	var familyID *uint64
	if req.Scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		targetID = m.FamilyID
		familyID = &m.FamilyID
	}

	// 投资桶当前余额（投资转账 + 投资收益历史）
	var invExpense, invIncome float64
	database.DB.Model(&models.Transaction{}).
		Where("scope = ? AND type = ? AND category = ?", req.Scope, models.TxTypeTransfer, models.TransferToInvestment).
		Where(func(db *gorm.DB) *gorm.DB {
			if req.Scope == models.TxScopePersonal {
				return db.Where("uid = ?", uid)
			}
			return db.Where("family_id = ?", targetID)
		}).
		Select("COALESCE(SUM(amount),0)").Scan(&invExpense)
	database.DB.Model(&models.Transaction{}).
		Where("scope = ? AND type = ? AND category = ?", req.Scope, models.TxTypeIncome, models.IncomeInvestment).
		Where(func(db *gorm.DB) *gorm.DB {
			if req.Scope == models.TxScopePersonal {
				return db.Where("uid = ?", uid)
			}
			return db.Where("family_id = ?", targetID)
		}).
		Select("COALESCE(SUM(amount),0)").Scan(&invIncome)
	// 找到已有 record
	var old models.InvestmentRecord
	hasOld := database.DB.Where("scope = ? AND target_id = ? AND year = ? AND month = ?", req.Scope, targetID, req.Year, req.Month).First(&old).Error == nil

	// 幂等关联键：同一 scope+target+年月 的自动入账流水唯一
	sourceRef := fmt.Sprintf("inv:%s:%d:%d:%d", req.Scope, targetID, req.Year, req.Month)

	if req.Amount != 0 || hasOld {
		// 事务内「删旧插新」：以 SourceRef 定位旧自动流水，改备注/多次编辑都不会重复入账
		err := database.DB.Transaction(func(tx *gorm.DB) error {
			if err := tx.Where("source_ref = ?", sourceRef).Delete(&models.Transaction{}).Error; err != nil {
				return err
			}
			if req.Amount == 0 {
				return nil // 清零：只删旧流水，不入新账（冲销）
			}
			txNew := models.Transaction{
				UID:        uid,
				FamilyID:   familyID,
				Scope:      req.Scope,
				Type:       models.TxTypeIncome,
				Category:   models.IncomeInvestment,
				Amount:     req.Amount,
				Note:       "投资月度收益自动入账",
				OccurredAt: time.Date(req.Year, time.Month(req.Month), 1, 0, 0, 0, 0, time.Local).Unix(),
				SourceRef:  sourceRef,
			}
			return tx.Create(&txNew).Error
		})
		if err != nil {
			utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
			return
		}
	}

	// upsert record
	var rec models.InvestmentRecord
	if hasOld {
		rec = old
	}
	rec.Scope = req.Scope
	rec.UID = uid
	rec.FamilyID = familyID
	rec.TargetID = targetID
	rec.Year = req.Year
	rec.Month = req.Month
	rec.MonthlyRate = req.MonthlyRate
	rec.Amount = req.Amount
	rec.Note = req.Note
	if rec.ID == 0 {
		database.DB.Create(&rec)
	} else {
		database.DB.Save(&rec)
	}
	utils.OK(c, rec)
}

func ListInvestments(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var targetID uint64
	if scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		targetID = m.FamilyID
	}
	var list []models.InvestmentRecord
	database.DB.Where("scope = ? AND target_id = ?", scope, targetID).Order("year DESC, month DESC").Find(&list)
	utils.OK(c, list)
}

// GetCurrentInvestment 获取当月投资记录
func GetCurrentInvestment(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var targetID uint64
	if scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.OK(c, nil)
			return
		}
		targetID = m.FamilyID
	}
	now := time.Now()
	var rec models.InvestmentRecord
	err := database.DB.Where("scope = ? AND target_id = ? AND year = ? AND month = ?", scope, targetID, now.Year(), int(now.Month())).First(&rec).Error
	if err != nil {
		utils.OK(c, nil)
		return
	}
	utils.OK(c, rec)
}

// InvestmentSettlement 投资年度汇算
// 计算上一年度的年化收益率，与预期收益率对比
// 未达标部分平均分摊到本年度每月消费桶扣除，自动转入投资桶
func InvestmentSettlement(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var targetID uint64
	var familyID *uint64
	if scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		targetID = m.FamilyID
		familyID = &m.FamilyID
	}

	// 读取规划（获取预期年化收益率）
	var plan models.FinancialPlan
	database.DB.Where("scope = ? AND target_id = ?", scope, targetID).First(&plan)
	targetRate := plan.InvestAnnualRate
	if targetRate <= 0 {
		targetRate = 0.03 // 默认3%
	}

	now := time.Now()
	lastYear := now.Year() - 1

	// 获取上一年度所有投资记录
	var records []models.InvestmentRecord
	database.DB.Where("scope = ? AND target_id = ? AND year = ?", scope, targetID, lastYear).
		Order("month ASC").Find(&records)

	// 计算上一年度投资本金总额（从交易记录中统计转入投资桶的金额）
	yearStart := time.Date(lastYear, 1, 1, 0, 0, 0, 0, time.Local).Unix()
	yearEnd := time.Date(lastYear+1, 1, 1, 0, 0, 0, 0, time.Local).Unix()

	var totalPrincipal float64
	q := database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND occurred_at >= ? AND occurred_at < ?",
			models.TxTypeTransfer, models.TransferToInvestment, yearStart, yearEnd)
	if scope == models.TxScopePersonal {
		q = q.Where("uid = ?", uid)
	} else if familyID != nil {
		q = q.Where("family_id = ?", *familyID)
	}
	q.Select("COALESCE(SUM(amount),0)").Scan(&totalPrincipal)

	// 计算上一年度实际收益总额
	var totalProfit float64
	for _, r := range records {
		totalProfit += r.Amount
	}

	// 计算年化收益率
	actualRate := 0.0
	if totalPrincipal > 0 {
		actualRate = totalProfit / totalPrincipal
	}

	// 计算差额
	expectedProfit := totalPrincipal * targetRate
	deficit := expectedProfit - totalProfit // 正数=未达标，负数=超额

	// 本年度每月应扣除金额（仅未达标时）
	monthlyDeduction := 0.0
	if deficit > 0 {
		monthlyDeduction = deficit / 12.0
	}

	// 本年度已执行的扣除月数（从投资收益记录中推算）
	var currentYearRecords int64
	database.DB.Model(&models.InvestmentRecord{}).
		Where("scope = ? AND target_id = ? AND year = ?", scope, targetID, now.Year()).
		Count(&currentYearRecords)

	utils.OK(c, gin.H{
		"lastYear":           lastYear,
		"targetRate":         targetRate,
		"actualRate":         actualRate,
		"totalPrincipal":     totalPrincipal,
		"totalProfit":        totalProfit,
		"expectedProfit":     expectedProfit,
		"deficit":            deficit,
		"monthlyDeduction":   monthlyDeduction,
		"currentYearMonths":  currentYearRecords,
		"records":            records,
	})
}

// CheckBigPurchase 按当前可承担现金判定可购买项，触发通知（不代替用户标记"已购买"）
func CheckBigPurchase(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var familyID *uint64
	if scope == models.TxScopeFamily {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		familyID = &m.FamilyID
	}
	fs := services.NewFinanceService(database.DB)
	ov, err := fs.GetOverview(scope, uid, familyID)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	var targetID uint64
	if scope == models.TxScopePersonal {
		targetID = uid
	} else {
		targetID = *familyID
	}
	// 大件可占用比例（来自规划，默认 0.5）：可购买阈值 = 现金 × 比例
	ratio := 1.0
	var plan models.FinancialPlan
	if err := database.DB.Where("scope = ? AND target_id = ?", scope, targetID).First(&plan).Error; err == nil && plan.BigPurchaseRatio > 0 && plan.BigPurchaseRatio <= 1 {
		ratio = plan.BigPurchaseRatio
	}
	var plans []models.PurchasePlan
	database.DB.Where("scope = ? AND target_id = ? AND achieved = ?", scope, targetID, false).Order("priority ASC").Find(&plans)

	ns := services.NewNotifyService(database.DB)
	limit := ov.TotalCash * ratio
	triggered := []string{}
	now := time.Now().Unix()
	for i := range plans {
		if plans[i].Price > limit {
			continue
		}
		// 可购买通知 7 天去重；Achieved 仅代表"已购买"，由用户在计划上手动标记
		if plans[i].NotifiedAt != nil && now-*plans[i].NotifiedAt < 7*24*3600 {
			continue
		}
		plans[i].NotifiedAt = &now
		database.DB.Save(&plans[i])
		// 通知全体相关成员（家庭 scope 广播）
		if scope == models.TxScopeFamily && familyID != nil {
			var members []models.FamilyMember
			database.DB.Where("family_id = ? AND status = ?", *familyID, models.MemberStatusActive).Find(&members)
			for _, mem := range members {
				_ = ns.PushTo(mem.UserID, models.NotifyTypeBigPurchase, "大件可购买", "已可购买："+plans[i].Name, "")
			}
		} else {
			_ = ns.PushTo(uid, models.NotifyTypeBigPurchase, "大件可购买", "已可购买："+plans[i].Name, "")
		}
		triggered = append(triggered, plans[i].Name)
	}
	utils.OK(c, gin.H{"triggered": triggered, "cashAvailable": limit})
}
