package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"github.com/yourname/family-finance/backend/internal/utils"
)

type SourceDetail struct {
	Bucket string  `json:"bucket"`
	Amount float64 `json:"amount"`
}

type CreateTxReq struct {
	Scope         string         `json:"scope"` // personal/family，合法性在业务校验统一给出中文提示
	Type          string         `json:"type"`  // income/expense/transfer
	Category      string         `json:"category"`
	Amount        float64        `json:"amount"` // 正负由业务校验给出中文提示（金额必须大于 0）
	Note          string         `json:"note"`
	OccurredAt    int64          `json:"occurredAt"`
	LoanRef       string         `json:"loanRef"`       // 偿还贷款关联，category=loan_repay 时必填："hf:1" / "cl:2" / "bm:3"
	TargetBucket  string         `json:"targetBucket"`  // 收入目标桶：saving/investment/emergency/pension/consumption
	SourceBucket  string         `json:"sourceBucket"`  // 支出来源桶（单来源兼容）
	SourceDetails []SourceDetail `json:"sourceDetails"` // 多来源明细：[{bucket, amount}, ...]
}

// TxItem 包含记账和记录人信息
type TxItem struct {
	models.Transaction
	Username  string `json:"username"`
	Nickname  string `json:"nickname"`
	OverWorry bool   `json:"overWorry"` // 单笔是否超过无顾虑单笔
	LoanName  string `json:"loanName"`  // 偿还的贷款名称（loanRef 解析，便于账单里直接看到）
}

// resolveLoanName 根据 loanRef 解析贷款名称："hf:1" → "公积金贷款 #1"
func resolveLoanName(loanRef string) string {
	if loanRef == "" {
		return ""
	}
	parts := strings.SplitN(loanRef, ":", 2)
	if len(parts) != 2 {
		return ""
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return ""
	}
	var name string
	switch parts[0] {
	case "hf":
		var l models.HousingFundLoan
		if database.DB.First(&l, id).Error == nil {
			return l.Name
		}
		name = "公积金贷款"
	case "cl":
		var l models.CommercialLoan
		if database.DB.First(&l, id).Error == nil {
			return l.Name
		}
		name = "商业贷款"
	case "bm":
		var l models.BorrowedMoney
		if database.DB.First(&l, id).Error == nil {
			return l.Name
		}
		name = "借款"
	}
	return fmt.Sprintf("%s #%d", name, id)
}

// applyLoanRef 偿还贷款后同步更新对应贷款的累计已还本金
// loanRef 格式："hf:1"（公积金）/ "cl:2"（商业）/ "bm:3"（借款）
// delta 为正表示新增偿还，为负表示删除账单回滚
func applyLoanRef(loanRef string, delta float64) {
	if loanRef == "" || delta == 0 {
		return
	}
	parts := strings.SplitN(loanRef, ":", 2)
	if len(parts) != 2 {
		return
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return
	}
	switch parts[0] {
	case "hf":
		database.DB.Model(&models.HousingFundLoan{}).Where("id = ?", id).
			Update("paid_amount", gorm.Expr("COALESCE(paid_amount,0) + ?", delta))
	case "cl":
		database.DB.Model(&models.CommercialLoan{}).Where("id = ?", id).
			Update("paid_amount", gorm.Expr("COALESCE(paid_amount,0) + ?", delta))
	case "bm":
		database.DB.Model(&models.BorrowedMoney{}).Where("id = ?", id).
			Update("paid_amount", gorm.Expr("COALESCE(paid_amount,0) + ?", delta))
	}
}

// bucketLabelCN 桶名 → 中文，错误提示别把 "cash" 直接甩给用户
func bucketLabelCN(bucket string) string {
	switch bucket {
	case "cash":
		return "可支配额度"
	case "saving":
		return "储蓄桶"
	case "investment":
		return "投资桶"
	case "emergency":
		return "应急备用金"
	case "pension":
		return "养老金"
	case "housing_fund":
		return "公积金"
	case "consumption":
		return "消费额度"
	}
	return bucket
}

// loanRefExists 校验 loanRef 指向的贷款是否真实存在。
// 只有"选了贷款但该贷款已被删除"时才会为 false —— 这种账单存进去，
// 用户在账单里既看不到还的是哪笔，贷款条目也不会变化，必须挡在入口。
func loanRefExists(loanRef string) bool {
	parts := strings.SplitN(loanRef, ":", 2)
	if len(parts) != 2 {
		return false
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return false
	}
	var n int64
	switch parts[0] {
	case "hf":
		database.DB.Model(&models.HousingFundLoan{}).Where("id = ?", id).Count(&n)
	case "cl":
		database.DB.Model(&models.CommercialLoan{}).Where("id = ?", id).Count(&n)
	case "bm":
		database.DB.Model(&models.BorrowedMoney{}).Where("id = ?", id).Count(&n)
	}
	return n > 0
}

