package database

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Init SQLite 连接（-tags sqlite，云托管沙箱用）。
//
// 数据文件路径：环境变量 SQLITE_PATH，默认 data/finance.db。
// 纯 Go 驱动（glebarez/sqlite），不依赖 CGO，任何环境都能编译。
//
// 沙箱里随包上传的文件可能是只读的（连 -journal 都建不了，
// 报 "attempt to write a readonly database"），检测到不可写就
// 把库拷到临时目录再打开。
func Init() error {
	path := os.Getenv("SQLITE_PATH")
	if path == "" {
		path = "data/finance.db"
	}

	if _, err := os.Stat(path); err == nil {
		if !writableFile(path) || !writableDir(filepath.Dir(path)) {
			tmp := filepath.Join(os.TempDir(), "finance.db")
			if data, err := os.ReadFile(path); err == nil {
				if err := os.WriteFile(tmp, data, 0o644); err == nil {
					path = tmp
				}
			}
		}
	} else if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}

	gormCfg := &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	}

	db, err := gorm.Open(sqlite.Open(path), gormCfg)
	if err != nil {
		return fmt.Errorf("open sqlite %s: %w", path, err)
	}

	// SQLite 单文件写并发有限，收紧连接数避免 database is locked
	sqlDB, err := db.DB()
	if err == nil {
		sqlDB.SetMaxOpenConns(1)
		sqlDB.SetMaxIdleConns(1)
	}

	DB = db
	return nil
}

func writableFile(path string) bool {
	f, err := os.OpenFile(path, os.O_RDWR, 0o644)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

// writableDir 目录里能不能建临时文件（SQLite 还要写 -journal）
func writableDir(dir string) bool {
	tmp := filepath.Join(dir, ".finance-write-test")
	f, err := os.Create(tmp)
	if err != nil {
		return false
	}
	_ = f.Close()
	_ = os.Remove(tmp)
	return true
}
