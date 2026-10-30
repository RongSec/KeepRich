package services

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// FinanceService 财务预规划相关计算与判定
type FinanceService struct{ DB *gorm.DB }

func NewFinanceService(db *gorm.DB) *FinanceService { return &FinanceService{DB: db} }

// applyScopeQuery 为查询应用 scope 条件
// 个人：只查 uid 的数据
// 家庭：聚合所有活跃成员的个人数据 + 家庭数据
func (s *FinanceService) applyScopeQuery(q *gorm.DB, scope string, uid uint64, familyID *uint64) *gorm.DB {
	if scope == models.TxScopePersonal {
		return q.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid)
	}
	// 家庭：获取所有活跃成员的 uid
	var memberIDs []uint64
	s.DB.Model(&models.FamilyMember{}).
		Where("family_id = ? AND status = ?", *familyID, models.MemberStatusActive).
		Pluck("user_id", &memberIDs)
	if len(memberIDs) == 0 {
		memberIDs = []uint64{0}
	}
	return q.Where("(scope = 'personal' AND uid IN ?) OR (scope = 'family' AND family_id = ?)",
		memberIDs, *familyID)
}

// OverviewData 总览数据
type OverviewData struct {
	// 三大资产池
	TotalCash         float64 `json:"totalCash"`         // 现金 = 累计收入 - 累计日常消费
	TotalHousingFund  float64 `json:"totalHousingFund"`  // 公积金（单独展示）
	TotalWealthProduct float64 `json:"totalWealthProduct"` // 未来利益（折现到当下）

	// 6 大分配桶的当前余额（来自记账聚合）
	SavingBalance    float64 `json:"savingBalance"`    // 储蓄
	InvestmentBalance float64 `json:"investmentBalance"` // 长远投资（含收益复利）
	EmergencyBalance  float64 `json:"emergencyBalance"`  // 应急备用金
	PensionBalance    float64 `json:"pensionBalance"`    // 养老金
	DailySpent        float64 `json:"dailySpent"`        // 本月日常消费
	// 全量累计（用于家庭总财富）
	CumulativeIncome   float64 `json:"cumulativeIncome"`   // 累计收入
	CumulativeDaily    float64 `json:"cumulativeDaily"`    // 累计日常消费

	// 目标
	EmergencyTarget float64 `json:"emergencyTarget"`
	PensionTarget   float64 `json:"pensionTarget"`

	// 完成度与预估月数
	EmergencyPct        float64 `json:"emergencyPct"`        // 0-1
	EmergencyMonthsLeft int     `json:"emergencyMonthsLeft"` // 0 表示已达成
	PensionPct          float64 `json:"pensionPct"`
	PensionMonthsLeft   int     `json:"pensionMonthsLeft"`

	// 关键指标
	WorryFreePerBuy    float64 `json:"worryFreePerBuy"`    // (储蓄桶 + 年收入*20) ÷ 1万，单位：元
	AnnualIncome       float64 `json:"annualIncome"`       // 年薪（工资+公积金年化）
	MonthlyConsumable  float64 `json:"monthlyConsumable"`  // 本月可消费（累加机制后）
	MonthConsumableLeft float64 `json:"monthConsumableLeft"` // 本月剩余可消费（= MonthlyConsumable - DailySpent）
	SavingCarryOver    float64 `json:"savingCarryOver"`    // 上月剩余沉淀到储蓄的金额
	RemainingBudget    float64 `json:"remainingBudget"`    // 当月可支配 - 已记账支出

	// 未来财富（不含债务，仅未来利益折现）— 用于 2x2 卡片阵列
	FutureWealth float64 `json:"futureWealth"`

	// 家庭总财富
	// 总财富 = (累计收入 - 累计日常消费) + 投资桶余额 + 公积金 + 未来利益折现 - 待还款
	TotalWealth float64 `json:"totalWealth"`
	// 总还进度（聚合）
	TotalPending         float64 `json:"totalPending"`
	TotalProgressPct     float64 `json:"totalProgressPct"`
	TotalRemainingMonths int     `json:"totalRemainingMonths"`
	EstimatedPayoffAt    int64   `json:"estimatedPayoffAt"`

	// 月度分配
	Allocation Allocation `json:"allocation"`

	// 大件前 5（按优先级，含预估完成所需月数）
	TopPurchases []PurchaseProjection `json:"topPurchases"`
}