// bucketBalance 指定来源桶的当前可用余额。
// bucket: cash / saving / investment / emergency / pension / housing_fund / consumption
//
// 直接复用总览（GetOverview）的同一套口径 —— 来源标签上显示多少余额，
// 校验就用多少，否则前端显示 9000 而后端按另一种算法算出 0，用户会看到
// "明明有钱却提示余额不足"（公积金曾经就是这样）。
//   - cash 分支返回 ov.RemainingBudget（剩余待支配，存钱/现金支出的可用额）
//   - consumption 分支返回 ov.ConsumptionBalance（消费额度桶当前余额）
func bucketBalance(scope string, uid uint64, familyID *uint64, bucket string) float64 {
	return bucketBalances(scope, uid, familyID)[bucket]
}

// bucketBalances 一次拉取全部来源桶余额（多来源校验时避免多次全量聚合）。
func bucketBalances(scope string, uid uint64, familyID *uint64) map[string]float64 {
	svc := services.NewFinanceService(database.DB)
	ov, err := svc.GetOverview(scope, uid, familyID)
	if err != nil || ov == nil {
		return map[string]float64{}
	}
	return map[string]float64{
		"cash":         utils.Round2(ov.RemainingBudget),
		"saving":       utils.Round2(ov.SavingBalance),
		"investment":   utils.Round2(ov.InvestmentBalance),
		"emergency":    utils.Round2(ov.EmergencyBalance),
		"pension":      utils.Round2(ov.PensionBalance),
		"housing_fund": utils.Round2(ov.TotalHousingFund),
		"consumption":  utils.Round2(ov.ConsumptionBalance),
	}
}

func CreateTx(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req CreateTxReq
	if !bindJSON(c, &req) {
		return
	}
	if !requireScope(c, req.Scope) {
		return
	}
	if req.Scope == models.TxScopeFamily {
		// 必须为家庭成员
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
			return
		}
	}
	if req.OccurredAt == 0 {
		req.OccurredAt = time.Now().Unix()
	}
	req.Amount = utils.Round2(req.Amount) // 金额统一规范化到分
	// 转账分类自动写入 targetBucket
	if req.Type == models.TxTypeTransfer {
		req.TargetBucket = models.BucketFromTransfer(req.Category)
	}
	// 序列化多来源明细
	sourceDetailsJSON := ""
	if len(req.SourceDetails) > 0 {
		b, _ := json.Marshal(req.SourceDetails)
		sourceDetailsJSON = string(b)
	}
	tx := models.Transaction{
		UID:           uid,
		Scope:         req.Scope,
		Type:          req.Type,
		Category:      req.Category,
		Amount:        req.Amount,
		Note:          req.Note,
		OccurredAt:    req.OccurredAt,
		LoanRef:       req.LoanRef,
		TargetBucket:  req.TargetBucket,
		SourceBucket:  req.SourceBucket,
		SourceDetails: sourceDetailsJSON,
	}
	if req.Scope == models.TxScopeFamily {
		var m models.FamilyMember
		database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m)
		tx.FamilyID = &m.FamilyID
	}
	// 全面合法性判定：金额>0、分类合法、loanRef 存在性、支出来源合法、
	// 支出来源余额充足、存钱金额 ≤ 待支配余额 —— 错误文案统一中文
	balances := bucketBalances(req.Scope, uid, tx.FamilyID)
	if msg := validateTxRule(&tx, balances, nil); msg != "" {
		failBadRequest(c, msg)
		return
	}

	if err := database.DB.Create(&tx).Error; err != nil {
		failSave(c)
		return
	}

	// 偿还贷款：同步累加对应贷款的已还本金，否则贷款条目永远不变
	if req.Category == models.ExpenseLoanRepay {
		applyLoanRef(req.LoanRef, req.Amount)
	}

	// 超支提醒：仅当支出超过无顾虑单笔时触发
	if req.Type == models.TxTypeExpense {
		worryPerBuy := computeWorryFreePerBuy(req.Scope, uid, tx.FamilyID)
		if worryPerBuy > 0 && req.Amount > worryPerBuy {
			ns := services.NewNotifyService(database.DB)
			f := "%.0f"
			// 模板变量：{分类}/{金额}/{限额}/{日期}，默认/自定义模板统一在 PushTo 渲染
			_ = ns.PushTo(uid, models.NotifyTypeOverSpend, map[string]string{
				"分类": models.CategoryLabel[req.Category],
				"金额": fmt.Sprintf(f, req.Amount),
				"限额": fmt.Sprintf(f, worryPerBuy),
				"日期": time.Now().Format("2006-01-02"),
			}, "")
		}
	}

	utils.OK(c, tx)
}

