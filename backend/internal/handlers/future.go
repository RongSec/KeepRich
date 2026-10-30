package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// ====== 通用 scope 解析 ======

func resolveTarget(c *gin.Context, scope string) (targetID uint64, familyID *uint64, ok bool) {
	uid := middleware.MustUID(c)
	if scope == models.TxScopePersonal {
		return uid, nil, true
	}
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
		return 0, nil, false
	}
	return m.FamilyID, &m.FamilyID, true
}

// ====== 公积金贷款 ======

type HousingFundLoanReq struct {
	Scope      string  `json:"scope" binding:"required,oneof=personal family"`
	Name       string  `json:"name" binding:"required"`
	Total      float64 `json:"total" binding:"required,gt=0"`
	AnnualRate float64 `json:"annualRate" binding:"required,gte=0"`
	TermMonths int     `json:"termMonths" binding:"required,gt=0"`
	Method     string  `json:"method" binding:"required,oneof=equal_payment equal_capital"`
	StartMonth int64   `json:"startMonth"`
	PaidMonths int     `json:"paidMonths"`
	Note       string  `json:"note"`
}

func ListHousingFundLoans(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	targetID, _, ok := resolveTarget(c, scope)
	if !ok {
		return
	}
	var list []models.HousingFundLoan
	database.DB.Where("scope = ? AND uid = ?", scope, uid).Order("id DESC").Find(&list)
	_ = targetID
	utils.OK(c, list)
}

func CreateHousingFundLoan(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req HousingFundLoanReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	_, familyID, ok := resolveTarget(c, req.Scope)
	if !ok {
		return
	}
	rec := models.HousingFundLoan{
		Scope:      req.Scope,
		UID:        uid,
		FamilyID:   familyID,
		Name:       req.Name,
		Total:      req.Total,
		AnnualRate: req.AnnualRate,
		TermMonths: req.TermMonths,
		Method:     req.Method,
		StartMonth: req.StartMonth,
		PaidMonths: req.PaidMonths,
		Note:       req.Note,
	}
	database.DB.Create(&rec)
	utils.OK(c, rec)
}

func UpdateHousingFundLoan(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.HousingFundLoan
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权修改")
		return
	}
	var req HousingFundLoanReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	rec.Name = req.Name
	rec.Total = req.Total
	rec.AnnualRate = req.AnnualRate
	rec.TermMonths = req.TermMonths
	rec.Method = req.Method
	rec.StartMonth = req.StartMonth
	rec.PaidMonths = req.PaidMonths
	rec.Note = req.Note
	database.DB.Save(&rec)
	utils.OK(c, rec)
}

func DeleteHousingFundLoan(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.HousingFundLoan
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	database.DB.Delete(&rec)
	utils.OK(c, gin.H{"ok": true})
}

// ====== 商业贷款 ======

type CommercialLoanReq struct {
	Scope      string  `json:"scope" binding:"required,oneof=personal family"`
	Name       string  `json:"name" binding:"required"`
	Total      float64 `json:"total" binding:"required,gt=0"`
	AnnualRate float64 `json:"annualRate" binding:"required,gte=0"`
	TermMonths int     `json:"termMonths" binding:"required,gt=0"`
	Method     string  `json:"method" binding:"required,oneof=equal_payment equal_capital"`
	StartMonth int64   `json:"startMonth"`
	PaidMonths int     `json:"paidMonths"`
	Note       string  `json:"note"`
}

func ListCommercialLoans(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var list []models.CommercialLoan
	database.DB.Where("scope = ? AND uid = ?", scope, uid).Order("id DESC").Find(&list)
	utils.OK(c, list)
}

func CreateCommercialLoan(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req CommercialLoanReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	_, familyID, ok := resolveTarget(c, req.Scope)
	if !ok {
		return
	}
	rec := models.CommercialLoan{
		Scope:      req.Scope,
		UID:        uid,
		FamilyID:   familyID,
		Name:       req.Name,
		Total:      req.Total,
		AnnualRate: req.AnnualRate,
		TermMonths: req.TermMonths,
		Method:     req.Method,
		StartMonth: req.StartMonth,
		PaidMonths: req.PaidMonths,
		Note:       req.Note,
	}
	database.DB.Create(&rec)
	utils.OK(c, rec)
}

