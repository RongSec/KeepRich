package models

// AuditLog 审计日志
type AuditLog struct {
	Base
	UID       uint64 `gorm:"index" json:"uid"`     // 操作用户；0 表示系统
	Username  string `gorm:"size:64" json:"username"`
	Action    string `gorm:"size:64;index" json:"action"`   // login/create_user/disable_user/...
	Target    string `gorm:"size:128" json:"target"`        // 资源描述
	IP        string `gorm:"size:64" json:"ip"`
	UserAgent string `gorm:"size:255" json:"userAgent"`
	Status    string `gorm:"size:16;index" json:"status"`  // ok / fail
	Detail    string `gorm:"type:text" json:"detail"`
}

// ErrorReport 客户端错误收集
type ErrorReport struct {
	Base
	UID       uint64 `gorm:"index" json:"uid"`
	Platform  string `gorm:"size:16;index" json:"platform"` // web/android/ios
	App       string `gorm:"size:32;index" json:"app"`      // client/admin
	Version   string `gorm:"size:32" json:"version"`
	URL       string `gorm:"size:255" json:"url"`
	Message   string `gorm:"type:text" json:"message"`
	Stack     string `gorm:"type:text" json:"stack"`
	Extra     string `gorm:"type:text" json:"extra"`
}
