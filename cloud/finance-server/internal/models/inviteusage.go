package models

// InviteCodeUsage 一次成功注册 = 一行（v0.5.0 新增）。
//
// 独立表而不是给 users 加 inviteCodeId：users 在快照里走 userExportRow/userImportRow
// 对称类型，改结构风险远大于收益；且 maxUses>1 时独立表才能追溯每个使用者。
// uk_usage_code_user 防止同一用户对同一码重复记账（防御性约束）。
type InviteCodeUsage struct {
	Base
	InviteCodeID uint64 `gorm:"not null;uniqueIndex:uk_usage_code_user,priority:1;index" json:"inviteCodeId"`
	Code         string `gorm:"size:16;index" json:"code"`
	UserID       uint64 `gorm:"not null;uniqueIndex:uk_usage_code_user,priority:2;index" json:"userId"`
	UsedAt       int64  `gorm:"index;not null" json:"usedAt"`
	IP           string `gorm:"size:64" json:"ip"`
	UserAgent    string `gorm:"size:255" json:"userAgent"`
}
