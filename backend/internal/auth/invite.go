package auth

import (
	"errors"
	"time"

	"github.com/yourname/family-finance/backend/config"
	"github.com/yourname/family-finance/backend/internal/database"
	"github.com/yourname/family-finance/backend/internal/models"
	"github.com/yourname/family-finance/backend/internal/utils"
	"gorm.io/gorm"
)

// 邀请码领域错误（handler 统一映射成中文，绝不透传 err.Error()）。
var (
	ErrInviteNotFound        = errors.New("invite not found")
	ErrInviteRevoked         = errors.New("invite revoked")
	ErrInviteExpired         = errors.New("invite expired")
	ErrInviteExhausted       = errors.New("invite exhausted")
	ErrInviteCollision       = errors.New("invite code collision")
	ErrUsernameTaken         = errors.New("username taken")
	ErrInviteUsedNoRevoke    = errors.New("invite used, cannot revoke")
	ErrInviteExpiredNoRevoke = errors.New("invite expired, cannot revoke")
)

// InviteService 邀请码服务（无状态）。
type InviteService struct{}

// Invites 返回服务实例。
func Invites() *InviteService { return &InviteService{} }

// CreateInviteParams 发码参数（已由 handler 校验过范围，这里再做一次兜底夹取）。
type CreateInviteParams struct {
	AdminID       uint64
	Count         int
	MaxUses       int
	ExpiresInDays int
	Note          string
}

// InviteFilter 管理端列表筛选。
type InviteFilter struct {
	Status  string
	Keyword string
	Page    int
	Size    int
}

// InviteUsageView 使用者展示项（不含 IP / UA）。
type InviteUsageView struct {
	UserID   uint64 `json:"userId"`
	Username string `json:"username"`
	Nickname string `json:"nickname"`
	UsedAt   int64  `json:"usedAt"`
}

// InviteView 管理端列表项（DTO，只回展示字段）。
type InviteView struct {
	ID        uint64            `json:"id"`
	Code      string            `json:"code"`
	Note      string            `json:"note"`
	MaxUses   int               `json:"maxUses"`
	UsedCount int               `json:"usedCount"`
	ExpiresAt int64             `json:"expiresAt"`
	RevokedAt *int64            `json:"revokedAt"`
	Status    string            `json:"status"`
	CreatedBy uint64            `json:"createdBy"`
	CreatedAt int64             `json:"createdAt"`
	Usages    []InviteUsageView `json:"usages"`
}

