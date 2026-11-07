package handlers

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/middleware"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// compareVersion 简单语义化版本比较：a<b 返回 -1，a==b 返回 0，a>b 返回 1
func compareVersion(a, b string) int {
	pa := strings.Split(strings.TrimSpace(a), ".")
	pb := strings.Split(strings.TrimSpace(b), ".")
	for i := 0; i < 3; i++ {
		va, vb := 0, 0
		if i < len(pa) {
			va, _ = strconv.Atoi(strings.TrimSpace(pa[i]))
		}
		if i < len(pb) {
			vb, _ = strconv.Atoi(strings.TrimSpace(pb[i]))
		}
		if va != vb {
			if va < vb {
				return -1
			}
			return 1
		}
	}
	return 0
}

// grayIn 灰度判定：确定性哈希（同设备结果稳定）
func grayIn(identifier string, percent int) bool {
	if percent >= 100 {
		return true
	}
	if percent <= 0 {
		return false
	}
	if identifier == "" {
		identifier = "anon"
	}
	h := fnv.New32a()
	h.Write([]byte(identifier))
	return int(h.Sum32()%100) < percent
}

// ====== GitHub Releases 在线更新 ======
//
// 配置 app.githubRepo（或环境变量 GITHUB_REPO，形如 "owner/repo"）后，
// /api/app/version 优先从 GitHub Releases 拉取最新版本：
//   - 版本号取 tag（去掉前缀 v）
//   - APK 按 ABI 匹配资产（app-<abi>-release.apk），App 会上报设备 ABI
//   - sha256 从 SHA256SUMS.txt 资产解析
//   - 结果缓存 5 分钟，避免触发 GitHub 匿名限流（60 次/小时/IP）
// 拉取失败或未配置时回退到后台维护的 app_versions 表。