func UpdateCommercialLoan(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.CommercialLoan
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权修改")
		return
	}
	var req CommercialLoanReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	rec.Name = req.Name
	rec.Total = req.Total
	rec.AnnualRate = req.AnnualRate
	rec.TermMonths = req.TermMonths
	rec.Method = req.Method
	rec.StartMonth = req.StartMonth
	rec.PaidMonths = req.PaidMonths
	rec.Note = req.Note
	database.DB.Save(&rec)
	utils.OK(c, rec)
}

func DeleteCommercialLoan(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.CommercialLoan
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	database.DB.Delete(&rec)
	utils.OK(c, gin.H{"ok": true})
}

// ====== 借款 ======

type BorrowedMoneyReq struct {
	Scope      string  `json:"scope" binding:"required,oneof=personal family"`
	Name       string  `json:"name" binding:"required"`
	Total      float64 `json:"total" binding:"required,gt=0"`
	AnnualRate float64 `json:"annualRate" binding:"gte=0"`
	TermMonths int     `json:"termMonths" binding:"required,gt=0"`
	Method     string  `json:"method" binding:"required,oneof=equal_payment equal_capital interest_free"`
	StartMonth int64   `json:"startMonth"`
	PaidMonths int     `json:"paidMonths"`
	Note       string  `json:"note"`
}

func ListBorrowedMoney(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var list []models.BorrowedMoney
	database.DB.Where("scope = ? AND uid = ?", scope, uid).Order("id DESC").Find(&list)
	utils.OK(c, list)
}

func CreateBorrowedMoney(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req BorrowedMoneyReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	_, familyID, ok := resolveTarget(c, req.Scope)
	if !ok {
		return
	}
	rec := models.BorrowedMoney{
		Scope:      req.Scope,
		UID:        uid,
		FamilyID:   familyID,
		Name:       req.Name,
		Total:      req.Total,
		AnnualRate: req.AnnualRate,
		TermMonths: req.TermMonths,
		Method:     req.Method,
		StartMonth: req.StartMonth,
		PaidMonths: req.PaidMonths,
		Note:       req.Note,
	}
	database.DB.Create(&rec)
	utils.OK(c, rec)
}

func UpdateBorrowedMoney(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.BorrowedMoney
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权修改")
		return
	}
	var req BorrowedMoneyReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	rec.Name = req.Name
	rec.Total = req.Total
	rec.AnnualRate = req.AnnualRate
	rec.TermMonths = req.TermMonths
	rec.Method = req.Method
	rec.StartMonth = req.StartMonth
	rec.PaidMonths = req.PaidMonths
	rec.Note = req.Note
	database.DB.Save(&rec)
	utils.OK(c, rec)
}

func DeleteBorrowedMoney(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.BorrowedMoney
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	database.DB.Delete(&rec)
	utils.OK(c, gin.H{"ok": true})
}

// ====== 未来利益 ======

type FutureBenefitReq struct {
	Scope        string  `json:"scope" binding:"required,oneof=personal family"`
	Name         string  `json:"name" binding:"required"`
	Type         string  `json:"type" binding:"required,oneof=monthly yearly lump_sum lifetime custom_years"`
	PayoutDate   int64   `json:"payoutDate" binding:"required"`   // 一次性：发放日期；逐月/年/终身/自定义：开始发放时间
	PayoutAmount float64 `json:"payoutAmount" binding:"required"` // 一次性：发放额；逐月：每月发放额；按年：每年发放额；终身/自定义：每月发放额
	CustomYears  int     `json:"customYears"`                     // 自定义年限（仅 type=custom_years 用）
	Note         string  `json:"note"`
}

func ListFutureBenefits(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	var list []models.FutureBenefit
	database.DB.Where("scope = ? AND uid = ?", scope, uid).Order("id DESC").Find(&list)
	utils.OK(c, list)
}

func CreateFutureBenefit(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req FutureBenefitReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	_, familyID, ok := resolveTarget(c, req.Scope)
	if !ok {
		return
	}
	if req.PayoutDate == 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "请填写发放时间")
		return
	}
	if req.PayoutAmount <= 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "请填写有效的发放金额")
		return
	}
	rec := models.FutureBenefit{
		Scope:        req.Scope,
		UID:          uid,
		FamilyID:     familyID,
		Name:         req.Name,
		Type:         req.Type,
		PayoutDate:   req.PayoutDate,
		PayoutAmount: req.PayoutAmount,
		CustomYears:  req.CustomYears,
		Note:         req.Note,
	}
	database.DB.Create(&rec)
	utils.OK(c, rec)
}

