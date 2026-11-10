package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// 记账录入合法性测试（handlers 层）：
// 存钱超待支配被拒 / 支出走 consumption 桶 / 超消费桶余额被拒 /
// PutTx 改成超额被拒（回滚旧账后重校验）/ 多来源逐桶校验 / 全中文文案。

func txTestDB(t *testing.T) (*gorm.DB, uint64) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	dsn := "file:txh_" + t.Name() + "?mode=memory&cache=shared"
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
	database.DB = db
	if config.C == nil {
		config.C = &config.Config{}
	}
	const uid = uint64(1)
	plan := models.FinancialPlan{
		Scope:            models.TxScopePersonal,
		UID:              uid,
		TargetID:         uid,
		LoanRatio:        0.25,
		SavingRatio:      0.2,
		InvestmentRatio:  0.2,
		EmergencyRatio:   0.1,
		PensionRatio:     0.1,
		ConsumptionRatio: 0.25,
	}
	if err := db.Create(&plan).Error; err != nil {
		t.Fatalf("插入规划失败: %v", err)
	}
	return db, uid
}

// callJSON 以 JSON body 调用 handler，返回响应记录
func callJSON(t *testing.T, uid uint64, method, body string, h gin.HandlerFunc, params gin.Params) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(method, "/api/transactions", strings.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Set(middleware.CtxUID, uid)
	c.Set(middleware.CtxRole, "user")
	if params != nil {
		c.Params = params
	}
	h(c)
	return w
}

type testResp struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func decodeResp(t *testing.T, w *httptest.ResponseRecorder) testResp {
	t.Helper()
	var resp testResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应失败: %v（body=%s）", err, w.Body.String())
	}
	return resp
}

func overview(t *testing.T, uid uint64) *services.OverviewData {
	t.Helper()
	ov, err := services.NewFinanceService(database.DB).GetOverview(models.TxScopePersonal, uid, nil)
	if err != nil {
		t.Fatalf("GetOverview 失败: %v", err)
	}
	return ov
}

