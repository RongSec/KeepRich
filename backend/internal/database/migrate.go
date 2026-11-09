package database

import (
	"log"

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
	log.Println("[db] migration done")
	return nil
}
