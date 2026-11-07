// Package main 入口
// @title 家庭与个人财务管理系统 API
// @version 1.0
// @description 个人与家庭记账、预规划、家庭管理
// @host localhost:8080
// @BasePath /api
package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

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
	serveWebApp(r)

	addr := ":" + strconv.Itoa(config.C.App.Port)
	log.Printf("listening on %s (env=%s)", addr, config.C.App.Env)
	if err := r.Run(addr); err != nil {
		log.Fatalf("server: %v", err)
	}
}

// serveWebApp 托管 Flutter Web 构建产物（存在时才挂载）
//
// 本地 / 私有部署时把 `flutter build web` 的产物放到 WEB_DIST（默认 ./web），
// 后端会直接把它作为站点根目录；发布新版本只需替换目录内容，用户端会通过
// /api/app/web-version 收到"有新版本，点此刷新"的提示。
func serveWebApp(r *gin.Engine) {
	dist := os.Getenv("WEB_DIST")
	if dist == "" {
		dist = "./web"
	}
	indexPath := filepath.Join(dist, "index.html")
	if _, err := os.Stat(indexPath); err != nil {
		log.Printf("web dist not found at %s, skip static hosting", dist)
		return
	}
	log.Printf("serving web app from %s", dist)

	r.Static("/assets", filepath.Join(dist, "assets"))
	r.Static("/canvaskit", filepath.Join(dist, "canvaskit"))
	r.Static("/icons", filepath.Join(dist, "icons"))
	// dist 顶层的所有文件全部挂载（main.dart.js、flutter_bootstrap.js、
	// main.dart.js_1 分片等）。此前固定清单漏了 main.dart.js，
	// 请求 404 被兜底成 index.html（text/html），浏览器拒绝执行，
	// 整个 Web 卡死在 index 的静态加载占位上 —— 用户看到的就是"永远的开屏"。
	entries, err := os.ReadDir(dist)
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if strings.HasSuffix(name, ".html") {
				continue // html 走 NoRoute 的 SPA 兜底
			}
			p := filepath.Join(dist, name)
			r.StaticFile("/"+name, p)
		}
	}

	r.NoRoute(func(c *gin.Context) {
		path := c.Request.URL.Path
		if strings.HasPrefix(path, "/api") || strings.HasPrefix(path, "/swagger") {
			c.JSON(http.StatusNotFound, gin.H{"code": 40400, "message": "not found"})
			return
		}
		// 入口文件绝不缓存，否则用户始终拿到旧构建
		c.Header("Cache-Control", "no-cache, no-store, must-revalidate")
		c.File(indexPath)
	})
}

