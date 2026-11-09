package backup

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"reflect"

	"gorm.io/gorm"
)

// ImportMode 导入模式。
type ImportMode int

const (
	// ImportMerge 查-插，已存在主键则跳过（= v0.3.1 行为，restore 默认）
	ImportMerge ImportMode = iota
	// ImportReplace 事务内先清后插（云端快照覆盖本地 = 唯一事实源语义）
	ImportReplace
)

// ImportOptions 导入选项。
type ImportOptions struct {
	Mode ImportMode
	// KeepTables Replace 模式下**不清空**的表。默认空 = 全表替换
	// （users 也必须替换，否则沙箱重启后账号丢失；users 行已带口令哈希，可安全替换）。
	KeepTables []string
}

// ImportResult 导入结果（运维靠这张表判断"到底动了什么"）。
type ImportResult struct {
	Inserted    map[string]int64 `json:"inserted"`    // 本次新插入的行数（按表）
	Skipped     map[string]int64 `json:"skipped"`     // 主键已存在被跳过的行数（merge 语义）
	Deleted     map[string]int64 `json:"deleted"`     // 被删除的行数（仅 replace 非空）
	Overwritten map[string]int64 `json:"overwritten"` // 被覆盖的行数（仅 replace 可能 > 0）
	Replaced    bool             `json:"replaced"`    // 是否走了全表替换
}

func newImportResult() ImportResult {
	return ImportResult{
		Inserted:    map[string]int64{},
		Skipped:     map[string]int64{},
		Deleted:     map[string]int64{},
		Overwritten: map[string]int64{},
	}
}

// TotalOverwritten 汇总覆盖行数（handler 回显用）
func (r ImportResult) TotalOverwritten() int64 {
	var total int64
	for _, n := range r.Overwritten {
		total += n
	}
	return total
}

// tablePlan 一张表的预解析结果：rows 是 **可直接 Create 的指针**（*T）。
type tablePlan struct {
	name  string
	model any
	rows  []any
	count int64
}

// Import 把 tables（JSON 数组的原始字节）导入数据库。
//
// 顺序严格按 DESIGN §2.B.3：
//  1. 预解析（任一表 JSON 非法 → 直接返回错误，不写库；users 走 userImportRow）
//  2. 安全校验（tables 为空 → 拒绝；users 解析后 0 行 → 保留本地 users）
//  3. BEGIN
//  4. replace：按 Tables() **逆序** DELETE（只清本次输入里出现的表）
//  5. 按 Tables() **正序**逐行 Create（显式带 ID / CreatedAt / UpdatedAt / DeletedAt）
//  6. COMMIT（任一步出错 → 整体回滚，本地数据保持原样）
func Import(db *gorm.DB, tables map[string]json.RawMessage, opt ImportOptions) (ImportResult, error) {
	res := newImportResult()
	if db == nil {
		return res, errors.New("backup: db 未初始化")
	}
	// 红线 5.3.3：空输入一律拒绝，绝不"猜"成清库
	if len(tables) == 0 {
		return res, errors.New("backup: tables 为空，拒绝导入")
	}

	// ---- 1. 预解析（此时不碰数据库）----
	plans, err := parsePlans(tables)
	if err != nil {
		return res, err
	}
	if len(plans) == 0 {
		return res, errors.New("backup: tables 里没有任何可识别的表，拒绝导入")
	}

	// ---- 2. 安全校验：users 为 0 行时保留本地 users ----
	// 没有 users 的快照导入后谁都登不进，属于"把库洗坏"，宁可不导。
	if p, ok := plans[usersTable]; ok && p.count == 0 {
		log.Printf("[backup] warn: tables.users 解析后 0 行 → 保留本地 users（不删不插）")
		delete(plans, usersTable)
	}

	if opt.Mode == ImportReplace {
		res.Replaced = true
		err = importReplace(db, plans, opt.KeepTables, &res)
	} else {
		err = importMerge(db, plans, &res)
	}
	if err != nil {
		// 事务已回滚，把计数器恢复到"什么都没发生"，避免 handler 回显误导运维
		return newImportResult(), err
	}
	return res, nil
}

// importMerge 查-插模式：已存在主键则跳过（可重复执行 / 幂等）。
//
// 保留这个模式的唯一理由：`POST /api/admin/backup/restore` 是人工兜底动作，
// 语义应当是"把缺的补进去"，绝不该清库。云端快照拉取才需要 replace。
func importMerge(db *gorm.DB, plans map[string]*tablePlan, res *ImportResult) error {
	return db.Transaction(func(tx *gorm.DB) error {
		for _, t := range Tables() {
			p, ok := plans[t.Name]
			if !ok {
				continue
			}
			for _, row := range p.rows {
				id, okID := primaryKeyOf(row)
				if okID && id != 0 {
					var cnt int64
					if err := tx.Model(t.Model).Unscoped().Where("id = ?", id).Count(&cnt).Error; err != nil {
						return fmt.Errorf("merge %s (id=%d) count: %w", t.Name, id, err)
					}
					if cnt > 0 {
						res.Skipped[t.Name]++
						continue
					}
				}
				if err := tx.Unscoped().Create(row).Error; err != nil {
					return fmt.Errorf("merge %s insert: %w", t.Name, err)
				}
				res.Inserted[t.Name]++
			}
		}
		return nil
	})
}

