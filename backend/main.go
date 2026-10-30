// Package main 入口
// @title 家庭与个人财务管理系统 API
// @version 1.0
// @description 个人与家庭记账、预规划、家庭管理
// @host localhost:8080
// @BasePath /api
package main

import (
	"log"
	"os"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/routes"
)

func main() {
	if err := config.Load(); err != nil {
		log.Fatalf("load config: %v", err)
	}
	if err := database.Init(); err != nil {
		log.Fatalf("init db: %v", err)
	}
	if err := database.Migrate(); err != nil {
		log.Fatalf("migrate: %v", err)
	}
	if err := database.SeedAdmin(os.Getenv("ADMIN_USERNAME"), os.Getenv("ADMIN_PASSWORD")); err != nil {
		log.Printf("seed admin: %v", err)
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), middleware.Recovery(), middleware.CORS())

	routes.Register(r)

	addr := ":" + strconv.Itoa(config.C.App.Port)
	log.Printf("listening on %s (env=%s)", addr, config.C.App.Env)
	if err := r.Run(addr); err != nil {
		log.Fatalf("server: %v", err)
	}
}
