package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// 录入类接口的统一合法性判定小工具。
// 规则（产品口径 v0.5.1）：金额>0、分类合法、余额充足、必填齐全；
// 错误文案一律中文，禁止英文/异常类名/HTTP 状态码外露。

// bindJSON 解析请求体。失败统一中文提示 —— gin validator 的报错是英文
// （"failed on the 'required' tag" 等），绝不允许透给用户。
func bindJSON(c *gin.Context, obj interface{}) bool {
	if err := c.ShouldBindJSON(obj); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgRequestFormat)
		return false
	}
	return true
}

// failBadRequest 参数不合法（中文文案）
func failBadRequest(c *gin.Context, msg string) {
	utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, msg)
}

// failSave 保存失败统一中文提示（内部错误/异常不外露）
func failSave(c *gin.Context) {
	utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgSaveFailed)
}

// failLoad 加载失败统一中文提示
func failLoad(c *gin.Context) {
	utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgLoadFailed)
}

// failInternal 内部错误统一中文提示（读写皆可用，异常细节只进日志不外露）
func failInternal(c *gin.Context) {
	utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, utils.MsgOpFailed)
}

// requireAmount 金额必须大于 0；label 为字段中文名（如"金额"/"价格"/"贷款总额"）
func requireAmount(c *gin.Context, v float64, label string) bool {
	if v <= 0 {
		failBadRequest(c, label+"必须大于 0")
		return false
	}
	return true
}

// requireText 必填文本
func requireText(c *gin.Context, s, label string) bool {
	if strings.TrimSpace(s) == "" {
		failBadRequest(c, "请填写"+label)
		return false
	}
	return true
}

// requireScope 账本范围必须是 personal/family
func requireScope(c *gin.Context, scope string) bool {
	if scope != models.TxScopePersonal && scope != models.TxScopeFamily {
		failBadRequest(c, "请先选择个人账本或家庭账本")
		return false
	}
	return true
}

// validateLoanCommon 贷款类录入（公积金/商业/借款）的通用合法性判定：
// 金额>0、期限>0、年利率非负、还款方式合法、必填齐全 —— 文案统一中文。
func validateLoanCommon(c *gin.Context, scope, name, method string, total, annualRate float64, termMonths int, allowedMethods []string) bool {
	if !requireScope(c, scope) {
		return false
	}
	if !requireText(c, name, "名称") {
		return false
	}
	if !requireAmount(c, total, "贷款金额") {
		return false
	}
	if termMonths <= 0 {
		failBadRequest(c, "还款期限必须大于 0")
		return false
	}
	if annualRate < 0 {
		failBadRequest(c, "年利率不能为负")
		return false
	}
	for _, m := range allowedMethods {
		if m == method {
			return true
		}
	}
	failBadRequest(c, "还款方式不正确")
	return false
}

// bucketDraws 记账从各桶占用的金额（编辑回滚用）：
// 支出按来源桶（多来源明细优先），存钱（transfer）视为从待支配（cash）占用。
func bucketDraws(tx *models.Transaction) map[string]float64 {
	draws := map[string]float64{}
	switch tx.Type {
	case models.TxTypeExpense:
		for _, d := range parseSourceList(tx) {
			draws[d.Bucket] += d.Amount
		}
	case models.TxTypeTransfer:
		draws["cash"] += tx.Amount
	}
	return draws
}

// sourceDraw 单条来源占用
type sourceDraw struct {
	Bucket string
	Amount float64
}

// parseSourceList 解析账单来源：多来源明细（source_details JSON）优先，
// 否则单来源（source_bucket）；都没有时支出默认视为现金（cash）来源。
func parseSourceList(tx *models.Transaction) []sourceDraw {
	if tx.Type != models.TxTypeExpense {
		return nil
	}
	if tx.SourceDetails != "" {
		var details []SourceDetail
		if err := json.Unmarshal([]byte(tx.SourceDetails), &details); err == nil {
			out := make([]sourceDraw, 0, len(details))
			for _, d := range details {
				out = append(out, sourceDraw{Bucket: d.Bucket, Amount: d.Amount})
			}
			return out
		}
	}
	if tx.SourceBucket != "" {
		return []sourceDraw{{Bucket: tx.SourceBucket, Amount: tx.Amount}}
	}
	// 未指定来源的支出默认从待支配（现金）支付
	return []sourceDraw{{Bucket: "cash", Amount: tx.Amount}}
}

