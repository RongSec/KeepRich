package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
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
	Scope         string         `json:"scope" binding:"required,oneof=personal family"`
	Type          string         `json:"type" binding:"required,oneof=income expense transfer"`
	Category      string         `json:"category" binding:"required"`
	Amount        float64        `json:"amount" binding:"gte=0"` // 投资收益可正可负
	Note          string         `json:"note"`
	OccurredAt    int64          `json:"occurredAt"`
	LoanRef       string         `json:"loanRef"`       // 偿还贷款关联，category=loan_repay 时必填："hf:1" / "cl:2" / "bm:3"
	TargetBucket  string         `json:"targetBucket"`  // 收入目标桶：saving/investment/emergency/pension
	SourceBucket  string         `json:"sourceBucket"`  // 支出来源桶（单来源兼容）
	SourceDetails []SourceDetail `json:"sourceDetails"` // 多来源明细：[{bucket, amount}, ...]
}

// TxItem 包含记账和记录人信息
type TxItem struct {
	models.Transaction
	Username  string `json:"username"`
	Nickname  string `json:"nickname"`
	OverWorry bool   `json:"overWorry"` // 单笔是否超过无顾虑单笔
}

func CreateTx(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req CreateTxReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
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
	if req.Amount <= 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "金额必须大于 0")
		return
	}
	// 校验分类与类型匹配
	switch req.Type {
	case models.TxTypeIncome:
		if !models.IsIncomeCategory(req.Category) {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "非法的收入分类")
			return
		}
	case models.TxTypeExpense:
		if !models.IsExpenseCategory(req.Category) {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "非法的支出分类")
			return
		}
	case models.TxTypeTransfer:
		if !models.IsTransferCategory(req.Category) {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "非法的存钱分类")
			return
		}
		// 转账分类自动写入 targetBucket
		req.TargetBucket = models.BucketFromTransfer(req.Category)
	}
	// 偿还贷款需关联 loanRef
	if req.Category == models.ExpenseLoanRepay && req.LoanRef == "" {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "请选择要偿还的贷款")
		return
	}
	// 支出来源校验：按支出类别限制允许的来源桶
	if req.Type == models.TxTypeExpense {
		if len(req.SourceDetails) > 0 {
			// 多来源模式：校验每个来源
			var totalSource float64
			for _, sd := range req.SourceDetails {
				if !models.IsAllowedSourceBucket(req.Category, sd.Bucket) {
					utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest,
						fmt.Sprintf("支出类别 %s 不允许使用来源 %s", models.CategoryLabel[req.Category], sd.Bucket))
					return
				}
				if sd.Amount <= 0 {
					utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "各来源金额必须大于 0")
					return
				}
				totalSource += sd.Amount
			}
			// 校验各来源金额之和等于总金额（精确到分）
			if !utils.EqualMoney(totalSource, req.Amount) {
				utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest,
					fmt.Sprintf("各来源金额之和 (%.2f) 与总金额 (%.2f) 不一致", totalSource, req.Amount))
				return
			}
		} else if req.SourceBucket != "" {
			// 单来源兼容模式
			if !models.IsAllowedSourceBucket(req.Category, req.SourceBucket) {
				utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest,
					fmt.Sprintf("支出类别 %s 不允许使用来源 %s", models.CategoryLabel[req.Category], req.SourceBucket))
				return
			}
		}
	}
	// 投资收益可指定目标桶
	if req.Category == models.IncomeInvestment && req.TargetBucket != "" {
		if !isValidBucket(req.TargetBucket) {
			utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "目标桶无效")
			return
		}
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
	if err := database.DB.Create(&tx).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}

	// 超支提醒：仅当支出超过无顾虑单笔时触发
	if req.Type == models.TxTypeExpense {
		worryPerBuy := computeWorryFreePerBuy(req.Scope, uid, tx.FamilyID)
		if worryPerBuy > 0 && req.Amount > worryPerBuy {
			ns := services.NewNotifyService(database.DB)
			f := "%.0f"
			_ = ns.PushTo(uid, models.NotifyTypeOverSpend, "超支提醒",
				"一笔 "+models.CategoryLabel[req.Category]+" 支出 ¥"+fmt.Sprintf(f, req.Amount)+" 超过无顾虑单笔 ¥"+fmt.Sprintf(f, worryPerBuy), "")
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
		q = q.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid)
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
		q = q.Where("(scope = ? AND uid IN ?) OR (scope = ? AND family_id = ?)",
			models.TxScopePersonal, memberIDs, models.TxScopeFamily, m.FamilyID)
	}
	if txType != "" {
		q = q.Where("type = ?", txType)
	}
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

	var total int64
	q.Count(&total)

	// 收入/支出/存钱合计（按当前筛选条件全量聚合；用 Session 复用 q 上的 where 但不复用 limit/order）
	var sumIncome, sumExpense, sumTransfer float64
	qIncome := q.Session(&gorm.Session{})
	qIncome.Where("type = ?", models.TxTypeIncome).Select("COALESCE(SUM(amount),0)").Scan(&sumIncome)
	qExpense := q.Session(&gorm.Session{})
	qExpense.Where("type = ?", models.TxTypeExpense).Select("COALESCE(SUM(amount),0)").Scan(&sumExpense)
	qTransfer := q.Session(&gorm.Session{})
	qTransfer.Where("type = ?", models.TxTypeTransfer).Select("COALESCE(SUM(amount),0)").Scan(&sumTransfer)

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
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "not found")
		return
	}
	if tx.UID != uid && middleware.MustRole(c) != "admin" {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权删除")
		return
	}
	database.DB.Delete(&tx)
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
	scopeQ := txScopeQuery(scope, uid, familyID)

	// 储蓄桶余额
	var savingBalance float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ?", models.TxTypeTransfer, models.TransferToSaving).
		Where(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&savingBalance)

	var interestSaving float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND target_bucket = ?", models.TxTypeIncome, models.IncomeInvestment, "saving").
		Where(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&interestSaving)
	savingBalance += interestSaving

	// 年薪 = 月均工资 × 12，按实际有收入的月数年化（不含公积金）
	yearAgo := time.Now().AddDate(-1, 0, 0).Unix()
	var salaryIncome float64
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND occurred_at >= ?", models.TxTypeIncome, models.IncomeSalary, yearAgo).
		Where(scopeQ).
		Select("COALESCE(SUM(amount),0)").Scan(&salaryIncome)

	baseIncome := salaryIncome

	// 计算实际有工资收入的月数（不含公积金）
	var activeMonths int
	database.DB.Model(&models.Transaction{}).
		Where("type = ? AND category = ? AND occurred_at >= ?", models.TxTypeIncome, models.IncomeSalary, yearAgo).
		Where(scopeQ).
		Select("COUNT(DISTINCT DATE_FORMAT(FROM_UNIXTIME(occurred_at), '%Y-%m'))").Scan(&activeMonths)
	if activeMonths < 1 {
		activeMonths = 1
	}
	annualIncome := baseIncome / float64(activeMonths) * 12.0

	return savingBalance + annualIncome*20
}

func isValidBucket(b string) bool {
	switch b {
	case "saving", "investment", "emergency", "pension":
		return true
	}
	return false
}
