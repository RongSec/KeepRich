package models

// DeviceCredential 设备授权凭据（v0.5.0 新增）。
//
// 红线：服务端**只存** HMAC-SHA256 指纹，明文 deviceToken 仅在签发响应里返回一次。
// 能力边界：只能用于 POST /api/auth/device-login 换取会话，不能改密码/邮箱，
// 也不能当 JWT 过 middleware.JWT()（它不是 JWT，验签天然失败）。
//
// CredentialHash 同样必须进快照（不能 json:"-"），否则发布后指纹登录全端失效；
// API 侧用 DTO 隔离，绝不直接返回本结构体。
type DeviceCredential struct {
	Base
	UserID         uint64 `gorm:"not null;uniqueIndex:uk_devcred_user_device,priority:1" json:"userId"`
	DeviceID       string `gorm:"size:64;not null;uniqueIndex:uk_devcred_user_device,priority:2" json:"deviceId"`
	CredentialHash string `gorm:"size:64;uniqueIndex;not null" json:"credentialHash"`
	DeviceName     string `gorm:"size:64" json:"deviceName"`
	Platform       string `gorm:"size:16" json:"platform"`
	LastUsedAt     int64  `gorm:"index;not null" json:"lastUsedAt"`
	ExpiresAt      int64  `gorm:"index;not null" json:"expiresAt"`
	RevokedAt      *int64 `gorm:"index" json:"revokedAt"`
	RevokedReason  string `gorm:"size:32" json:"revokedReason"`
}

// Usable 未撤销、未过期。使用即由 DeviceService 续期 ExpiresAt（不轮换）。
func (d *DeviceCredential) Usable(now int64) bool {
	return d != nil && d.RevokedAt == nil && d.ExpiresAt > now
}
