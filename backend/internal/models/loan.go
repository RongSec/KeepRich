package models

// 贷款方式
const (
	LoanMethodEqualPayment = "equal_payment"   // 等额本息
	LoanMethodEqualCapital = "equal_capital"   // 等额本金
	LoanMethodInterestFree = "interest_free"   // 无息（借款）
)

// HousingFundLoan 公积金贷款
type HousingFundLoan struct {
	Base
	Scope       string  `gorm:"size:16;index" json:"scope"`        // personal/family
	UID         uint64  `gorm:"index" json:"uid"`
	FamilyID    *uint64 `gorm:"index" json:"familyId,omitempty"`   // 家庭 ID
	Name        string  `gorm:"size:128" json:"name"`              // 贷款名称
	Total       float64 `json:"total"`                             // 贷款总额
	AnnualRate  float64 `json:"annualRate"`                        // 年利率（百分比，如 3.25 表示 3.25%）
	TermMonths  int     `json:"termMonths"`                        // 贷款期数（月）
	Method      string  `gorm:"size:32" json:"method"`             // equal_payment / equal_capital
	StartMonth  int64   `json:"startMonth"`                        // 开始还款月份（Unix 秒，月份粒度）
	PaidMonths  int     `json:"paidMonths"`                        // 已还期数
	Note        string  `gorm:"size:512" json:"note"`
}

// CommercialLoan 商业贷款
type CommercialLoan struct {
	Base
	Scope       string  `gorm:"size:16;index" json:"scope"`
	UID         uint64  `gorm:"index" json:"uid"`
	FamilyID    *uint64 `gorm:"index" json:"familyId,omitempty"`
	Name        string  `gorm:"size:128" json:"name"`
	Total       float64 `json:"total"`
	AnnualRate  float64 `json:"annualRate"`
	TermMonths  int     `json:"termMonths"`
	Method      string  `gorm:"size:32" json:"method"`
	StartMonth  int64   `json:"startMonth"`
	PaidMonths  int     `json:"paidMonths"`
	Note        string  `gorm:"size:512" json:"note"`
}

// BorrowedMoney 借款
type BorrowedMoney struct {
	Base
	Scope       string  `gorm:"size:16;index" json:"scope"`
	UID         uint64  `gorm:"index" json:"uid"`
	FamilyID    *uint64 `gorm:"index" json:"familyId,omitempty"`
	Name        string  `gorm:"size:128" json:"name"`
	Total       float64 `json:"total"`
	AnnualRate  float64 `json:"annualRate"`  // 0 = 无息
	TermMonths  int     `json:"termMonths"`
	Method      string  `gorm:"size:32" json:"method"` // equal_payment/equal_capital/interest_free
	StartMonth  int64   `json:"startMonth"`
	PaidMonths  int     `json:"paidMonths"`
	Note        string  `gorm:"size:512" json:"note"`
}

// BenefitType 未来利益类型
const (
	BenefitTypeMonthly = "monthly" // 到期后每月领取
	BenefitTypeYearly  = "yearly"  // 到期后每年领取
	BenefitTypeLumpSum = "lump_sum" // 到期后一次性领取
)

// FutureBenefit 未来利益（理财/保险）
type FutureBenefit struct {
	Base
	Scope        string  `gorm:"size:16;index" json:"scope"`
	UID          uint64  `gorm:"index" json:"uid"`
	FamilyID     *uint64 `gorm:"index" json:"familyId,omitempty"`
	Name         string  `gorm:"size:128" json:"name"`        // 名称
	Type         string  `gorm:"size:16" json:"type"`         // monthly/yearly/lump_sum/lifetime/custom_years
	PayoutDate   int64   `json:"payoutDate"`                  // 一次性：发放日期；逐月/年/终身：开始发放时间
	PayoutAmount float64 `json:"payoutAmount"`                // 一次性：发放额；逐月：每月发放额；按年：每年发放额；终身：每月发放额
	CustomYears  int     `json:"customYears"`                 // 自定义年限（仅 type=custom_years 用）
	Note         string  `gorm:"size:512" json:"note"`
}