// seedSalary 记一笔本月工资 10000（消费比例 0.25 → 消费桶自动入账 2500）
func seedSalary(t *testing.T, uid uint64) {
	t.Helper()
	w := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"income","category":"salary","amount":10000}`,
		CreateTx, nil)
	if w.Code != 200 {
		t.Fatalf("记工资失败: %d %s", w.Code, w.Body.String())
	}
}

// TestTransferOverBudgetRejected B1：存钱金额 > 待支配余额被拒，中文文案；边界内放行
func TestTransferOverBudgetRejected(t *testing.T) {
	_, uid := txTestDB(t)
	seedSalary(t, uid)
	// 待支配 = 10000 − 自动入账 2500 = 7500
	w := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"transfer","category":"transfer_saving","amount":8000}`,
		CreateTx, nil)
	resp := decodeResp(t, w)
	if w.Code != 400 {
		t.Fatalf("超额存钱应被拒，实际 %d（%s）", w.Code, w.Body.String())
	}
	want := "待支配余额不足：当前 7500.00 元，本次存钱 8000.00 元"
	if resp.Message != want {
		t.Fatalf("文案 = %q，期望 %q", resp.Message, want)
	}
	if !isChineseMessage(resp.Message) {
		t.Fatalf("文案必须全中文: %q", resp.Message)
	}
	// 边界内放行
	w2 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"transfer","category":"transfer_saving","amount":7500}`,
		CreateTx, nil)
	if w2.Code != 200 {
		t.Fatalf("7500 存钱应放行，实际 %d（%s）", w2.Code, w2.Body.String())
	}
	// 存钱后待支配清零
	if got := overview(t, uid).RemainingBudget; got != 0 {
		t.Fatalf("存钱后待支配 = %.2f，期望 0", got)
	}
}

// TestExpenseFromConsumptionAccepted 支出选 consumption 作来源：接受且扣消费桶余额
func TestExpenseFromConsumptionAccepted(t *testing.T) {
	_, uid := txTestDB(t)
	seedSalary(t, uid)
	if got := overview(t, uid).ConsumptionBalance; got != 2500 {
		t.Fatalf("初始消费桶余额 = %.2f，期望 2500.00", got)
	}
	w := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"daily","amount":500,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	if w.Code != 200 {
		t.Fatalf("consumption 来源支出应被接受，实际 %d（%s）", w.Code, w.Body.String())
	}
	ov := overview(t, uid)
	if ov.ConsumptionBalance != 2000 {
		t.Fatalf("消费桶余额 = %.2f，期望 2000.00", ov.ConsumptionBalance)
	}
	if ov.ConsumptionSpend != 500 {
		t.Fatalf("消费桶本月支出 = %.2f，期望 500.00", ov.ConsumptionSpend)
	}
	// 待支配不受桶内支出影响（仍为 7500）
	if ov.RemainingBudget != 7500 {
		t.Fatalf("待支配 = %.2f，期望 7500.00（花桶不扣待支配）", ov.RemainingBudget)
	}
}

// TestExpenseOverConsumptionBalanceRejected 支出超过消费桶余额被拒（中文文案）
func TestExpenseOverConsumptionBalanceRejected(t *testing.T) {
	_, uid := txTestDB(t)
	seedSalary(t, uid)
	w := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"daily","amount":2600,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	resp := decodeResp(t, w)
	if w.Code != 400 {
		t.Fatalf("超消费桶余额应被拒，实际 %d（%s）", w.Code, w.Body.String())
	}
	want := "「消费额度」余额不足：当前 2500.00 元，本次支出 2600.00 元"
	if resp.Message != want {
		t.Fatalf("文案 = %q，期望 %q", resp.Message, want)
	}
}

// TestPutTxOverdrawRejected PutTx 改成超额被拒；回滚旧账后合法调整放行
func TestPutTxOverdrawRejected(t *testing.T) {
	db, uid := txTestDB(t)
	seedSalary(t, uid)
	// 建两笔消费桶支出：1500 + 800，消费桶余额剩 200
	w1 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"daily","amount":1500,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	if w1.Code != 200 {
		t.Fatalf("建账失败: %s", w1.Body.String())
	}
	w2 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"daily","amount":800,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	if w2.Code != 200 {
		t.Fatalf("建账失败: %s", w2.Body.String())
	}
	var created models.Transaction
	if err := db.Where("type = ? AND amount = ?", models.TxTypeExpense, 1500).First(&created).Error; err != nil {
		t.Fatalf("定位账单失败: %v", err)
	}
	params := gin.Params{{Key: "id", Value: strconv.FormatUint(created.ID, 10)}}

	// 改成 1800：回滚 1500 后可用 = 200 + 1500 = 1700 < 1800 → 拒
	w3 := callJSON(t, uid, "PUT",
		`{"amount":1800,"sourceBucket":"consumption"}`, PutTx, params)
	resp3 := decodeResp(t, w3)
	if w3.Code != 400 {
		t.Fatalf("改成超额应被拒，实际 %d（%s）", w3.Code, w3.Body.String())
	}
	want := "「消费额度」余额不足：当前 1700.00 元，本次支出 1800.00 元"
	if resp3.Message != want {
		t.Fatalf("文案 = %q，期望 %q", resp3.Message, want)
	}
	// 改成 1600：≤1700 → 放行
	w4 := callJSON(t, uid, "PUT",
		`{"amount":1600,"sourceBucket":"consumption"}`, PutTx, params)
	if w4.Code != 200 {
		t.Fatalf("回滚后合法调整应放行，实际 %d（%s）", w4.Code, w4.Body.String())
	}
	if got := overview(t, uid).ConsumptionBalance; got != 100 {
		t.Fatalf("改账后消费桶余额 = %.2f，期望 100.00（2500 − 1600 − 800）", got)
	}
}

// TestMultiSourcePerBucketValidation 多来源含 consumption 时各来源分别校验
func TestMultiSourcePerBucketValidation(t *testing.T) {
	_, uid := txTestDB(t)
	seedSalary(t, uid)
	// 先存 1000 到储蓄桶（待支配 7500 → 6500）
	w0 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"transfer","category":"transfer_saving","amount":1000}`,
		CreateTx, nil)
	if w0.Code != 200 {
		t.Fatalf("存钱失败: %s", w0.Body.String())
	}
	// 多来源：consumption 600 + saving 400 → 放行
	w1 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"big_purchase","amount":1000,
		  "sourceDetails":[{"bucket":"consumption","amount":600},{"bucket":"saving","amount":400}]}`,
		CreateTx, nil)
	if w1.Code != 200 {
		t.Fatalf("多来源支出应被接受，实际 %d（%s）", w1.Code, w1.Body.String())
	}
	ov := overview(t, uid)
	if ov.ConsumptionBalance != 1900 {
		t.Fatalf("消费桶余额 = %.2f，期望 1900.00", ov.ConsumptionBalance)
	}
	if ov.SavingBalance != 600 {
		t.Fatalf("储蓄桶余额 = %.2f，期望 600.00", ov.SavingBalance)
	}
	// 多来源：consumption 2600 超余额（1900）→ 只拦超的那个来源
	w2 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"big_purchase","amount":2700,
		  "sourceDetails":[{"bucket":"consumption","amount":2600},{"bucket":"saving","amount":100}]}`,
		CreateTx, nil)
	resp2 := decodeResp(t, w2)
	if w2.Code != 400 {
		t.Fatalf("多来源超额应被拒，实际 %d（%s）", w2.Code, w2.Body.String())
	}
	want := "「消费额度」余额不足：当前 1900.00 元，本次支出 2600.00 元"
	if resp2.Message != want {
		t.Fatalf("文案 = %q，期望 %q", resp2.Message, want)
	}
}

