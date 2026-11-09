// Package main 入口
// @title 家庭与个人财务管理系统 API
// @version 1.0
// @description 个人与家庭记账、预规划、家庭管理
// @host localhost:8080
// @BasePath /api
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/auth"
	"github.com/yourname/family-finance/backend/internal/cloudsync"
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

	// ---- v0.5.0 会话 last_seen 批量刷盘 ----
	// 热路径只改内存（绝不每请求写库），这里每 touchFlushSec(默认 60s)
	// 用单事务合并 UPDATE；退出前显式 Flush 一次，避免最后 60s 的活跃丢失。
	flusherCtx, flusherCancel := context.WithCancel(context.Background())
	defer flusherCancel()
	go auth.R().RunFlusher(flusherCtx, time.Duration(config.AuthParams().TouchFlushSec)*time.Second)
	log.Printf("[auth] session flusher started (every=%ds)", config.AuthParams().TouchFlushSec)

	// ---- 云快照同步：Init → StartupPull ----
	// 启动时先拉一次，把"云端是唯一事实源"落实到进程启动顺序里。
	// 拉取失败只打日志 + 记 lastError，**绝不 fatal、绝不清空本地**（红线 5.3.3）。
	cloudsync.Init(config.C.CloudSync)
	pullCtx, pullCancel := context.WithTimeout(context.Background(), 8*time.Second)
	pullRes := cloudsync.M().StartupPull(pullCtx)
	pullCancel()
	log.Printf("[cloudsync] startup pull: action=%s reason=%s remoteExportedAt=%d err=%s",
		pullRes.Action, pullRes.Reason, pullRes.RemoteExportedAt, pullRes.Error)

	// 快照可能没有 admin（或换过口令）→ 幂等补建一次。
	// 注意：接续场景下 admin 以 SeedAdmin 为准（Q-M5），这是预期行为。
	if err := database.SeedAdmin(os.Getenv("ADMIN_USERNAME"), os.Getenv("ADMIN_PASSWORD")); err != nil {
		log.Printf("seed admin (after pull): %v", err)
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), middleware.Recovery(), middleware.CORS())

	routes.Register(r)
	serveAdminApp(r)
	serveWebApp(r)

	// 后台推送循环（60s 兜底 ticker + 防抖 + 退避）
	runCtx, runCancel := context.WithCancel(context.Background())
	defer runCancel()
	go cloudsync.M().Run(runCtx)

	// 显式 http.Server（r.Run() 无法在退出前 flush 最后一次推送）
	addr := ":" + strconv.Itoa(config.C.App.Port)
	srv := &http.Server{Addr: addr, Handler: r}

	go func() {
		log.Printf("listening on %s (env=%s)", addr, config.C.App.Env) // 保持原格式，验收依赖它
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	sig := <-sigCh
	log.Printf("[shutdown] signal %v received", sig)

	// 先停后台循环，避免与新的一次 Flush 互相竞争
	runCancel()
	flusherCancel()
	auth.R().Flush()
	log.Println("[shutdown] session last_seen flushed")

	// 退出前最后一次推送（best-effort：只在 dirty==1 / pending 时推）。
	// 真正的保障是 debounce 只有 1.5s —— 沙箱被 SIGKILL 时丢失窗口极小。
	log.Println("[shutdown] flushing cloud snapshot ...")
	flushCtx, flushCancel := context.WithTimeout(context.Background(), 8*time.Second)
	if err := cloudsync.M().Flush(flushCtx); err != nil {
		log.Printf("[shutdown] flush failed: %v", err)
	} else {
		log.Println("[shutdown] flush done")
	}
	flushCancel()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Printf("[shutdown] server shutdown: %v", err)
	}
	shutCancel()
	log.Println("[shutdown] bye")
}

// serveWebApp 托管 Flutter Web 构建产物（存在时才挂载）
//
// 本地 / 私有部署时把 `flutter build web` 的产物放到 WEB_DIST（默认 ./web），
// 后端会直接把它作为站点根目录；发布新版本只需替换目录内容，用户端会通过
// /api/app/web-version 收到"有新版本，点此刷新"的提示。
// serveAdminApp 托管管理后台（独立 Flutter Web 构建，--base-href=/admin/ 产物）
//
// 放到 ADMIN_DIST（默认 ./admin_dist）；此前管理后台靠独立 nginx 部署，
// 云托管单端口场景下没有它就会"消失"，这里统一由后端挂到 /admin 路径。
func serveAdminApp(r *gin.Engine) {
	dist := os.Getenv("ADMIN_DIST")
	if dist == "" {
		// 放在 web/admin 下随主 web 产物一起分发（独立 admin_dist 目录曾被
		// 托管平台的上传排除规则滤掉，导致 /admin 永远走主 App 兜底）
		dist = "./web/admin"
	}
	indexPath := filepath.Join(dist, "index.html")
	if _, err := os.Stat(indexPath); err != nil {
		log.Printf("admin dist not found at %s, skip admin hosting", dist)
		return
	}
	log.Printf("serving admin app from %s", dist)

	r.Static("/admin/assets", filepath.Join(dist, "assets"))
	r.Static("/admin/canvaskit", filepath.Join(dist, "canvaskit"))
	if entries, err := os.ReadDir(dist); err == nil {
		for _, e := range entries {
			if e.IsDir() || strings.HasSuffix(e.Name(), ".html") {
				continue
			}
			r.StaticFile("/admin/"+e.Name(), filepath.Join(dist, e.Name()))
		}
	}
	// /admin 前缀的兜底交给 serveWebApp 的 NoRoute（gin 的 NoRoute 后注册覆盖前者），
	// 这里只把入口路径记下来供其判断
	adminIndex = indexPath
}

// adminIndex 管理后台入口（serveAdminApp 设置；空表示未挂载）
var adminIndex string

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
		c.Header("Cache-Control", "no-cache, no-store, must-revalidate")
		// 管理后台兜底：/admin 前缀回 admin 入口（区别于主 App 的 SPA 兜底）
		if adminIndex != "" && strings.HasPrefix(path, "/admin") {
			if path == "/admin" {
				c.Redirect(http.StatusMovedPermanently, "/admin/")
				return
			}
			c.File(adminIndex)
			return
		}
		c.File(indexPath)
	})
}
