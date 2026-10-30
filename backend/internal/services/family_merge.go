package services

import (
	"log"

	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
)

// FamilyMergeService 家庭数据合并服务
type FamilyMergeService struct{ DB *gorm.DB }

func NewFamilyMergeService(db *gorm.DB) *FamilyMergeService {
	return &FamilyMergeService{DB: db}
}

// MergePersonalToFamily 将用户的个人数据合并到家庭空间
//
// 重要口径：交易流水【不复制】。家庭聚合口径为
// 「活跃成员的个人流水 + family 空间流水」（见 finance.applyScopeQuery），
// 复制流水会导致家庭账目双倍计算；同步删除则会误删家庭空间原生记的账。
// 因此本方法只合并规划/大件/投资/贷款/未来利益等元数据（家庭尚无则创建，不覆盖）。
func (s *FamilyMergeService) MergePersonalToFamily(uid uint64, familyID uint64) error {
	// 1. 交易流水：不再复制/删除（聚合口径已覆盖成员个人流水）

	// 2. 合并财务规划：如果家庭尚无规划，则复制个人规划（不覆盖已有）
	var familyPlan models.FinancialPlan
	if err := s.DB.Where("scope = ? AND target_id = ?", models.TxScopeFamily, familyID).First(&familyPlan).Error; err != nil {
		var personalPlan models.FinancialPlan
		if err := s.DB.Where("scope = ? AND target_id = ?", models.TxScopePersonal, uid).First(&personalPlan).Error; err == nil {
			familyPlan = models.FinancialPlan{
				Scope:               models.TxScopeFamily,
				UID:                 uid,
				FamilyID:            &familyID,
				TargetID:            familyID,
				MonthlySurvivalCost: personalPlan.MonthlySurvivalCost,
				EmergencyTarget:     personalPlan.EmergencyTarget,
				PensionTarget:       personalPlan.PensionTarget,
				SavingRatio:         personalPlan.SavingRatio,
				InvestmentRatio:     personalPlan.InvestmentRatio,
				EmergencyRatio:      personalPlan.EmergencyRatio,
				PensionRatio:        personalPlan.PensionRatio,
				ConsumptionRatio:    personalPlan.ConsumptionRatio,
				BigPurchaseRatio:    personalPlan.BigPurchaseRatio,
				InvestAnnualRate:    personalPlan.InvestAnnualRate,
				CurrentAge:          personalPlan.CurrentAge,
				LifeExpectancy:      personalPlan.LifeExpectancy,
			}
			s.DB.Create(&familyPlan)
		}
	}

	// 3. 合并大件购买计划：按 scope+target_id+name+price 去重
	var personalPurchases []models.PurchasePlan
	s.DB.Where("scope = ? AND target_id = ?", models.TxScopePersonal, uid).Find(&personalPurchases)
	for _, p := range personalPurchases {
		var existing models.PurchasePlan
		err := s.DB.Where("scope = ? AND target_id = ? AND name = ? AND price = ?",
			models.TxScopeFamily, familyID, p.Name, p.Price).First(&existing).Error
		if err == nil {
			continue
		}

		familyP := models.PurchasePlan{
			Scope:      models.TxScopeFamily,
			UID:        p.UID,
			FamilyID:   &familyID,
			TargetID:   familyID,
			Name:       p.Name,
			Price:      p.Price,
			Priority:   p.Priority,
			TargetDate: p.TargetDate,
			Note:       p.Note,
			Achieved:   p.Achieved,
			AchievedAt: p.AchievedAt,
		}
		s.DB.Create(&familyP)
	}

	// 4. 合并投资记录：按 scope+target_id+year+month 去重
	var personalInvestments []models.InvestmentRecord
	s.DB.Where("scope = ? AND target_id = ?", models.TxScopePersonal, uid).Find(&personalInvestments)
	for _, inv := range personalInvestments {
		var existing models.InvestmentRecord
		if err := s.DB.Where("scope = ? AND target_id = ? AND year = ? AND month = ?",
			models.TxScopeFamily, familyID, inv.Year, inv.Month).First(&existing).Error; err == nil {
			continue
		}
		familyInv := models.InvestmentRecord{
			Scope:       models.TxScopeFamily,
			UID:         inv.UID,
			FamilyID:    &familyID,
			TargetID:    familyID,
			Year:        inv.Year,
			Month:       inv.Month,
			MonthlyRate: inv.MonthlyRate,
			Amount:      inv.Amount,
			Note:        inv.Note,
		}
		s.DB.Create(&familyInv)
	}

	// 5. 合并贷款（公积金、商业、借款）：按 scope+uid+name+total 去重
	mergeLoans(s.DB, uid, familyID)

	// 6. 合并未来利益：按 scope+uid+name+type+payout_date 去重
	var personalBenefits []models.FutureBenefit
	s.DB.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid).Find(&personalBenefits)
	for _, b := range personalBenefits {
		var existing models.FutureBenefit
		err := s.DB.Where("scope = ? AND uid = ? AND name = ? AND type = ? AND payout_date = ?",
			models.TxScopeFamily, uid, b.Name, b.Type, b.PayoutDate).First(&existing).Error
		if err == nil {
			continue
		}

		familyB := models.FutureBenefit{
			Scope:        models.TxScopeFamily,
			UID:          b.UID,
			FamilyID:     &familyID,
			Name:         b.Name,
			Type:         b.Type,
			PayoutDate:   b.PayoutDate,
			PayoutAmount: b.PayoutAmount,
			CustomYears:  b.CustomYears,
			Note:         b.Note,
		}
		s.DB.Create(&familyB)
	}

	// 7. 通知用户合并完成
	ns := NewNotifyService(s.DB)
	_ = ns.PushTo(uid, models.NotifyTypeSystem, "数据同步完成", "规划/大件/投资/贷款/未来利益已合并到家庭空间（流水按聚合口径自动计入，无需复制）", "")

	log.Printf("[family_merge] synced uid=%d to family=%d", uid, familyID)
	return nil
}

