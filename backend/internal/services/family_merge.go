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
// 去重策略：按关键字段判断是否已存在，有则跳过，无则新增
// 同步删除：家庭中该用户已同步的账单，如果个人空间已不存在，则从家庭中删除
func (s *FamilyMergeService) MergePersonalToFamily(uid uint64, familyID uint64) error {
	mergedTx := 0
	deletedTx := 0

	// 1. 合并交易记录：按 uid+type+category+amount+occurred_at 去重
	var personalTxs []models.Transaction
	s.DB.Where("uid = ? AND scope = ?", uid, models.TxScopePersonal).Find(&personalTxs)

	// 构建个人账单的匹配键集合
	type txKey struct {
		Type       string
		Category   string
		Amount     float64
		OccurredAt int64
	}
	personalKeys := make(map[txKey]bool)
	for _, tx := range personalTxs {
		personalKeys[txKey{tx.Type, tx.Category, tx.Amount, tx.OccurredAt}] = true
	}

	// 新增：个人有但家庭没有的
	for _, tx := range personalTxs {
		var existing models.Transaction
		err := s.DB.Where("scope = ? AND uid = ? AND type = ? AND category = ? AND amount = ? AND occurred_at = ?",
			models.TxScopeFamily, uid, tx.Type, tx.Category, tx.Amount, tx.OccurredAt).First(&existing).Error
		if err == nil {
			continue
		}
		familyTx := models.Transaction{
			UID:          tx.UID,
			FamilyID:     &familyID,
			Scope:        models.TxScopeFamily,
			Type:         tx.Type,
			Category:     tx.Category,
			Amount:       tx.Amount,
			Note:         tx.Note,
			OccurredAt:   tx.OccurredAt,
			LoanRef:      tx.LoanRef,
			TargetBucket: tx.TargetBucket,
		}
		if err := s.DB.Create(&familyTx).Error; err != nil {
			log.Printf("[family_merge] merge tx uid=%d err: %v", uid, err)
		} else {
			mergedTx++
		}
	}

	// 删除：家庭有但个人已不存在的（用户删除了个人账单）
	var familyTxs []models.Transaction
	s.DB.Where("scope = ? AND uid = ? AND family_id = ?", models.TxScopeFamily, uid, familyID).Find(&familyTxs)
	for _, tx := range familyTxs {
		key := txKey{tx.Type, tx.Category, tx.Amount, tx.OccurredAt}
		if !personalKeys[key] {
			s.DB.Delete(&tx)
			deletedTx++
		}
	}

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
	msg := ""
	if mergedTx > 0 {
		msg = "新增 " + itoa(mergedTx) + " 条"
	}
	if deletedTx > 0 {
		if msg != "" {
			msg += "，"
		}
		msg += "删除 " + itoa(deletedTx) + " 条已移除的账单"
	}
	if msg != "" {
		ns := NewNotifyService(s.DB)
		_ = ns.PushTo(uid, models.NotifyTypeSystem, "数据同步完成", msg, "")
	}

	log.Printf("[family_merge] synced uid=%d to family=%d, new=%d, deleted=%d", uid, familyID, mergedTx, deletedTx)
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

// itoa 整数转字符串
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
