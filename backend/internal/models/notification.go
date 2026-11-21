package models

const (
	NotifyTypeOverSpend    = "overspend"     // 超支提醒
	NotifyTypeBigPurchase  = "big_purchase"  // 大件可购买提醒
	NotifyTypeFamilyApply  = "family_apply"  // 家庭加入申请
	NotifyTypeFamilyResult = "family_result" // 家庭申请结果
	NotifyTypeSystem       = "system"        // 系统通知
	NotifyTypeFamilyTx     = "family_tx"     // 家庭成员记账提醒
)

// NotifyTypes 五类通知的固定顺序（设置接口返回/校验用），Go 1.22 兼容：普通切片。
var NotifyTypes = []string{
	NotifyTypeOverSpend,
	NotifyTypeBigPurchase,
	NotifyTypeFamilyApply,
	NotifyTypeFamilyResult,
	NotifyTypeSystem,
	NotifyTypeFamilyTx,
}

// NotifyValidType 是否为已知通知类型
func NotifyValidType(typ string) bool {
	for _, t := range NotifyTypes {
		if t == typ {
			return true
		}
	}
	return false
}

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

// NotificationSetting 通知设置（每用户每类型一行）。
//
// 选型取舍：用"每用户每类型一行"而非"每用户一行 JSON"——
// (user_id, type) 唯一索引，按类型独立增改，无需 JSON 解析/整行覆盖。
//
// enabled=false 时该类通知整条跳过（不落库、不推系统通知）；
// title_template / content_template 为空表示用默认模板（DefaultNotifyTemplates）。
// 五类都允许关闭：家庭申请/结果虽强相关，但关闭仅表示"不提醒"，
// 申请记录仍在家庭管理页可见，不会丢流程，故不强制开启（默认全开）。
//
// 本表不进云端快照/备份清单（同 sync_state 口径）：纯偏好设置，
// 丢失即回默认模板，不值得进账目级快照。
type NotificationSetting struct {
	Base
	UserID          uint64 `gorm:"uniqueIndex:idx_notify_setting_user_type;not null" json:"userId"`
	Type            string `gorm:"size:32;uniqueIndex:idx_notify_setting_user_type;not null" json:"type"`
	Enabled         bool   `json:"enabled"`                       // 不加 gorm default 标签：GORM 会跳过零值 false、被列默认值覆盖；默认开启语义在查询侧（无行=开启）
	TitleTemplate   string `gorm:"size:256" json:"titleTemplate"` // 空=默认模板
	ContentTemplate string `gorm:"type:text" json:"contentTemplate"`
}

// NotifyTemplate 通知文案模板（title/content 均支持 {占位符}）
type NotifyTemplate struct {
	Title   string
	Content string
}

// DefaultNotifyTemplates 各类型默认文案模板（后端常量，用户可在设置里覆盖）。
// 占位符由推送方以 vars 传入（如 {金额}/{分类}/{日期}/{名称}），
// 渲染在 services.renderTemplate 完成；缺失的占位符保留原文，不 panic。
// system 类由各调用点以 {标题}/{内容} 传入实际文案。
var DefaultNotifyTemplates = map[string]NotifyTemplate{
	NotifyTypeOverSpend:    {Title: "超支提醒", Content: "{分类} 本次支出 {金额} 元，超过无顾虑单笔 {限额} 元"},
	NotifyTypeBigPurchase:  {Title: "大件可购买", Content: "已可购买：{名称}"},
	NotifyTypeFamilyApply:  {Title: "新加入申请", Content: "有用户申请加入家庭：{家庭名}"},
	NotifyTypeFamilyResult: {Title: "家庭加入结果", Content: "{结果}"},
	NotifyTypeSystem:       {Title: "{标题}", Content: "{内容}"},
	NotifyTypeFamilyTx:     {Title: "家庭成员记账", Content: "{昵称} 记了一笔{类型}：{分类} {金额} 元"},
}
