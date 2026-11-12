package services

import (
	"strings"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// 通知模板渲染 + PushTo 应用通知设置测试：
// 缺变量占位符保留原文不 panic / 关闭类型不落库 / 自定义模板按 vars 渲染 /
// 无设置行走默认模板 / 渲染超长截断到列宽。

func notifyTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := "file:notify_" + t.Name() + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if sqlDB, err := db.DB(); err == nil {
		sqlDB.SetMaxOpenConns(1)
	}
	if err := db.AutoMigrate(&models.Notification{}, &models.NotificationSetting{}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

func TestRenderTemplate(t *testing.T) {
	vars := map[string]string{"金额": "100", "分类": "餐饮"}
	cases := []struct {
		name string
		tpl  string
		want string
	}{
		{"普通替换", "{分类} 支出 {金额} 元", "餐饮 支出 100 元"},
		{"缺变量保留原文", "{分类} 支出 {日期} 元", "餐饮 支出 {日期} 元"},
		{"无占位符", "纯文本", "纯文本"},
		{"空模板", "", ""},
		{"未闭合括号照抄", "支出 {金额", "支出 {金额"},
		{"连续占位符", "{金额}{分类}", "100餐饮"},
		{"花括号对不吞安全", "{{金额}}", "{{金额}}"},
	}
	for _, c := range cases {
		if got := renderTemplate(c.tpl, vars); got != c.want {
			t.Fatalf("%s：renderTemplate(%q) = %q，期望 %q", c.name, c.tpl, got, c.want)
		}
	}
	// vars 为 nil 不 panic
	if got := renderTemplate("{金额}", nil); got != "{金额}" {
		t.Fatalf("vars 为 nil 应保留原文，实际 %q", got)
	}
}

// TestPushToDisabledSkipped 关闭某类型后：不生成通知记录也不推送
func TestPushToDisabledSkipped(t *testing.T) {
	db := notifyTestDB(t)
	ns := NewNotifyService(db)
	const uid = uint64(1)
	if err := db.Create(&models.NotificationSetting{
		UserID: uid, Type: models.NotifyTypeOverSpend, Enabled: false,
	}).Error; err != nil {
		t.Fatalf("建设置失败: %v", err)
	}
	if err := ns.PushTo(uid, models.NotifyTypeOverSpend, map[string]string{"金额": "9"}, ""); err != nil {
		t.Fatalf("PushTo 不应报错: %v", err)
	}
	var n int64
	db.Model(&models.Notification{}).Where("uid = ?", uid).Count(&n)
	if n != 0 {
		t.Fatalf("关闭类型后仍有 %d 条通知，期望 0", n)
	}
	// 其它类型不受影响
	if err := ns.PushTo(uid, models.NotifyTypeBigPurchase, map[string]string{"名称": "相机"}, ""); err != nil {
		t.Fatalf("PushTo 不应报错: %v", err)
	}
	db.Model(&models.Notification{}).Where("uid = ?", uid).Count(&n)
	if n != 1 {
		t.Fatalf("其它类型应正常生成，实际 %d 条", n)
	}
}

// TestPushToCustomTemplateRendered 开启 + 自定义模板：content 为模板渲染后的文案
func TestPushToCustomTemplateRendered(t *testing.T) {
	db := notifyTestDB(t)
	ns := NewNotifyService(db)
	const uid = uint64(2)
	if err := db.Create(&models.NotificationSetting{
		UserID: uid, Type: models.NotifyTypeOverSpend, Enabled: true,
		TitleTemplate:   "【自定义】{分类}",
		ContentTemplate: "{日期} {分类} 花了 {金额}，限额 {限额}",
	}).Error; err != nil {
		t.Fatalf("建设置失败: %v", err)
	}
	err := ns.PushTo(uid, models.NotifyTypeOverSpend, map[string]string{
		"分类": "餐饮", "金额": "300", "限额": "200", "日期": "2026-01-02",
	}, "")
	if err != nil {
		t.Fatalf("PushTo 失败: %v", err)
	}
	var n models.Notification
	if err := db.Where("uid = ?", uid).First(&n).Error; err != nil {
		t.Fatalf("未生成通知: %v", err)
	}
	if n.Title != "【自定义】餐饮" {
		t.Fatalf("标题 = %q，期望 %q", n.Title, "【自定义】餐饮")
	}
	want := "2026-01-02 餐饮 花了 300，限额 200"
	if n.Content != want {
		t.Fatalf("内容 = %q，期望 %q", n.Content, want)
	}
}

// TestPushToDefaultTemplate 无设置行走默认模板并渲染
func TestPushToDefaultTemplate(t *testing.T) {
	db := notifyTestDB(t)
	ns := NewNotifyService(db)
	const uid = uint64(3)
	if err := ns.PushTo(uid, models.NotifyTypeOverSpend, map[string]string{
		"分类": "日常", "金额": "500", "限额": "300", "日期": "2026-01-03",
	}, ""); err != nil {
		t.Fatalf("PushTo 失败: %v", err)
	}
	var n models.Notification
	if err := db.Where("uid = ?", uid).First(&n).Error; err != nil {
		t.Fatalf("未生成通知: %v", err)
	}
	tpl := models.DefaultNotifyTemplates[models.NotifyTypeOverSpend]
	if n.Title != tpl.Title {
		t.Fatalf("标题 = %q，期望默认 %q", n.Title, tpl.Title)
	}
	want := "日常 本次支出 500 元，超过无顾虑单笔 300 元"
	if n.Content != want {
		t.Fatalf("内容 = %q，期望 %q", n.Content, want)
	}
	if !strings.Contains(n.Content, "500") {
		t.Fatalf("内容未渲染变量: %q", n.Content)
	}
}

// TestPushToTruncate 渲染结果超列宽按字符截断（标题 128 / 内容 512）
func TestPushToTruncate(t *testing.T) {
	db := notifyTestDB(t)
	ns := NewNotifyService(db)
	const uid = uint64(4)
	long := strings.Repeat("很", 600)
	if err := ns.PushTo(uid, models.NotifyTypeSystem, map[string]string{
		"标题": long, "内容": long,
	}, ""); err != nil {
		t.Fatalf("PushTo 失败: %v", err)
	}
	var n models.Notification
	if err := db.Where("uid = ?", uid).First(&n).Error; err != nil {
		t.Fatalf("未生成通知: %v", err)
	}
	if got := len([]rune(n.Title)); got != 128 {
		t.Fatalf("标题长度 = %d，期望 128", got)
	}
	if got := len([]rune(n.Content)); got != 512 {
		t.Fatalf("内容长度 = %d，期望 512", got)
	}
}
