package models

const (
	NotifyTypeOverSpend    = "overspend"     // 超支提醒
	NotifyTypeBigPurchase  = "big_purchase"  // 大件可购买提醒
	NotifyTypeFamilyApply  = "family_apply"  // 家庭加入申请
	NotifyTypeFamilyResult = "family_result" // 家庭申请结果
	NotifyTypeSystem       = "system"        // 系统通知
)

// Notification 通知
type Notification struct {
	Base
	UID     uint64 `gorm:"index;not null" json:"uid"`
	Type    string `gorm:"size:32;index" json:"type"`
	Title   string `gorm:"size:128" json:"title"`
	Content string `gorm:"size:512" json:"content"`
	Data    string `gorm:"type:text" json:"data,omitempty"` // 扩展 JSON
	Read    bool   `gorm:"column:is_read;default:false;index" json:"read"`
}