type Allocation struct {
	MonthlyIncome   float64 `json:"monthlyIncome"`
	Loan            float64 `json:"loan"`
	Saving          float64 `json:"saving"`
	Investment      float64 `json:"investment"`
	Emergency       float64 `json:"emergency"`
	Pension         float64 `json:"pension"`
	Consumption     float64 `json:"consumption"`
	Overspend       float64 `json:"overspend"`
	InvestmentGap   float64 `json:"investmentGap"`
	InvestmentExcess float64 `json:"investmentExcess"`

	// 本月已入桶金额（按 category 累计）
	SavingThisMonth      float64 `json:"savingThisMonth"`
	InvestmentThisMonth  float64 `json:"investmentThisMonth"`
	EmergencyThisMonth   float64 `json:"emergencyThisMonth"`
	PensionThisMonth     float64 `json:"pensionThisMonth"`
	ConsumptionThisMonth float64 `json:"consumptionThisMonth"`
	// 本月应入桶金额（按 plan 比例计算）
	SavingTarget      float64 `json:"savingTarget"`
	InvestmentTarget  float64 `json:"investmentTarget"`
	EmergencyTarget   float64 `json:"emergencyTarget"`
	PensionTarget     float64 `json:"pensionTarget"`
	ConsumptionTarget float64 `json:"consumptionTarget"`
}

type PurchaseProjection struct {
	ID                uint64  `json:"id"`
	Name              string  `json:"name"`
	Price             float64 `json:"price"`
	Priority          int     `json:"priority"`
	EstimatedMonths   int     `json:"estimatedMonths"` // 0 表示已达成
	Achievable        bool    `json:"achievable"`
}

