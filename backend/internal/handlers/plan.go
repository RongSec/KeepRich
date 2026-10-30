package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// Overview 总览
func Overview(c *gin.Context) {
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
	s := services.NewFinanceService(database.DB)
	data, err := s.GetOverview(scope, uid, familyID)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, data)
}

// OverviewChart 总览图表数据
func OverviewChart(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	period := c.DefaultQuery("period", "month") // month 或 year
	var familyID *uint64
	if scope == models.TxScopeFamily {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
		familyID = &m.FamilyID
	}
	s := services.NewFinanceService(database.DB)
	data, err := s.GetChartData(scope, uid, familyID, period)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, data)
}

type SavePlanReq struct {
	Scope            string  `json:"scope" binding:"required,oneof=personal family"`
	EmergencyTarget  float64 `json:"emergencyTarget"`
	PensionTarget    float64 `json:"pensionTarget"`
	MonthlySurvivalCost float64 `json:"monthlySurvivalCost"`
	LoanRatio        float64 `json:"loanRatio"`
	SavingRatio      float64 `json:"savingRatio"`
	InvestmentRatio  float64 `json:"investmentRatio"`
	EmergencyRatio   float64 `json:"emergencyRatio"`
	PensionRatio     float64 `json:"pensionRatio"`
	ConsumptionRatio float64 `json:"consumptionRatio"`
	BigPurchaseRatio float64 `json:"bigPurchaseRatio"`
	InvestAnnualRate float64 `json:"investAnnualRate"`
	CurrentAge       int     `json:"currentAge"`
	LifeExpectancy   int     `json:"lifeExpectancy"`
}

// SavePlan 保存预规划
func SavePlan(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req SavePlanReq
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
		if err := database.DB.Where("user_id = ? AND is_admin = ? AND status = ?", uid, true, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "仅家庭管理员可设置家庭规划")
			return
		}
		targetID = m.FamilyID
		familyID = &m.FamilyID
	}

	// 比例合计校验（包含贷款比例）
	sum := req.LoanRatio + req.SavingRatio + req.InvestmentRatio + req.EmergencyRatio + req.PensionRatio + req.ConsumptionRatio
	if sum < 0.9999 || sum > 1.0001 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "收入占比合计必须等于 1")
		return
	}
	// 单项范围校验：比例均须落在 [0,1]，拒绝负值/超限
	for name, r := range map[string]float64{
		"贷款": req.LoanRatio, "储蓄": req.SavingRatio, "投资": req.InvestmentRatio,
		"应急": req.EmergencyRatio, "养老": req.PensionRatio, "消费": req.ConsumptionRatio,
	} {
		if r < 0 || r > 1 {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, name+"占比必须在 0~1 之间")
			return
		}
	}
	if req.BigPurchaseRatio < 0 || req.BigPurchaseRatio > 1 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "大件可占用比例必须在 0~1 之间")
		return
	}
	if req.BigPurchaseRatio == 0 {
		req.BigPurchaseRatio = 0.5 // 未设置时回退默认值
	}
	if req.InvestAnnualRate < 0 || req.InvestAnnualRate > 1 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "投资年收益率必须在 0~1 之间（0.05 表示 5%）")
		return
	}

	var p models.FinancialPlan
	err := database.DB.Where("scope = ? AND target_id = ?", req.Scope, targetID).First(&p).Error
	if err != nil {
		p = models.FinancialPlan{Scope: req.Scope, UID: uid, FamilyID: familyID, TargetID: targetID}
	}
	p.EmergencyTarget = req.EmergencyTarget
	p.PensionTarget = req.PensionTarget
	p.MonthlySurvivalCost = req.MonthlySurvivalCost
	p.LoanRatio = req.LoanRatio
	p.SavingRatio = req.SavingRatio
	p.InvestmentRatio = req.InvestmentRatio
	p.EmergencyRatio = req.EmergencyRatio
	p.PensionRatio = req.PensionRatio
	p.ConsumptionRatio = req.ConsumptionRatio
	p.BigPurchaseRatio = req.BigPurchaseRatio
	p.InvestAnnualRate = req.InvestAnnualRate
	if req.CurrentAge > 0 {
		p.CurrentAge = req.CurrentAge
	}
	if req.LifeExpectancy > 0 {
		p.LifeExpectancy = req.LifeExpectancy
	}

	if p.ID == 0 {
		database.DB.Create(&p)
	} else {
		database.DB.Save(&p)
	}
	utils.OK(c, p)
}

// GetPlan 读取规划
func GetPlan(c *gin.Context) {
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
	var p models.FinancialPlan
	if err := database.DB.Where("scope = ? AND target_id = ?", scope, targetID).First(&p).Error; err != nil {
		// 返回默认值
		defaults := models.GetDefaultRatios()
		utils.OK(c, gin.H{
			"loanRatio":        defaults["loan"],
			"savingRatio":      defaults["saving"],
			"investmentRatio":  defaults["investment"],
			"emergencyRatio":   defaults["emergency"],
			"pensionRatio":     defaults["pension"],
			"consumptionRatio": defaults["consumption"],
			"emergencyTarget":  100000,
			"pensionTarget":    500000,
			"bigPurchaseRatio": 0.5,
			"investAnnualRate": 0.05,
			"currentAge":       30,
			"lifeExpectancy":   80,
		})
		return
	}
	utils.OK(c, p)
}
