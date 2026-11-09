package config

import (
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/spf13/viper"
)

type AppConfig struct {
	Name     string `mapstructure:"name"`
	Env      string `mapstructure:"env"`
	Port     int    `mapstructure:"port"`
	Timezone string `mapstructure:"timezone"`
	// GitHub 仓库（owner/repo）：设置后 App 在线更新从 Releases 拉取
	GitHubRepo string `mapstructure:"githubRepo"`
	// 云托管分享码：网关要求每个请求带 ?sharecode=，且会在转发前把它吃掉，
	// 导致后端无法从请求里取到。配置后可在 /api/app/version 里回一个
	// 「带码的绝对下载地址」，让 v0.4.0 及更早的客户端也能更新。
	ShareCode string `mapstructure:"shareCode"`
}

type DatabaseConfig struct {
	Host      string `mapstructure:"host"`
	Port      int    `mapstructure:"port"`
	User      string `mapstructure:"user"`
	Password  string `mapstructure:"password"`
	Name      string `mapstructure:"name"`
	Charset   string `mapstructure:"charset"`
	ParseTime bool   `mapstructure:"parseTime"`
	Loc       string `mapstructure:"loc"`
}

type JWTConfig struct {
	AccessSecret  string `mapstructure:"accessSecret"`
	RefreshSecret string `mapstructure:"refreshSecret"`
	AccessTTL     int    `mapstructure:"accessTTL"`
	RefreshTTL    int    `mapstructure:"refreshTTL"`
}

// AuthConfig v0.5.0 会话 / 设备凭据 / 邀请码时效参数。
//
// 全部是纯数值，**不含任何密钥**（可入库）。隐患 6.1 的解法：时效语义收敛到一处，
// Validate() 统一夹取默认值，避免配成 0 导致「登录成功但下一次请求 401」。
type AuthConfig struct {
	SessionIdleTTL  int `mapstructure:"sessionIdleTTL"`  // 24h 不活跃失效（严格 0 容差）
	RefreshGraceSec int `mapstructure:"refreshGraceSec"` // 旧 refresh 轮换宽限 120s
	TouchFlushSec   int `mapstructure:"touchFlushSec"`   // last_seen 批量刷盘间隔 60s
	DeviceIdleTTL   int `mapstructure:"deviceIdleTTL"`   // 设备凭据 30 天闲置失效
	SoftPushMinSec  int `mapstructure:"softPushMinSec"`  // cloudsync soft 推送节流 600s
	RegisterIPLimit int `mapstructure:"registerIPLimit"` // 同 IP 注册尝试 10 次/小时
	InviteTTLDays   int `mapstructure:"inviteTTLDays"`   // 邀请码默认有效期 7 天
	InviteMaxUses   int `mapstructure:"inviteMaxUses"`   // 邀请码默认配额 1 次
}

// DefaultAuthConfig 返回全套默认值。
//
// 单独抽出来的原因：单测里 config.C 可能为 nil（没有走 Load()），
// 所有读取点统一走 AuthParams()，避免 nil 解引用把测试打挂。
func DefaultAuthConfig() AuthConfig {
	return AuthConfig{
		SessionIdleTTL:  86400,
		RefreshGraceSec: 120,
		TouchFlushSec:   60,
		DeviceIdleTTL:   2592000,
		SoftPushMinSec:  600,
		RegisterIPLimit: 10,
		InviteTTLDays:   7,
		InviteMaxUses:   1,
	}
}

// AuthParams 安全读取认证参数：未初始化时回落到默认值。
func AuthParams() AuthConfig {
	if C == nil {
		return DefaultAuthConfig()
	}
	return C.Auth
}

type MFAConfig struct {
	Issuer       string `mapstructure:"issuer"`
	CooldownDays int    `mapstructure:"cooldownDays"`
}

type NotifyConfig struct {
	WSEnabled    bool   `mapstructure:"wsEnabled"`
	FCMEnabled   bool   `mapstructure:"fcmEnabled"`
	FCMServerKey string `mapstructure:"fcmServerKey"`
}

type PlanConfig struct {
	EmergencyTarget  float64 `mapstructure:"emergencyTarget"`
	PensionTarget    float64 `mapstructure:"pensionTarget"`
	BigPurchaseRatio float64 `mapstructure:"bigPurchaseRatio"`
	InvestAnnualRate float64 `mapstructure:"investAnnualRate"`
}

