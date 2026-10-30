package handlers

import (
	"hash/fnv"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
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

// GetAppVersion 版本检查（公开接口，App 启动时调用）
// GET /api/app/version?platform=android&channel=stable&current=0.1.0&did=<设备ID>
func GetAppVersion(c *gin.Context) {
	platform := c.DefaultQuery("platform", "android")
	channel := c.DefaultQuery("channel", "stable")
	current := c.Query("current")
	did := c.Query("did")

	var v models.AppVersion
	err := database.DB.
		Where("platform = ? AND channel = ? AND published = ?", platform, channel, true).
		Order("build_number DESC, id DESC").
		First(&v).Error
	if err != nil {
		utils.OK(c, gin.H{"updateAvailable": false, "forceUpdate": false})
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
