package handlers

import (
	"testing"

	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
)

// TestFamilyTxNotification 家庭成员记账 → 通知同家庭其他成员，且不打扰记录人自己。
func TestFamilyTxNotification(t *testing.T) {
	db, recorder := txTestDB(t)

	// 同家庭的另一位成员
	// 显式给 ID：测试库里 recorder 占用了 1，自动增量在 sqlite 内存库下不可靠
	other := models.User{Base: models.Base{ID: 2}, Username: "wife", Nickname: "老婆", PasswordHash: "x"}
	if err := db.Create(&other).Error; err != nil {
		t.Fatalf("创建成员失败: %v", err)
	}
	if other.ID != 2 {
		t.Fatalf("成员 ID = %d，期望 2", other.ID)
	}
	famID := uint64(7)
	if err := db.Create(&models.FamilyMember{FamilyID: famID, UserID: recorder, Status: models.MemberStatusActive}).Error; err != nil {
		t.Fatalf("建成员A失败: %v", err)
	}
	if err := db.Create(&models.FamilyMember{FamilyID: famID, UserID: other.ID, Status: models.MemberStatusActive}).Error; err != nil {
		t.Fatalf("建成员B失败: %v", err)
	}

	w := callJSON(t, recorder, "POST",
		`{"scope":"family","type":"expense","category":"daily","amount":88,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	if w.Code != 200 {
		t.Fatalf("家庭记账失败: %d %s", w.Code, w.Body.String())
	}

	// 另一位成员应收到
	var got models.Notification
	if err := db.Where("uid = ? AND type = ?", other.ID, models.NotifyTypeFamilyTx).
		First(&got).Error; err != nil {
		t.Fatalf("家庭成员未收到记账通知: %v", err)
	}
	if got.Content == "" || !contains(got.Content, "88") {
		t.Fatalf("通知文案异常: %q", got.Content)
	}
	// 记录人自己不应收到
	var self int64
	db.Model(&models.Notification{}).
		Where("uid = ? AND type = ?", recorder, models.NotifyTypeFamilyTx).Count(&self)
	if self != 0 {
		t.Fatalf("记录人不应收到自己的记账通知，实际 %d 条", self)
	}
	_ = database.DB
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
