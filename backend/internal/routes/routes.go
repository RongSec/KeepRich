package routes

import (
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/cloudsync"
	"github.com/yourname/family-finance/backend/internal/handlers"
	"github.com/yourname/family-finance/backend/internal/middleware"
)

// Register 注册路由
func Register(r *gin.Engine) {
	// 安全响应头（CSP / X-Frame-Options / nosniff / HSTS 等）
	r.Use(middleware.SecurityHeaders())

	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(200, gin.H{"ok": true})
	})

	api := r.Group("/api")
	// 云端快照：挂在 /api 组最外层，捕获**所有**业务写操作 → MarkDirty（非阻塞）。
	// /healthz 不在 /api 下 → 天然不触发。
	api.Use(cloudsync.M().Middleware())
	{
		// 公开（登录/刷新限流：单 IP 5 分钟 30 次）
		authLimiter := middleware.RateLimit(5*time.Minute, 30, "auth-ip")
		api.POST("/auth/login", authLimiter, handlers.Login)
		api.POST("/auth/refresh", authLimiter, handlers.Refresh)
		api.POST("/auth/device-login", authLimiter, handlers.DeviceLogin)
		// 邀请码注册（R-08）：公开 + authLimiter；另有 register-ip 维度限流在 handler 内
		api.POST("/auth/register", authLimiter, handlers.Register)

		api.GET("/app/version", handlers.GetAppVersion)     // 在线更新版本检查
		api.GET("/app/download", handlers.AppDownload)      // 云服务代理 APK 下载（设备无需直连 GitHub）
		api.GET("/app/web-version", handlers.GetWebVersion) // Web 端在线更新检查

		// 客户端错误上报：**公开**（不再要求登录）。
		// 扫码失败常发生在登录前/登录态失效时，此前挂在 auth 组下会先 401，
		// 错误永远上报不上来；接口结构不变，旧客户端零改动。
		api.POST("/errors", middleware.RateLimit(5*time.Minute, 30, "err-ip"), handlers.ReportError)

		// 需要登录
		auth := api.Group("")
		// 已登录接口：单 IP 每分钟 600 次（正常使用远达不到，只挡脚本刷接口）
		auth.Use(middleware.RateLimit(time.Minute, 600, "api-ip"), middleware.JWT(), middleware.Audit())
		{
			auth.GET("/auth/me", handlers.Me)
			// v0.5.0 会话与设备管理
			auth.POST("/auth/logout", handlers.Logout)
			auth.GET("/auth/devices", handlers.ListDevices)
			auth.POST("/auth/devices/revoke-others", handlers.RevokeOthers)
			auth.POST("/auth/devices/:id/revoke", handlers.RevokeDevice)
			auth.POST("/mfa/setup", handlers.MFASetup)
			auth.POST("/mfa/enable", handlers.MFAEnable)
			auth.POST("/mfa/disable", handlers.MFADisable)

			auth.GET("/overview", handlers.Overview)
			auth.GET("/overview/chart", handlers.OverviewChart)
			auth.GET("/plan", handlers.GetPlan)
			auth.POST("/plan", handlers.SavePlan)

			auth.GET("/transactions", handlers.ListTx)
			auth.POST("/transactions", handlers.CreateTx)
			auth.PUT("/transactions/:id", handlers.PutTx)
			auth.DELETE("/transactions/:id", handlers.DeleteTx)

			auth.GET("/purchase-plans", handlers.ListPurchasePlans)
			auth.POST("/purchase-plans", handlers.CreatePurchasePlan)
			auth.PUT("/purchase-plans/:id", handlers.UpdatePurchasePlan)
			auth.DELETE("/purchase-plans/:id", handlers.DeletePurchasePlan)
			auth.POST("/purchase-plans/check", handlers.CheckBigPurchase)

			auth.GET("/investments", handlers.ListInvestments)
			auth.GET("/investments/current", handlers.GetCurrentInvestment)
			auth.GET("/investments/settlement", handlers.InvestmentSettlement)
			auth.POST("/investments", handlers.UpsertInvestment)

			auth.GET("/family", handlers.MyFamily)
			auth.POST("/family", handlers.CreateFamily)
			auth.POST("/family/join", handlers.ApplyJoin)
			auth.GET("/family/requests", handlers.ListJoinRequests)
			auth.POST("/family/approve", handlers.ApproveJoin)
			auth.POST("/family/transfer", handlers.TransferAdmin)
			auth.POST("/family/bind-forever", handlers.BindForever)
			auth.POST("/family/sync", handlers.SyncPersonalData)
			auth.POST("/family/delete", handlers.RequestDeleteFamily)
			auth.POST("/family/delete/vote", handlers.VoteDeleteFamily)
			auth.GET("/family/delete/votes", handlers.ListDeleteVotes)
			auth.POST("/family/delete/:id/cancel", handlers.CancelDeleteFamily)
			auth.POST("/family/force-delete", handlers.ForceDeleteFamily)
			auth.GET("/family/members", handlers.ListFamilyMembers)
			auth.PUT("/family/members/:id", handlers.UpdateFamilyMember)
			auth.DELETE("/family/members/:id", handlers.RemoveFamilyMember)

			// 未来财务
			auth.GET("/future", handlers.FutureFinance)
			auth.GET("/future/housing-loans", handlers.ListHousingFundLoans)
			auth.POST("/future/housing-loans", handlers.CreateHousingFundLoan)
			auth.PUT("/future/housing-loans/:id", handlers.UpdateHousingFundLoan)
			auth.DELETE("/future/housing-loans/:id", handlers.DeleteHousingFundLoan)
			auth.GET("/future/commercial-loans", handlers.ListCommercialLoans)
			auth.POST("/future/commercial-loans", handlers.CreateCommercialLoan)
			auth.PUT("/future/commercial-loans/:id", handlers.UpdateCommercialLoan)
			auth.DELETE("/future/commercial-loans/:id", handlers.DeleteCommercialLoan)
			auth.GET("/future/borrowed", handlers.ListBorrowedMoney)
			auth.POST("/future/borrowed", handlers.CreateBorrowedMoney)
			auth.PUT("/future/borrowed/:id", handlers.UpdateBorrowedMoney)
			auth.DELETE("/future/borrowed/:id", handlers.DeleteBorrowedMoney)
			auth.GET("/future/benefits", handlers.ListFutureBenefits)
			auth.POST("/future/benefits", handlers.CreateFutureBenefit)
			auth.PUT("/future/benefits/:id", handlers.UpdateFutureBenefit)
			auth.DELETE("/future/benefits/:id", handlers.DeleteFutureBenefit)
			auth.GET("/future/investment-check", handlers.MonthlyInvestmentCheck)

			auth.GET("/notifications", handlers.ListNotifications)
			auth.POST("/notifications/:id/read", handlers.MarkNotificationRead)
			auth.POST("/notifications/read-all", handlers.MarkAllNotificationsRead)
			auth.GET("/ws", handlers.WS)

			auth.POST("/profile", handlers.UpdateProfile)
			auth.POST("/profile/password", handlers.ChangePassword)

			// 云端同步状态（登录用户可读：App 靠它驱动"同步失败"横条；
			// 只回主机名，不回完整 URL/key）
			auth.GET("/sync/status", handlers.SyncStatus)
		}

		// 系统管理员（普通用户被 AdminOnly 挡在 403）
		admin := api.Group("/admin")
		admin.Use(middleware.JWT(), middleware.AdminOnly(), middleware.Audit())
		{
			admin.POST("/users", handlers.CreateUser)
			admin.GET("/users", handlers.ListUsers)
			admin.POST("/users/:id/toggle", handlers.ToggleUserStatus)
			admin.POST("/users/:id/reset-password", handlers.AdminResetPassword)
			admin.POST("/users/:id/reset-mfa", handlers.AdminResetMFA)
			admin.DELETE("/users/:id", handlers.DeleteUser)
			admin.GET("/families", handlers.AdminListFamiliesWithStats)
			admin.GET("/families/:id/stats", handlers.AdminFamilyStats)
			admin.DELETE("/families/:id", handlers.AdminDeleteFamily)
			admin.GET("/audit", handlers.AdminListAudit)
			admin.GET("/errors", handlers.AdminListErrors)
			admin.DELETE("/errors/:id", handlers.AdminDeleteError)
			admin.DELETE("/errors", handlers.AdminClearErrors)

			// v0.5.0 邀请码管理（本版只有接口 + 脚本，UI 排 v0.5.1）
			admin.POST("/invite-codes", handlers.AdminCreateInviteCodes)
			admin.GET("/invite-codes", handlers.AdminListInviteCodes)
			admin.POST("/invite-codes/:id/revoke", handlers.AdminRevokeInviteCode)

			// 应用版本管理（在线更新）
			admin.GET("/app-versions", handlers.AdminListAppVersions)
			admin.POST("/app-versions", handlers.AdminCreateAppVersion)
			admin.PUT("/app-versions/:id", handlers.AdminUpdateAppVersion)
			admin.DELETE("/app-versions/:id", handlers.AdminDeleteAppVersion)

			// 数据备份：沙箱临时库重置保险（发布前导出 / 发布后导入）
			admin.GET("/backup", handlers.AdminExportBackup)
			admin.POST("/backup/restore", handlers.AdminRestoreBackup)

			// 云端快照运维口（管理员显式触发；日常由后台 goroutine 自动做）
			admin.POST("/sync/push", handlers.AdminSyncPush)
			admin.POST("/sync/pull", handlers.AdminSyncPull)
		}
	}
}