func UpdateFutureBenefit(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.FutureBenefit
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权修改")
		return
	}
	var req FutureBenefitReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	if req.PayoutDate > 0 {
		rec.PayoutDate = req.PayoutDate
	}
	if req.PayoutAmount > 0 {
		rec.PayoutAmount = req.PayoutAmount
	}
	if req.Name != "" {
		rec.Name = req.Name
	}
	if req.Type != "" {
		rec.Type = req.Type
	}
	if req.CustomYears > 0 {
		rec.CustomYears = req.CustomYears
	}
	if req.Note != "" {
		rec.Note = req.Note
	}
	database.DB.Save(&rec)
	utils.OK(c, rec)
}

func DeleteFutureBenefit(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var rec models.FutureBenefit
	if err := database.DB.First(&rec, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if rec.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	database.DB.Delete(&rec)
	utils.OK(c, gin.H{"ok": true})
}

// ====== 聚合 + 进度 ======

// LoanWithSummary 单条带汇总
type LoanWithSummary struct {
	models.HousingFundLoan
	Summary utils.LoanSummary `json:"summary"`
}
type CommercialWithSummary struct {
	models.CommercialLoan
	Summary utils.LoanSummary `json:"summary"`
}
type BorrowedWithSummary struct {
	models.BorrowedMoney
	Summary utils.LoanSummary `json:"summary"`
}
type BenefitWithSummary struct {
	models.FutureBenefit
	Summary map[string]any `json:"summary"`
}

// FutureFinanceResponse 未来财务聚合数据
type FutureFinanceResponse struct {
	// 总还进度
	TotalPending         float64 `json:"totalPending"`         // 待还款总额
	TotalProgressPct     float64 `json:"totalProgressPct"`     // 加权进度
	TotalRemainingMonths int     `json:"totalRemainingMonths"` // 最大剩余月数
	EstimatedPayoffAt    int64   `json:"estimatedPayoffAt"`    // 预计全部还清时间戳

	// 分类明细
	HousingFundLoans  []LoanWithSummary     `json:"housingFundLoans"`
	CommercialLoans   []CommercialWithSummary `json:"commercialLoans"`
	BorrowedMoneys    []BorrowedWithSummary `json:"borrowedMoneys"`
	FutureBenefits    []BenefitWithSummary  `json:"futureBenefits"`

	// 投资桶（移入此处）
	Investment  InvestmentSummary  `json:"investment"`
}

// InvestmentSummary 投资桶汇总
type InvestmentSummary struct {
	CurrentMonthRate  float64 `json:"currentMonthRate"`
	CurrentYear       int     `json:"currentYear"`
	CurrentMonth      int     `json:"currentMonth"`
	TargetRate        float64 `json:"targetRate"`
	Excess            float64 `json:"excess"`           // 超出目标部分的金额（30% 入硬性存储）
	HardSavingTransfer float64 `json:"hardSavingTransfer"` // 实际转入硬性存储的金额
	Deficit           float64 `json:"deficit"`          // 不足部分（下月消费余额扣补）
}

// FutureFinance 未来财务聚合
func FutureFinance(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	// 若请求 family scope 但用户未加入家庭，自动降级为 personal，避免返回 403
	if scope == models.TxScopeFamily {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			scope = models.TxScopePersonal
		}
	}
	// 读取用户规划（用于未来利益折现）——必须按 scope+target_id 查询，家庭成员共享家庭规划
	var plan models.FinancialPlan
	planTarget := uid
	if scope == models.TxScopeFamily {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err == nil {
			planTarget = m.FamilyID
		}
	}
	_ = database.DB.Where("scope = ? AND target_id = ?", scope, planTarget).First(&plan).Error
	currentAge := plan.CurrentAge
	lifeExpectancy := plan.LifeExpectancy
	if lifeExpectancy <= 0 {
		lifeExpectancy = 80
	}
	resp := FutureFinanceResponse{
		HousingFundLoans: []LoanWithSummary{},
		CommercialLoans:  []CommercialWithSummary{},
		BorrowedMoneys:   []BorrowedWithSummary{},
		FutureBenefits:   []BenefitWithSummary{},
	}

	// 公积金/商业/借款/未来利益：家庭 scope 聚合全家（family_id），个人按 uid
	var famID uint64
	if scope == models.TxScopeFamily {
		var fm models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&fm).Error; err == nil {
			famID = fm.FamilyID
		}
	}
	// 公积金
	var hfl []models.HousingFundLoan
	qHf := database.DB.Where("scope = ?", scope)
	if scope == models.TxScopePersonal {
		qHf = qHf.Where("uid = ?", uid)
	} else {
		qHf = qHf.Where("family_id = ?", famID)
	}
	qHf.Find(&hfl)
	for _, l := range hfl {
		s := utils.ComputeLoanSummary(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
		resp.HousingFundLoans = append(resp.HousingFundLoans, LoanWithSummary{HousingFundLoan: l, Summary: s})
	}
	// 商业
	var cl []models.CommercialLoan
	qCl := database.DB.Where("scope = ?", scope)
	if scope == models.TxScopePersonal {
		qCl = qCl.Where("uid = ?", uid)
	} else {
		qCl = qCl.Where("family_id = ?", famID)
	}
	qCl.Find(&cl)
	for _, l := range cl {
		s := utils.ComputeLoanSummary(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
		resp.CommercialLoans = append(resp.CommercialLoans, CommercialWithSummary{CommercialLoan: l, Summary: s})
	}
	// 借款
	var bm []models.BorrowedMoney
	qBm := database.DB.Where("scope = ?", scope)
	if scope == models.TxScopePersonal {
		qBm = qBm.Where("uid = ?", uid)
	} else {
		qBm = qBm.Where("family_id = ?", famID)
	}
	qBm.Find(&bm)
	for _, l := range bm {
		s := utils.ComputeLoanSummary(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
		resp.BorrowedMoneys = append(resp.BorrowedMoneys, BorrowedWithSummary{BorrowedMoney: l, Summary: s})
	}
	// 未来利益
	var fb []models.FutureBenefit
	qFb := database.DB.Where("scope = ?", scope)
	if scope == models.TxScopePersonal {
		qFb = qFb.Where("uid = ?", uid)
	} else {
		qFb = qFb.Where("family_id = ?", famID)
	}
	qFb.Find(&fb)
	for _, b := range fb {
		s := utils.BenefitSummary(b.PayoutDate, b.PayoutAmount, b.Type, currentAge, lifeExpectancy, b.CustomYears)
		resp.FutureBenefits = append(resp.FutureBenefits, BenefitWithSummary{FutureBenefit: b, Summary: s})
	}

	// 聚合待还款
	var totalRemain, totalPaid, totalAll float64
	maxRemain := 0
	now := time.Now()
	for _, l := range resp.HousingFundLoans {
		totalRemain += l.Summary.RemainingAmount
		totalPaid += l.Summary.PaidAmount
		totalAll += l.Summary.TotalPayment
		if l.Summary.RemainingMonths > maxRemain {
			maxRemain = l.Summary.RemainingMonths
		}
	}
	for _, l := range resp.CommercialLoans {
		totalRemain += l.Summary.RemainingAmount
		totalPaid += l.Summary.PaidAmount
		totalAll += l.Summary.TotalPayment
		if l.Summary.RemainingMonths > maxRemain {
			maxRemain = l.Summary.RemainingMonths
		}
	}
	for _, l := range resp.BorrowedMoneys {
		totalRemain += l.Summary.RemainingAmount
		totalPaid += l.Summary.PaidAmount
		totalAll += l.Summary.TotalPayment
		if l.Summary.RemainingMonths > maxRemain {
			maxRemain = l.Summary.RemainingMonths
		}
	}
	resp.TotalPending = totalRemain
	if totalAll > 0 {
		resp.TotalProgressPct = totalPaid / totalAll
	}
	resp.TotalRemainingMonths = maxRemain
	// 预估还清时间（按当前时间 + 剩余月数）
	resp.EstimatedPayoffAt = now.AddDate(0, maxRemain, 0).Unix()

	// 投资桶
	var targetID uint64
	if scope == models.TxScopePersonal {
		targetID = uid
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err == nil {
			targetID = m.FamilyID
		}
	}
	// 取 plan 中的 investAnnualRate 作为目标
	var investPlan models.FinancialPlan
	database.DB.Where("scope = ? AND target_id = ?", scope, targetID).First(&investPlan)
	monthlyTarget := 0.0
	if investPlan.InvestAnnualRate > 0 {
		monthlyTarget = investPlan.InvestAnnualRate / 12.0
	}
	curYear, curMonth := now.Year(), int(now.Month())
	// 上月记录
	prevYear, prevMonth := curYear, curMonth-1
	if prevMonth < 1 {
		prevMonth = 12
		prevYear--
	}
	var prevRec models.InvestmentRecord
	_ = database.DB.Where("scope = ? AND target_id = ? AND year = ? AND month = ?", scope, targetID, prevYear, prevMonth).First(&prevRec).Error
	resp.Investment = InvestmentSummary{
		CurrentMonthRate: prevRec.MonthlyRate,
		CurrentYear:      curYear,
		CurrentMonth:     curMonth,
		TargetRate:       monthlyTarget,
	}
	if prevRec.ID > 0 {
		// 投资本金取 investment 桶累计（转账 + 息金 + 投资收益 50/30/20 中的 30%）
		var invPrincipal float64
		q := database.DB.Model(&models.Transaction{}).Where("scope = ? AND type = ? AND category = ?", scope, models.TxTypeTransfer, models.TransferToInvestment)
		if scope == models.TxScopePersonal {
			q = q.Where("uid = ?", uid)
		} else {
			q = q.Where("family_id = ?", targetID)
		}
		q.Select("COALESCE(SUM(amount),0)").Scan(&invPrincipal)
		// 超额/不足（基于本金）
		actualGain := invPrincipal * prevRec.MonthlyRate
		expectGain := invPrincipal * monthlyTarget
		diff := actualGain - expectGain
		if diff > 0 {
			resp.Investment.Excess = diff
			resp.Investment.HardSavingTransfer = diff * 0.3
		} else if diff < 0 {
			resp.Investment.Deficit = -diff
		}
	}

	utils.OK(c, resp)
}

// ============== 用户管理（家庭成员） ==============

// UpdateFamilyMemberReq 修改家庭成员角色
type UpdateFamilyMemberReq struct {
	IsAdmin bool `json:"isAdmin"`
}

// UpdateFamilyMember 修改家庭成员角色
func UpdateFamilyMember(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
		return
	}
	if !m.IsAdmin {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	id := c.Param("id")
	var req UpdateFamilyMemberReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var target models.FamilyMember
	if err := database.DB.First(&target, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "成员不存在")
		return
	}
	if target.FamilyID != m.FamilyID {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权操作")
		return
	}
	// 不允许取消自己管理员（避免无主家庭）
	if target.UserID == uid && !req.IsAdmin {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "请先将管理员权限移交给其他成员")
		return
	}
	database.DB.Model(&target).Update("is_admin", req.IsAdmin)
	// 同步家庭 admin 字段
	if req.IsAdmin {
		database.DB.Model(&models.Family{}).Where("id = ?", m.FamilyID).Update("admin_id", target.UserID)
	}
	utils.OK(c, gin.H{"ok": true})
}