// CloudSyncConfig 云端快照同步配置（DESIGN v0.4.0 §2.E.1）。
//
// ⚠️ 真实 apiKey **永不入库**：config.yaml 里只有 enabled:false 或干脆没有这一节，
// 真实值来自不入库的 sidecar（config/cloudsync.local.yaml，由 cloud/sync.sh 注入）
// 或环境变量（CLOUD_SYNC_*）。仓库是公开的，任何真实 key 写进受控文件都是事故。
type CloudSyncConfig struct {
	Enabled  bool   `mapstructure:"enabled"`
	Endpoint string `mapstructure:"endpoint"` // 含表名的完整 REST URL
	APIKey   string `mapstructure:"apiKey"`
	// SnapshotID 云端快照行主键。默认 1；测试时可用 999 而不污染线上那行。
	SnapshotID     int64    `mapstructure:"snapshotId"`
	DebounceMS     int      `mapstructure:"debounceMs"`     // 默认 1500
	PushTimeoutSec int      `mapstructure:"pushTimeoutSec"` // 默认 5
	ExcludeTables  []string `mapstructure:"excludeTables"`  // 默认 ["audit_logs","error_reports"]
}

type Config struct {
	App       AppConfig       `mapstructure:"app"`
	Database  DatabaseConfig  `mapstructure:"database"`
	JWT       JWTConfig       `mapstructure:"jwt"`
	Auth      AuthConfig      `mapstructure:"auth"`
	MFA       MFAConfig       `mapstructure:"mfa"`
	Notify    NotifyConfig    `mapstructure:"notify"`
	Plan      PlanConfig      `mapstructure:"plan"`
	CloudSync CloudSyncConfig `mapstructure:"cloudSync"`
}

var C *Config

// Load 加载配置：先读 config/config.yaml，再被环境变量覆盖。
func Load() error {
	viper.SetConfigName("config")
	viper.SetConfigType("yaml")
	viper.AddConfigPath("./config")
	viper.AddConfigPath(".")

	viper.SetEnvPrefix("APP")
	viper.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	viper.AutomaticEnv()

	// 兼容环境变量直接覆盖常见字段
	_ = viper.BindEnv("app.port", "APP_PORT", "PORT") // PORT：云托管沙箱注入的监听端口
	_ = viper.BindEnv("app.githubRepo", "GITHUB_REPO")
	_ = viper.BindEnv("app.env", "APP_ENV")
	_ = viper.BindEnv("database.host", "DB_HOST")
	_ = viper.BindEnv("database.port", "DB_PORT")
	_ = viper.BindEnv("database.user", "DB_USER")
	_ = viper.BindEnv("database.password", "DB_PASSWORD")
	_ = viper.BindEnv("database.name", "DB_NAME")
	_ = viper.BindEnv("jwt.accessSecret", "JWT_ACCESS_SECRET")
	_ = viper.BindEnv("jwt.refreshSecret", "JWT_REFRESH_SECRET")
	_ = viper.BindEnv("jwt.accessTTL", "JWT_ACCESS_TTL")
	_ = viper.BindEnv("jwt.refreshTTL", "JWT_REFRESH_TTL")
	_ = viper.BindEnv("mfa.cooldownDays", "MFA_COOLDOWN_DAYS")
	_ = viper.BindEnv("notify.fcmServerKey", "FCM_SERVER_KEY")
	// v0.5.0 认证时效：显式 BindEnv，便于本地验收把 24h 窗口/刷盘间隔缩短模拟。
	_ = viper.BindEnv("auth.sessionIdleTTL", "AUTH_SESSION_IDLE_TTL")
	_ = viper.BindEnv("auth.refreshGraceSec", "AUTH_REFRESH_GRACE_SEC")
	_ = viper.BindEnv("auth.touchFlushSec", "AUTH_TOUCH_FLUSH_SEC")
	_ = viper.BindEnv("auth.deviceIdleTTL", "AUTH_DEVICE_IDLE_TTL")
	_ = viper.BindEnv("auth.softPushMinSec", "AUTH_SOFT_PUSH_MIN_SEC")
	_ = viper.BindEnv("auth.registerIPLimit", "AUTH_REGISTER_IP_LIMIT")
	_ = viper.BindEnv("auth.inviteTTLDays", "AUTH_INVITE_TTL_DAYS")
	_ = viper.BindEnv("auth.inviteMaxUses", "AUTH_INVITE_MAX_USES")
	// 云端快照：环境变量优先级最高（应急覆盖，不用改文件）
	_ = viper.BindEnv("cloudSync.enabled", "CLOUD_SYNC_ENABLED")
	_ = viper.BindEnv("cloudSync.endpoint", "CLOUD_SYNC_ENDPOINT")
	_ = viper.BindEnv("cloudSync.apiKey", "CLOUD_SYNC_API_KEY")
	_ = viper.BindEnv("cloudSync.snapshotId", "CLOUD_SYNC_SNAPSHOT_ID")

	if err := viper.ReadInConfig(); err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	// 密钥 sidecar：本地/部署目录里不入库的 cloudsync.local.yaml。
	// 用 MergeConfig(io.Reader) 而**不是** SetConfigFile —— 后者会把已读到的
	// config.yaml 换掉，导致 app/jwt 等字段全丢（DESIGN §2.E.1）。
	for _, p := range []string{"./config/cloudsync.local.yaml", "./cloudsync.local.yaml"} {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		if err := viper.MergeConfig(f); err != nil {
			_ = f.Close()
			log.Printf("[config][WARN] merge sidecar %s: %v", p, err)
			continue
		}
		_ = f.Close()
		log.Printf("[config] merged sidecar %s", p)
		break
	}

	C = &Config{}
	if err := viper.Unmarshal(C); err != nil {
		return fmt.Errorf("unmarshal config: %w", err)
	}
	return C.Validate()
}

