package database

import (
	"errors"
	"log"

	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// SeedAdmin 启动时检查并创建默认管理员账号
// 账号信息从环境变量读取；不存在则跳过。
func SeedAdmin(username, password string) error {
	if username == "" || password == "" {
		return nil
	}
	var u models.User
	err := DB.Where("username = ?", username).First(&u).Error
	if err == nil {
		return nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}

	hash, err := utils.HashPassword(password)
	if err != nil {
		return err
	}
	admin := models.User{
		Username:     username,
		PasswordHash: hash,
		Role:         models.RoleAdmin,
		Nickname:     "系统管理员",
	}
	if err := DB.Create(&admin).Error; err != nil {
		return err
	}
	log.Printf("[seed] admin user %s created", username)
	return nil
}
