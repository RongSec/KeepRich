package models

// FinancialPlan 财务预规划
// 既支持个人空间也支持家庭空间，通过 Scope + TargetID 区分
type FinancialPlan struct {
	Base
	Scope     string  `gorm:"size:16;index;not null" json:"scope"`     // personal/family
	UID       uint64  `gorm:"index;not null" json:"uid"`              // 拥有者
	FamilyID  *uint64 `gorm:"index" json:"familyId,omitempty"`        // 家庭时关联
	TargetID  uint64  `gorm:"index;not null" json:"targetId"`         // 实际目标（UID 或 FamilyID）

	// 基础参数
	MonthlySurvivalCost float64 `gorm:"type:decimal(14,2)" json:"monthlySurvivalCost"` // 每月最低生存成本

	// 合并后的目标
	EmergencyTarget float64 `gorm:"type:decimal(14,2)" json:"emergencyTarget"` // 应急备用金目标
	PensionTarget   float64 `gorm:"type:decimal(14,2)" json:"pensionTarget"`   // 养老金目标

	// 每月收入占比（合计=1，6 个分配桶：贷款/储蓄/投资/应急/养老金/消费）
	LoanRatio        float64 `gorm:"type:decimal(6,4)" json:"loanRatio"`        // 贷款还款（默认 40%）
	SavingRatio      float64 `gorm:"type:decimal(6,4)" json:"savingRatio"`      // 储蓄（默认 20%）
	InvestmentRatio  float64 `gorm:"type:decimal(6,4)" json:"investmentRatio"`  // 投资（默认 5%）
	EmergencyRatio   float64 `gorm:"type:decimal(6,4)" json:"emergencyRatio"`   // 应急（默认 5%）
	PensionRatio     float64 `gorm:"type:decimal(6,4)" json:"pensionRatio"`     // 养老（默认 5%）
	ConsumptionRatio float64 `gorm:"type:decimal(6,4)" json:"consumptionRatio"` // 消费（默认 25%）

	// 大件规划相关
	BigPurchaseRatio float64 `gorm:"type:decimal(6,4)" json:"bigPurchaseRatio"` // 大件可占用储蓄总额比例

	// 投资参数
	InvestAnnualRate float64 `gorm:"type:decimal(6,4)" json:"investAnnualRate"` // 投资规划年收益率

	// 用户寿命规划（用于未来利益按月发放的折现）
	CurrentAge   int `gorm:"type:int" json:"currentAge"`   // 当前年龄
	LifeExpectancy int `gorm:"type:int" json:"lifeExpectancy"` // 预期活到 X 岁（默认 80）
}

// GetDefaultRatios 获取默认分配比例
func GetDefaultRatios() map[string]float64 {
	return map[string]float64{
		"loan":        0.40, // 贷款 40%
		"saving":      0.20, // 储蓄 20%
		"investment":  0.05, // 投资 5%
		"emergency":   0.05, // 应急 5%
		"pension":     0.05, // 养老 5%
		"consumption": 0.25, // 消费 25%
	}
}
