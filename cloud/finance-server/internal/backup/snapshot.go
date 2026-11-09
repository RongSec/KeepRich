// Package backup 纯数据层：表清单 + 全量导出 + 导入（merge / replace）。
//
// 本包**不依赖 gin、不做网络请求**，handler 与 cloudsync 共用同一套序列化逻辑，
// 保证 /api/admin/backup 与云端快照 payload 的格式永不漂移（DESIGN §2.B.1）。
//
// 三条硬约束（写在这里是因为它们都是"看起来写对了、其实数据已经丢了"的陷阱）：
//
//  1. users 表必须走 userExportRow / userImportRow 这对**对称**类型。
//     models.User 的 PasswordHash / MFASecret / MFABackupCodes 是 json:"-"，
//     直接 JSON 编解码会**静默丢弃**口令哈希：导出侧丢 → 快照没哈希；
//     导入侧丢 → 哈希进不来但也不报错（DESIGN §2.B.2 第 5 条 / R5）。
//
//  2. 导出必须 Unscoped()：软删除的行要一起带走，否则导入后"删除"复活。
//
//  3. replace 模式是"云端快照 = 唯一事实源"的落地方式；merge 模式只保留给
//     人工 restore（语义是"把缺的补进去"，绝不清库）。
package backup

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"time"

	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
)

// SchemaVersion 当前快照格式版本（v0.3.1 的导出没有这个字段，读取时视为 1）
const SchemaVersion = 2

// Table 表清单条目：Name 是 API/payload 里的键名，Model 是 *T 的零值指针。
type Table struct {
	Name  string
	Model any
}

// Tables 返回 22 张表的清单（v0.4.1 是 18 张 + v0.5.0 新增 4 张）。
//
// 顺序即插入顺序：users → families → ... → app_versions → 会话/凭据/邀请码表
// （被引用方在前，避免 replace 导入时的引用错位；DELETE 时按逆序）。
// 必须与 internal/database/migrate.go 的 AutoMigrate 清单保持一致。
func Tables() []Table {
	return []Table{
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
		// v0.5.0 新增：4 张表全部进云端快照。
		// auth_sessions / device_credentials 不进 → 每次沙箱重启/发布全端被踢回登录页；
		// invite_codes / invite_code_usages 不进 → 已发出的码全失效，且 used_count 归零
		// 会让**一次性邀请码被重复使用**（比 payload 变大严重得多，§8.2 Q1）。
		{"auth_sessions", &models.AuthSession{}},
		{"device_credentials", &models.DeviceCredential{}},
		{"invite_codes", &models.InviteCode{}},
		{"invite_code_usages", &models.InviteCodeUsage{}},
	}
}

// IsBusinessTable 判定「本地是否有业务数据」时被排除的表名。
//
// ⚠️⚠️ v0.5.0 R3（本版最容易踩的 P0 坑）：新增 4 张表**必须显式排除**。
// 否则「本地只有会话/邀请码、没有任何账目」的库会被判成"有业务数据"，
// cloudsync 的 P6「本地空才允许拉取覆盖」会拒绝拉云端快照 →
// 极端情况下**反向覆盖真实账目**。会话与凭据不是账目，绝不能充当业务数据。
const (
	usersTable             = "users"
	auditLogsTable         = "audit_logs"
	errorReportTable       = "error_reports"
	sessionsTable          = "auth_sessions"
	deviceCredentialsTable = "device_credentials"
	inviteCodesTable       = "invite_codes"
	inviteUsagesTable      = "invite_code_usages"
)

// IsBusinessTable 判断某张表是否算"业务数据"。
//
// 用途：cloudsync 判定表里的 local.HasBusiness（附录 A）——只看"账 / 家庭 / 计划"
// 这类真正代表用户数据的表。只有 admin 账号、没有任何业务行的库，等于空库。
func IsBusinessTable(name string) bool {
	switch name {
	case usersTable, auditLogsTable, errorReportTable,
		sessionsTable, deviceCredentialsTable, inviteCodesTable, inviteUsagesTable:
		return false
	}
	return true
}

// Snapshot 全量快照（/api/admin/backup 的响应体，也是云端 payload 的结构）。
type Snapshot struct {
	SchemaVersion int                        `json:"schemaVersion"`
	AppVersion    string                     `json:"appVersion,omitempty"`
	ExportedAt    int64                      `json:"exportedAt"` // Unix 秒，**唯一时间闸门依据**
	Counts        map[string]int64           `json:"counts"`
	Tables        map[string]json.RawMessage `json:"tables"`
}

// ExportOptions 导出选项。
type ExportOptions struct {
	// Exclude 排除的表（仅在 IncludeAudit=false 时生效）。
	// 云端快照默认排除 ["audit_logs","error_reports"]：这两张是只增日志表，
	// 每次写操作都加行，进快照会让 payload 单调膨胀且对"账目完整"零贡献。
	Exclude []string
	// IncludeAudit true = 导出全表（/api/admin/backup 的备份语义，保持与 v0.3.1 同构）
	IncludeAudit bool
	// AppVersion 写入 payload 的 appVersion 字段
	AppVersion string
}

