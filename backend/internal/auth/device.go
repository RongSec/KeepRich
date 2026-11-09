package auth

import (
	"errors"
	"log"
	"time"

	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
)

// ErrDeviceInvalid 设备凭据无效 / 过期 / 撤销（handler 映射成 40112 中文文案）。
var ErrDeviceInvalid = errors.New("device credential invalid")

// DeviceService 设备授权凭据服务（无状态）。
type DeviceService struct{}

// Devices 返回服务实例。
func Devices() *DeviceService { return &DeviceService{} }

func deviceSecret() string {
	access, _, _, _ := jwtSecrets()
	return access
}

// Issue 签发设备凭据：同 (user, deviceId) 覆盖为一行，旧明文立即失效。
//
// 仅当 platform != web 且 deviceId 非空时由调用方触发；Web 不签发（PRD §0.3）。
// 服务端只写 HmacHex(accessSecret, deviceToken)，明文只随响应返回一次。
func (s *DeviceService) Issue(u *models.User, dev DeviceInfo) (string, error) {
	if u == nil || dev.DeviceID == "" || dev.Platform == "web" || database.DB == nil {
		return "", nil
	}
	raw, err := NewOpaqueToken()
	if err != nil {
		return "", err
	}
	hash := HmacHex(deviceSecret(), raw)
	now := time.Now().Unix()
	expires := now + int64(config.AuthParams().DeviceIdleTTL)

	var existing models.DeviceCredential
	err = database.DB.Unscoped().
		Where("user_id = ? AND device_id = ?", u.ID, dev.DeviceID).First(&existing).Error
	if err == nil {
		updates := map[string]any{
			"credential_hash": hash,
			"device_name":     dev.DeviceName,
			"platform":        dev.Platform,
			"last_used_at":    now,
			"expires_at":      expires,
			"revoked_at":      nil,
			"revoked_reason":  "",
			"deleted_at":      nil,
		}
		if err := database.DB.Unscoped().Model(&models.DeviceCredential{}).
			Where("id = ?", existing.ID).Updates(updates).Error; err != nil {
			return "", err
		}
		return raw, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return "", err
	}
	row := models.DeviceCredential{
		UserID:         u.ID,
		DeviceID:       dev.DeviceID,
		CredentialHash: hash,
		DeviceName:     dev.DeviceName,
		Platform:       dev.Platform,
		LastUsedAt:     now,
		ExpiresAt:      expires,
	}
	if err := database.DB.Create(&row).Error; err != nil {
		return "", err
	}
	return raw, nil
}

// Validate 校验设备凭据并续期 30 天（使用即续期，**不轮换**：弱网丢响应会让用户
// 永久丢失指纹入口；30 天闲置 + 可撤销已把暴露面收得足够小，DESIGN §B.2 / R6）。
func (s *DeviceService) Validate(rawToken, deviceID string) (*models.User, error) {
	if rawToken == "" || deviceID == "" || database.DB == nil {
		return nil, ErrDeviceInvalid
	}
	hash := HmacHex(deviceSecret(), rawToken)
	var cred models.DeviceCredential
	if err := database.DB.Unscoped().
		Where("credential_hash = ? AND device_id = ?", hash, deviceID).First(&cred).Error; err != nil {
		return nil, ErrDeviceInvalid
	}
	if cred.DeletedAt.Valid || !cred.Usable(time.Now().Unix()) {
		return nil, ErrDeviceInvalid
	}
	var u models.User
	if err := database.DB.First(&u, cred.UserID).Error; err != nil {
		return nil, ErrDeviceInvalid
	}
	if u.Disabled {
		return nil, ErrUserDisabled
	}
	now := time.Now().Unix()
	if err := database.DB.Model(&models.DeviceCredential{}).Where("id = ?", cred.ID).
		Updates(map[string]any{
			"last_used_at": now,
			"expires_at":   now + int64(config.AuthParams().DeviceIdleTTL),
		}).Error; err != nil {
		log.Printf("[auth] 设备凭据续期失败 id=%d: %v", cred.ID, err)
	}
	return &u, nil
}

// RevokeByDevice 撤销该 (user, deviceId) 的**会话与凭据一起**（否则指纹会立刻把人登回去）。
func (s *DeviceService) RevokeByDevice(userID uint64, deviceID, reason string) (int64, int64) {
	sessionCount := Sessions().RevokeByDeviceID(userID, deviceID, reason)
	credCount := int64(0)
	if database.DB != nil {
		now := time.Now().Unix()
		res := database.DB.Model(&models.DeviceCredential{}).
			Where("user_id = ? AND device_id = ? AND revoked_at IS NULL", userID, deviceID).
			Updates(map[string]any{"revoked_at": now, "revoked_reason": reason})
		if res.Error != nil {
			log.Printf("[auth] 撤销设备凭据失败 uid=%d: %v", userID, res.Error)
		} else {
			credCount = res.RowsAffected
		}
	}
	R().InvalidateAll()
	return sessionCount, credCount
}

// RevokeOthers 撤销除 keepDeviceID 之外的全部设备会话与凭据（当前设备保留）。
func (s *DeviceService) RevokeOthers(userID uint64, keepDeviceID, reason string) int64 {
	count := Sessions().RevokeOthers(userID, keepDeviceID, reason)
	if database.DB != nil {
		now := time.Now().Unix()
		q := database.DB.Model(&models.DeviceCredential{}).
			Where("user_id = ? AND revoked_at IS NULL", userID)
		if keepDeviceID != "" {
			q = q.Where("device_id <> ?", keepDeviceID)
		}
		if err := q.Updates(map[string]any{"revoked_at": now, "revoked_reason": reason}).Error; err != nil {
			log.Printf("[auth] 撤销其他设备凭据失败 uid=%d: %v", userID, err)
		}
	}
	R().InvalidateAll()
	return count
}

// RevokeAll 撤销用户全部会话与设备凭据（改密 / 停用 / 删除）。
func (s *DeviceService) RevokeAll(userID uint64, reason string) int64 {
	count := Sessions().RevokeAll(userID, reason)
	if database.DB != nil {
		now := time.Now().Unix()
		if err := database.DB.Model(&models.DeviceCredential{}).
			Where("user_id = ? AND revoked_at IS NULL", userID).
			Updates(map[string]any{"revoked_at": now, "revoked_reason": reason}).Error; err != nil {
			log.Printf("[auth] 撤销全部设备凭据失败 uid=%d: %v", userID, err)
		}
	}
	R().InvalidateAll()
	return count
}