// RemoveFamilyMember 移除家庭成员
func RemoveFamilyMember(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
		return
	}
	if !m.IsAdmin {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	id := c.Param("id")
	var target models.FamilyMember
	if err := database.DB.First(&target, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "成员不存在")
		return
	}
	if target.FamilyID != m.FamilyID {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权操作")
		return
	}
	if target.UserID == uid {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "不能移除自己")
		return
	}
	now := time.Now().Unix()
	database.DB.Model(&target).Updates(map[string]interface{}{
		"status":  models.MemberStatusLeft,
		"left_at": now,
	})
	utils.OK(c, gin.H{"ok": true})
}

// ============== 立即删除家庭（绕过冷静期） ==============

// ForceDeleteFamily 冷静期到期后执行家庭删除（文档 §11）
// 前置条件：存在全体同意（approved）的删除请求且 executeAt（发起+7天）已到期
func ForceDeleteFamily(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND is_admin = ? AND status = ?", uid, true, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	if m.FamilyID == 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "未加入家庭")
		return
	}
	familyID := m.FamilyID

	// 必须有已批准的删除请求，且冷静期（executeAt = 发起 + 7 天）已到期
	var req models.DeleteFamilyRequest
	if err := database.DB.Where("family_id = ? AND status = ?", familyID, "approved").First(&req).Error; err != nil {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "不存在已通过投票的删除请求")
		return
	}
	now := time.Now().Unix()
	if req.ExecuteAt > now {
		remaining := (req.ExecuteAt - now + 3599) / 3600
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "冷静期未到期，剩余约 "+strconv.FormatInt(remaining, 10)+" 小时")
		return
	}

	// 事务内级联软删：成员、家庭、家庭范围的规划/大件/投资/贷款/未来利益
	err := database.DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&req).Update("status", "executed").Error; err != nil {
			return err
		}
		if err := tx.Model(&models.FamilyMember{}).Where("family_id = ?", familyID).Update("status", models.MemberStatusLeft).Error; err != nil {
			return err
		}
		// 家庭空间的规划类数据一并软删（流水保留为历史，不再随家庭展示）
		if err := tx.Where("scope = ? AND target_id = ?", models.TxScopeFamily, familyID).Delete(&models.FinancialPlan{}).Error; err != nil {
			return err
		}
		if err := tx.Where("scope = ? AND target_id = ?", models.TxScopeFamily, familyID).Delete(&models.PurchasePlan{}).Error; err != nil {
			return err
		}
		if err := tx.Where("scope = ? AND target_id = ?", models.TxScopeFamily, familyID).Delete(&models.InvestmentRecord{}).Error; err != nil {
			return err
		}
		// 贷款/借款/未来利益按 family_id 关联
		for _, mdl := range []any{&models.HousingFundLoan{}, &models.CommercialLoan{}, &models.BorrowedMoney{}, &models.FutureBenefit{}} {
			if err := tx.Where("scope = ? AND family_id = ?", models.TxScopeFamily, familyID).Delete(mdl).Error; err != nil {
				return err
			}
		}
		return tx.Delete(&models.Family{}, familyID).Error
	})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true, "message": "家庭已解散"})
}

