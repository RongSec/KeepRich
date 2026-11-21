package handlers

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"gorm.io/gorm"
)

// 通知设置接口测试：默认 5 类 / 读改自己 / 未知类型被拒 /
// 普通成员改他人 403 中文 / 家庭管理员改同家庭成员 200 / 跨家庭 403 /
// 关闭超支类型后记账不生成通知，开启后 content 为模板渲染文案。

func seedNotifySetting(t *testing.T, db *gorm.DB, uid uint64, typ string, enabled bool, titleTpl, contentTpl string) {
	t.Helper()
	var row models.NotificationSetting
	err := db.Where("user_id = ? AND type = ?", uid, typ).First(&row).Error
	if err != nil {
		row = models.NotificationSetting{
			UserID: uid, Type: typ, Enabled: enabled,
			TitleTemplate: titleTpl, ContentTemplate: contentTpl,
		}
		if err := db.Create(&row).Error; err != nil {
			t.Fatalf("建通知设置失败: %v", err)
		}
		return
	}
	row.Enabled = enabled
	row.TitleTemplate = titleTpl
	row.ContentTemplate = contentTpl
	if err := db.Save(&row).Error; err != nil {
		t.Fatalf("改通知设置失败: %v", err)
	}
}

func settingsOf(t *testing.T, w testResp) []map[string]interface{} {
	t.Helper()
	var data struct {
		Settings []map[string]interface{} `json:"settings"`
	}
	decodeInto(t, w, &data)
	return data.Settings
}

func decodeInto(t *testing.T, w testResp, v interface{}) {
	t.Helper()
	if err := json.Unmarshal(w.Data, v); err != nil {
		t.Fatalf("解析 data 失败: %v（data=%s）", err, string(w.Data))
	}
}

// TestNotificationSettingsCRUD 读改自己的设置：默认全开、可改开关与模板、未知类型被拒
func TestNotificationSettingsCRUD(t *testing.T) {
	db, uid := txTestDB(t)
	_ = db

	// 默认：6 类全开、模板为空（空=用默认模板）
	w := callJSON(t, uid, "GET", "", GetNotificationSettings, nil)
	if w.Code != 200 {
		t.Fatalf("查询设置失败: %d %s", w.Code, w.Body.String())
	}
	list := settingsOf(t, decodeResp(t, w))
	if len(list) != len(models.NotifyTypes) {
		t.Fatalf("设置项 = %d，期望 %d", len(list), len(models.NotifyTypes))
	}
	for i, typ := range models.NotifyTypes {
		if list[i]["type"] != typ {
			t.Fatalf("第 %d 项 type = %v，期望 %s", i, list[i]["type"], typ)
		}
		if list[i]["enabled"] != true {
			t.Fatalf("%s 默认应开启", typ)
		}
		if list[i]["titleTemplate"] != "" || list[i]["contentTemplate"] != "" {
			t.Fatalf("%s 默认模板应为空", typ)
		}
	}

	// 改自己：关闭超支 + 自定义大件模板
	body := `{"settings":[
		{"type":"overspend","enabled":false,"titleTemplate":"","contentTemplate":""},
		{"type":"big_purchase","enabled":true,"titleTemplate":"可以买啦","contentTemplate":"快买 {名称}"}]}`
	w2 := callJSON(t, uid, "PUT", body, UpdateNotificationSettings, nil)
	if w2.Code != 200 {
		t.Fatalf("保存设置失败: %d %s", w2.Code, w2.Body.String())
	}
	list2 := settingsOf(t, decodeResp(t, w2))
	byType := map[string]map[string]interface{}{}
	for _, it := range list2 {
		byType[it["type"].(string)] = it
	}
	if byType["overspend"]["enabled"] != false {
		t.Fatalf("超支应已关闭")
	}
	if byType["big_purchase"]["contentTemplate"] != "快买 {名称}" {
		t.Fatalf("大件模板未生效: %v", byType["big_purchase"]["contentTemplate"])
	}
	// 其余类型不受影响仍开启
	if byType["system"]["enabled"] != true {
		t.Fatalf("系统通知应保持开启")
	}

	// 未知类型被拒（中文文案）
	w3 := callJSON(t, uid, "PUT",
		`{"settings":[{"type":"unknown_type","enabled":true}]}`,
		UpdateNotificationSettings, nil)
	if w3.Code != 400 {
		t.Fatalf("未知类型应 400，实际 %d", w3.Code)
	}
	if got := decodeResp(t, w3).Message; got != "未知的通知类型" {
		t.Fatalf("文案 = %q，期望 %q", got, "未知的通知类型")
	}
}

