package models

// 邀请码状态（派生，不入库 —— 避免状态机与时间/配额不一致）。
const (
	InviteStatusUnused  = "unused"
	InviteStatusPartial = "partial"
	InviteStatusUsed    = "used"
	InviteStatusExpired = "expired"
	InviteStatusRevoked = "revoked"
)

// InviteCode 邀请码（v0.5.0 新增）。
//
// 邀请码不携带任何家庭信息：注册成功后的账号是「无家庭」普通用户，
// 加入家庭仍走既有的家庭加入申请 / 管理员审批流程。
type InviteCode struct {
	Base
	Code      string  `gorm:"size:16;uniqueIndex;not null" json:"code"`
	CreatedBy uint64  `gorm:"index;not null" json:"createdBy"`
	Note      string  `gorm:"size:128" json:"note"`
	MaxUses   int     `gorm:"default:1;not null" json:"maxUses"`
	UsedCount int     `gorm:"default:0;not null" json:"usedCount"`
	ExpiresAt int64   `gorm:"index" json:"expiresAt"` // 0 = 永不过期（仅运维应急）
	RevokedAt *int64  `gorm:"index" json:"revokedAt"`
	RevokedBy *uint64 `json:"revokedBy"`
}

// Usable 可注册：未撤销、未过期、未用尽。
func (c *InviteCode) Usable(now int64) bool {
	if c == nil || c.RevokedAt != nil {
		return false
	}
	if c.ExpiresAt > 0 && now > c.ExpiresAt {
		return false
	}
	return c.UsedCount < c.MaxUses
}

// Status 派生状态（DESIGN §C.2 的判定顺序）。
func (c *InviteCode) Status(now int64) string {
	if c == nil {
		return InviteStatusUnused
	}
	if c.RevokedAt != nil {
		return InviteStatusRevoked
	}
	if c.ExpiresAt > 0 && now > c.ExpiresAt {
		return InviteStatusExpired
	}
	if c.UsedCount >= c.MaxUses {
		return InviteStatusUsed
	}
	if c.UsedCount > 0 {
		return InviteStatusPartial
	}
	return InviteStatusUnused
}
