package services

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// 消费额度桶（consumption）按月推演测试。
// 固定 now 做推演，避免用例随真实日期漂移；覆盖：
// 自动入账=工资×比例 / 50/50 结转 / 超支全额负结转 / 跨月推演（含多来源支出）。

func ledgerTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := "file:ledger_" + t.Name() + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if sqlDB, err := db.DB(); err == nil {
		sqlDB.SetMaxOpenConns(1)
	}
	if err := db.AutoMigrate(
		&models.User{}, &models.Transaction{}, &models.FinancialPlan{}, &models.FamilyMember{},
		&models.PurchasePlan{}, &models.InvestmentRecord{}, &models.FutureBenefit{},
		&models.HousingFundLoan{}, &models.CommercialLoan{}, &models.BorrowedMoney{},
		&models.Notification{},
	); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if config.C == nil {
		config.C = &config.Config{}
	}
	return db
}

func ledgerInsertTx(t *testing.T, db *gorm.DB, uid uint64, typ, category string, amount float64, at time.Time, sourceBucket, sourceDetails string) {
	t.Helper()
	tx := models.Transaction{
		UID:           uid,
		Scope:         models.TxScopePersonal,
		Type:          typ,
		Category:      category,
		Amount:        amount,
		OccurredAt:    at.Unix(),
		SourceBucket:  sourceBucket,
		SourceDetails: sourceDetails,
	}
	if err := db.Create(&tx).Error; err != nil {
		t.Fatalf("插入流水失败: %v", err)
	}
}

func ledgerInsertPlan(t *testing.T, db *gorm.DB, uid uint64, consumptionRatio float64) {
	t.Helper()
	p := models.FinancialPlan{
		Scope:            models.TxScopePersonal,
		UID:              uid,
		TargetID:         uid,
		LoanRatio:        0.25,
		SavingRatio:      0.2,
		InvestmentRatio:  0.2,
		EmergencyRatio:   0.1,
		PensionRatio:     0.1,
		ConsumptionRatio: consumptionRatio,
	}
	if err := db.Create(&p).Error; err != nil {
		t.Fatalf("插入规划失败: %v", err)
	}
}

// TestConsumptionAutoInFromSalary 消费桶自动入账 = 工资 × 消费比例
func TestConsumptionAutoInFromSalary(t *testing.T) {
	db := ledgerTestDB(t)
	const uid = uint64(1)
	now := time.Date(2026, 3, 15, 12, 0, 0, 0, time.Local)
	ledgerInsertPlan(t, db, uid, 0.25)
	ledgerInsertTx(t, db, uid, models.TxTypeIncome, models.IncomeSalary, 10000,
		time.Date(2026, 3, 5, 10, 0, 0, 0, time.Local), "", "")

	led := NewFinanceService(db).consumptionLedger(models.TxScopePersonal, uid, nil, now, 0.25)
	if led.AutoIn != 2500 {
		t.Fatalf("自动入账 = %.2f，期望 2500.00（10000 × 0.25）", led.AutoIn)
	}
	if led.Balance != 2500 {
		t.Fatalf("当前余额 = %.2f，期望 2500.00", led.Balance)
	}
	if led.CarryIn != 0 || led.Spend != 0 || led.RefundSum != 0 {
		t.Fatalf("首月应无结转/支出/回流：carryIn=%.2f spend=%.2f refund=%.2f",
			led.CarryIn, led.Spend, led.RefundSum)
	}
	if led.AutoInSum != 2500 {
		t.Fatalf("自动入账累计 = %.2f，期望 2500.00", led.AutoInSum)
	}
}

