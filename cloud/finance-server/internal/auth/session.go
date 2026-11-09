package auth

import (
	"errors"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// 会话领域错误（handler 统一映射成中文，绝不把 err.Error() 透给客户端）。
var (
	ErrSessionNotFound = errors.New("session not found")
	ErrSessionRevoked  = errors.New("session revoked")
	ErrSessionIdle     = errors.New("session idle")
	ErrUserDisabled    = errors.New("user disabled")
)

// 撤销原因枚举（DESIGN §7.1）。
const (
	ReasonLogout         = "logout"
	ReasonPasswordChange = "password_change"
	ReasonAdminDisable   = "admin_disable"
	ReasonAdminDelete    = "admin_delete"
	ReasonDeviceRevoke   = "device_revoke"
	ReasonRevokeOthers   = "revoke_others"
	ReasonIdle           = "idle"
	ReasonRefreshReplay  = "refresh_replay"
)

// DeviceInfo 一次登录/注册携带的设备描述。
type DeviceInfo struct {
	DeviceID   string
	DeviceName string
	Platform   string
}

// NormalizeDevice 补全设备名并保证不超列宽；空 deviceId 即「老客户端」标记。
func NormalizeDevice(d DeviceInfo) DeviceInfo {
	d.DeviceID = strings.TrimSpace(d.DeviceID)
	d.DeviceName = strings.TrimSpace(d.DeviceName)
	d.Platform = strings.ToLower(strings.TrimSpace(d.Platform))
	if d.DeviceName == "" {
		if d.Platform != "" {
			d.DeviceName = d.Platform + " 设备"
		} else {
			d.DeviceName = "未知设备"
		}
	}
	if len(d.DeviceName) > 64 {
		d.DeviceName = d.DeviceName[:64]
	}
	if len(d.DeviceID) > 64 {
		d.DeviceID = d.DeviceID[:64]
	}
	return d
}

// Tokens 一次会话签发的全部凭据；RefreshToken 为空表示「legacy 不轮换」。
type Tokens struct {
	AccessToken  string
	RefreshToken string
	ExpiresIn    int
	SessionID    string
	IdleExpireAt int64
}

// LoginBundle 登录 / 注册 / 设备登录共用，handler 不再自己算 expiresIn / idleExpireAt。
type LoginBundle struct {
	Tokens
	DeviceToken string
}

// DeviceView 设备列表展示项（DTO，绝不含任何哈希）。
type DeviceView struct {
	ID                  uint64 `json:"id"`
	SessionID           string `json:"sessionId"`
	DeviceID            string `json:"deviceId"`
	DeviceName          string `json:"deviceName"`
	Platform            string `json:"platform"`
	LastSeenAt          int64  `json:"lastSeenAt"`
	Current             bool   `json:"current"`
	HasDeviceCredential bool   `json:"hasDeviceCredential"`
}

// SessionService 会话领域服务（无状态，方法只依赖 database.DB）。
type SessionService struct{}

// Sessions 返回服务实例。
func Sessions() *SessionService { return &SessionService{} }

// jwtSecrets 集中读取签名参数；config.C 未初始化时回落默认值，避免 nil 解引用。
func jwtSecrets() (access, refresh string, accessTTL, refreshTTL int) {
	if config.C == nil {
		return "dev-access-secret", "dev-refresh-secret", 900, 86400
	}
	a, r := config.C.JWT.AccessSecret, config.C.JWT.RefreshSecret
	at, rt := config.C.JWT.AccessTTL, config.C.JWT.RefreshTTL
	if at <= 0 {
		at = 900
	}
	if rt <= 0 {
		rt = 86400
	}
	return a, r, at, rt
}

func signAccess(u *models.User, sid string) (string, error) {
	access, _, ttl, _ := jwtSecrets()
	return utils.TokenOpts{
		UID: u.ID, Role: u.Role, TokenType: utils.TokenTypeAccess,
		Secret: access, TTL: ttl, TokenVersion: u.TokenVersion, SessionID: sid,
	}.Sign()
}

func signRefresh(u *models.User, sid, jti string) (string, error) {
	_, refresh, _, ttl := jwtSecrets()
	return utils.TokenOpts{
		UID: u.ID, Role: u.Role, TokenType: utils.TokenTypeRefresh,
		Secret: refresh, TTL: ttl, TokenVersion: u.TokenVersion, SessionID: sid, JTI: jti,
	}.Sign()
}

// newRefresh 生成新一代 refresh：新 jti → 新 JWT → 新 HMAC 指纹。
func (s *SessionService) newRefresh(u *models.User, sid string) (raw, jti, hash string, err error) {
	jti, err = NewJTI()
	if err != nil {
		return "", "", "", err
	}
	raw, err = signRefresh(u, sid, jti)
	if err != nil {
		return "", "", "", err
	}
	_, secret, _, _ := jwtSecrets()
	return raw, jti, HmacHex(secret, raw), nil
}

// Create 建立会话行并签发 access + refresh（登录 / 注册 / 设备登录共用）。
func (s *SessionService) Create(u *models.User, dev DeviceInfo, ip, userAgent string) (*Tokens, error) {
	if u == nil || database.DB == nil {
		return nil, errors.New("auth: 用户或数据库未初始化")
	}
	now := time.Now().Unix()
	idleTTL := int64(config.AuthParams().SessionIdleTTL)
	sid, err := NewSessionID()
	if err != nil {
		return nil, err
	}
	jti, err := NewJTI()
	if err != nil {
		return nil, err
	}
	_, secret, accessTTL, _ := jwtSecrets()
	refreshRaw, err := signRefresh(u, sid, jti)
	if err != nil {
		return nil, err
	}
	accessRaw, err := signAccess(u, sid)
	if err != nil {
		return nil, err
	}
	if len(ip) > 64 {
		ip = ip[:64]
	}
	if len(userAgent) > 255 {
		userAgent = userAgent[:255]
	}
	row := models.AuthSession{
		UserID:       u.ID,
		SessionID:    sid,
		DeviceID:     dev.DeviceID,
		DeviceName:   dev.DeviceName,
		Platform:     dev.Platform,
		IP:           ip,
		UserAgent:    userAgent,
		RefreshHash:  HmacHex(secret, refreshRaw),
		JTI:          jti,
		LastSeenAt:   now,
		RefreshAt:    now,
		IdleDeadline: now + idleTTL,
		TokenVersion: u.TokenVersion,
	}
	if err := database.DB.Create(&row).Error; err != nil {
		return nil, err
	}
	// users.last_login_at 保留（管理端列表在用），失败不影响登录主流程。
	nowTime := time.Now()
	if err := database.DB.Model(u).Update("last_login_at", &nowTime).Error; err != nil {
		log.Printf("[auth] 更新 last_login_at 失败 uid=%d: %v", u.ID, err)
	}
	return &Tokens{
		AccessToken:  accessRaw,
		RefreshToken: refreshRaw,
		ExpiresIn:    accessTTL,
		SessionID:    sid,
		IdleExpireAt: now + idleTTL,
	}, nil
}

// Issue 统一签发入口：建会话 + 可选签发设备授权凭据。
//
// 设备凭据签发失败只记日志、不阻断登录（降级到密码路径，绝不出现「无路可走」）。
func (s *SessionService) Issue(u *models.User, dev DeviceInfo, ip, userAgent string, issueDevice bool) (*LoginBundle, error) {
	tokens, err := s.Create(u, dev, ip, userAgent)
	if err != nil {
		return nil, err
	}
	bundle := &LoginBundle{Tokens: *tokens}
	if issueDevice && dev.DeviceID != "" && dev.Platform != "web" {
		raw, err := Devices().Issue(u, dev)
		if err != nil {
			log.Printf("[auth] 签发设备凭据失败 uid=%d device=%s: %v", u.ID, dev.DeviceID, err)
		} else {
			bundle.DeviceToken = raw
		}
	}
	return bundle, nil
}

// Rotate refresh 轮换 + 120s 宽限 + 重放撤销（DESIGN §A.3）。
//
// 三条分支：
//  1. fp == RefreshHash        → 正常轮换，prev 记住旧 fp、开 120s 宽限
//  2. fp == PrevRefreshHash 且宽限内 → 弱网重试，再轮换一次（prev 只保留一层）
//  3. 其它（含超宽限旧 fp / 未知指纹）→ 判重放并撤销会话
//
// legacy 分支：会话 DeviceID 为空（v0.4.1 客户端不传 deviceId，也不落盘新 refresh）
// 时**不轮换**，只回新 access，避免 120s 后被判重放把老用户每 30 分钟踢一次。
func (s *SessionService) Rotate(sid, rawRefresh string) (*Tokens, error) {
	if database.DB == nil {
		return nil, ErrSessionRevoked
	}
	var row models.AuthSession
	if err := database.DB.Unscoped().Where("session_id = ?", sid).First(&row).Error; err != nil {
		return nil, ErrSessionNotFound
	}
	if row.RevokedAt != nil || row.DeletedAt.Valid {
		return nil, ErrSessionRevoked
	}
	now := time.Now().Unix()
	idleTTL := int64(config.AuthParams().SessionIdleTTL)
	if now > row.LastSeenAt+idleTTL {
		s.Revoke(sid, ReasonIdle)
		return nil, ErrSessionIdle
	}
	var u models.User
	if err := database.DB.First(&u, row.UserID).Error; err != nil {
		return nil, ErrSessionRevoked
	}
	if u.Disabled {
		return nil, ErrUserDisabled
	}
	if u.TokenVersion != row.TokenVersion {
		s.Revoke(sid, ReasonPasswordChange)
		return nil, ErrSessionRevoked
	}
	if row.DeviceID == "" {
		return s.issueAccessOnly(&row, &u, now, idleTTL)
	}

	_, secret, accessTTL, _ := jwtSecrets()
	fp := HmacHex(secret, rawRefresh)
	newRaw, newJTI, newHash, err := s.newRefresh(&u, sid)
	if err != nil {
		return nil, err
	}
	grace := now + int64(config.AuthParams().RefreshGraceSec)
	deadline := now + idleTTL

	var updates map[string]any
	switch {
	case fp == row.RefreshHash:
		updates = map[string]any{
			"prev_refresh_hash": row.RefreshHash,
			"prev_valid_until":  grace,
			"refresh_hash":      newHash,
			"jti":               newJTI,
			"refresh_at":        now,
			"last_seen_at":      now,
			"idle_deadline":     deadline,
		}
	case fp == row.PrevRefreshHash && row.PrevRefreshHash != "" && now < row.PrevValidUntil:
		// prev 保持原值（只保留一层），只把宽限窗口顺延，不累积历史代次。
		updates = map[string]any{
			"prev_valid_until": grace,
			"refresh_hash":     newHash,
			"jti":              newJTI,
			"refresh_at":       now,
			"last_seen_at":     now,
			"idle_deadline":    deadline,
		}
	default:
		s.Revoke(sid, ReasonRefreshReplay)
		return nil, ErrSessionRevoked
	}
	if err := database.DB.Model(&models.AuthSession{}).Where("id = ?", row.ID).Updates(updates).Error; err != nil {
		return nil, err
	}
	R().Invalidate(sid)
	access, err := signAccess(&u, sid)
	if err != nil {
		return nil, err
	}
	return &Tokens{
		AccessToken:  access,
		RefreshToken: newRaw,
		ExpiresIn:    accessTTL,
		SessionID:    sid,
		IdleExpireAt: deadline,
	}, nil
}

// issueAccessOnly legacy 分支：不轮换、不发新 refresh，保持 v0.4.1 响应形状。
func (s *SessionService) issueAccessOnly(row *models.AuthSession, u *models.User, now, idleTTL int64) (*Tokens, error) {
	access, err := signAccess(u, row.SessionID)
	if err != nil {
		return nil, err
	}
	// refresh 是低频操作，这里直接落一次 last_seen（不是「每请求写库」）。
	if err := database.DB.Model(&models.AuthSession{}).Where("id = ?", row.ID).
		Updates(map[string]any{"last_seen_at": now, "idle_deadline": now + idleTTL}).Error; err != nil {
		log.Printf("[auth] legacy refresh 更新会话失败: %v", err)
	}
	R().Invalidate(row.SessionID)
	_, _, accessTTL, _ := jwtSecrets()
	return &Tokens{
		AccessToken:  access,
		RefreshToken: "",
		ExpiresIn:    accessTTL,
		SessionID:    row.SessionID,
		IdleExpireAt: now + idleTTL,
	}, nil
}

// Revoke 撤销单条会话（DB + 内存双写，立即生效）。
func (s *SessionService) Revoke(sid, reason string) {
	if sid == "" || database.DB == nil {
		return
	}
	now := time.Now().Unix()
	if err := database.DB.Model(&models.AuthSession{}).
		Where("session_id = ? AND revoked_at IS NULL", sid).
		Updates(map[string]any{"revoked_at": now, "revoked_reason": reason}).Error; err != nil {
		log.Printf("[auth] 撤销会话失败 sid=%s: %v", sid, err)
	}
	R().Invalidate(sid)
}

// RevokeAll 撤销某用户的全部会话（改密 / 停用 / 删除 / 撤销全部设备）。
func (s *SessionService) RevokeAll(userID uint64, reason string) int64 {
	if database.DB == nil {
		return 0
	}
	now := time.Now().Unix()
	res := database.DB.Model(&models.AuthSession{}).
		Where("user_id = ? AND revoked_at IS NULL", userID).
		Updates(map[string]any{"revoked_at": now, "revoked_reason": reason})
	if res.Error != nil {
		log.Printf("[auth] 撤销全部会话失败 uid=%d: %v", userID, res.Error)
		return 0
	}
	R().InvalidateAll()
	return res.RowsAffected
}

// RevokeByDeviceID 撤销某用户某设备下的全部会话。
func (s *SessionService) RevokeByDeviceID(userID uint64, deviceID, reason string) int64 {
	if database.DB == nil {
		return 0
	}
	now := time.Now().Unix()
	res := database.DB.Model(&models.AuthSession{}).
		Where("user_id = ? AND device_id = ? AND revoked_at IS NULL", userID, deviceID).
		Updates(map[string]any{"revoked_at": now, "revoked_reason": reason})
	if res.Error != nil {
		log.Printf("[auth] 按设备撤销会话失败 uid=%d: %v", userID, res.Error)
		return 0
	}
	R().InvalidateAll()
	return res.RowsAffected
}

// RevokeOthers 撤销除 keepDeviceID 之外的全部会话。
func (s *SessionService) RevokeOthers(userID uint64, keepDeviceID, reason string) int64 {
	if database.DB == nil {
		return 0
	}
	now := time.Now().Unix()
	q := database.DB.Model(&models.AuthSession{}).
		Where("user_id = ? AND revoked_at IS NULL", userID)
	if keepDeviceID != "" {
		q = q.Where("device_id <> ?", keepDeviceID)
	}
	res := q.Updates(map[string]any{"revoked_at": now, "revoked_reason": reason})
	if res.Error != nil {
		log.Printf("[auth] 撤销其他设备会话失败 uid=%d: %v", userID, res.Error)
		return 0
	}
	R().InvalidateAll()
	return res.RowsAffected
}

// ListByUser 设备列表：同一 deviceId 多条会话时按 last_seen 聚合，只返回最新一条。
func (s *SessionService) ListByUser(userID uint64, currentSID string) []DeviceView {
	out := make([]DeviceView, 0)
	if database.DB == nil {
		return out
	}
	var rows []models.AuthSession
	if err := database.DB.Unscoped().
		Where("user_id = ? AND revoked_at IS NULL AND deleted_at IS NULL", userID).
		Order("last_seen_at DESC").Find(&rows).Error; err != nil {
		log.Printf("[auth] 查询设备列表失败 uid=%d: %v", userID, err)
		return out
	}
	seen := make(map[string]bool)
	now := time.Now().Unix()
	for _, r := range rows {
		key := r.DeviceID
		if key == "" {
			key = "legacy-" + strconv.FormatUint(r.ID, 10)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		var credCount int64
		if r.DeviceID != "" {
			if err := database.DB.Model(&models.DeviceCredential{}).
				Where("user_id = ? AND device_id = ? AND revoked_at IS NULL AND expires_at > ?", userID, r.DeviceID, now).
				Count(&credCount).Error; err != nil {
				log.Printf("[auth] 查询设备凭据失败 uid=%d: %v", userID, err)
			}
		}
		out = append(out, DeviceView{
			ID:                  r.ID,
			SessionID:           r.SessionID,
			DeviceID:            r.DeviceID,
			DeviceName:          r.DeviceName,
			Platform:            r.Platform,
			LastSeenAt:          r.LastSeenAt,
			Current:             r.SessionID == currentSID,
			HasDeviceCredential: credCount > 0,
		})
	}
	return out
}

// SessionByID 按主键取会话（设备撤销接口用；不做用户归属判断，由 handler 校验）。
func (s *SessionService) SessionByID(id uint64) (models.AuthSession, error) {
	var row models.AuthSession
	if database.DB == nil {
		return row, gorm.ErrRecordNotFound
	}
	err := database.DB.First(&row, id).Error
	return row, err
}
