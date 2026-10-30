package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

type CreateUserReq struct {
	Username string `json:"username" binding:"required,min=3,max=32"`
	Password string `json:"password" binding:"required,min=8"`
	Nickname string `json:"nickname"`
	Email    string `json:"email"`
	Phone    string `json:"phone"`
	Role     string `json:"role"` // admin/user
}

type UpdateProfileReq struct {
	// 指针语义：nil=不修改，非 nil（含空串）=设置该值
	Nickname *string `json:"nickname"`
	Avatar   *string `json:"avatar"`
	Email    *string `json:"email"`
	Phone    *string `json:"phone"`
}

type ChangePasswordReq struct {
	OldPassword string `json:"oldPassword" binding:"required"`
	NewPassword string `json:"newPassword" binding:"required,min=8"`
}

// CreateUser 管理员创建账号
func CreateUser(c *gin.Context) {
	var req CreateUserReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	role := req.Role
	if role == "" {
		role = models.RoleUser
	}
	hash, err := utils.HashPassword(req.Password)
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	u := models.User{
		Username:     req.Username,
		PasswordHash: hash,
		Nickname:     req.Nickname,
		Email:        req.Email,
		Phone:        req.Phone,
		Role:         role,
	}
	if err := database.DB.Create(&u).Error; err != nil {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "账号已存在")
		return
	}
	utils.OK(c, u)
}

// ListUsers 管理员查看账号列表
func ListUsers(c *gin.Context) {
	var users []models.User
	keyword := c.Query("keyword")
	q := database.DB.Model(&models.User{})
	if keyword != "" {
		q = q.Where("username LIKE ? OR nickname LIKE ?", "%"+keyword+"%", "%"+keyword+"%")
	}
	if err := q.Order("id DESC").Limit(200).Find(&users).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, users)
}

// DisableUser 启用/停用账号
func ToggleUserStatus(c *gin.Context) {
	id := c.Param("id")
	var u models.User
	if err := database.DB.First(&u, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	u.Disabled = !u.Disabled
	database.DB.Save(&u)
	utils.OK(c, u)
}

// DeleteUser 管理员删除用户（软删除）
func DeleteUser(c *gin.Context) {
	id := c.Param("id")
	var u models.User
	if err := database.DB.First(&u, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "用户不存在")
		return
	}
	// 不允许删除管理员
	if u.Role == models.RoleAdmin {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "不能删除管理员账号")
		return
	}
	// 软删除用户
	if err := database.DB.Delete(&u).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true, "message": "用户已删除"})
}

// UpdateProfile 修改自身资料
func UpdateProfile(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req UpdateProfileReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	updates := map[string]interface{}{}
	if req.Nickname != nil {
		updates["nickname"] = *req.Nickname
	}
	if req.Avatar != nil {
		updates["avatar"] = *req.Avatar
	}
	if req.Email != nil {
		updates["email"] = *req.Email
	}
	if req.Phone != nil {
		updates["phone"] = *req.Phone
	}
	if len(updates) > 0 {
		if err := database.DB.Model(&models.User{}).Where("id = ?", uid).Updates(updates).Error; err != nil {
			utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
			return
		}
	}
	utils.OK(c, gin.H{"ok": true})
}

// ChangePassword 修改密码
func ChangePassword(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req ChangePasswordReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var u models.User
	if err := database.DB.First(&u, uid).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "user not found")
		return
	}
	if !utils.CheckPassword(u.PasswordHash, req.OldPassword) {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "原密码错误")
		return
	}
	hash, _ := utils.HashPassword(req.NewPassword)
	// 改密后递增 token 版本，使旧 access/refresh token 全部失效
	if err := database.DB.Model(&u).Updates(map[string]interface{}{
		"password_hash": hash,
		"token_version": gorm.Expr("token_version + 1"),
	}).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true})
}