// Create 批量生成邀请码：服务端生成 8 位、不可自定义、循环重试避碰。
func (s *InviteService) Create(p CreateInviteParams) ([]models.InviteCode, error) {
	if database.DB == nil {
		return nil, errors.New("invite: 数据库未初始化")
	}
	cfg := config.AuthParams()
	count := p.Count
	if count <= 0 || count > 5 {
		count = 1
	}
	maxUses := p.MaxUses
	if maxUses <= 0 {
		maxUses = cfg.InviteMaxUses
	}
	days := p.ExpiresInDays
	if days != 1 && days != 7 && days != 30 {
		days = 7
		if cfg.InviteTTLDays == 1 || cfg.InviteTTLDays == 30 {
			days = cfg.InviteTTLDays
		}
	}
	now := time.Now().Unix()
	expiresAt := now + int64(days)*86400
	out := make([]models.InviteCode, 0, count)
	for i := 0; i < count; i++ {
		code := ""
		for attempt := 0; attempt < 5; attempt++ {
			generated, err := utils.GenerateCode(8)
			if err != nil {
				return nil, err
			}
			var n int64
			if err := database.DB.Model(&models.InviteCode{}).Unscoped().
				Where("code = ?", generated).Count(&n).Error; err != nil {
				return nil, err
			}
			if n == 0 {
				code = generated
				break
			}
		}
		if code == "" {
			return nil, ErrInviteCollision
		}
		row := models.InviteCode{
			Code:      code,
			CreatedBy: p.AdminID,
			Note:      p.Note,
			MaxUses:   maxUses,
			ExpiresAt: expiresAt,
		}
		if err := database.DB.Create(&row).Error; err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, nil
}

// Precheck 注册前的只读预检（给用户精确文案）。真正判定在 ConsumeTx 的条件 UPDATE。
func (s *InviteService) Precheck(code string) (models.InviteCode, error) {
	var inv models.InviteCode
	if database.DB == nil {
		return inv, ErrInviteNotFound
	}
	if err := database.DB.Where("code = ?", code).First(&inv).Error; err != nil {
		return inv, ErrInviteNotFound
	}
	now := time.Now().Unix()
	if inv.RevokedAt != nil {
		return inv, ErrInviteRevoked
	}
	if inv.ExpiresAt > 0 && now > inv.ExpiresAt {
		return inv, ErrInviteExpired
	}
	if inv.UsedCount >= inv.MaxUses {
		return inv, ErrInviteExhausted
	}
	return inv, nil
}

// ConsumeTx 「抢配额 + 建用户 + 记 usage」同一个事务。
//
// 铁律（DESIGN §C.3）：
//  1. 只用**条件 UPDATE** 抢配额，绝不「先 SELECT 判可用再 +1」（并发会超发）；
//  2. fn 返回任何错误（含用户名冲突）都会 ROLLBACK，
//     配额自动归还，不会「占着名额报 409」；
//  3. used_count 用 SQL 表达式自增，不读进内存再写回。
//
// 20 个并发抢 maxUses=1 的码时，SQLite 单连接把事务串行化，恰好 1 个
// RowsAffected==1，其余全部 ROLLBACK → 恰好 1 个 200。
func (s *InviteService) ConsumeTx(code string, fn func(tx *gorm.DB, inv *models.InviteCode) error) error {
	if database.DB == nil {
		return ErrInviteNotFound
	}
	return database.DB.Transaction(func(tx *gorm.DB) error {
		var inv models.InviteCode
		if err := tx.Where("code = ?", code).First(&inv).Error; err != nil {
			return ErrInviteNotFound
		}
		now := time.Now().Unix()
		if inv.RevokedAt != nil {
			return ErrInviteRevoked
		}
		if inv.ExpiresAt > 0 && now > inv.ExpiresAt {
			return ErrInviteExpired
		}
		res := tx.Exec(`UPDATE invite_codes
		                   SET used_count = used_count + 1, updated_at = ?
		                 WHERE id = ? AND used_count < max_uses AND revoked_at IS NULL
		                   AND (expires_at = 0 OR expires_at > ?)`,
			time.Now(), inv.ID, now)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected != 1 {
			return ErrInviteExhausted
		}
		return fn(tx, &inv)
	})
}

// List 管理端列表：状态是派生值，取全量后在内存里过滤（小表、低频）。
func (s *InviteService) List(f InviteFilter) ([]InviteView, int64, error) {
	page, size := f.Page, f.Size
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 100 {
		size = 20
	}
	q := database.DB.Model(&models.InviteCode{})
	if f.Keyword != "" {
		kw := "%" + f.Keyword + "%"
		q = q.Where("code LIKE ? OR note LIKE ?", kw, kw)
	}
	var rows []models.InviteCode
	if err := q.Order("id DESC").Find(&rows).Error; err != nil {
		return nil, 0, err
	}
	now := time.Now().Unix()
	out := make([]InviteView, 0, len(rows))
	for _, r := range rows {
		status := r.Status(now)
		if f.Status != "" && f.Status != "all" && f.Status != status {
			continue
		}
		v := InviteView{
			ID:        r.ID,
			Code:      r.Code,
			Note:      r.Note,
			MaxUses:   r.MaxUses,
			UsedCount: r.UsedCount,
			ExpiresAt: r.ExpiresAt,
			RevokedAt: r.RevokedAt,
			Status:    status,
			CreatedBy: r.CreatedBy,
			CreatedAt: r.CreatedAt.Unix(),
			Usages:    make([]InviteUsageView, 0),
		}
		var usages []models.InviteCodeUsage
		if err := database.DB.Where("invite_code_id = ?", r.ID).Order("id ASC").Find(&usages).Error; err == nil {
			for _, u := range usages {
				var user models.User
				_ = database.DB.Unscoped().Select("id", "username", "nickname").First(&user, u.UserID).Error
				v.Usages = append(v.Usages, InviteUsageView{
					UserID: u.UserID, Username: user.Username, Nickname: user.Nickname, UsedAt: u.UsedAt,
				})
			}
		}
		out = append(out, v)
	}
	total := int64(len(out))
	start := (page - 1) * size
	if start >= len(out) {
		return []InviteView{}, total, nil
	}
	end := start + size
	if end > len(out) {
		end = len(out)
	}
	return out[start:end], total, nil
}

// Revoke 撤销未使用的邀请码（幂等；已使用 / 已过期不可撤销）。
func (s *InviteService) Revoke(id uint64, adminID uint64) (bool, error) {
	var inv models.InviteCode
	if err := database.DB.First(&inv, id).Error; err != nil {
		return false, ErrInviteNotFound
	}
	if inv.RevokedAt != nil {
		return true, nil
	}
	if inv.UsedCount > 0 {
		return false, ErrInviteUsedNoRevoke
	}
	now := time.Now().Unix()
	if inv.ExpiresAt > 0 && now > inv.ExpiresAt {
		return false, ErrInviteExpiredNoRevoke
	}
	if err := database.DB.Model(&models.InviteCode{}).Where("id = ?", inv.ID).
		Updates(map[string]any{"revoked_at": now, "revoked_by": adminID}).Error; err != nil {
		return false, err
	}
	return false, nil
}
