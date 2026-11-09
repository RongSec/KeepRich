package models

// AuthSession 会话（v0.5.0 新增）。
//
// 服务端判定「24h 不活跃」的唯一权威状态。字段全部可序列化进云端快照：
// 不进快照会导致每次沙箱重启/发布全端被踢回登录页（DESIGN §3.6）。
//
// ⚠️ RefreshHash / PrevRefreshHash 虽是秘密指纹，但**不能**加 json:"-"：
// 快照里丢掉它们 = 重启后所有 refresh 失效。API 侧一律用 DTO 返回展示字段
// （handlers/devices.go），绝不把本结构体直接序列化给客户端。
type AuthSession struct {
	Base
	UserID          uint64 `gorm:"index;not null" json:"userId"`
	SessionID       string `gorm:"size:48;uniqueIndex;not null" json:"sessionId"`
	DeviceID        string `gorm:"size:64;index" json:"deviceId"`
	DeviceName      string `gorm:"size:64" json:"deviceName"`
	Platform        string `gorm:"size:16" json:"platform"`
	IP              string `gorm:"size:64" json:"ip"`
	UserAgent       string `gorm:"size:255" json:"userAgent"`
	RefreshHash     string `gorm:"size:64;index" json:"refreshHash"`
	PrevRefreshHash string `gorm:"size:64" json:"prevRefreshHash"`
	PrevValidUntil  int64  `json:"prevValidUntil"`
	JTI             string `gorm:"size:48" json:"jti"`
	LastSeenAt      int64  `gorm:"index;not null" json:"lastSeenAt"`
	RefreshAt       int64  `json:"refreshAt"`
	IdleDeadline    int64  `gorm:"index" json:"idleDeadline"`
	TokenVersion    int    `gorm:"default:0" json:"tokenVersion"`
	RevokedAt       *int64 `gorm:"index" json:"revokedAt"`
	RevokedReason   string `gorm:"size:32" json:"revokedReason"`
}

// IdleExpired 以 IdleDeadline 冗余列判定（由 last_seen_at + sessionIdleTTL 落库维护）。
func (s *AuthSession) IdleExpired(now int64) bool {
	if s == nil || s.IdleDeadline == 0 {
		return true
	}
	return now > s.IdleDeadline
}

// IsActive 未撤销且未闲置。
func (s *AuthSession) IsActive(now int64) bool {
	return s != nil && s.RevokedAt == nil && !s.IdleExpired(now)
}
