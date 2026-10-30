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
	); err != nil {
		return err
	}
	log.Println("[db] migration done")
	return nil
}
