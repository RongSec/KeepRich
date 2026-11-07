package models

const (
	// 交易类型
	TxTypeIncome   = "income"   // 收入
	TxTypeExpense  = "expense"  // 支出
	TxTypeTransfer = "transfer" // 存钱（桶间转账，不影响总财富）

	// 范围
	TxScopePersonal = "personal" // 个人
	TxScopeFamily   = "family"   // 家庭

	// 收入子类
	IncomeSalary         = "salary"            // 工资
	IncomeHousingFund    = "housing_fund"      // 公积金（不计入年薪）
	IncomeWindfall       = "windfall"          // 意外收入
	IncomeInvestment     = "investment_return" // 投资收益+息金（合并）
	IncomePastHousing    = "past_housing"      // 过往公积金（不计入年薪）
	IncomePastSaving     = "past_saving"       // 过往存款（不计入年薪）

	// 支出子类（用户视角：钱花到哪里去）
	ExpenseDaily       = "daily"         // 日常消费
	ExpenseBigPurchase = "big_purchase"  // 大件购物
	ExpensePension     = "pension"       // 养老
	ExpenseEmergency   = "emergency"     // 应急
	ExpenseLoanRepay   = "loan_repay"    // 偿还贷款（关联 loanRef）

	// 存钱（转账）子类 — 从现金池向各桶转入
	TransferToSaving     = "transfer_saving"     // 转入储蓄桶
	TransferToInvestment = "transfer_investment" // 转入投资桶（长远投资）
	TransferToEmergency  = "transfer_emergency"  // 转入应急备用金桶
	TransferToPension    = "transfer_pension"    // 转入养老金桶
)

// Transaction 记账
type Transaction struct {
	Base
	UID          uint64  `gorm:"index;not null" json:"uid"`         // 记录人 uid
	FamilyID     *uint64 `gorm:"index" json:"familyId,omitempty"`  // 家庭账单时关联
	Scope        string  `gorm:"size:16;index" json:"scope"`        // personal/family
	Type         string  `gorm:"size:16;index" json:"type"`         // income/expense/transfer
	Category     string  `gorm:"size:32;index" json:"category"`     // 分类
	Amount       float64 `gorm:"type:decimal(14,2);not null" json:"amount"`
	Note         string  `gorm:"size:255" json:"note"`
	OccurredAt   int64   `gorm:"index" json:"occurredAt"` // 业务发生时间
	LoanRef      string  `gorm:"size:64;index" json:"loanRef,omitempty"`      // 偿还贷款关联："hf:1" / "cl:2" / "bm:3"
	TargetBucket string  `gorm:"size:32;index" json:"targetBucket,omitempty"` // 收入目标桶：saving/investment/emergency/pension
	SourceBucket  string  `gorm:"size:32;index" json:"sourceBucket,omitempty"`  // 支出来源桶（单来源兼容）
	SourceDetails string  `gorm:"type:text" json:"sourceDetails,omitempty"`    // 多来源 JSON: [{"bucket":"cash","amount":60},{"bucket":"saving","amount":40}]
	SourceRef     string  `gorm:"size:64;index" json:"sourceRef,omitempty"`    // 自动流水幂等关联键，如 "inv:personal:1:2026:10"（投资月度入账）
}

// CategoryLabel 分类显示名
var CategoryLabel = map[string]string{
	IncomeSalary:         "工资",
	IncomeHousingFund:    "公积金",
	IncomeWindfall:       "意外收入",
	IncomeInvestment:     "投资收益",
	IncomePastHousing:    "过往公积金",
	IncomePastSaving:     "过往存款",
	ExpenseDaily:         "日常消费",
	ExpenseBigPurchase:   "大件购物",
	ExpensePension:       "养老",
	ExpenseEmergency:     "应急",
	ExpenseLoanRepay:     "偿还贷款",
	TransferToSaving:     "存入储蓄桶",
	TransferToInvestment: "存入投资桶",
	TransferToEmergency:  "存入应急桶",
	TransferToPension:    "存入养老桶",
}

// IsIncomeCategory 判断是否为合法收入分类
func IsIncomeCategory(c string) bool {
	switch c {
	case IncomeSalary, IncomeHousingFund, IncomeWindfall, IncomeInvestment, IncomePastHousing, IncomePastSaving:
		return true
	}
	return false
}

// IsExpenseCategory 判断是否为合法支出分类
func IsExpenseCategory(c string) bool {
	switch c {
	case ExpenseDaily, ExpenseBigPurchase, ExpensePension, ExpenseEmergency, ExpenseLoanRepay:
		return true
	}
	return false
}

// IsTransferCategory 判断是否为合法存钱（转账）分类
func IsTransferCategory(c string) bool {
	switch c {
	case TransferToSaving, TransferToInvestment, TransferToEmergency, TransferToPension:
		return true
	}
	return false
}

// BucketFromTransfer 存钱分类 → 桶名
func BucketFromTransfer(c string) string {
	switch c {
	case TransferToSaving:
		return "saving"
	case TransferToInvestment:
		return "investment"
	case TransferToEmergency:
		return "emergency"
	case TransferToPension:
		return "pension"
	}
	return ""
}

// TransferFromBucket 桶名 → 存钱分类
func TransferFromBucket(bucket string) string {
	switch bucket {
	case "saving":
		return TransferToSaving
	case "investment":
		return TransferToInvestment
	case "emergency":
		return TransferToEmergency
	case "pension":
		return TransferToPension
	}
	return ""
}

// 不计入年薪的收入分类
var NonSalaryIncomeCategories = map[string]bool{
	IncomeHousingFund: true,
	IncomePastHousing: true,
	IncomePastSaving:  true,
	IncomeWindfall:    true,
}

// IsSalaryIncome 判断是否为计入年薪的收入
func IsSalaryIncome(category string) bool {
	return !NonSalaryIncomeCategories[category]
}

// AllowedSourceBuckets 各支出类别允许的来源桶
var AllowedSourceBuckets = map[string][]string{
	ExpenseDaily:       {"cash"},                          // 日常消费：仅现金
	ExpenseBigPurchase: {"cash", "saving"},                // 大件购物：现金、储蓄桶
	ExpensePension:     {"pension"},                       // 养老：仅养老桶
	ExpenseEmergency:   {"emergency"},                     // 应急：仅应急桶
	ExpenseLoanRepay:   {"cash", "saving", "housing_fund"}, // 偿还贷款：现金、储蓄桶、公积金
}

// IsAllowedSourceBucket 校验支出类别的来源桶是否合法
func IsAllowedSourceBucket(expenseCategory, sourceBucket string) bool {
	allowed, ok := AllowedSourceBuckets[expenseCategory]
	if !ok {
		return false
	}
	for _, b := range allowed {
		if b == sourceBucket {
			return true
		}
	}
	return false
}
