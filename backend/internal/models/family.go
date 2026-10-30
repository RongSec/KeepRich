package models

const (
	MemberStatusPending  = "pending"  // 等待家庭管理员审批
	MemberStatusActive   = "active"   // 正常
	MemberStatusLeft     = "left"     // 已退出
	MemberStatusRejected = "rejected" // 被拒
)

// Family 家庭空间
type Family struct {
	Base
	Name        string `gorm:"size:64;not null" json:"name"`
	Code        string `gorm:"size:16;uniqueIndex;not null" json:"code"` // 家庭码
	AdminID     uint64 `gorm:"index;not null" json:"adminId"`             // 家庭管理员 uid
	Bound       bool   `gorm:"default:false" json:"bound"`                // 终身绑定标记：开启后所有成员无法恢复个人数据
	BoundAt     *int64 `json:"boundAt,omitempty"`
	Description string `gorm:"size:255" json:"description"`
}

// FamilyMember 家庭成员
type FamilyMember struct {
	Base
	FamilyID  uint64 `gorm:"index;not null" json:"familyId"`
	UserID    uint64 `gorm:"index;not null" json:"userId"`
	IsAdmin   bool   `gorm:"default:false" json:"isAdmin"`
	Status    string `gorm:"size:16;default:active" json:"status"`
	JoinedAt  int64  `json:"joinedAt"`
	LeftAt    *int64 `json:"leftAt,omitempty"`
}

// FamilyJoinRequest 加入家庭申请
type FamilyJoinRequest struct {
	Base
	FamilyID  uint64 `gorm:"index;not null" json:"familyId"`
	UserID    uint64 `gorm:"index;not null" json:"userId"`
	Status    string `gorm:"size:16;default:pending" json:"status"` // pending/approved/rejected
	Message   string `gorm:"size:255" json:"message"`
	HandledBy *uint64 `json:"handledBy,omitempty"`
	HandledAt *int64  `json:"handledAt,omitempty"`
}

// DeleteFamilyRequest 家庭删除请求（成员投票制 + 7 天冷静期）
type DeleteFamilyRequest struct {
	Base
	FamilyID  uint64 `gorm:"index;not null" json:"familyId"`
	RequestBy uint64 `gorm:"index;not null" json:"requestBy"`
	Status    string `gorm:"size:16;default:pending" json:"status"` // pending/approved/canceled/executed
	Reason    string `gorm:"size:255" json:"reason"`
	ExecuteAt int64  `json:"executeAt"`             // 冷静期到期时间（发起 + 7 天），到期后方可执行删除
	ApprovedAt *int64 `json:"approvedAt,omitempty"` // 全体成员同意时间
}

// DeleteFamilyVote 家庭删除投票
type DeleteFamilyVote struct {
	Base
	RequestID uint64 `gorm:"index;not null" json:"requestId"` // 关联的删除请求
	FamilyID  uint64 `gorm:"index;not null" json:"familyId"`
	UserID    uint64 `gorm:"index;not null" json:"userId"`
	Vote      bool   `gorm:"not null" json:"vote"` // true=同意, false=反对
}
