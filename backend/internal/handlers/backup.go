package handlers

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/backup"
	"github.com/yourname/family-finance/backend/internal/cloudsync"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/utils"
	"github.com/yourname/family-finance/backend/internal/version"
)

// 云托管沙箱的 SQLite 运行副本在临时目录，沙箱重启即重置为部署快照。
// 本文件是**薄协议层**：只做参数校验、调 backup、包 utils.OK/Fail。
//
//   GET  /api/admin/backup          全表 JSON 导出（与 v0.3.1 逐字节同构，另加
//                                   schemaVersion / appVersion 两个新字段）
//   POST /api/admin/backup/restore  导入 JSON（merge：逐表插入，冲突跳过）
//
// 导入模式差异（**别把两者"统一"成一个**）：
//   - restore 用 ImportMerge：人工兜底动作，语义是"把缺的补进去"，绝不该清库；
//   - 云端快照拉取用 ImportReplace：本地是丢弃型缓存，云端才是唯一事实源。

// AdminExportBackup 全表导出为 JSON（审计日志可含敏感操作记录，仅管理员）
func AdminExportBackup(c *gin.Context) {
	snap, err := backup.Export(database.DB, backup.ExportOptions{
		IncludeAudit: true, // 备份语义：导出全部 18 表（与 v0.3.1 同构）
		AppVersion:   version.App,
	})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "export: "+err.Error())
		return
	}
	c.Header("Content-Disposition",
		"attachment; filename=finance-backup-"+time.Now().Format("20060102-150405")+".json")
	utils.OK(c, snap)
}

// restoreReq 导入请求体。
//
// ExportedAt 是备份文件**顶层**的 exportedAt（唯一时间闸门依据），必须由调用方回传。
// 老脚本不带它 → 409（故意变严，红线 5.3.1）；要保留"无脑导入"必须显式 force=true。
type restoreReq struct {
	Tables     map[string]json.RawMessage `json:"tables"`
	ExportedAt int64                      `json:"exportedAt"`
	Force      bool                       `json:"force"`
}

// gateExportTs 时间闸门：**唯一实现**（DESIGN §2.B.8），
// restore / 首次接续共用；真实逻辑在 backup.GateExportTs（纯函数、可测）。
func gateExportTs(reqExportedAt, remoteExportedAt int64, force bool) (bool, string, string) {
	return backup.GateExportTs(reqExportedAt, remoteExportedAt, force)
}

// AdminRestoreBackup 导入 JSON（merge 模式，可重复执行）。
func AdminRestoreBackup(c *gin.Context) {
	var req restoreReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	if len(req.Tables) == 0 {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, "tables 为空")
		return
	}

	// 闸门：与"云端上次成功同步的 exportedAt"比较（F4：不看 updated_at）
	remoteExportedAt := cloudsync.M().Status().RemoteExportedAt
	allowed, decision, reason := gateExportTs(req.ExportedAt, remoteExportedAt, req.Force)
	gate := gin.H{
		"decision":          decision, // forced / allowed / rejected_no_ts / rejected_older（已落审计）
		"forced":            req.Force,
		"requestExportedAt": req.ExportedAt,
		"remoteExportedAt":  remoteExportedAt,
		"at":                time.Now().Unix(),
	}
	if !allowed {
		// 409 而不是静默执行；响应里带上 gate，便于事后追查"被谁拦下了"
		c.JSON(http.StatusConflict, utils.Response{
			Code:    utils.CodeConflict,
			Message: reason,
			Data:    gin.H{"gate": gate},
		})
		return
	}

	res, err := backup.Import(database.DB, req.Tables, backup.ImportOptions{Mode: backup.ImportMerge})
	if err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, "restore: "+err.Error())
		return
	}

	utils.OK(c, gin.H{
		"inserted":    res.Inserted,
		"skipped":     res.Skipped,            // "没被破坏"的证据（已存在主键被跳过）
		"deleted":     res.Deleted,            // merge 模式恒为空
		"replaced":    res.Replaced,           // merge 模式恒 false
		"overwritten": res.TotalOverwritten(), // merge 模式恒 0
		"gate":        gate,
	})
}
