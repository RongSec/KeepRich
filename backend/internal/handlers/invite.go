package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/auth"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// CreateInviteCodesReq 生成邀请码（服务端生成，不接受自定义码串）。
type CreateInviteCodesReq struct {
	Count         int    `json:"count"`
	MaxUses       int    `json:"maxUses"`
	ExpiresInDays int    `json:"expiresInDays"`
	Note          string `json:"note"`
}

// AdminCreateInviteCodes 批量发码。挂在 admin 组（JWT + AdminOnly），普通用户 403。
//
// 频控：同一管理员 1 小时最多生成 20 个（PRD R-09 ⑤）。
// 邀请码不绑定家庭：新账号默认无家庭，加入家庭走既有申请/审批流程。
func AdminCreateInviteCodes(c *gin.Context) {
	adminID := middleware.MustUID(c)
	if !middleware.Allow("invite-gen:"+strconv.FormatUint(adminID, 10), time.Hour, 20) {
		utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, utils.MsgGenerateFrequent)
		return
	}
	var req CreateInviteCodesReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgRequestFormat)
		return
	}
	cfg := config.AuthParams()
	count := req.Count
	if count == 0 {
		count = 1
	}
	if count < 1 || count > 5 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgInviteCountRange)
		return
	}
	maxUses := req.MaxUses
	if maxUses == 0 {
		maxUses = cfg.InviteMaxUses
	}
	if maxUses < 1 || maxUses > 50 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgInviteMaxUses)
		return
	}
	days := req.ExpiresInDays
	if days == 0 {
		days = cfg.InviteTTLDays
	}
	if days != 1 && days != 7 && days != 30 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgInviteTTLRange)
		return
	}
	note := strings.TrimSpace(req.Note)
	if utf8.RuneCountInString(note) > 32 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, utils.MsgNoteTooLong)
		return
	}

	codes, err := auth.Invites().Create(auth.CreateInviteParams{
		AdminID:       adminID,
		Count:         count,
		MaxUses:       maxUses,
		ExpiresInDays: days,
		Note:          note,
	})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "邀请码生成失败，请稍后再试")
		return
	}
	list := make([]gin.H, 0, len(codes))
	for _, x := range codes {
		list = append(list, gin.H{
			"id":        x.ID,
			"code":      x.Code,
			"maxUses":   x.MaxUses,
			"usedCount": x.UsedCount,
			"expiresAt": x.ExpiresAt,
		})
	}
	utils.OK(c, gin.H{
		"count":   len(codes),
		"codes":   list,
		"message": utils.MsgInviteGenerated,
	})
}

// AdminListInviteCodes 列表 + 状态筛选 + 分页；状态为派生值，不入库。
func AdminListInviteCodes(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("size", "20"))
	list, total, err := auth.Invites().List(auth.InviteFilter{
		Status:  c.Query("status"),
		Keyword: strings.TrimSpace(c.Query("keyword")),
		Page:    page,
		Size:    size,
	})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "获取邀请码列表失败，请稍后再试")
		return
	}
	if list == nil {
		list = []auth.InviteView{}
	}
	utils.OK(c, gin.H{"total": total, "list": list})
}

// AdminRevokeInviteCode 撤销未使用的邀请码（幂等；已使用 / 已过期不可撤销）。
func AdminRevokeInviteCode(c *gin.Context) {
	adminID := middleware.MustUID(c)
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "邀请码不存在")
		return
	}
	alreadyRevoked, err := auth.Invites().Revoke(id, adminID)
	if err != nil {
		switch {
		case errors.Is(err, auth.ErrInviteNotFound):
			utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "邀请码不存在")
		case errors.Is(err, auth.ErrInviteUsedNoRevoke):
			utils.Fail(c, http.StatusConflict, utils.CodeConflict, utils.MsgInviteUsedNoRevoke)
		case errors.Is(err, auth.ErrInviteExpiredNoRevoke):
			utils.Fail(c, http.StatusConflict, utils.CodeConflict, utils.MsgInviteExpiredNoRevoke)
		default:
			utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "撤销失败，请稍后再试")
		}
		return
	}
	utils.OK(c, gin.H{
		"ok":             true,
		"alreadyRevoked": alreadyRevoked,
		"message":        utils.MsgInviteRevokeOK,
	})
}
