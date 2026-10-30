package handlers

import (
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/services"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

type CreateFamilyReq struct {
	Name        string `json:"name" binding:"required"`
	Description string `json:"description"`
}

type JoinFamilyReq struct {
	Code    string `json:"code" binding:"required"`
	Message string `json:"message"`
}

type ApproveJoinReq struct {
	RequestID uint64 `json:"requestId" binding:"required"`
	Approve   bool   `json:"approve"`
}

type TransferAdminReq struct {
	ToUserID uint64 `json:"toUserId" binding:"required"`
}

type RequestDeleteFamilyReq struct {
	Reason string `json:"reason"`
	MFACode string `json:"mfaCode"`
}

// CreateFamily 创建家庭
func CreateFamily(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req CreateFamilyReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	// 已加入家庭则不能再创建
	var existing models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&existing).Error; err == nil {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "已加入家庭，无法再创建")
		return
	}
	code, err := utils.GenerateFamilyCode()
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	f := models.Family{
		Name:        req.Name,
		Code:        code,
		AdminID:     uid,
		Description: req.Description,
	}
	if err := database.DB.Create(&f).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	m := models.FamilyMember{
		FamilyID: f.ID,
		UserID:   uid,
		IsAdmin:  true,
		Status:   models.MemberStatusActive,
		JoinedAt: time.Now().Unix(),
	}
	database.DB.Create(&m)

	// 异步合并创建者的个人数据到家庭空间
	go func(userID uint64, famID uint64) {
		merger := services.NewFamilyMergeService(database.DB)
		if err := merger.MergePersonalToFamily(userID, famID); err != nil {
			log.Printf("[family] merge on create failed uid=%d family=%d: %v", userID, famID, err)
		}
	}(uid, f.ID)

	utils.OK(c, f)
}

// MyFamily 当前家庭信息
func MyFamily(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.OK(c, nil)
		return
	}
	var f models.Family
	if err := database.DB.First(&f, m.FamilyID).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "family not found")
		return
	}
	utils.OK(c, gin.H{"family": f, "member": m})
}

// ApplyJoin 申请加入家庭
func ApplyJoin(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req JoinFamilyReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var f models.Family
	if err := database.DB.Where("code = ?", req.Code).First(&f).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "家庭码无效")
		return
	}
	// 不能重复加入
	var existing models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&existing).Error; err == nil {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "已加入家庭")
		return
	}
	// 已有待处理申请
	var pending models.FamilyJoinRequest
	if err := database.DB.Where("family_id = ? AND user_id = ? AND status = ?", f.ID, uid, models.MemberStatusPending).First(&pending).Error; err == nil {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "已存在待处理申请")
		return
	}
	r := models.FamilyJoinRequest{
		FamilyID: f.ID,
		UserID:   uid,
		Status:   models.MemberStatusPending,
		Message:  req.Message,
	}
	database.DB.Create(&r)

	// 通知家庭管理员
	ns := services.NewNotifyService(database.DB)
	_ = ns.PushTo(f.AdminID, models.NotifyTypeFamilyApply, "新加入申请", "有用户申请加入家庭："+f.Name, "")

	utils.OK(c, r)
}

// ListJoinRequests 家庭管理员查看申请
func ListJoinRequests(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND is_admin = ? AND status = ?", uid, true, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	var rs []models.FamilyJoinRequest
	if err := database.DB.Where("family_id = ? AND status = ?", m.FamilyID, models.MemberStatusPending).Order("id DESC").Find(&rs).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, rs)
}

