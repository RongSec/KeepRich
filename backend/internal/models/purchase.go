package models

// PurchasePlan 大件购买计划
type PurchasePlan struct {
	Base
	Scope       string  `gorm:"size:16;index;not null" json:"scope"`     // personal/family
	UID         uint64  `gorm:"index;not null" json:"uid"`
	FamilyID    *uint64 `gorm:"index" json:"familyId,omitempty"`
	TargetID    uint64  `gorm:"index;not null" json:"targetId"`

	Name        string  `gorm:"size:64;not null" json:"name"`
	Price       float64 `gorm:"type:decimal(14,2);not null" json:"price"`
	Priority    int     `gorm:"default:0" json:"priority"` // 数字越小优先级越高
	TargetDate  int64   `json:"targetDate"`                // 期望购买时间
	Note        string  `gorm:"size:255" json:"note"`
	Achieved    bool    `gorm:"default:false" json:"achieved"`
	AchievedAt  *int64  `json:"achievedAt,omitempty"`
}

// InvestmentRecord 投资月度收益记录
type InvestmentRecord struct {
	Base
	Scope     string  `gorm:"size:16;index;not null" json:"scope"`
	UID       uint64  `gorm:"index;not null" json:"uid"`
	FamilyID  *uint64 `gorm:"index" json:"familyId,omitempty"`
	TargetID  uint64  `gorm:"index;not null" json:"targetId"`
	Year      int     `gorm:"index" json:"year"`
	Month     int     `gorm:"index" json:"month"`
	MonthlyRate float64 `gorm:"type:decimal(8,6)" json:"monthlyRate"` // 月收益率
	Amount    float64 `gorm:"type:decimal(14,2)" json:"amount"`     // 实际收益额（元，可正可负）
	Note      string  `gorm:"size:255" json:"note"`
}