// GetOverview scope=personal 时传 uid；scope=family 时传 familyID
func (s *FinanceService) GetOverview(scope string, uid uint64, familyID *uint64) (*OverviewData, error) {
	if scope != models.TxScopePersonal && scope != models.TxScopeFamily {
		return nil, errors.New("invalid scope")
	}

	// 全部使用直接 SUM 查询（与 sumScopeBetween 相同模式），避免 GROUP BY + Rows/Scan 的潜在问题
	var expenseSum, cumulativeDaily float64
	_ = s.sumScopeAll(scope, uid, familyID, models.TxTypeExpense, &expenseSum)
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeExpense, models.ExpenseDaily, &cumulativeDaily)

	// 桶余额 = 存钱（转账）累计 + 息金（按 targetBucket 累计）- 按 sourceBucket 扣减的支出
	var saving, investment, emergency, pension float64
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeTransfer, models.TransferToSaving, &saving)
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeTransfer, models.TransferToInvestment, &investment)
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeTransfer, models.TransferToEmergency, &emergency)
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeTransfer, models.TransferToPension, &pension)
	// 息金按目标桶聚合
	_ = s.sumScopeByTargetBucket(scope, uid, familyID, "saving", &saving)
	_ = s.sumScopeByTargetBucket(scope, uid, familyID, "investment", &investment)
	_ = s.sumScopeByTargetBucket(scope, uid, familyID, "emergency", &emergency)
	_ = s.sumScopeByTargetBucket(scope, uid, familyID, "pension", &pension)

	// 按 sourceBucket 从对应桶扣减支出
	var savingExp, investmentExp, emergencyExp, pensionExp, housingFundExp float64
	_ = s.sumScopeBySourceBucket(scope, uid, familyID, "saving", &savingExp)
	_ = s.sumScopeBySourceBucket(scope, uid, familyID, "investment", &investmentExp)
	_ = s.sumScopeBySourceBucket(scope, uid, familyID, "emergency", &emergencyExp)
	_ = s.sumScopeBySourceBucket(scope, uid, familyID, "pension", &pensionExp)
	_ = s.sumScopeBySourceBucket(scope, uid, familyID, "housing_fund", &housingFundExp)
	saving -= savingExp
	investment -= investmentExp
	// 现金来源的支出 = 总支出 - 非现金来源的支出（避免双重扣减）
	nonCashExpense := savingExp + investmentExp + emergencyExp + pensionExp + housingFundExp
	cumulativeExpense := expenseSum - nonCashExpense
	if cumulativeExpense < 0 {
		cumulativeExpense = 0
	}
	emergency -= emergencyExp
	pension -= pensionExp

	var incomeSum, housingFund float64
	_ = s.sumScopeAll(scope, uid, familyID, models.TxTypeIncome, &incomeSum)
	// 公积金桶 = 当月公积金 + 过往公积金
	var currentHousingFund, pastHousingFund float64
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeIncome, models.IncomeHousingFund, &currentHousingFund)
	_ = s.sumScopeCategory(scope, uid, familyID, models.TxTypeIncome, models.IncomePastHousing, &pastHousingFund)
	housingFund = currentHousingFund + pastHousingFund

	// 公积金余额扣减已从公积金来源支付的支出
	housingFund -= housingFundExp
	if housingFund < 0 {
		housingFund = 0
	}

	// 不计入现金池的收入（公积金+过往公积金，因为公积金有独立账户）
	// 过往存款、意外收入纳入个人总财富（通过 totalCash）
	nonSalaryIncome := currentHousingFund + pastHousingFund

	// 现金池：累计收入 - 不计入现金的收入 - 现金来源的支出 - 存钱总额
	var totalTransfer float64
	_ = s.sumScopeAll(scope, uid, familyID, models.TxTypeTransfer, &totalTransfer)
	totalCash := incomeSum - nonSalaryIncome - cumulativeExpense - totalTransfer
	if totalCash < 0 {
		totalCash = 0
	}

	// 年薪计算：仅基于工资收入（不包含公积金、过往存款等）
	yearAgo := time.Now().AddDate(-1, 0, 0).Unix()
	var salaryIncome float64
	_ = s.sumScopeAfter(scope, uid, familyID, models.TxTypeIncome, models.IncomeSalary, yearAgo, &salaryIncome)

	// 计算实际有工资收入的月数
	var activeMonths int
	s.DB.Model(&models.Transaction{}).
		Where("scope = ? AND type = ? AND category = ? AND occurred_at >= ?", scope, models.TxTypeIncome, models.IncomeSalary, yearAgo).
		Where(func(db *gorm.DB) *gorm.DB {
			if scope == models.TxScopePersonal {
				return db.Where("uid = ?", uid)
			}
			return db.Where("family_id = ?", *familyID)
		}).
		Select("COUNT(DISTINCT DATE_FORMAT(FROM_UNIXTIME(occurred_at), '%Y-%m'))").Scan(&activeMonths)
	if activeMonths < 1 {
		activeMonths = 1
	}
	annualIncome := salaryIncome / float64(activeMonths) * 12.0

	// 无顾虑单笔（元）= (储蓄桶余额 + 年薪×20) ÷ 1万
	worryFree := (saving + annualIncome*20) / 10000

	plan, err := s.getPlan(scope, uid, familyID)
	if err != nil {
		return nil, err
	}

	// 本月已实现工资收入（桶分配仅基于工资，不含公积金、过往存款、意外收入等）
	now := time.Now()
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location()).Unix()
	var monthlyIncome float64
	_ = s.sumScopeAfter(scope, uid, familyID, models.TxTypeIncome, models.IncomeSalary, monthStart, &monthlyIncome)

	// 本月已支出
	var monthExpense float64
	_ = s.sumScopeAfter(scope, uid, familyID, models.TxTypeExpense, "", monthStart, &monthExpense)

	alloc := Allocation{
		MonthlyIncome:        monthlyIncome,
		Loan:                 monthlyIncome * plan.LoanRatio,
		Saving:               monthlyIncome * plan.SavingRatio,
		Investment:           monthlyIncome * plan.InvestmentRatio,
		Emergency:            monthlyIncome * plan.EmergencyRatio,
		Pension:              monthlyIncome * plan.PensionRatio,
		Consumption:          monthlyIncome * plan.ConsumptionRatio,
		SavingTarget:         monthlyIncome * plan.SavingRatio,
		InvestmentTarget:     monthlyIncome * plan.InvestmentRatio,
		EmergencyTarget:      monthlyIncome * plan.EmergencyRatio,
		PensionTarget:        monthlyIncome * plan.PensionRatio,
		ConsumptionTarget:    monthlyIncome * plan.ConsumptionRatio,
	}
	// 本月已入桶金额（按 transfer 分类）
	nowEnd := now.Unix()
	_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToSaving, monthStart, nowEnd, &alloc.SavingThisMonth)
	_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToInvestment, monthStart, nowEnd, &alloc.InvestmentThisMonth)
	_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToEmergency, monthStart, nowEnd, &alloc.EmergencyThisMonth)
	_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToPension, monthStart, nowEnd, &alloc.PensionThisMonth)
	// 消费 = 本月总支出 - 偿还贷款（已知的非消费支出）
	var monthLoanRepay float64
	_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeExpense, models.ExpenseLoanRepay, monthStart, nowEnd, &monthLoanRepay)
	alloc.ConsumptionThisMonth = monthExpense - monthLoanRepay
	if alloc.ConsumptionThisMonth < 0 {
		alloc.ConsumptionThisMonth = 0
	}
	// Consumption 直接按比例计算，不用 leftover 方式
	// alloc.Consumption 已在上面通过 monthlyIncome * plan.ConsumptionRatio 计算

	// 本月日常消费（用于计算本月剩余可消费）
	var monthDaily float64
	_ = s.sumScopeAfter(scope, uid, familyID, models.TxTypeExpense, models.ExpenseDaily, monthStart, &monthDaily)

	// 投资缺口：当月实际收益率 < 目标
	monthlyRate, _ := s.monthlyInvestmentRate(scope, uid, familyID, now.Year(), int(now.Month()))
	expectRate := plan.InvestAnnualRate / 12.0
	if monthlyRate < expectRate {
		alloc.InvestmentGap = (expectRate - monthlyRate) * monthlyIncome
	}

	// 完成度
	emergencyPct := 0.0
	emergencyMonthsLeft := 0
	if plan.EmergencyTarget > 0 {
		emergencyPct = clamp01(emergency / plan.EmergencyTarget)
		emergencyMonthsLeft = monthsToTarget(plan.EmergencyRatio, monthlyIncome, plan.EmergencyTarget, emergency)
	}
	pensionPct := 0.0
	pensionMonthsLeft := 0
	if plan.PensionTarget > 0 {
		pensionPct = clamp01(pension / plan.PensionTarget)
		pensionMonthsLeft = monthsToTarget(plan.PensionRatio, monthlyIncome, plan.PensionTarget, pension)
	}

	// 大件前 5 + 预估月数
	top, _ := s.topPurchaseProjections(scope, uid, familyID, totalCash, plan)

	// 当月可支配 - 已记账支出
	remaining := monthlyIncome - monthExpense
	if remaining < 0 {
		remaining = 0
	}

	// 家庭总财富：现金池 + 投资桶 + 公积金 + 未来利益折现 - 待还款
	// 现金池 = 累计收入 - 累计日常消费（其余 4 桶已转入对应桶余额，不扣减现金）
	wealthProduct := 0.0
	var fb []models.FutureBenefit
	fbQ := s.applyGenericScopeQuery(s.DB, scope, uid, familyID)
	fbQ.Find(&fb)
	for _, b := range fb {
		s := utils.BenefitSummary(b.PayoutDate, b.PayoutAmount, b.Type, plan.CurrentAge, plan.LifeExpectancy, b.CustomYears)
		if pv, ok := s["presentValue"].(float64); ok {
			wealthProduct += pv
		}
	}

	// 待还款总额（聚合 loans）
	totalPending := 0.0
	totalPaidAgg := 0.0
	totalAllAgg := 0.0
	maxRemain := 0
	aggLoans := func(months int, total, paid float64) {
		totalPending += total - paid
		totalPaidAgg += paid
		totalAllAgg += total
		if months > maxRemain {
			maxRemain = months
		}
	}
	var hflist []models.HousingFundLoan
	s.applyGenericScopeQuery(s.DB, scope, uid, familyID).Find(&hflist)
	for _, l := range hflist {
		sm := utils.ComputeLoanSummary(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
		aggLoans(sm.RemainingMonths, sm.TotalPayment, sm.PaidAmount)
	}
	var cllist []models.CommercialLoan
	s.applyGenericScopeQuery(s.DB, scope, uid, familyID).Find(&cllist)
	for _, l := range cllist {
		sm := utils.ComputeLoanSummary(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
		aggLoans(sm.RemainingMonths, sm.TotalPayment, sm.PaidAmount)
	}
	var bmlist []models.BorrowedMoney
	s.applyGenericScopeQuery(s.DB, scope, uid, familyID).Find(&bmlist)
	for _, l := range bmlist {
		sm := utils.ComputeLoanSummary(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
		aggLoans(sm.RemainingMonths, sm.TotalPayment, sm.PaidAmount)
	}

	totalProgressPct := 0.0
	if totalAllAgg > 0 {
		totalProgressPct = totalPaidAgg / totalAllAgg
	}
	estimatedPayoffAt := time.Now().AddDate(0, maxRemain, 0).Unix()

	// 家庭总财富：现金池 + 5 大桶余额 + 公积金
	// 不包含贷款、债务、未来利益（这些单独在卡片中展示）
	totalWealth := totalCash + saving + investment + emergency + pension + housingFund
	if totalWealth < 0 {
		totalWealth = 0
	}

	// 本月剩余可消费 = 本月可消费配额 - 本月已花日常消费
	// 注意：花超后保留负数，便于用户直观看到超支金额
	// 使用 alloc.Consumption（原始配额）而非 monthlyConsumable（已扣减 monthDaily 的剩余），避免重复扣减
	monthConsumableLeft := alloc.Consumption - monthDaily

	return &OverviewData{
		TotalCash:           totalCash,
		TotalHousingFund:    housingFund,
		TotalWealthProduct:  wealthProduct,
		SavingBalance:       saving,
		InvestmentBalance:   investment,
		EmergencyBalance:    emergency,
		PensionBalance:      pension,
		DailySpent:          monthDaily,
		CumulativeIncome:    incomeSum,
		CumulativeDaily:     cumulativeDaily,
		EmergencyTarget:     plan.EmergencyTarget,
		PensionTarget:       plan.PensionTarget,
		EmergencyPct:        emergencyPct,
		EmergencyMonthsLeft: emergencyMonthsLeft,
		PensionPct:          pensionPct,
		PensionMonthsLeft:   pensionMonthsLeft,
		WorryFreePerBuy:     worryFree,
		AnnualIncome:        annualIncome,
		MonthlyConsumable:   alloc.Consumption,
		MonthConsumableLeft: monthConsumableLeft,
		SavingCarryOver:     0,
		RemainingBudget:     remaining,
		FutureWealth:        wealthProduct, // 未来财富（仅未来利益折现，不含债务）
		Allocation:          alloc,
		TopPurchases:        top,
		TotalWealth:         totalWealth,
		TotalPending:        totalPending,
		TotalProgressPct:    totalProgressPct,
		TotalRemainingMonths: maxRemain,
		EstimatedPayoffAt:   estimatedPayoffAt,
	}, nil
}

// topPurchaseProjections 取前 5 条，按 (priority asc, price desc) 排序，
// 预估月数 = (price - 可用现金) / (月收入 * 大件可占比)
func (s *FinanceService) topPurchaseProjections(scope string, uid uint64, familyID *uint64, cash float64, plan *models.FinancialPlan) ([]PurchaseProjection, error) {
	var list []models.PurchasePlan
	q := s.DB.Where("achieved = ?", false)
	if scope == models.TxScopePersonal {
		q = q.Where("scope = ? AND target_id = ?", models.TxScopePersonal, uid)
	} else {
		// 家庭：获取所有成员的个人计划 + 家庭计划
		var memberIDs []uint64
		s.DB.Model(&models.FamilyMember{}).
			Where("family_id = ? AND status = ?", *familyID, models.MemberStatusActive).
			Pluck("user_id", &memberIDs)
		if len(memberIDs) == 0 {
			memberIDs = []uint64{0}
		}
		q = q.Where("(scope = ? AND target_id IN ?) OR (scope = ? AND target_id = ?)",
			models.TxScopePersonal, memberIDs, models.TxScopeFamily, *familyID)
	}
	if err := q.Order("priority ASC, price DESC").Limit(5).Find(&list).Error; err != nil {
		return nil, err
	}
	out := make([]PurchaseProjection, 0, len(list))
	for _, p := range list {
		pp := PurchaseProjection{ID: p.ID, Name: p.Name, Price: p.Price, Priority: p.Priority}
		if p.Price <= cash {
			pp.Achievable = true
			pp.EstimatedMonths = 0
		} else {
			// 用近 12 个月工资收入推月均（仅工资，不含公积金、过往存款等）
			yearAgo := time.Now().AddDate(-1, 0, 0).Unix()
			var annual float64
			_ = s.sumScopeAfter(scope, uid, familyID, models.TxTypeIncome, models.IncomeSalary, yearAgo, &annual)
			monthly := annual / 12.0
			avail := monthly * plan.BigPurchaseRatio
			if avail <= 0 {
				pp.EstimatedMonths = -1
			} else {
				pp.EstimatedMonths = int((p.Price - cash) / avail)
				if pp.EstimatedMonths < 1 {
					pp.EstimatedMonths = 1
				}
			}
		}
		out = append(out, pp)
	}
	return out, nil
}

// ChartData 用于前端总览图表
type ChartData struct {
	// 最近 12 个月家庭总财富曲线
	Wealth []WealthPoint `json:"wealth"`
	// 最近 30 天支出分类构成
	CategoryPie []CategorySlice `json:"categoryPie"`
}

type WealthPoint struct {
	Month      string  `json:"month"` // YYYY-MM
	TotalWealth float64 `json:"totalWealth"` // 累计净财富
	Saving      float64 `json:"saving"`
	Investment  float64 `json:"investment"`
	Emergency   float64 `json:"emergency"`
	Pension     float64 `json:"pension"`
	WealthProduct float64 `json:"wealthProduct"` // 未来利益折现
	Pending     float64 `json:"pending"`         // 待还款
}

type CategorySlice struct {
	Category string  `json:"category"`
	Label    string  `json:"label"`
	Amount   float64 `json:"amount"`
}

func (s *FinanceService) GetChartData(scope string, uid uint64, familyID *uint64, period string) (*ChartData, error) {
	out := &ChartData{Wealth: []WealthPoint{}, CategoryPie: []CategorySlice{}}
	now := time.Now()

	// 加载用户规划（用于未来利益折现的年龄参数）
	plan, _ := s.getPlan(scope, uid, familyID)

	// 贷款和未来利益（恒定）— 折现到各月时假设线性增长（简化处理）
	var hflist []models.HousingFundLoan
	var cllist []models.CommercialLoan
	var bmlist []models.BorrowedMoney
	var fblist []models.FutureBenefit
	loanQ := s.DB
	if scope == models.TxScopePersonal {
		loanQ = loanQ.Where("uid = ?", uid)
	} else if familyID != nil {
		loanQ = loanQ.Where("family_id = ?", *familyID)
	}
	loanQ.Find(&hflist)
	loanQ.Find(&cllist)
	loanQ.Find(&bmlist)
	loanQ.Find(&fblist)
	pendingNow := 0.0
	for _, l := range hflist {
		pendingNow += utils.RemainingPrincipalAny(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
	}
	for _, l := range cllist {
		pendingNow += utils.RemainingPrincipalAny(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
	}
	for _, l := range bmlist {
		pendingNow += utils.RemainingPrincipalAny(l.Total, l.AnnualRate, l.TermMonths, l.PaidMonths, l.Method)
	}
	wealthProductNow := 0.0
	for _, b := range fblist {
		sm := utils.BenefitSummary(b.PayoutDate, b.PayoutAmount, b.Type, plan.CurrentAge, plan.LifeExpectancy, b.CustomYears)
		if v, ok := sm["presentValue"].(float64); ok {
			wealthProductNow += v
		}
	}

	// 累计净财富曲线（支持月/年两种粒度）
	type timePoint struct {
		label string
		end   int64
	}
	var points []timePoint
	if period == "year" {
		// 最近 5 年，每年一个数据点
		for i := 4; i >= 0; i-- {
			year := now.Year() - i
			t := time.Date(year+1, 1, 1, 0, 0, 0, 0, now.Location()) // 次年1月1日
			points = append(points, timePoint{
				label: fmt.Sprintf("%d", year),
				end:   t.Unix(),
			})
		}
	} else {
		// 最近 12 个月（默认）
		for i := 11; i >= 0; i-- {
			t := time.Date(now.Year(), now.Month()-time.Month(i), 1, 0, 0, 0, 0, now.Location())
			end := t.AddDate(0, 1, 0).Unix()
			points = append(points, timePoint{
				label: t.Format("2006-01"),
				end:   end,
			})
		}
	}
	for _, p := range points {
		var inc, exp float64
		_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeIncome, "", 0, p.end, &inc)
		_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeExpense, "", 0, p.end, &exp)
		net := inc - exp
		var sv, iv, em, pn float64
		_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToSaving, 0, p.end, &sv)
		_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToInvestment, 0, p.end, &iv)
		_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToEmergency, 0, p.end, &em)
		_ = s.sumScopeBetween(scope, uid, familyID, models.TxTypeTransfer, models.TransferToPension, 0, p.end, &pn)
		var svI, ivI, emI, pnI float64
		_ = s.sumByBucketBetween(scope, uid, familyID, "saving", 0, p.end, &svI)
		_ = s.sumByBucketBetween(scope, uid, familyID, "investment", 0, p.end, &ivI)
		_ = s.sumByBucketBetween(scope, uid, familyID, "emergency", 0, p.end, &emI)
		_ = s.sumByBucketBetween(scope, uid, familyID, "pension", 0, p.end, &pnI)
		sv += svI
		iv += ivI
		em += emI
		pn += pnI
		out.Wealth = append(out.Wealth, WealthPoint{
			Month:         p.label,
			TotalWealth:   net + wealthProductNow - pendingNow,
			Saving:        sv,
			Investment:    iv,
			Emergency:     em,
			Pension:       pn,
			WealthProduct: wealthProductNow,
			Pending:       pendingNow,
		})
	}

	// 30 天分类
	thirtyAgo := now.AddDate(0, 0, -30).Unix()
	rows, err := s.aggregateByCategoryAfter(scope, uid, familyID, models.TxTypeExpense, thirtyAgo)
	if err != nil {
		return out, nil
	}
	for _, r := range rows {
		out.CategoryPie = append(out.CategoryPie, CategorySlice{
			Category: r.Category,
			Label:    models.CategoryLabel[r.Category],
			Amount:   r.Total,
		})
	}
	return out, nil
}