// ApproveJoin 家庭管理员审批
// 事务内以 status=pending 抢占式更新做并发防护，防止重复审批产生重复成员
func ApproveJoin(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req ApproveJoinReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND is_admin = ? AND status = ?", uid, true, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	var r models.FamilyJoinRequest
	if err := database.DB.First(&r, req.RequestID).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "申请不存在")
		return
	}
	if r.FamilyID != m.FamilyID {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权操作")
		return
	}
	now := time.Now().Unix()

	err := database.DB.Transaction(func(tx *gorm.DB) error {
		// 抢占式更新：仅 pending 状态可处理，重复审批在此被拒
		newStatus := models.MemberStatusRejected
		if req.Approve {
			newStatus = models.MemberStatusActive
		}
		res := tx.Model(&models.FamilyJoinRequest{}).
			Where("id = ? AND status = ?", r.ID, models.MemberStatusPending).
			Updates(map[string]interface{}{
				"status":     newStatus,
				"handled_by": uid,
				"handled_at": now,
			})
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return errAlreadyHandled
		}
		if !req.Approve {
			return nil
		}
		// 已是活跃成员则不重复创建
		var cnt int64
		if err := tx.Model(&models.FamilyMember{}).
			Where("family_id = ? AND user_id = ? AND status = ?", r.FamilyID, r.UserID, models.MemberStatusActive).
			Count(&cnt).Error; err != nil {
			return err
		}
		if cnt > 0 {
			return nil
		}
		fm := models.FamilyMember{
			FamilyID: r.FamilyID,
			UserID:   r.UserID,
			IsAdmin:  false,
			Status:   models.MemberStatusActive,
			JoinedAt: now,
		}
		return tx.Create(&fm).Error
	})
	if err != nil {
		if err == errAlreadyHandled {
			utils.Fail(c, http.StatusConflict, utils.CodeConflict, "该申请已处理")
			return
		}
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}

	if req.Approve {
		// 异步合并个人数据到家庭空间
		go func(userID uint64, famID uint64) {
			merger := services.NewFamilyMergeService(database.DB)
			if err := merger.MergePersonalToFamily(userID, famID); err != nil {
				log.Printf("[family] merge failed uid=%d family=%d: %v", userID, famID, err)
			}
		}(r.UserID, r.FamilyID)
	}
	r.Status = map[bool]string{true: models.MemberStatusActive, false: models.MemberStatusRejected}[req.Approve]
	r.HandledBy = &uid
	r.HandledAt = &now

	ns := services.NewNotifyService(database.DB)
	_ = ns.PushTo(r.UserID, models.NotifyTypeFamilyResult, "家庭加入结果", map[bool]string{true: "已通过", false: "已拒绝"}[req.Approve], "")

	utils.OK(c, r)
}

// errAlreadyHandled 申请已被处理（并发审批冲突）
var errAlreadyHandled = errors.New("request already handled")

// TransferAdmin 家庭管理员移交
func TransferAdmin(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req TransferAdminReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	var f models.Family
	if err := database.DB.Where("admin_id = ?", uid).First(&f).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	var target models.FamilyMember
	if err := database.DB.Where("family_id = ? AND user_id = ? AND status = ?", f.ID, req.ToUserID, models.MemberStatusActive).First(&target).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "目标用户不是家庭成员")
		return
	}
	database.DB.Model(&models.FamilyMember{}).Where("family_id = ? AND user_id = ?", f.ID, uid).Update("is_admin", false)
	database.DB.Model(&models.FamilyMember{}).Where("family_id = ? AND user_id = ?", f.ID, req.ToUserID).Update("is_admin", true)
	database.DB.Model(&f).Update("admin_id", req.ToUserID)
	utils.OK(c, gin.H{"ok": true})
}