// TestCreateTxValidationMessages 录入合法性判定全中文：金额/类型/分类
func TestCreateTxValidationMessages(t *testing.T) {
	_, uid := txTestDB(t)
	cases := []struct {
		body string
		want string
	}{
		{`{"scope":"personal","type":"income","category":"salary","amount":0}`, "金额必须大于 0"},
		{`{"scope":"personal","type":"income","category":"salary","amount":-5}`, "金额必须大于 0"},
		{`{"scope":"personal","type":"xxx","category":"salary","amount":10}`, "非法的账单类型"},
		{`{"scope":"personal","type":"income","category":"bad","amount":10}`, "非法的收入分类"},
		{`{"scope":"personal","type":"expense","category":"bad","amount":10}`, "非法的支出分类"},
		{`{"scope":"personal","type":"transfer","category":"bad","amount":10}`, "非法的存钱分类"},
		{`{"type":"income","category":"salary","amount":10}`, "请先选择个人账本或家庭账本"},
		{`{"scope":"personal","type":"expense","category":"loan_repay","amount":10,"sourceBucket":"cash"}`, "请选择要偿还的贷款"},
	}
	for _, tc := range cases {
		w := callJSON(t, uid, "POST", tc.body, CreateTx, nil)
		resp := decodeResp(t, w)
		if w.Code != 400 {
			t.Fatalf("应被拒 %s → 实际 %d（%s）", tc.body, w.Code, w.Body.String())
		}
		if resp.Message != tc.want {
			t.Fatalf("文案 = %q，期望 %q（body=%s）", resp.Message, tc.want, tc.body)
		}
		if !isChineseMessage(resp.Message) {
			t.Fatalf("文案必须全中文: %q", resp.Message)
		}
	}
}

// isChineseMessage 判定错误文案不夹带英文/异常类名/HTTP 状态码（数字与中文标点允许）
func isChineseMessage(s string) bool {
	for _, r := range s {
		switch {
		case r >= 0x4e00 && r <= 0x9fff: // 汉字
		case r == ' ' || r == '，' || r == '。' || r == '：' || r == '「' || r == '」' || r == '、' || r == '（' || r == '）':
		case r >= '0' && r <= '9':
		case r == '.' || r == '%' || r == '-':
		default:
			return false
		}
	}
	return true
}