// TestConsumptionCarryOverSplitHalf 月末余额>0：carryIn 与 refund 各一半
func TestConsumptionCarryOverSplitHalf(t *testing.T) {
	db := ledgerTestDB(t)
	const uid = uint64(1)
	now := time.Date(2026, 3, 15, 12, 0, 0, 0, time.Local)
	ledgerInsertPlan(t, db, uid, 0.25)
	// 上月（2026-02）：工资 10000 → 自动入账 2500，消费桶支出 500，剩余 2000
	ledgerInsertTx(t, db, uid, models.TxTypeIncome, models.IncomeSalary, 10000,
		time.Date(2026, 2, 10, 10, 0, 0, 0, time.Local), "", "")
	ledgerInsertTx(t, db, uid, models.TxTypeExpense, models.ExpenseDaily, 500,
		time.Date(2026, 2, 12, 10, 0, 0, 0, time.Local), "consumption", "")

	led := NewFinanceService(db).consumptionLedger(models.TxScopePersonal, uid, nil, now, 0.25)
	if led.CarryIn != 1000 {
		t.Fatalf("本月结转入 = %.2f，期望 1000.00（2000 × 0.5）", led.CarryIn)
	}
	if led.RefundSum != 1000 {
		t.Fatalf("结转回流累计 = %.2f，期望 1000.00（2000 × 0.5）", led.RefundSum)
	}
	if led.Balance != 1000 {
		t.Fatalf("当前余额 = %.2f，期望 1000.00", led.Balance)
	}
	if led.AutoIn != 0 || led.Spend != 0 {
		t.Fatalf("本月应无自动入账/支出：autoIn=%.2f spend=%.2f", led.AutoIn, led.Spend)
	}
}

// TestConsumptionOverspendFullNegativeCarry 月末余额<0：全额结转负数，不产生回流
func TestConsumptionOverspendFullNegativeCarry(t *testing.T) {
	db := ledgerTestDB(t)
	const uid = uint64(1)
	now := time.Date(2026, 3, 15, 12, 0, 0, 0, time.Local)
	ledgerInsertPlan(t, db, uid, 0.25)
	// 上月（2026-02）：自动入账 2500，支出 3200（服务层不拦超额，直接构造超支态）
	ledgerInsertTx(t, db, uid, models.TxTypeIncome, models.IncomeSalary, 10000,
		time.Date(2026, 2, 10, 10, 0, 0, 0, time.Local), "", "")
	ledgerInsertTx(t, db, uid, models.TxTypeExpense, models.ExpenseDaily, 3200,
		time.Date(2026, 2, 12, 10, 0, 0, 0, time.Local), "consumption", "")

	led := NewFinanceService(db).consumptionLedger(models.TxScopePersonal, uid, nil, now, 0.25)
	if led.CarryIn != -700 {
		t.Fatalf("本月结转入 = %.2f，期望 -700.00（超支全额结转负数）", led.CarryIn)
	}
	if led.RefundSum != 0 {
		t.Fatalf("结转回流累计 = %.2f，期望 0（超支不回流）", led.RefundSum)
	}
	if led.Balance != -700 {
		t.Fatalf("当前余额 = %.2f，期望 -700.00", led.Balance)
	}
}

// TestConsumptionCrossMonthDerivation 跨月推演（两个月连续）+ 多来源支出归月
func TestConsumptionCrossMonthDerivation(t *testing.T) {
	db := ledgerTestDB(t)
	const uid = uint64(1)
	now := time.Date(2026, 3, 15, 12, 0, 0, 0, time.Local)
	ledgerInsertPlan(t, db, uid, 0.25)

	// 2026-01：工资 10000 → 自动入账 2500，无支出 → 月末 carry 1250 / refund 1250
	ledgerInsertTx(t, db, uid, models.TxTypeIncome, models.IncomeSalary, 10000,
		time.Date(2026, 1, 5, 10, 0, 0, 0, time.Local), "", "")
	// 2026-02：工资 10000 → 自动入账 2500；支出 700（单来源 200 + 多来源里 consumption 500）
	ledgerInsertTx(t, db, uid, models.TxTypeIncome, models.IncomeSalary, 10000,
		time.Date(2026, 2, 5, 10, 0, 0, 0, time.Local), "", "")
	ledgerInsertTx(t, db, uid, models.TxTypeExpense, models.ExpenseDaily, 200,
		time.Date(2026, 2, 8, 10, 0, 0, 0, time.Local), "consumption", "")
	ledgerInsertTx(t, db, uid, models.TxTypeExpense, models.ExpenseBigPurchase, 700,
		time.Date(2026, 2, 9, 10, 0, 0, 0, time.Local), "",
		`[{"bucket":"cash","amount":200},{"bucket":"consumption","amount":500}]`)

	led := NewFinanceService(db).consumptionLedger(models.TxScopePersonal, uid, nil, now, 0.25)
	// 2026-02 结算：bal = 2500 + 1250 − 700 = 3050 → carry 1525 / refund 1525
	if led.CarryIn != 1525 {
		t.Fatalf("本月结转入 = %.2f，期望 1525.00", led.CarryIn)
	}
	if led.RefundSum != 2775 {
		t.Fatalf("结转回流累计 = %.2f，期望 2775.00（1250 + 1525）", led.RefundSum)
	}
	if led.Balance != 1525 {
		t.Fatalf("当前余额 = %.2f，期望 1525.00", led.Balance)
	}
	if led.AutoInSum != 5000 {
		t.Fatalf("自动入账累计 = %.2f，期望 5000.00（1、2 月各 2500）", led.AutoInSum)
	}
	// 2 月消费桶支出应为 200 + 500 = 700（cash 部分不计）
	if led.Spend != 0 {
		t.Fatalf("本月支出 = %.2f，期望 0（当前月无支出）", led.Spend)
	}
}

