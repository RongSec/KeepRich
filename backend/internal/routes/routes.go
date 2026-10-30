package routes

import (
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/handlers"
	"github.com/yourname/family-finance/backend/internal/middleware"
)

// Register 注册路由
func Register(r *gin.Engine) {
	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(200, gin.H{"ok": true})
	})

	api := r.Group("/api")
	{
		// 公开（登录/刷新限流：单 IP 5 分钟 30 次）
		authLimiter := middleware.RateLimit(5*time.Minute, 30, "auth-ip")
		api.POST("/auth/login", authLimiter, handlers.Login)
		api.POST("/auth/refresh", authLimiter, handlers.Refresh)
		api.GET("/app/version", handlers.GetAppVersion) // 在线更新版本检查

		// 需要登录
		auth := api.Group("")
		auth.Use(middleware.JWT(), middleware.Audit())
		{
			auth.GET("/auth/me", handlers.Me)
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

			// 客户端错误上报（任意登录用户）
			auth.POST("/errors", handlers.ReportError)
		}

		// 系统管理员
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

			// 应用版本管理（在线更新）
			admin.GET("/app-versions", handlers.AdminListAppVersions)
			admin.POST("/app-versions", handlers.AdminCreateAppVersion)
			admin.PUT("/app-versions/:id", handlers.AdminUpdateAppVersion)
			admin.DELETE("/app-versions/:id", handlers.AdminDeleteAppVersion)
		}
	}
}
