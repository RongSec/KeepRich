package database

import (
	"log"
	"time"

	"github.com/yourname/family-finance/backend/internal/models"
)

func Migrate() error {
	if err := DB.AutoMigrate(
		&models.User{},
		&models.Family{},
		&models.FamilyMember{},
		&models.FamilyJoinRequest{},
		&models.Transaction{},
		&models.FinancialPlan{},
		&models.PurchasePlan{},
		&models.InvestmentRecord{},
		&models.Notification{},
		// 通知设置（每用户每类型一行）：不进云端快照/备份 Tables() 清单
		// （同 sync_state 口径：纯偏好，丢失回默认），仅建表。
		&models.NotificationSetting{},
		&models.DeleteFamilyRequest{},
		&models.DeleteFamilyVote{},
		&models.AuditLog{},
		&models.ErrorReport{},
		&models.HousingFundLoan{},
		&models.CommercialLoan{},
		&models.BorrowedMoney{},
		&models.FutureBenefit{},
		&models.AppVersion{},
		// sync_state：云端快照同步的元数据（dirty / last_*_at / row_exists）。
		// 必须建表，否则"重启后先推再比"的闸门失效（DESIGN §2.B.5）。
		&models.SyncState{},
		// v0.5.0 新增 4 表：会话 / 设备凭据 / 邀请码 / 邀请码使用记录。
		// 与 backup.Tables() 的 22 表清单严格一致（顺序也一致，追加在末尾）。
		&models.AuthSession{},
		&models.DeviceCredential{},
		&models.InviteCode{},
		&models.InviteCodeUsage{},
	); err != nil {
		return err
	}
	cleanupOrphanLoanCopies()
	log.Println("[db] migration done")
	return nil
}

// cleanupOrphanLoanCopies 清理「孤儿家庭复件」贷款。
//
// 背景：MergePersonalToFamily 建家庭时把个人贷款复制成家庭记录（按 uid+name+total）。
// 删除个人贷款时若未级联删复件（已补 cascadeDeleteLoanCopy），复件会留下成为幽灵债务——
// 用户反馈：App 贷款页为空（原件已软删）但总财富为负数百万（复件仍在算）。
//
// 判定：scope=family 且未删除，且存在同 uid+name+total 的【已软删除】个人记录，
// 且不存在同 uid+name+total 的【未删除】个人记录（避免误删仍有效复件）。
// 幂等：已删的不会重复处理；每类贷款各跑一次。
func cleanupOrphanLoanCopies() {
	for _, tb := range []string{"housing_fund_loans", "commercial_loans", "borrowed_moneys"} {
		res := DB.Exec(`
			UPDATE `+tb+` SET deleted_at = ?
			WHERE scope = 'family' AND deleted_at IS NULL
			  AND EXISTS (
			      SELECT 1 FROM (SELECT * FROM `+tb+`) x
			      WHERE x.uid = `+tb+`.uid AND x.name = `+tb+`.name AND x.total = `+tb+`.total
			        AND x.scope = 'personal' AND x.deleted_at IS NOT NULL)
			  AND NOT EXISTS (
			      SELECT 1 FROM (SELECT * FROM `+tb+`) y
			      WHERE y.uid = `+tb+`.uid AND y.name = `+tb+`.name AND y.total = `+tb+`.total
			        AND y.scope = 'personal' AND y.deleted_at IS NULL)`,
			time.Now())
		if res.Error == nil && res.RowsAffected > 0 {
			log.Printf("[db] cleanup orphan loan copies: %s soft-deleted %d rows", tb, res.RowsAffected)
		}
	}
}