type ghAsset struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"browser_download_url"`
}

type ghRelease struct {
	TagName string    `json:"tag_name"`
	Body    string    `json:"body"`
	Assets  []ghAsset `json:"assets"`
}

var (
	ghMu      sync.Mutex
	ghCache   *ghRelease
	ghCacheAt time.Time
)

func fetchLatestRelease(repo string) (*ghRelease, error) {
	ghMu.Lock()
	defer ghMu.Unlock()
	if ghCache != nil && time.Since(ghCacheAt) < 5*time.Minute {
		return ghCache, nil
	}
	url := "https://api.github.com/repos/" + repo + "/releases/latest"
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "keeprich-backend")
	req.Header.Set("Accept", "application/vnd.github+json")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github api status %d", resp.StatusCode)
	}
	var rel ghRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, err
	}
	ghCache = &rel
	ghCacheAt = time.Now()
	return ghCache, nil
}

// pickAPKAsset 按设备 ABI 选 APK；匹配不到时回退 arm64-v8a，再回退第一个 .apk
func pickAPKAsset(rel *ghRelease, abi string) *ghAsset {
	var first *ghAsset
	for i := range rel.Assets {
		a := &rel.Assets[i]
		if !strings.HasSuffix(strings.ToLower(a.Name), ".apk") {
			continue
		}
		if first == nil {
			first = a
		}
		if abi != "" && strings.Contains(a.Name, abi) {
			return a
		}
	}
	if first != nil {
		return first
	}
	for i := range rel.Assets {
		a := &rel.Assets[i]
		if strings.Contains(a.Name, "arm64-v8a") && strings.HasSuffix(strings.ToLower(a.Name), ".apk") {
			return a
		}
	}
	return first
}

// fetchChecksum 从 SHA256SUMS.txt 里解析指定文件的 sha256（标准格式：`<hash>  <filename>`）
func fetchChecksum(repo, tag, filename string) string {
	url := "https://github.com/" + repo + "/releases/download/" + tag + "/SHA256SUMS.txt"
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", "keeprich-backend")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	// 文件不会太大，直接全量读
	buf := make([]byte, 0, 8192)
	tmp := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if err != nil || len(buf) > 1<<20 {
			break
		}
	}
	for _, line := range strings.Split(string(buf), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == filename {
			return fields[0]
		}
	}
	return ""
}

// GetAppVersion 版本检查（公开接口，App 启动时调用）
// GET /api/app/version?platform=android&channel=stable&current=0.1.0&did=<设备ID>&abi=arm64-v8a
func GetAppVersion(c *gin.Context) {
	platform := c.DefaultQuery("platform", "android")
	channel := c.DefaultQuery("channel", "stable")
	current := c.Query("current")
	did := c.Query("did")
	abi := c.Query("abi")

	// 优先 GitHub Releases：仓库发布新 Release 后 App 即可拉到，无需后台登记
	if repo := strings.TrimSpace(config.C.App.GitHubRepo); repo != "" && platform == "android" {
		if rel, err := fetchLatestRelease(repo); err == nil {
			version := strings.TrimPrefix(strings.TrimPrefix(rel.TagName, "v"), "V")
			asset := pickAPKAsset(rel, abi)
			if version != "" && asset != nil {
				updateAvailable := compareVersion(current, version) < 0
				utils.OK(c, gin.H{
					"version":         version,
					"buildNumber":     0,
					"notes":           rel.Body,
					"apkUrl":          asset.URL,
					"sha256":          fetchChecksum(repo, rel.TagName, asset.Name),
					"sizeBytes":       asset.Size,
					"minSupported":    "",
					"updateAvailable": updateAvailable,
					"forceUpdate":     false,
					"source":          "github",
					"githubRepo":      repo,
				})
				return
			}
		}
		// GitHub 拉取失败或没有 APK 资产 → 走下方数据库回退
	}

	var v models.AppVersion
	err := database.DB.
		Where("platform = ? AND channel = ? AND published = ?", platform, channel, true).
		Order("build_number DESC, id DESC").
		First(&v).Error
	if err != nil {
		utils.OK(c, gin.H{"updateAvailable": false, "forceUpdate": false,
			"githubRepo": strings.TrimSpace(config.C.App.GitHubRepo)})
		return
	}

	updateAvailable := compareVersion(current, v.Version) < 0
	forceUpdate := false
	if v.MinSupported != "" {
		forceUpdate = compareVersion(current, v.MinSupported) < 0
	}
	inGray := grayIn(did, v.GrayPercent)

	utils.OK(c, gin.H{
		"version":         v.Version,
		"buildNumber":     v.BuildNumber,
		"notes":           v.Notes,
		"apkUrl":          v.APKUrl,
		"sha256":          v.SHA256,
		"sizeBytes":       v.SizeBytes,
		"minSupported":    v.MinSupported,
		"updateAvailable": (updateAvailable || forceUpdate) && inGray,
		"forceUpdate":     forceUpdate && inGray,
		"inGray":          inGray,
		"githubRepo":      strings.TrimSpace(config.C.App.GitHubRepo),
	})
}

// AdminListAppVersions 版本列表（管理员）
func AdminListAppVersions(c *gin.Context) {
	var list []models.AppVersion
	q := database.DB.Model(&models.AppVersion{})
	if p := c.Query("platform"); p != "" {
		q = q.Where("platform = ?", p)
	}
	var total int64
	q.Count(&total)
	q.Order("id DESC").Limit(200).Find(&list)
	utils.OK(c, gin.H{"list": list, "total": total})
}

type appVersionReq struct {
	Platform     string `json:"platform" binding:"required"`
	Version      string `json:"version" binding:"required"`
	BuildNumber  int    `json:"buildNumber" binding:"required"`
	Channel      string `json:"channel"`
	MinSupported string `json:"minSupported"`
	GrayPercent  *int   `json:"grayPercent"`
	Notes        string `json:"notes"`
	APKUrl       string `json:"apkUrl"`
	SHA256       string `json:"sha256"`
	SizeBytes    int64  `json:"sizeBytes"`
	Published    *bool  `json:"published"`
}

func applyVersionReq(v *models.AppVersion, req *appVersionReq) {
	v.Platform = req.Platform
	v.Version = req.Version
	v.BuildNumber = req.BuildNumber
	if req.Channel != "" {
		v.Channel = req.Channel
	}
	v.MinSupported = req.MinSupported
	if req.GrayPercent != nil {
		p := *req.GrayPercent
		if p < 0 {
			p = 0
		}
		if p > 100 {
			p = 100
		}
		v.GrayPercent = p
	}
	v.Notes = req.Notes
	v.APKUrl = req.APKUrl
	v.SHA256 = req.SHA256
	v.SizeBytes = req.SizeBytes
	if req.Published != nil {
		v.Published = *req.Published
	}
}

// AdminCreateAppVersion 新建版本记录
func AdminCreateAppVersion(c *gin.Context) {
	var req appVersionReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	v := models.AppVersion{Channel: "stable", GrayPercent: 100}
	applyVersionReq(&v, &req)
	if err := database.DB.Create(&v).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	_ = middleware.MustUID(c)
	utils.OK(c, v)
}

// AdminUpdateAppVersion 更新版本记录（支持草稿→发布、调灰度/强更）
func AdminUpdateAppVersion(c *gin.Context) {
	id, _ := strconv.ParseUint(c.Param("id"), 10, 64)
	var v models.AppVersion
	if err := database.DB.First(&v, id).Error; err != nil {
		utils.Fail(c, http.StatusNotFound, utils.CodeNotFound, "版本不存在")
		return
	}
	var req appVersionReq
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Fail(c, http.StatusBadRequest, utils.CodeBadRequest, err.Error())
		return
	}
	applyVersionReq(&v, &req)
	if err := database.DB.Save(&v).Error; err != nil {
		utils.Fail(c, http.StatusInternalServerError, utils.CodeServer, err.Error())
		return
	}
	utils.OK(c, v)
}

// AdminDeleteAppVersion 删除版本记录
func AdminDeleteAppVersion(c *gin.Context) {
	id, _ := strconv.ParseUint(c.Param("id"), 10, 64)
	database.DB.Delete(&models.AppVersion{}, id)
	utils.OK(c, gin.H{"deleted": true})
}

// GetWebVersion Web 端版本检查（公开接口）
//
// Web 的"在线更新"与 APK 不同：服务端部署新构建后，已打开页面的用户需要被
// 提示刷新。判定依据有两种，按优先级：
//  1. 后台维护的 platform=web 版本记录（可写更新说明、控制发布）
//  2. 环境变量 WEB_VERSION / WEB_BUILD / WEB_NOTES（部署脚本注入，免配置）
//
// GET /api/app/web-version?build=12
func GetWebVersion(c *gin.Context) {
	currentBuild := 0
	if b := c.Query("build"); b != "" {
		currentBuild, _ = strconv.Atoi(b)
	}

	var v models.AppVersion
	err := database.DB.
		Where("platform = ? AND channel = ? AND published = ?", "web", "stable", true).
		Order("build_number DESC, id DESC").
		First(&v).Error

	if err == nil && v.Version != "" {
		utils.OK(c, gin.H{
			"version":         v.Version,
			"buildNumber":     v.BuildNumber,
			"notes":           v.Notes,
			"updateAvailable": v.BuildNumber > currentBuild || compareVersion(c.Query("current"), v.Version) < 0,
			"source":          "db",
		})
		return
	}

	// 回退：环境变量（部署时写入，适合个人/小团队部署）
	wv := strings.TrimSpace(os.Getenv("WEB_VERSION"))
	if wv == "" {
		utils.OK(c, gin.H{"updateAvailable": false, "version": "", "buildNumber": 0})
		return
	}
	wb, _ := strconv.Atoi(strings.TrimSpace(os.Getenv("WEB_BUILD")))
	utils.OK(c, gin.H{
		"version":         wv,
		"buildNumber":     wb,
		"notes":           os.Getenv("WEB_NOTES"),
		"updateAvailable": wb > currentBuild,
		"source":          "env",
	})
}