// 工具
func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func pow(x, n float64) float64 {
	return math.Pow(x, n)
}

// monthsToTarget 估算达到目标所需的月份；monthlyAdd = monthlyIncome * ratio
func monthsToTarget(ratio, monthlyIncome, target, current float64) int {
	if current >= target {
		return 0
	}
	monthlyAdd := monthlyIncome * ratio
	if monthlyAdd <= 0 {
		return -1
	}
	m := int((target - current) / monthlyAdd)
	if m < 1 {
		return 1
	}
	return m
}

// ====== 复用方法 ======
type categorySum struct {
	Category string
	Total    float64
}

func (s *FinanceService) aggregateByCategory(scope string, uid uint64, familyID *uint64, txType string) ([]categorySum, error) {
	q := s.DB.Model(&models.Transaction{}).
		Select("category, COALESCE(SUM(amount),0) AS total").
		Where("type = ?", txType).
		Group("category")
	q = s.applyScopeQuery(q, scope, uid, familyID)
	rows, err := q.Rows()
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []categorySum{}
	for rows.Next() {
		var c categorySum
		if err := rows.Scan(&c.Category, &c.Total); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

func (s *FinanceService) aggregateByCategoryAfter(scope string, uid uint64, familyID *uint64, txType string, after int64) ([]categorySum, error) {
	q := s.DB.Model(&models.Transaction{}).
		Select("category, COALESCE(SUM(amount),0) AS total").
		Where("type = ? AND occurred_at >= ?", txType, after).
		Group("category")
	q = s.applyScopeQuery(q, scope, uid, familyID)
	rows, err := q.Rows()
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []categorySum{}
	for rows.Next() {
		var c categorySum
		if err := rows.Scan(&c.Category, &c.Total); err == nil {
			out = append(out, c)
		}
	}
	return out, nil
}

func (s *FinanceService) sumScopeAfter(scope string, uid uint64, familyID *uint64, txType, category string, after int64, out *float64) error {
	q := s.DB.Model(&models.Transaction{}).Where("type = ? AND occurred_at >= ?", txType, after)
	if category != "" {
		q = q.Where("category = ?", category)
	}
	q = s.applyScopeQuery(q, scope, uid, familyID)
	return q.Select("COALESCE(SUM(amount),0)").Scan(out).Error
}

func (s *FinanceService) sumScopeBetween(scope string, uid uint64, familyID *uint64, txType, category string, start, end int64, out *float64) error {
	q := s.DB.Model(&models.Transaction{}).Where("type = ? AND occurred_at >= ? AND occurred_at < ?", txType, start, end)
	if category != "" {
		q = q.Where("category = ?", category)
	}
	q = s.applyScopeQuery(q, scope, uid, familyID)
	return q.Select("COALESCE(SUM(amount),0)").Scan(out).Error
}

// sumScopeCategory 累计指定 type+category 的全量金额（无时间窗口）
func (s *FinanceService) sumScopeCategory(scope string, uid uint64, familyID *uint64, txType, category string, out *float64) error {
	q := s.DB.Model(&models.Transaction{}).Where("type = ? AND category = ?", txType, category)
	q = s.applyScopeQuery(q, scope, uid, familyID)
	return q.Select("COALESCE(SUM(amount),0)").Scan(out).Error
}

// sumScopeAll 累计指定 type 的全量金额（所有 category，无时间窗口）
func (s *FinanceService) sumScopeAll(scope string, uid uint64, familyID *uint64, txType string, out *float64) error {
	q := s.DB.Model(&models.Transaction{}).Where("type = ?", txType)
	q = s.applyScopeQuery(q, scope, uid, familyID)
	return q.Select("COALESCE(SUM(amount),0)").Scan(out).Error
}

// sumScopeByTargetBucket 累计指定 targetBucket 的息金/转账（累加到 *out，不覆盖）
func (s *FinanceService) sumScopeByTargetBucket(scope string, uid uint64, familyID *uint64, bucket string, out *float64) error {
	var sum float64
	q := s.DB.Model(&models.Transaction{}).Where("type = ? AND target_bucket = ?", models.TxTypeIncome, bucket)
	q = s.applyScopeQuery(q, scope, uid, familyID)
	if err := q.Select("COALESCE(SUM(amount),0)").Scan(&sum).Error; err != nil {
		return err
	}
	*out += sum
	return nil
}

// sumByBucketBetween 在时间窗口内累计指定 targetBucket 的息金
func (s *FinanceService) sumByBucketBetween(scope string, uid uint64, familyID *uint64, bucket string, start, end int64, out *float64) error {
	q := s.DB.Model(&models.Transaction{}).
		Where("type = ? AND target_bucket = ? AND occurred_at >= ? AND occurred_at < ?", models.TxTypeIncome, bucket, start, end)
	q = s.applyScopeQuery(q, scope, uid, familyID)
	return q.Select("COALESCE(SUM(amount),0)").Scan(out).Error
}

// sumScopeBySourceBucket 累计指定 sourceBucket 的支出（从对应桶扣减）
// 优先读取 source_details（多来源），无 source_details 时回退到 source_bucket（单来源）
func (s *FinanceService) sumScopeBySourceBucket(scope string, uid uint64, familyID *uint64, bucket string, out *float64) error {
	// 1) 单来源记录（source_bucket 匹配，且无 source_details）
	var singleSum float64
	q := s.DB.Model(&models.Transaction{}).
		Where("type = ? AND source_bucket = ? AND (source_details IS NULL OR source_details = '')", models.TxTypeExpense, bucket)
	q = s.applyScopeQuery(q, scope, uid, familyID)
	if err := q.Select("COALESCE(SUM(amount),0)").Scan(&singleSum).Error; err != nil {
		return err
	}

	// 2) 多来源记录（source_details JSON 中包含该 bucket）
	var multiSum float64
	q2 := s.DB.Model(&models.Transaction{}).
		Where("type = ? AND source_details IS NOT NULL AND source_details != ''", models.TxTypeExpense)
	q2 = s.applyScopeQuery(q2, scope, uid, familyID)
	var txs []models.Transaction
	q2.Select("source_details").Find(&txs)
	for _, tx := range txs {
		var details []struct {
			Bucket string  `json:"bucket"`
			Amount float64 `json:"amount"`
		}
		if err := json.Unmarshal([]byte(tx.SourceDetails), &details); err == nil {
			for _, d := range details {
				if d.Bucket == bucket {
					multiSum += d.Amount
				}
			}
		}
	}

	*out = singleSum + multiSum
	return nil
}

// applyGenericScopeQuery 通用 scope 查询（适用于非 transactions 表，如 loans、benefits 等）
func (s *FinanceService) applyGenericScopeQuery(q *gorm.DB, scope string, uid uint64, familyID *uint64) *gorm.DB {
	if scope == models.TxScopePersonal {
		return q.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid)
	}
	var memberIDs []uint64
	s.DB.Model(&models.FamilyMember{}).
		Where("family_id = ? AND status = ?", *familyID, models.MemberStatusActive).
		Pluck("user_id", &memberIDs)
	if len(memberIDs) == 0 {
		memberIDs = []uint64{0}
	}
	return q.Where("(scope = 'personal' AND uid IN ?) OR (scope = 'family' AND family_id = ?)",
		memberIDs, *familyID)
}

func (s *FinanceService) getPlan(scope string, uid uint64, familyID *uint64) (*models.FinancialPlan, error) {
	var p models.FinancialPlan
	q := s.DB.Where("scope = ?", scope)
	if scope == models.TxScopePersonal {
		q = q.Where("target_id = ?", uid)
	} else {
		q = q.Where("target_id = ?", *familyID)
	}
	if err := q.First(&p).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			cfg := config.C.Plan
			return &models.FinancialPlan{
				Scope:            scope,
				TargetID:         pickTargetID(scope, uid, familyID),
				UID:              uid,
				FamilyID:         familyID,
				EmergencyTarget:  cfg.EmergencyTarget,
				PensionTarget:    cfg.PensionTarget,
				BigPurchaseRatio: cfg.BigPurchaseRatio,
				InvestAnnualRate: cfg.InvestAnnualRate,
				SavingRatio:      0.2,
				InvestmentRatio:  0.2,
				EmergencyRatio:   0.1,
				PensionRatio:     0.1,
				ConsumptionRatio: 0.4,
			}, nil
		}
		return nil, err
	}
	return &p, nil
}

func (s *FinanceService) monthlyInvestmentRate(scope string, uid uint64, familyID *uint64, year, month int) (float64, error) {
	var rec models.InvestmentRecord
	q := s.DB.Where("scope = ? AND year = ? AND month = ?", scope, year, month)
	if scope == models.TxScopePersonal {
		q = q.Where("target_id = ?", uid)
	} else {
		q = q.Where("target_id = ?", *familyID)
	}
	if err := q.First(&rec).Error; err != nil {
		return 0, err
	}
	return rec.MonthlyRate, nil
}

func pickTargetID(scope string, uid uint64, familyID *uint64) uint64 {
	if scope == models.TxScopeFamily && familyID != nil {
		return *familyID
	}
	return uid
}
