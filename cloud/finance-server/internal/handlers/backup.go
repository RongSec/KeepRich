package handlers

import (
	"encoding/json"
	"net/http"
	"reflect"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// 云托管沙箱的 SQLite 运行副本在临时目录，沙箱重启即重置为部署快照。
// 这对接口提供"发布前导出 / 发布后导入"的数据保险：
//   GET  /api/admin/backup          全表 JSON 导出
//   POST /api/admin/backup/restore  导入 JSON（逐表插入，冲突跳过）

// backupTables 与 cmd/migrate 的表清单保持一致
type backupTable struct {
	name  string
	model any
}

func backupTables() []backupTable {
	return []backupTable{
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
}

// newSlicePtr 按 model 的元素类型新建 []*T 切片指针
func newSlicePtr(model any) any {
	return reflect.New(reflect.SliceOf(reflect.TypeOf(model).Elem())).Interface()
}

// AdminExportBackup 全表导出为 JSON（审计日志可含敏感操作记录，仅管理员）
func AdminExportBackup(c *gin.Context) {
	out := map[string]any{}
	counts := map[string]int64{}
	for _, t := range backupTables() {
		rows := newSlicePtr(t.model)
		if err := database.DB.Unscoped().Find(rows).Error; err != nil {
			utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "export "+t.name+": "+err.Error())
			return
		}
		v := reflect.ValueOf(rows).Elem()
		out[t.name] = v.Interface()
		counts[t.name] = int64(v.Len())
	}
	c.Header("Content-Disposition", "attachment; filename=finance-backup-"+time.Now().Format("20060102-150405")+".json")
	utils.OK(c, gin.H{
		"exportedAt": time.Now().Unix(),
		"counts":     counts,
		"tables":     out,
	})
}

// AdminRestoreBackup 导入 JSON：逐表按主键插入，已存在的行跳过（可重复执行）
func AdminRestoreBackup(c *gin.Context) {
	var body struct {
		Tables map[string]json.RawMessage `json:"tables"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	if len(body.Tables) == 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "tables 为空")
		return
	}

	inserted := map[string]int64{}
	skipped := map[string]int64{}
	err := database.DB.Transaction(func(tx *gorm.DB) error {
		for _, t := range backupTables() {
			raw, ok := body.Tables[t.name]
			if !ok || len(raw) == 0 {
				continue
			}
			rows := newSlicePtr(t.model)
			if err := json.Unmarshal(raw, rows); err != nil {
				return err
			}
			v := reflect.ValueOf(rows).Elem()
			for i := 0; i < v.Len(); i++ {
				row := v.Index(i).Addr().Interface()
				// 先查后插：GORM 的 OnConflict+default 字段组合在冲突行上会触发
				// 反射 panic（SetBool unaddressable），查-插模式完全绕开
				if pk := reflect.Indirect(reflect.ValueOf(row)).FieldByName("ID"); pk.IsValid() && !pk.IsZero() {
					var cnt int64
					res := tx.Model(t.model).Unscoped().Where("id = ?", pk.Interface()).Count(&cnt)
					if res.Error != nil {
						return res.Error
					}
					if cnt > 0 {
						skipped[t.name]++
						continue
					}
				}
				res := tx.Create(row)
				if res.Error != nil {
					return res.Error
				}
				if res.RowsAffected > 0 {
					inserted[t.name]++
				} else {
					skipped[t.name]++
				}
			}
		}
		return nil
	})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "restore: "+err.Error())
		return
	}
	utils.OK(c, gin.H{"inserted": inserted, "skipped": skipped})
}
