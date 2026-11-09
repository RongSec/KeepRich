package handlers

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/cloudsync"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// SyncStatusResp GET /api/sync/status 的响应体（字段不含密钥，只回主机名）。
//
// 登录用户即可读：App 靠它驱动"云端同步失败"横条（consecutiveFailures >= 3）。
type SyncStatusResp struct {
	Enabled             bool   `json:"enabled"`
	EndpointHost        string `json:"endpointHost"`
	LastPullAt          int64  `json:"lastPullAt"`
	LastPushAt          int64  `json:"lastPushAt"`
	RemoteExportedAt    int64  `json:"remoteExportedAt"`
	PayloadBytes        int    `json:"payloadBytes"`
	Pending             bool   `json:"pending"`
	ConsecutiveFailures int    `json:"consecutiveFailures"`
	LastError           string `json:"lastError"`
	LastErrorAt         int64  `json:"lastErrorAt"`
}

// SyncStatus 同步状态（R-11 可观测性）
func SyncStatus(c *gin.Context) {
	st := cloudsync.M().Status()
	utils.OK(c, SyncStatusResp{
		Enabled:             st.Enabled,
		EndpointHost:        st.EndpointHost,
		LastPullAt:          st.LastPullAt,
		LastPushAt:          st.LastPushAt,
		RemoteExportedAt:    st.RemoteExportedAt,
		PayloadBytes:        st.PayloadBytes,
		Pending:             st.Pending,
		ConsecutiveFailures: st.ConsecutiveFailures,
		LastError:           st.LastError,
		LastErrorAt:         st.LastErrorAt,
	})
}

// AdminSyncPush POST /api/admin/sync/push —— 强制推送一次。
//
// 502 = 云不可达（真的失败了）；503 = 功能未启用（配置缺失，不是错误，但要让人看见）。
func AdminSyncPush(c *gin.Context) {
	m := cloudsync.M()
	if !m.Enabled() {
		utils.Fail(c, http.StatusServiceUnavailable, utils.CodeServer, "云端同步未启用（缺少 endpoint/apiKey 配置）")
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 30*time.Second)
	defer cancel()

	res := m.PushNow(ctx)
	if res.Error != "" {
		utils.Fail(c, http.StatusBadGateway, utils.CodeServer, "云端不可达："+res.Error)
		return
	}
	utils.OK(c, gin.H{
		"ok":           true,
		"payloadBytes": res.PayloadBytes,
		"exportedAt":   res.ExportedAt,
	})
}

// AdminSyncPull POST /api/admin/sync/pull?force=true —— 手动拉取。
//
// force=false（默认）走与启动完全相同的判定表；force=true 无视 P5/P8 强制覆盖
// （仍拒绝 P3/P4 损坏快照，避免把库洗成"谁都登不进"）。
func AdminSyncPull(c *gin.Context) {
	m := cloudsync.M()
	if !m.Enabled() {
		utils.Fail(c, http.StatusServiceUnavailable, utils.CodeServer, "云端同步未启用（缺少 endpoint/apiKey 配置）")
		return
	}
	var body struct {
		Force bool `json:"force"`
	}
	// 允许空 body：`curl -X POST .../sync/pull` 也要能用
	_ = c.ShouldBindJSON(&body)
	force := body.Force || c.Query("force") == "true" || c.Query("force") == "1"

	ctx, cancel := context.WithTimeout(c.Request.Context(), 30*time.Second)
	defer cancel()

	res := m.PullNow(ctx, force)
	if res.Error != "" {
		utils.Fail(c, http.StatusBadGateway, utils.CodeServer, "拉取失败："+res.Error)
		return
	}
	// 快照损坏 / 没有 users：明确 409，让运维知道"云端那行是坏的"，而不是静默 200
	if res.Action == "skipped" &&
		(res.Reason == "snapshot corrupt" || res.Reason == "snapshot has no users") {
		utils.Fail(c, http.StatusConflict, utils.CodeConflict, res.Reason)
		return
	}
	utils.OK(c, gin.H{
		"action":           res.Action,
		"reason":           res.Reason,
		"inserted":         res.Inserted,
		"deleted":          res.Deleted,
		"remoteExportedAt": res.RemoteExportedAt,
	})
}
