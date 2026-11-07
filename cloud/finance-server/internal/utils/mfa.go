package utils

import (
	"crypto/rand"
	"encoding/base32"
	"fmt"

	"github.com/pquerna/otp/totp"
)

// GenerateMFASecret 生成 base32 编码的 TOTP 密钥
func GenerateMFASecret() (string, error) {
	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(buf), nil
}

// BuildOTPAuthURI 生成 otpauth URI（用于二维码）
func BuildOTPAuthURI(secret, account, issuer string) string {
	return fmt.Sprintf("otpauth://totp/%s:%s?secret=%s&issuer=%s", issuer, account, secret, issuer)
}

// VerifyMFACode 校验 TOTP
func VerifyMFACode(secret, code string) bool {
	return totp.Validate(code, secret)
}
