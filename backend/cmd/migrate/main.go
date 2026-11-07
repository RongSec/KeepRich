// 一次性迁移工具：把本地 MySQL 数据整库搬到 SQLite 文件（云托管部署用）。
//
// 用法（在 backend 目录）：
//
//	go run ./cmd/migrate -out /path/to/data/finance.db
//
// 只在本地跑 —— 云上的构建不包含本目录（没有 MySQL 驱动）。
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"

	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func openMySQL() (*gorm.DB, error) {
	cfg := config.C.Database
	dsn := fmt.Sprintf(
		"%s:%s@tcp(%s:%d)/%s?charset=%s&parseTime=%t&loc=%s",
		cfg.User, cfg.Password, cfg.Host, cfg.Port, cfg.Name,
		cfg.Charset, cfg.ParseTime, cfg.Loc,
	)
	return gorm.Open(mysql.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
}

func main() {
	out := flag.String("out", "data/finance.db", "输出 SQLite 文件路径")
	flag.Parse()
	if err := config.Load(); err != nil {
		log.Fatalf("load config: %v", err)
	}

	src, err := openMySQL()
	if err != nil {
		log.Fatalf("connect mysql: %v", err)
	}

	// 目标文件每次重建，保证幂等（用安全写法：只删具体文件，不递归删目录）
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		log.Fatal(err)
	}
	if _, err := os.Stat(*out); err == nil {
		if err := os.Remove(*out); err != nil {
			log.Fatalf("remove old %s: %v", *out, err)
		}
	}

	dst, err := gorm.Open(sqlite.Open(*out), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		log.Fatalf("open sqlite: %v", err)
	}
	if sqlDB, err := dst.DB(); err == nil {
		sqlDB.SetMaxOpenConns(1)
	}

	// 借用全局句柄建表（与线上一致的 AutoMigrate 列表）
	database.DB = dst
	if err := database.Migrate(); err != nil {
		log.Fatalf("sqlite migrate: %v", err)
	}

	type table struct {
		name  string
		model any
	}
	tables := []table{
		{"users", &models.User{}},
		{"families", &models.Family{}},
		{"family_members", &models.FamilyMember{}},
		{"family_join_requests", &models.FamilyJoinRequest{}},
		{"transactions", &models.Transaction{}},
		{"financial_plans", &models.FinancialPlan{}},
		{"purchase_plans", &models.PurchasePlan{}},
		{"investment_records", &models.InvestmentRecord{}},
		{"notifications", &models.Notification{}},
		{"delete_family_requests", &models.DeleteFamilyRequest{}},
		{"delete_family_votes", &models.DeleteFamilyVote{}},
		{"audit_logs", &models.AuditLog{}},
		{"error_reports", &models.ErrorReport{}},
		{"housing_fund_loans", &models.HousingFundLoan{}},
		{"commercial_loans", &models.CommercialLoan{}},
		{"borrowed_moneys", &models.BorrowedMoney{}},
		{"future_benefits", &models.FutureBenefit{}},
		{"app_versions", &models.AppVersion{}},
	}

	failed := false
	for _, t := range tables {
		rows := reflectNewSlice(t.model)
		if err := src.Unscoped().Find(rows).Error; err != nil {
			log.Printf("[skip] %-24s read: %v", t.name, err)
			failed = true
			continue
		}
		n := reflectLen(rows)
		if n == 0 {
			log.Printf("[ok]   %-24s 0 row", t.name)
			continue
		}
		if err := dst.CreateInBatches(rows, 100).Error; err != nil {
			log.Printf("[FAIL] %-24s insert: %v", t.name, err)
			failed = true
			continue
		}
		log.Printf("[ok]   %-24s %d rows", t.name, n)
	}
	if failed {
		log.Println("部分表迁移失败，请检查上方日志")
		os.Exit(1)
	}
	log.Printf("迁移完成 → %s", *out)
}

// reflectNewSlice：按模型类型 *T 造出 *[]*T，gorm Find 直接填充，
// 元素保留主键 ID，回写 SQLite 时原样插入。
func reflectNewSlice(model any) any {
	t := reflect.TypeOf(model) // *T
	return reflect.New(reflect.SliceOf(t)).Interface()
}

func reflectLen(rows any) int {
	return reflect.ValueOf(rows).Elem().Len()
}