// TestMemberNotificationSettingsPermission 权限口径：
// 普通成员只能改自己；家庭管理员可改同家庭成员；跨家庭 403 中文。
func TestMemberNotificationSettingsPermission(t *testing.T) {
	db, adminUID := txTestDB(t)
	const memberUID = uint64(11)
	const outsiderUID = uint64(12)
	// adminUID 已是 txTestDB 的用户；补两条家庭成员关系：同家庭普通成员 + 跨家庭用户
	member := models.FamilyMember{
		FamilyID: 1, UserID: memberUID, IsAdmin: false,
		Status: models.MemberStatusActive,
	}
	if err := db.Create(&member).Error; err != nil {
		t.Fatalf("建成员失败: %v", err)
	}
	// 把 admin 挂进同一家庭
	if err := db.Create(&models.FamilyMember{
		FamilyID: 1, UserID: adminUID, IsAdmin: true,
		Status: models.MemberStatusActive,
	}).Error; err != nil {
		t.Fatalf("建管理员失败: %v", err)
	}
	// 跨家庭用户
	if err := db.Create(&models.FamilyMember{
		FamilyID: 2, UserID: outsiderUID, IsAdmin: true,
		Status: models.MemberStatusActive,
	}).Error; err != nil {
		t.Fatalf("建外部成员失败: %v", err)
	}

	adminParam := gin.Params{{Key: "uid", Value: strconv.FormatUint(adminUID, 10)}}
	memberParam := gin.Params{{Key: "uid", Value: strconv.FormatUint(memberUID, 10)}}
	outsiderParam := gin.Params{{Key: "uid", Value: strconv.FormatUint(outsiderUID, 10)}}

	// 普通成员改管理员（他人）→ 403
	w := callJSON(t, memberUID, "PUT",
		`{"settings":[{"type":"system","enabled":false}]}`,
		UpdateMemberNotificationSettings, adminParam)
	if w.Code != 403 {
		t.Fatalf("普通成员改他人应 403，实际 %d（%s）", w.Code, w.Body.String())
	}
	if got := decodeResp(t, w).Message; got != "仅家庭管理员可修改他人通知设置" {
		t.Fatalf("文案 = %q，期望 %q", got, "仅家庭管理员可修改他人通知设置")
	}
	if !isChineseMessage(decodeResp(t, w).Message) {
		t.Fatalf("文案必须全中文")
	}

	// 普通成员看他人 → 403
	w2 := callJSON(t, memberUID, "GET", "", GetMemberNotificationSettings, adminParam)
	if w2.Code != 403 {
		t.Fatalf("普通成员看他人应 403，实际 %d", w2.Code)
	}
	if got := decodeResp(t, w2).Message; got != "仅家庭管理员可查看他人通知设置" {
		t.Fatalf("文案 = %q，期望 %q", got, "仅家庭管理员可查看他人通知设置")
	}

	// 管理员改同家庭成员 → 200 且落库
	body := `{"settings":[{"type":"overspend","enabled":false,"titleTemplate":"改了","contentTemplate":"{金额}"}]}`
	w3 := callJSON(t, adminUID, "PUT", body, UpdateMemberNotificationSettings, memberParam)
	if w3.Code != 200 {
		t.Fatalf("管理员改成员应 200，实际 %d（%s）", w3.Code, w3.Body.String())
	}
	var saved models.NotificationSetting
	if err := db.Where("user_id = ? AND type = ?", memberUID, models.NotifyTypeOverSpend).
		First(&saved).Error; err != nil {
		t.Fatalf("成员设置未落库: %v", err)
	}
	if saved.Enabled || saved.TitleTemplate != "改了" || saved.ContentTemplate != "{金额}" {
		t.Fatalf("成员设置落库不符: %+v", saved)
	}

	// 管理员看同家庭成员 → 200
	w4 := callJSON(t, adminUID, "GET", "", GetMemberNotificationSettings, memberParam)
	if w4.Code != 200 {
		t.Fatalf("管理员看成员应 200，实际 %d", w4.Code)
	}

	// 管理员改跨家庭用户 → 403
	w5 := callJSON(t, adminUID, "PUT", body, UpdateMemberNotificationSettings, outsiderParam)
	if w5.Code != 403 {
		t.Fatalf("跨家庭应 403，实际 %d（%s）", w5.Code, w5.Body.String())
	}
	if got := decodeResp(t, w5).Message; got != "仅可修改同一家庭成员的通知设置" {
		t.Fatalf("文案 = %q，期望 %q", got, "仅可修改同一家庭成员的通知设置")
	}

	// 自己改自己（走 :uid 路由）→ 200
	selfParam := gin.Params{{Key: "uid", Value: strconv.FormatUint(memberUID, 10)}}
	w6 := callJSON(t, memberUID, "PUT",
		`{"settings":[{"type":"system","enabled":true}]}`,
		UpdateMemberNotificationSettings, selfParam)
	if w6.Code != 200 {
		t.Fatalf("自己改自己应 200，实际 %d（%s）", w6.Code, w6.Body.String())
	}
}