// clampPositive 把 <=0 的配置值夹取回默认值并打 WARN（服务照常启动，绝不 fatal）。
func clampPositive(v, def int, name string) int {
	if v > 0 {
		return v
	}
	fmt.Printf("[config][WARN] %s 缺失或非正数(%d)，已回退默认值 %d\n", name, v, def)
	return def
}

// Validate 启动校验：生产环境禁止使用默认/空 JWT 密钥（防止 token 伪造）
func (c *Config) Validate() error {
	// ---- v0.5.0：时效参数统一夹取（隐患 6.1）----
	d := DefaultAuthConfig()
	c.Auth.SessionIdleTTL = clampPositive(c.Auth.SessionIdleTTL, d.SessionIdleTTL, "auth.sessionIdleTTL")
	c.Auth.RefreshGraceSec = clampPositive(c.Auth.RefreshGraceSec, d.RefreshGraceSec, "auth.refreshGraceSec")
	c.Auth.TouchFlushSec = clampPositive(c.Auth.TouchFlushSec, d.TouchFlushSec, "auth.touchFlushSec")
	c.Auth.DeviceIdleTTL = clampPositive(c.Auth.DeviceIdleTTL, d.DeviceIdleTTL, "auth.deviceIdleTTL")
	c.Auth.SoftPushMinSec = clampPositive(c.Auth.SoftPushMinSec, d.SoftPushMinSec, "auth.softPushMinSec")
	c.Auth.RegisterIPLimit = clampPositive(c.Auth.RegisterIPLimit, d.RegisterIPLimit, "auth.registerIPLimit")
	c.Auth.InviteTTLDays = clampPositive(c.Auth.InviteTTLDays, d.InviteTTLDays, "auth.inviteTTLDays")
	c.Auth.InviteMaxUses = clampPositive(c.Auth.InviteMaxUses, d.InviteMaxUses, "auth.inviteMaxUses")
	if c.JWT.AccessTTL <= 0 {
		fmt.Printf("[config][WARN] jwt.accessTTL 无效(%d)，已回退默认值 900\n", c.JWT.AccessTTL)
		c.JWT.AccessTTL = 900
	}
	if c.JWT.RefreshTTL <= 0 {
		fmt.Printf("[config][WARN] jwt.refreshTTL 无效(%d)，已回退默认值 %d\n", c.JWT.RefreshTTL, d.SessionIdleTTL)
		c.JWT.RefreshTTL = d.SessionIdleTTL
	}

	devSecrets := map[string]string{
		"dev-access-secret":  c.JWT.AccessSecret,
		"dev-refresh-secret": c.JWT.RefreshSecret,
	}
	isDevDefault := false
	for def, actual := range devSecrets {
		if actual == def || actual == "" {
			isDevDefault = true
		}
	}
	if isDevDefault {
		if c.App.Env == "production" {
			return fmt.Errorf("jwt 密钥仍为默认开发值，生产环境必须通过 JWT_ACCESS_SECRET / JWT_REFRESH_SECRET 环境变量注入强随机密钥")
		}
		fmt.Println("[config][WARN] JWT 密钥为开发默认值，仅限本地开发使用；部署生产前必须更换")
	}

	// ---- 云端快照同步：降级而不是 fatal ----
	// 配错密钥绝不能让服务起不来（R-02 ② / §6.4）：降级为 disabled 并打 WARN，
	// 代价只是"数据不持久化"，而不是"整个服务不可用"。
	if c.CloudSync.Enabled && (c.CloudSync.Endpoint == "" || c.CloudSync.APIKey == "") {
		fmt.Println("[config][WARN] cloudSync 已启用但 endpoint/apiKey 缺失 → 自动降级为 disabled（数据不会持久化）")
		c.CloudSync.Enabled = false
	}
	if c.CloudSync.SnapshotID <= 0 {
		c.CloudSync.SnapshotID = 1
	}
	if c.CloudSync.DebounceMS <= 0 {
		c.CloudSync.DebounceMS = 1500
	}
	if c.CloudSync.PushTimeoutSec <= 0 {
		c.CloudSync.PushTimeoutSec = 5
	}
	if len(c.CloudSync.ExcludeTables) == 0 {
		c.CloudSync.ExcludeTables = []string{"audit_logs", "error_reports"}
	}
	return nil
}
