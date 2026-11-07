// Package database 数据库连接与初始化。
//
// 通过构建标签选择驱动，两个文件二选一参与编译：
//
//	go build            → MySQL（本地 / 私有部署默认）
//	go build -tags sqlite → SQLite（云托管沙箱：单容器无外部数据库）
//
// 两个文件都必须实现 Init() error。
package database

import "gorm.io/gorm"

// DB 全局句柄
var DB *gorm.DB