// importReplace 事务内先清后插（本地是"丢弃型缓存"，云端快照才是真源）。
func importReplace(db *gorm.DB, plans map[string]*tablePlan, keepTables []string, res *ImportResult) error {
	keep := make(map[string]bool, len(keepTables))
	for _, name := range keepTables {
		keep[name] = true
	}
	all := Tables()
	return db.Transaction(func(tx *gorm.DB) error {
		// 4. 逆序 DELETE：只清本次输入里出现的表。
		//    audit_logs / error_reports 默认不在云端 payload 里 → 不能被清掉。
		for i := len(all) - 1; i >= 0; i-- {
			t := all[i]
			if _, ok := plans[t.Name]; !ok {
				continue
			}
			if keep[t.Name] {
				continue
			}
			del := tx.Unscoped().Where("1 = 1").Delete(t.Model)
			if del.Error != nil {
				return fmt.Errorf("replace %s delete: %w", t.Name, del.Error)
			}
			res.Deleted[t.Name] = del.RowsAffected
		}
		// 5. 正序 Create：显式带主键与时间戳（Unscoped 保证 deletedAt 也能写入）。
		for _, t := range all {
			p, ok := plans[t.Name]
			if !ok {
				continue
			}
			for _, row := range p.rows {
				if err := tx.Unscoped().Create(row).Error; err != nil {
					return fmt.Errorf("replace %s insert: %w", t.Name, err)
				}
				res.Inserted[t.Name]++
			}
		}
		// 6. 覆盖计数：被删掉又被重新插入的行数（诊断用）
		for name, deleted := range res.Deleted {
			inserted := res.Inserted[name]
			if inserted == 0 || deleted == 0 {
				continue
			}
			if deleted < inserted {
				res.Overwritten[name] = deleted
			} else {
				res.Overwritten[name] = inserted
			}
		}
		return nil
	})
}

// parsePlans 把所有 raw 预解析成 []any（元素为 *T）。
// 任何一张表 JSON 非法都直接返回错误 —— 不允许"半截数据"写库。
func parsePlans(tables map[string]json.RawMessage) (map[string]*tablePlan, error) {
	plans := make(map[string]*tablePlan, len(tables))
	for _, t := range Tables() {
		raw, ok := tables[t.Name]
		if !ok {
			continue
		}
		if len(bytes.TrimSpace(raw)) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			continue // 等价于未提供
		}
		plan := &tablePlan{name: t.Name, model: t.Model}

		if t.Name == usersTable {
			// ⚠️ 关键：users 必须反序列化到 userImportRow，再 toModel() 回填哈希。
			// 直接 Unmarshal 到 models.User 会因为 json:"-" **静默丢弃** passwordHash，
			// 结果是"账号在、但谁都登不进"，且全程不报错（本任务最大的陷阱）。
			var rows []*userImportRow
			if err := json.Unmarshal(raw, &rows); err != nil {
				return nil, fmt.Errorf("backup: 解析 users 失败（应为数组）: %w", err)
			}
			for _, r := range rows {
				if r == nil {
					continue
				}
				u := r.toModel()
				plan.rows = append(plan.rows, &u)
			}
			plan.count = int64(len(plan.rows))
			plans[t.Name] = plan
			continue
		}

		rowsPtr := newSlicePtr(t.Model)
		if err := json.Unmarshal(raw, rowsPtr); err != nil {
			return nil, fmt.Errorf("backup: 解析 %s 失败（应为数组）: %w", t.Name, err)
		}
		v := reflect.ValueOf(rowsPtr).Elem()
		for i := 0; i < v.Len(); i++ {
			elem := v.Index(i)
			if elem.Kind() == reflect.Ptr && elem.IsNil() {
				continue // 数组里的 null 元素
			}
			plan.rows = append(plan.rows, elem.Addr().Interface())
		}
		plan.count = int64(len(plan.rows))
		plans[t.Name] = plan
	}
	return plans, nil
}

// primaryKeyOf 读取行结构里的 ID 字段（所有模型都内嵌 models.Base，故必有 ID）。
func primaryKeyOf(row any) (uint64, bool) {
	v := reflect.Indirect(reflect.ValueOf(row))
	if !v.IsValid() || v.Kind() != reflect.Struct {
		return 0, false
	}
	f := v.FieldByName("ID")
	if !f.IsValid() {
		return 0, false
	}
	switch f.Kind() {
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return f.Uint(), true
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		n := f.Int()
		if n < 0 {
			return 0, false
		}
		return uint64(n), true
	}
	return 0, false
}

// GateExportTs 时间闸门（**唯一实现**，restore / 首次接续共用）。
//
// 返回 (allowed bool, decision string, reason string)：
//   - decision ∈ {"forced","allowed","rejected_no_ts","rejected_older"}，会落审计日志
//   - reason 是给用户直接看的中文文案（rejected 时非空）
//
// 为什么比的是 payload 内的 exportedAt 而不是行级 updated_at：
// finance_snapshot.updated_at 没有触发器、格式/时区不可靠；exportedAt 是业务自己写的
// 唯一权威时间戳，而且备份文件顶层本来就有这个字段（DESIGN §2.B.8 / Q-D2）。
func GateExportTs(reqExportedAt, remoteExportedAt int64, force bool) (bool, string, string) {
	switch {
	case force:
		return true, "forced", "" // 显式强制：放行并标记
	case reqExportedAt == 0:
		return false, "rejected_no_ts", "备份缺少 exportedAt 时间戳，已拒绝覆盖；如确需覆盖请携带 force=true"
	case remoteExportedAt > 0 && reqExportedAt < remoteExportedAt:
		return false, "rejected_older",
			fmt.Sprintf("备份较旧（exportedAt=%d < 云端 %d），已拒绝覆盖；如确需覆盖请携带 force=true",
				reqExportedAt, remoteExportedAt)
	}
	return true, "allowed", "" // 同等或更新：放行
}