// ============== 投资通知（月初1号） ==============

// MonthlyInvestmentCheck 返回当前是否需要更新上月投资收益（被 cron 或前端首次启动调用）
func MonthlyInvestmentCheck(c *gin.Context) {
	uid := middleware.MustUID(c)
	now := time.Now()
	// 上月
	prevYear, prevMonth := now.Year(), int(now.Month())-1
	if prevMonth < 1 {
		prevMonth = 12
		prevYear--
	}
	type PendingItem struct {
		Scope    string `json:"scope"`
		TargetID uint64 `json:"targetId"`
		Year     int    `json:"year"`
		Month    int    `json:"month"`
	}
	pending := []PendingItem{}
	// 检查个人
	var personalPlan models.FinancialPlan
	if err := database.DB.Where("scope = ? AND target_id = ?", models.TxScopePersonal, uid).First(&personalPlan).Error; err == nil {
		var rec models.InvestmentRecord
		err := database.DB.Where("scope = ? AND target_id = ? AND year = ? AND month = ?", models.TxScopePersonal, uid, prevYear, prevMonth).First(&rec).Error
		if err != nil {
			pending = append(pending, PendingItem{Scope: models.TxScopePersonal, TargetID: uid, Year: prevYear, Month: prevMonth})
		}
	}
	// 检查家庭
	var fm models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&fm).Error; err == nil {
		var rec models.InvestmentRecord
		err := database.DB.Where("scope = ? AND target_id = ? AND year = ? AND month = ?", models.TxScopeFamily, fm.FamilyID, prevYear, prevMonth).First(&rec).Error
		if err != nil {
			pending = append(pending, PendingItem{Scope: models.TxScopeFamily, TargetID: fm.FamilyID, Year: prevYear, Month: prevMonth})
		}
	}
	// 如果有待记录的投资收益，推送通知
	if len(pending) > 0 {
		ns := services.NewNotifyService(database.DB)
		monthStr := fmt.Sprintf("%d年%d月", prevYear, prevMonth)
		_ = ns.PushTo(uid, "system", "投资收益待记录", monthStr+"的投资收益尚未录入，请前往「未来财务」页面记录", "")
	}

	utils.OK(c, gin.H{
		"pending": pending,
		"year":    prevYear,
		"month":   prevMonth,
	})
}

// PutTx 编辑账单
func PutTx(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var tx models.Transaction
	if err := database.DB.First(&tx, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if tx.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权修改")
		return
	}
	var req CreateTxReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	if req.Type != "" {
		tx.Type = req.Type
	}
	if req.Category != "" {
		tx.Category = req.Category
	}
	if req.Amount > 0 {
		tx.Amount = req.Amount
	}
	if req.Note != "" {
		tx.Note = req.Note
	}
	if req.OccurredAt > 0 {
		tx.OccurredAt = req.OccurredAt
	}
	if req.LoanRef != "" {
		tx.LoanRef = req.LoanRef
	}
	if req.TargetBucket != "" {
		tx.TargetBucket = req.TargetBucket
	}
	database.DB.Save(&tx)
	utils.OK(c, tx)
}

// 查询参数辅助
func parseUintQuery(c *gin.Context, key string, def uint64) uint64 {
	v, _ := strconv.ParseUint(c.Query(key), 10, 64)
	if v == 0 {
		return def
	}
	return v
}