func ListTx(c *gin.Context) {
	uid := middleware.MustUID(c)
	scope := c.DefaultQuery("scope", models.TxScopePersonal)
	txType := c.Query("type")
	category := c.Query("category")
	recorder := c.Query("recorder") // uid 字符串，"-1" 表示全部
	// memberUid：家庭范围下「只看某个成员的个人账单」（每位家庭成员都可查看其他成员）。
	// 0 / 空 = 整个家庭聚合。必须校验目标成员与自己同属一个活跃家庭，防跨家庭窥探。
	memberUid, _ := strconv.ParseUint(c.Query("memberUid"), 10, 64)
	startAt, _ := strconv.ParseInt(c.Query("startAt"), 10, 64)
	endAt, _ := strconv.ParseInt(c.Query("endAt"), 10, 64)
	exceedWorry := c.Query("exceedWorry") // "1"=仅超支；"0"=仅未超支；空=全部
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("size", "20"))
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 200 {
		size = 20
	}

	q := database.DB.Model(&models.Transaction{})
	if scope == models.TxScopePersonal {
		// 个人 = 我记的账（含家庭 scope 记录）：用户在家庭记账后也要在个人看得到
		q = q.Where("uid = ?", uid)
	} else {
		// 家庭：聚合所有活跃成员的个人数据 + 家庭数据
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
			utils.OK(c, gin.H{"list": []any{}, "total": 0})
			return
		}
		var memberIDs []uint64
		database.DB.Model(&models.FamilyMember{}).
			Where("family_id = ? AND status = ?", m.FamilyID, models.MemberStatusActive).
			Pluck("user_id", &memberIDs)
		if len(memberIDs) == 0 {
			memberIDs = []uint64{0}
		}
		if memberUid > 0 {
			// 只看某个成员的账：目标必须是本家庭活跃成员（含自己）。
			// 与「个人」口径一致：该成员的全部记录（含家庭 scope）。
			isMember := false
			for _, id := range memberIDs {
				if id == memberUid {
					isMember = true
					break
				}
			}
			if !isMember {
				utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "该成员不属于当前家庭，无法查看其账单")
				return
			}
			q = q.Where("uid = ?", memberUid)
		} else {
			// 整个家庭：聚合所有活跃成员的个人数据 + 家庭数据
			q = q.Where("(scope = ? AND uid IN ?) OR (scope = ? AND family_id = ?)",
				models.TxScopePersonal, memberIDs, models.TxScopeFamily, m.FamilyID)
		}
	}
	// 注意：type 过滤挪到「三联求和」之后——收入/支出/存钱合计必须恒显示全部三项
	// （不随当前 tab 的 type 变成 0），只有列表和 total 才按 type 过滤。
	if category != "" && category != "all" {
		q = q.Where("category = ?", category)
	}
	if recorder != "" && recorder != "all" && recorder != "-1" {
		q = q.Where("uid = ?", recorder)
	}
	if startAt > 0 {
		q = q.Where("occurred_at >= ?", startAt)
	}
	if endAt > 0 {
		q = q.Where("occurred_at < ?", endAt)
	}

	// 计算无顾虑单笔金额（用于超支判断）
	worryPerBuy := 0.0
	if scope == models.TxScopePersonal {
		worryPerBuy = computeWorryFreePerBuy(scope, uid, nil)
	} else {
		var m models.FamilyMember
		if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err == nil {
			worryPerBuy = computeWorryFreePerBuy(scope, uid, &m.FamilyID)
		}
	}
	if exceedWorry == "1" {
		q = q.Where("amount > ?", worryPerBuy)
	} else if exceedWorry == "0" {
		q = q.Where("amount <= ?", worryPerBuy)
	}

	// 收入/支出/存钱合计（按当前筛选条件全量聚合；用 Session 复用 q 上的 where 但不复用 limit/order）
	var sumIncome, sumExpense, sumTransfer float64
	qIncome := q.Session(&gorm.Session{})
	qIncome.Where("type = ?", models.TxTypeIncome).Select("COALESCE(SUM(amount),0)").Scan(&sumIncome)
	qExpense := q.Session(&gorm.Session{})
	qExpense.Where("type = ?", models.TxTypeExpense).Select("COALESCE(SUM(amount),0)").Scan(&sumExpense)
	qTransfer := q.Session(&gorm.Session{})
	qTransfer.Where("type = ?", models.TxTypeTransfer).Select("COALESCE(SUM(amount),0)").Scan(&sumTransfer)

	// 三联求和已用「不含 type 过滤」的 q 算完；下面才按 type 过滤列表与 total。
	if txType != "" {
		q = q.Where("type = ?", txType)
	}

	// total 与 list 都按 type 过滤（三联求和不受影响）
	var total int64
	q.Count(&total)

	var list []models.Transaction
	q.Order("occurred_at DESC").Offset((page - 1) * size).Limit(size).Find(&list)

	// 收集 uid -> user info
	uids := make([]uint64, 0, len(list))
	for _, t := range list {
		uids = append(uids, t.UID)
	}
	userMap := map[uint64]models.User{}
	if len(uids) > 0 {
		var users []models.User
		database.DB.Where("id IN ?", uids).Find(&users)
		for _, u := range users {
			userMap[u.ID] = u
		}
	}

	out := make([]TxItem, 0, len(list))
	for _, t := range list {
		u := userMap[t.UID]
		out = append(out, TxItem{
			Transaction: t,
			Username:    u.Username,
			Nickname:    u.Nickname,
			OverWorry:   t.Amount > worryPerBuy,
			LoanName:    resolveLoanName(t.LoanRef),
		})
	}

	utils.OK(c, gin.H{
		"list":         out,
		"total":        total,
		"page":         page,
		"size":         size,
		"worryPerBuy":  worryPerBuy,
		"sumIncome":    sumIncome,
		"sumExpense":   sumExpense,
		"sumTransfer":  sumTransfer,
		"filter": gin.H{
			"scope":        scope,
			"type":         txType,
			"category":     category,
			"recorder":     recorder,
			"startAt":      startAt,
			"endAt":        endAt,
			"exceedWorry":  exceedWorry,
		},
	})
}

