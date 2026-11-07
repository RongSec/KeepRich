package models

import "time"

const (
	RoleAdmin    = "admin"    // 系统管理员
	RoleUser     = "user"     // 普通用户
	RoleFamAdmin = "famadmin" // 家庭管理员（基于普通用户叠加的角色）
)

// User 系统用户
type User struct {
	Base
	Username     string `gorm:"size:64;uniqueIndex;not null" json:"username"`
	PasswordHash string `gorm:"size:255;not null" json:"-"`
	Nickname     string `gorm:"size:64" json:"nickname"`
	Avatar       string `gorm:"size:255" json:"avatar"`
	Email        string `gorm:"size:128;index" json:"email"`
	Phone        string `gorm:"size:32;index" json:"phone"`
	Role         string `gorm:"size:16;default:user;index" json:"role"`

	// 多因子认证
	MFAEnabled   bool   `gorm:"default:false" json:"mfaEnabled"`
	MFASecret    string `gorm:"size:128" json:"-"`
	MFABackupCodes string `gorm:"type:text" json:"-"`

	Disabled bool `gorm:"default:false" json:"disabled"`
	LastLoginAt *time.Time `json:"lastLoginAt"`

	// TokenVersion 令牌版本号：改密/重置密码后 +1，使旧 access/refresh token 全部失效
	TokenVersion int `gorm:"default:0" json:"-"`
}