func mergeLoans(db *gorm.DB, uid uint64, familyID uint64) {
	// 公积金贷款：按 scope+uid+name+total 去重
	var hfl []models.HousingFundLoan
	db.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid).Find(&hfl)
	for _, l := range hfl {
		var existing models.HousingFundLoan
		err := db.Where("scope = ? AND uid = ? AND name = ? AND total = ?",
			models.TxScopeFamily, uid, l.Name, l.Total).First(&existing).Error
		if err == nil {
			continue
		}
		fl := models.HousingFundLoan{
			Scope:      models.TxScopeFamily,
			UID:        l.UID,
			FamilyID:   &familyID,
			Name:       l.Name,
			Total:      l.Total,
			AnnualRate: l.AnnualRate,
			TermMonths: l.TermMonths,
			Method:     l.Method,
			StartMonth: l.StartMonth,
			PaidMonths: l.PaidMonths,
			Note:       l.Note,
		}
		db.Create(&fl)
	}

	// 商业贷款
	var cll []models.CommercialLoan
	db.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid).Find(&cll)
	for _, l := range cll {
		var existing models.CommercialLoan
		err := db.Where("scope = ? AND uid = ? AND name = ? AND total = ?",
			models.TxScopeFamily, uid, l.Name, l.Total).First(&existing).Error
		if err == nil {
			continue
		}
		fl := models.CommercialLoan{
			Scope:      models.TxScopeFamily,
			UID:        l.UID,
			FamilyID:   &familyID,
			Name:       l.Name,
			Total:      l.Total,
			AnnualRate: l.AnnualRate,
			TermMonths: l.TermMonths,
			Method:     l.Method,
			StartMonth: l.StartMonth,
			PaidMonths: l.PaidMonths,
			Note:       l.Note,
		}
		db.Create(&fl)
	}

	// 借款
	var bml []models.BorrowedMoney
	db.Where("scope = ? AND uid = ?", models.TxScopePersonal, uid).Find(&bml)
	for _, l := range bml {
		var existing models.BorrowedMoney
		err := db.Where("scope = ? AND uid = ? AND name = ? AND total = ?",
			models.TxScopeFamily, uid, l.Name, l.Total).First(&existing).Error
		if err == nil {
			continue
		}
		fl := models.BorrowedMoney{
			Scope:      models.TxScopeFamily,
			UID:        l.UID,
			FamilyID:   &familyID,
			Name:       l.Name,
			Total:      l.Total,
			AnnualRate: l.AnnualRate,
			TermMonths: l.TermMonths,
			Method:     l.Method,
			StartMonth: l.StartMonth,
			PaidMonths: l.PaidMonths,
			Note:       l.Note,
		}
		db.Create(&fl)
	}
}