// TestOverviewConsumptionFieldsAndGetOverview 口径联调：
// MonthConsumableLeft = consumptionBalance；RemainingBudget = 现金池 − 自动入账累计 + 回流累计；
// 构成明细恒等式 CashPoolIncome − CashPoolTransfer − CashPoolExpense ≡ RemainingBudget。
func TestOverviewConsumptionFieldsAndGetOverview(t *testing.T) {
	db := ledgerTestDB(t)
	const uid = uint64(1)
	ledgerInsertPlan(t, db, uid, 0.25)
	// 本月工资 10000，消费桶支出 300
	ledgerInsertTx(t, db, uid, models.TxTypeIncome, models.IncomeSalary, 10000, time.Now(), "", "")
	ledgerInsertTx(t, db, uid, models.TxTypeExpense, models.ExpenseDaily, 300, time.Now(), "consumption", "")

	ov, err := NewFinanceService(db).GetOverview(models.TxScopePersonal, uid, nil)
	if err != nil {
		t.Fatalf("GetOverview 失败: %v", err)
	}
	if ov.ConsumptionAutoIn != 2500 {
		t.Fatalf("consumptionAutoIn = %.2f，期望 2500.00", ov.ConsumptionAutoIn)
	}
	if ov.ConsumptionSpend != 300 {
		t.Fatalf("consumptionSpend = %.2f，期望 300.00", ov.ConsumptionSpend)
	}
	if ov.ConsumptionCarryIn != 0 {
		t.Fatalf("consumptionCarryIn = %.2f，期望 0", ov.ConsumptionCarryIn)
	}
	if ov.ConsumptionBalance != 2200 {
		t.Fatalf("consumptionBalance = %.2f，期望 2200.00", ov.ConsumptionBalance)
	}
	if ov.MonthConsumableLeft != ov.ConsumptionBalance {
		t.Fatalf("monthConsumableLeft = %.2f，应等于 consumptionBalance = %.2f",
			ov.MonthConsumableLeft, ov.ConsumptionBalance)
	}
	// 剩余待支配 = 现金池 − 自动入账累计 + 回流累计 = 10000 − 2500 + 0
	if ov.RemainingBudget != 7500 {
		t.Fatalf("remainingBudget = %.2f，期望 7500.00", ov.RemainingBudget)
	}
	// 构成明细恒等式（供「剩余待支配」弹窗自洽）
	balance := ov.CashPoolIncome - ov.CashPoolTransfer - ov.CashPoolExpense
	if utils.Round2(balance) != ov.RemainingBudget {
		t.Fatalf("构成明细不自洽：%.2f − %.2f − %.2f = %.2f ≠ remainingBudget %.2f",
			ov.CashPoolIncome, ov.CashPoolTransfer, ov.CashPoolExpense, balance, ov.RemainingBudget)
	}
}