// RequestDeleteFamily 发起家庭删除请求（成员投票制 + 7 天冷静期，文档 §11）
func RequestDeleteFamily(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req RequestDeleteFamilyReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}

	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
		return
	}

	// 检查是否有待处理的删除请求（pending 或 approved 均视为进行中）
	var existing models.DeleteFamilyRequest
	if err := database.DB.Where("family_id = ? AND status IN ?", m.FamilyID, []string{"pending", "approved"}).First(&existing).Error; err == nil {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "已有待处理的删除请求")
		return
	}

	now := time.Now()
	r := models.DeleteFamilyRequest{
		FamilyID:  m.FamilyID,
		RequestBy: uid,
		Status:    "pending",
		Reason:    req.Reason,
		ExecuteAt: now.Add(7 * 24 * time.Hour).Unix(), // 冷静期 7 天
	}
	if err := database.DB.Create(&r).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}

	// 发起者自动投同意票
	vote := models.DeleteFamilyVote{
		RequestID: r.ID,
		FamilyID:  m.FamilyID,
		UserID:    uid,
		Vote:      true,
	}
	database.DB.Create(&vote)

	// 单人家庭：一票即全体同意，直接进入 approved（冷静期仍生效）
	var totalMembers int64
	database.DB.Model(&models.FamilyMember{}).Where("family_id = ? AND status = ?", m.FamilyID, models.MemberStatusActive).Count(&totalMembers)
	if totalMembers <= 1 {
		approvedAt := now.Unix()
		database.DB.Model(&r).Updates(map[string]interface{}{"status": "approved", "approved_at": approvedAt})
		r.Status = "approved"
		r.ApprovedAt = &approvedAt
	} else {
		// 通知其他家庭成员
		var members []models.FamilyMember
		database.DB.Where("family_id = ? AND status = ? AND user_id != ?", m.FamilyID, models.MemberStatusActive, uid).Find(&members)
		ns := services.NewNotifyService(database.DB)
		for _, member := range members {
			_ = ns.PushTo(member.UserID, models.NotifyTypeSystem, "家庭删除投票", "有成员发起了解散家庭的请求，请前往家庭管理页面投票", "")
		}
	}

	utils.OK(c, gin.H{"request": r, "message": "已发起删除投票，全体成员同意后进入 7 天冷静期，冷静期结束后可执行解散"})
}