// TestOverspendNotificationRespectsSettings 端到端：关闭超支类型 → 记账不生成通知；
// 开启 + 自定义模板 → 生成且 content 为渲染后文案。
func TestOverspendNotificationRespectsSettings(t *testing.T) {
	db, uid := txTestDB(t)
	seedSalary(t, uid)
	// 无顾虑单笔 = (年薪 120000×20)/10000 = 240 元；消费桶允许透支，1000 元支出触发超支提醒
	seedNotifySetting(t, db, uid, models.NotifyTypeOverSpend, false, "", "")

	w := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"daily","amount":1000,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	if w.Code != 200 {
		t.Fatalf("记账失败: %d %s", w.Code, w.Body.String())
	}
	var n int64
	db.Model(&models.Notification{}).Where("uid = ? AND type = ?", uid, models.NotifyTypeOverSpend).Count(&n)
	if n != 0 {
		t.Fatalf("关闭超支提醒后仍生成 %d 条通知，期望 0", n)
	}

	// 开启 + 自定义模板
	seedNotifySetting(t, db, uid, models.NotifyTypeOverSpend, true, "超支啦", "{分类} 花了 {金额} 元（限 {限额}）")
	w2 := callJSON(t, uid, "POST",
		`{"scope":"personal","type":"expense","category":"daily","amount":1000,"sourceBucket":"consumption"}`,
		CreateTx, nil)
	if w2.Code != 200 {
		t.Fatalf("记账失败: %d %s", w2.Code, w2.Body.String())
	}
	var noti models.Notification
	if err := db.Where("uid = ? AND type = ?", uid, models.NotifyTypeOverSpend).
		Order("id DESC").First(&noti).Error; err != nil {
		t.Fatalf("开启后未生成通知: %v", err)
	}
	if noti.Title != "超支啦" {
		t.Fatalf("标题 = %q，期望 %q", noti.Title, "超支啦")
	}
	// 断言「通知里的限额」与「总览口径」完全一致——这正是历史上分叉过的地方：
	// 通知曾漏了 /10000，阈值放大一万倍导致永不触发。用服务口径取值比对，
	// 将来口径调整只需改 services.WorryFreePerBuy 一处。
	limit := services.WorryFreePerBuyFor(db, "personal", uid, nil)
	if limit <= 0 {
		t.Fatalf("无顾虑单笔应为正数，实际 %v", limit)
	}
	if !strings.Contains(noti.Content, "1000") ||
		!strings.Contains(noti.Content, fmt.Sprintf("%.0f", limit)) {
		t.Fatalf("内容未按模板渲染: %q（期望限额 %.0f）", noti.Content, limit)
	}
	if !strings.Contains(noti.Content, "花了") {
		t.Fatalf("内容应为模板渲染文案: %q", noti.Content)
	}
}