func DeleteTx(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var tx models.Transaction
	if err := database.DB.First(&tx, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "账单不存在")
		return
	}
	if tx.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	// 删除账单时回滚贷款已还本金
	if tx.Category == models.ExpenseLoanRepay {
		applyLoanRef(tx.LoanRef, -tx.Amount)
	}
	if err := database.DB.Delete(&tx).Error; err != nil {
		failSave(c)
		return
	}
	utils.OK(c, gin.H{"ok": true})
}

// txScopeQuery 为交易查询构建 scope 条件
func txScopeQuery(scope string, uid uint64, familyID *uint64) func(db *gorm.DB) *gorm.DB {
	return func(db *gorm.DB) *gorm.DB {
		if scope == models.TxScopePersonal {
			return db.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid)
		}
		var memberIDs []uint64
		database.DB.Model(&models.FamilyMember{}).
			Where("family_id = ? AND status = ?", *familyID, models.MemberStatusActive).
			Pluck("user_id", &memberIDs)
		if len(memberIDs) == 0 {
			memberIDs = []uint64{0}
		}
		return db.Where("(scope = 'personal' AND uid IN ?) OR (scope = 'family' AND family_id = ?)",
			memberIDs, *familyID)
	}
}

// computeWorryFreePerBuy 无顾虑单笔（元）= 储蓄桶余额 + 年薪×20
// 文档 §4 公式结果以万元表述，API 与前端统一使用元，故此处不再 ÷10000
func computeWorryFreePerBuy(scope string, uid uint64, familyID *uint64) float64 {
	// scopeQ 是 scope 条件函数：必须用 Scopes 应用。
	// 历史 bug：曾写成 Where(scopeQ)——函数被当 SQL 绑定参数报错，
	// 查询静默失败，无顾虑单笔恒为 0，超支提醒从不触发。
	scopeQ := txScopeQuery(scope, uid, familyID)

	// 储蓄桶余额
	var savingBalance float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ?", models.TxTypeTransfer, models.TransferToSaving).
		Scopes(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&savingBalance)

	var interestSaving float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND target_bucket = ?", models.TxTypeIncome, models.IncomeInvestment, "saving").
		Scopes(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&interestSaving)
	savingBalance += interestSaving

	// 年薪 = 月均（工资 + 当月公积金）× 12，按实际有收入的月数年化
	// （过往公积金/过往存款/意外收入仍不计入）
	yearAgo := time.Now().AddDate(-1, 0, 0).Unix()
	var salaryIncome float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND occurred_at >= ?", models.TxTypeIncome, models.IncomeSalary, yearAgo).
		Scopes(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&salaryIncome)
	var housingIncome float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND occurred_at >= ?", models.TxTypeIncome, models.IncomeHousingFund, yearAgo).
		Scopes(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&housingIncome)

	baseIncome := salaryIncome + housingIncome

	// 计算实际有收入的月数（工资或当月公积金）
	activeMonths := services.CountDistinctMonths(
		database.DB.Model(&models.Transaction{}).
			Where("type = ? AND category IN ? AND occurred_at >= ?",
				models.TxTypeIncome,
				[]string{models.IncomeSalary, models.IncomeHousingFund}, yearAgo).
			Scopes(scopeQ))
	if activeMonths < 1 {
		activeMonths = 1
	}
	annualIncome := baseIncome / float64(activeMonths) * 12.0

	return savingBalance + annualIncome*20
}

func isValidBucket(b string) bool {
	switch b {
	case "saving", "investment", "emergency", "pension", "consumption":
		return true
	}
	return false
}