// VoteDeleteFamily 对家庭删除请求投票
func VoteDeleteFamily(c *gin.Context) {
	uid := middleware.MustUID(c)
	var req struct {
		RequestID uint64 `json:"requestId" binding:"required"`
		Vote      bool   `json:"vote"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}

	var request models.DeleteFamilyRequest
	if err := database.DB.First(&request, req.RequestID).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "请求不存在")
		return
	}
	if request.Status != "pending" {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "该请求已处理")
		return
	}

	// 检查是否是家庭成员
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND family_id = ? AND status = ?", uid, request.FamilyID, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "不是该家庭成员")
		return
	}

	// 检查是否已投票
	var existingVote models.DeleteFamilyVote
	if err := database.DB.Where("request_id = ? AND user_id = ?", request.ID, uid).First(&existingVote).Error; err == nil {
		// 更新投票
		existingVote.Vote = req.Vote
		database.DB.Save(&existingVote)
	} else {
		// 新增投票
		vote := models.DeleteFamilyVote{
			RequestID: request.ID,
			FamilyID:  request.FamilyID,
			UserID:    uid,
			Vote:      req.Vote,
		}
		database.DB.Create(&vote)
	}

	// 检查是否所有成员都已投票且全部同意
	var totalMembers int64
	database.DB.Model(&models.FamilyMember{}).Where("family_id = ? AND status = ?", request.FamilyID, models.MemberStatusActive).Count(&totalMembers)

	var agreeCount int64
	database.DB.Model(&models.DeleteFamilyVote{}).Where("request_id = ? AND vote = ?", request.ID, true).Count(&agreeCount)

	var voteCount int64
	database.DB.Model(&models.DeleteFamilyVote{}).Where("request_id = ?", request.ID).Count(&voteCount)

	if !req.Vote {
		// 有人反对，取消删除请求
		request.Status = "canceled"
		database.DB.Save(&request)
		utils.OK(c, gin.H{"message": "有成员反对，删除请求已取消", "status": "canceled"})
		return
	}

	if voteCount >= totalMembers && agreeCount == totalMembers {
		// 所有成员同意 → 进入冷静期（不立即删除，到期后由管理员执行 ForceDelete）
		now := time.Now().Unix()
		if err := database.DB.Model(&request).Updates(map[string]interface{}{
			"status":      "approved",
			"approved_at": now,
		}).Error; err != nil {
			utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
			return
		}
		// 通知全体成员
		var members []models.FamilyMember
		database.DB.Where("family_id = ? AND status = ?", request.FamilyID, models.MemberStatusActive).Find(&members)
		ns := services.NewNotifyService(database.DB)
		for _, member := range members {
			_ = ns.PushTo(member.UserID, models.NotifyTypeSystem, "家庭删除已通过", "全体成员已同意解散家庭，7 天冷静期结束后可执行；期间可取消", "")
		}
		utils.OK(c, gin.H{"message": "所有成员同意，已进入 7 天冷静期", "status": "approved", "executeAt": request.ExecuteAt})
		return
	}

	utils.OK(c, gin.H{
		"message":     "已记录投票",
		"status":      "pending",
		"agreeCount":  agreeCount,
		"totalMembers": totalMembers,
	})
}

// ListDeleteVotes 查看删除请求的投票状态
func ListDeleteVotes(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.OK(c, nil)
		return
	}

	var request models.DeleteFamilyRequest
	if err := database.DB.Where("family_id = ? AND status = ?", m.FamilyID, "pending").First(&request).Error; err != nil {
		utils.OK(c, nil)
		return
	}

	var votes []models.DeleteFamilyVote
	database.DB.Where("request_id = ?", request.ID).Find(&votes)

	// 检查当前用户是否已投票
	var myVote *models.DeleteFamilyVote
	for _, v := range votes {
		if v.UserID == uid {
			myVote = &v
			break
		}
	}

	utils.OK(c, gin.H{
		"request": request,
		"votes":   votes,
		"myVote":  myVote,
	})
}

// CancelDeleteFamily 取消家庭删除（冷静期内：发起人或家庭管理员可取消）
func CancelDeleteFamily(c *gin.Context) {
	uid := middleware.MustUID(c)
	id := c.Param("id")
	var r models.DeleteFamilyRequest
	if err := database.DB.First(&r, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "request not found")
		return
	}
	// 发起人或家庭管理员可取消
	isAdmin := false
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND family_id = ? AND is_admin = ? AND status = ?", uid, r.FamilyID, true, models.MemberStatusActive).First(&m).Error; err == nil {
		isAdmin = true
	}
	if r.RequestBy != uid && !isAdmin {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "无权操作")
		return
	}
	if r.Status != "pending" && r.Status != "approved" {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, "状态不允许取消")
		return
	}
	r.Status = "canceled"
	database.DB.Save(&r)
	utils.OK(c, gin.H{"ok": true})
}

// ListFamilyMembers 列出家庭成员（含用户信息）
func ListFamilyMembers(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.OK(c, []any{})
		return
	}
	type MemberWithUser struct {
		models.FamilyMember
		Username string `json:"username"`
		Nickname string `json:"nickname"`
		Avatar   string `json:"avatar"`
	}
	var rows []MemberWithUser
	database.DB.Table("family_members").
		Select("family_members.*, users.username AS username, users.nickname AS nickname, users.avatar AS avatar").
		Joins("LEFT JOIN users ON users.id = family_members.user_id").
		Where("family_members.family_id = ? AND family_members.status = ?", m.FamilyID, models.MemberStatusActive).
		Scan(&rows)
	utils.OK(c, rows)
}

// BindForever 终身绑定
func BindForever(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND is_admin = ? AND status = ?", uid, true, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "非家庭管理员")
		return
	}
	if m.FamilyID == 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "未加入家庭")
		return
	}
	now := time.Now().Unix()
	database.DB.Model(&models.Family{}).Where("id = ?", m.FamilyID).Updates(map[string]interface{}{
		"bound":    true,
		"bound_at": now,
	})
	utils.OK(c, gin.H{"ok": true, "congrats": true})
}

// SyncPersonalData 手动将个人数据同步到家庭空间
func SyncPersonalData(c *gin.Context) {
	uid := middleware.MustUID(c)
	var m models.FamilyMember
	if err := database.DB.Where("user_id = ? AND status = ?", uid, models.MemberStatusActive).First(&m).Error; err != nil {
		utils.Fail(c, http.StatusForbidden, utils.CodeForbidden, "未加入家庭")
		return
	}

	merger := services.NewFamilyMergeService(database.DB)
	if err := merger.MergePersonalToFamily(uid, m.FamilyID); err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, gin.H{"ok": true, "message": "个人数据已同步到家庭空间"})
}