// userExportRow / userImportRow 只用于 users 表的 JSON 往返：
// 把 json:"-" 的三个敏感字段显式提升为可序列化字段。
//
// 外层同名字段（深度 0）会遮蔽 models.User 里被提升的同名字段（深度 1），
// encoding/json 按"深度浅者优先"取值 → 输出/读回 passwordHash 而不是丢弃。
//
// ⚠️ 两个类型的三个字段 json tag 必须**完全一致**，否则哈希进不来。
type userExportRow struct {
	models.User
	PasswordHash   string `json:"passwordHash"`
	MFASecret      string `json:"mfaSecret,omitempty"`
	MFABackupCodes string `json:"mfaBackupCodes,omitempty"`
}

// userImportRow 与 userExportRow 一一对称；导入侧禁止直接 Unmarshal 到 models.User。
type userImportRow struct {
	models.User
	PasswordHash   string `json:"passwordHash"`
	MFASecret      string `json:"mfaSecret,omitempty"`
	MFABackupCodes string `json:"mfaBackupCodes,omitempty"`
}

// toModel 把提升字段回填到内嵌结构。
// 内嵌的 models.User.PasswordHash 仍是 ""（被 json:"-" 丢弃），必须显式赋值。
func (r *userImportRow) toModel() models.User {
	u := r.User
	u.PasswordHash = r.PasswordHash
	u.MFASecret = r.MFASecret
	u.MFABackupCodes = r.MFABackupCodes
	return u
}

// Export 导出全量快照。
func Export(db *gorm.DB, opt ExportOptions) (*Snapshot, error) {
	if db == nil {
		return nil, errors.New("backup: db 未初始化")
	}
	skip := make(map[string]bool)
	if !opt.IncludeAudit {
		for _, name := range opt.Exclude {
			skip[name] = true
		}
	}

	tables := Tables()
	snap := &Snapshot{
		SchemaVersion: SchemaVersion,
		AppVersion:    opt.AppVersion,
		ExportedAt:    time.Now().Unix(),
		Counts:        make(map[string]int64, len(tables)),
		Tables:        make(map[string]json.RawMessage, len(tables)),
	}

	for _, t := range tables {
		if skip[t.Name] {
			continue
		}
		var (
			raw []byte
			n   int64
			err error
		)
		if t.Name == usersTable {
			raw, n, err = exportUsers(db)
		} else {
			raw, n, err = exportTable(db, t)
		}
		if err != nil {
			return nil, fmt.Errorf("export %s: %w", t.Name, err)
		}
		snap.Tables[t.Name] = json.RawMessage(raw)
		snap.Counts[t.Name] = n
	}
	return snap, nil
}

// exportTable 通用表导出：Unscoped + ORDER BY id，保证 payload 字节级稳定、
// 且软删除行一起带走（DESIGN §2.B.2 第 1、2 条）。
func exportTable(db *gorm.DB, t Table) ([]byte, int64, error) {
	rows := newSlicePtr(t.Model)
	if err := db.Unscoped().Order("id ASC").Find(rows).Error; err != nil {
		return nil, 0, err
	}
	v := reflect.ValueOf(rows).Elem()
	b, err := json.Marshal(v.Interface())
	if err != nil {
		return nil, 0, err
	}
	return b, int64(v.Len()), nil
}

// exportUsers users 表导出：必须走 userExportRow（否则哈希被 json:"-" 丢掉）。
func exportUsers(db *gorm.DB) ([]byte, int64, error) {
	var users []models.User
	if err := db.Unscoped().Order("id ASC").Find(&users).Error; err != nil {
		return nil, 0, err
	}
	rows := make([]userExportRow, 0, len(users))
	for _, u := range users {
		rows = append(rows, userExportRow{
			User:           u,
			PasswordHash:   u.PasswordHash,
			MFASecret:      u.MFASecret,
			MFABackupCodes: u.MFABackupCodes,
		})
	}
	b, err := json.Marshal(rows)
	if err != nil {
		return nil, 0, err
	}
	return b, int64(len(rows)), nil
}

// newSlicePtr 按 model 的元素类型新建 []*T 切片指针（供 GORM Find / json.Unmarshal 填充）。
func newSlicePtr(model any) any {
	return reflect.New(reflect.SliceOf(reflect.TypeOf(model).Elem())).Interface()
}

// CountRows 统计 raw（JSON 数组）里的行数。
// 用于快照缺少 counts 字段时兜底估算（例如只带了 tables 的旧格式）。
func CountRows(raw json.RawMessage) (int64, error) {
	var rows []json.RawMessage
	if err := json.Unmarshal(raw, &rows); err != nil {
		return 0, err
	}
	return int64(len(rows)), nil
}
