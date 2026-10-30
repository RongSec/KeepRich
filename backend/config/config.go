package config

import (
	"fmt"
	"strings"

	"github.com/spf13/viper"
)

type AppConfig struct {
	Name     string `mapstructure:"name"`
	Env      string `mapstructure:"env"`
	Port     int    `mapstructure:"port"`
	Timezone string `mapstructure:"timezone"`
}

type DatabaseConfig struct {
	Host     string `mapstructure:"host"`
	Port     int    `mapstructure:"port"`
	User     string `mapstructure:"user"`
	Password string `mapstructure:"password"`
	Name     string `mapstructure:"name"`
	Charset  string `mapstructure:"charset"`
	ParseTime bool  `mapstructure:"parseTime"`
	Loc      string `mapstructure:"loc"`
}

type JWTConfig struct {
	AccessSecret  string `mapstructure:"accessSecret"`
	RefreshSecret string `mapstructure:"refreshSecret"`
	AccessTTL     int    `mapstructure:"accessTTL"`
	RefreshTTL    int    `mapstructure:"refreshTTL"`
}

type MFAConfig struct {
	Issuer       string `mapstructure:"issuer"`
	CooldownDays int    `mapstructure:"cooldownDays"`
}

type NotifyConfig struct {
	WSEnabled   bool   `mapstructure:"wsEnabled"`
	FCMEnabled  bool   `mapstructure:"fcmEnabled"`
	FCMServerKey string `mapstructure:"fcmServerKey"`
}

type PlanConfig struct {
	EmergencyTarget float64 `mapstructure:"emergencyTarget"`
	PensionTarget   float64 `mapstructure:"pensionTarget"`
	BigPurchaseRatio float64 `mapstructure:"bigPurchaseRatio"`
	InvestAnnualRate float64 `mapstructure:"investAnnualRate"`
}

type Config struct {
	App      AppConfig      `mapstructure:"app"`
	Database DatabaseConfig `mapstructure:"database"`
	JWT      JWTConfig      `mapstructure:"jwt"`
	MFA      MFAConfig      `mapstructure:"mfa"`
	Notify   NotifyConfig   `mapstructure:"notify"`
	Plan     PlanConfig     `mapstructure:"plan"`
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
	_ = viper.BindEnv("app.port", "APP_PORT")
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

	if err := viper.ReadInConfig(); err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	C = &Config{}
	if err := viper.Unmarshal(C); err != nil {
		return fmt.Errorf("unmarshal config: %w", err)
	}
	return C.Validate()
}

// Validate 启动校验：生产环境禁止使用默认/空 JWT 密钥（防止 token 伪造）
func (c *Config) Validate() error {
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
	return nil
}