// validateTxRule 校验一条账单（新建，或修改后的合并态）的合法性。
// balances：当前各桶可用余额快照（bucketBalances 口径）；
// rollback：编辑场景下旧账单将释放的桶占用（新建传 nil）。
// 返回空串表示通过，否则为中文错误文案。
func validateTxRule(tx *models.Transaction, balances map[string]float64, rollback map[string]float64) string {
	if utils.ToCents(tx.Amount) <= 0 {
		return "金额必须大于 0"
	}
	switch tx.Type {
	case models.TxTypeIncome:
		if !models.IsIncomeCategory(tx.Category) {
			return "非法的收入分类"
		}
		if tx.Category == models.IncomeInvestment && tx.TargetBucket != "" && !isValidBucket(tx.TargetBucket) {
			return "目标桶无效"
		}
	case models.TxTypeExpense:
		if !models.IsExpenseCategory(tx.Category) {
			return "非法的支出分类"
		}
		if tx.Category == models.ExpenseLoanRepay {
			if tx.LoanRef == "" {
				return "请选择要偿还的贷款"
			}
			if !loanRefExists(tx.LoanRef) {
				return "关联的贷款不存在（可能已被删除），请重新选择"
			}
		}
		sources := parseSourceList(tx)
		if tx.SourceDetails != "" || tx.SourceBucket != "" {
			// 显式指定来源时逐条校验合法性与金额
			totalSource := 0.0
			for _, sd := range sources {
				if !models.IsAllowedSourceBucket(tx.Category, sd.Bucket) {
					return fmt.Sprintf("支出类别 %s 不允许使用来源 %s",
						models.CategoryLabel[tx.Category], bucketLabelCN(sd.Bucket))
				}
				if utils.ToCents(sd.Amount) <= 0 {
					return "各来源金额必须大于 0"
				}
				totalSource += sd.Amount
			}
			if !utils.EqualMoney(totalSource, tx.Amount) {
				return fmt.Sprintf("各来源金额之和 (%.2f) 与总金额 (%.2f) 不一致", totalSource, tx.Amount)
			}
		}
		// 来源余额校验（含未显式指定来源、默认走现金的支出）。
		// 口径（用户拍板 v0.5.1）：**消费额度桶允许透支** —— 超支计入月末结转、
		// 下月额度全额扣减（"上月多消费的下月全额扣除"），所以这里不拦；
		// 其余桶（待支配/储蓄/投资/应急/养老/公积金）余额不足一律硬拦。
		for _, sd := range sources {
			if sd.Bucket == "consumption" {
				continue // 允许透支，由月末结转扣减下月额度
			}
			avail := utils.Round2(balances[sd.Bucket] + rollback[sd.Bucket])
			if sd.Amount > avail+0.005 {
				return fmt.Sprintf("「%s」余额不足：当前 %.2f 元，本次支出 %.2f 元",
					bucketLabelCN(sd.Bucket), avail, sd.Amount)
			}
		}
	case models.TxTypeTransfer:
		if !models.IsTransferCategory(tx.Category) {
			return "非法的存钱分类"
		}
		// 存钱来源固定是待支配，必须校验金额 ≤ 待支配余额（P0）
		avail := utils.Round2(balances["cash"] + rollback["cash"])
		if tx.Amount > avail+0.005 {
			return fmt.Sprintf("待支配余额不足：当前 %.2f 元，本次存钱 %.2f 元", avail, tx.Amount)
		}
	default:
		return "非法的账单类型"
	}
	return ""
}
