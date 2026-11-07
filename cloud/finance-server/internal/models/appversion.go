package models

// AppVersion 应用版本发布记录（在线更新）
// 分发走 GitHub Release 资产，本表负责灰度/强更控制
type AppVersion struct {
	Base
	Platform     string `json:"platform" gorm:"size:16;index"`           // android / ios / web
	Version      string `json:"version" gorm:"size:32;index"`            // 语义化版本，如 1.2.0
	BuildNumber  int    `json:"buildNumber"`                             // pubspec version+N 中的 N
	Channel      string `json:"channel" gorm:"size:16;default:stable"`   // stable / beta
	MinSupported string `json:"minSupported" gorm:"size:32"`             // 低于此版本强制更新（空=不强更）
	GrayPercent  int    `json:"grayPercent" gorm:"default:100"`          // 灰度放量 0-100
	Notes        string `json:"notes" gorm:"type:text"`                  // 更新日志
	APKUrl       string `json:"apkUrl" gorm:"size:512"`                  // GitHub Release 资产下载地址
	SHA256       string `json:"sha256" gorm:"size:64"`                   // 安装包校验和
	SizeBytes    int64  `json:"sizeBytes"`                               // 安装包大小
	Published    bool   `json:"published" gorm:"default:false"`          // 草稿(false)/已发布(true)
}
