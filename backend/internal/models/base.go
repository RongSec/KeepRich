package models

import (
	"time"

	"gorm.io/gorm"
)

// Base 公共字段
type Base struct {
	ID        uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	// DeletedAt 原为 json:"-"（v0.3.1），导致软删除的行导出后丢掉 deletedAt，
	// 再导入就变成"未删除" —— 用户删掉的账目/家庭会在每次重启后复活。
	// 改为 json:"deletedAt" 后：gorm.DeletedAt 自带 MarshalJSON（Valid=false → null），
	// 非删除行只多一个 "deletedAt": null，纯增量、旧客户端忽略（DESIGN §2.B.2 第 6 条）。
	DeletedAt gorm.DeletedAt `gorm:"index" json:"deletedAt"`
}
