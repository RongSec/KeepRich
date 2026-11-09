// Package auth v0.5.0 会话 / 设备凭据 / 邀请码的领域服务。
//
// 依赖方向：auth → models / database / utils / config，**不 import gin**，
// 与 internal/backup 同风格；handler 只做协议转换（DESIGN §2.A.1）。
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
)

// DeviceTokenPrefix 设备凭据明文前缀。它不是 JWT，过不了 middleware.JWT() 的验签，
// 天然把「能力」限定在 POST /api/auth/device-login 一个入口。
const DeviceTokenPrefix = "dvc_"

// randomString 生成 n 字节密码学随机数并编码为 base64url（无 padding）。
func randomString(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// NewOpaqueToken 设备授权凭据明文（32B → 43 字符 base64url）。
// 明文只在签发响应里返回一次，服务端只落 HmacHex 指纹。
func NewOpaqueToken() (string, error) {
	s, err := randomString(32)
	if err != nil {
		return "", err
	}
	return DeviceTokenPrefix + s, nil
}

// NewSessionID 会话标识：24B → 32 字符 base64url，进 JWT 的 sid claim。
func NewSessionID() (string, error) {
	return randomString(24)
}

// NewJTI 当前 refresh 的轮换标识（日志排查用，非安全依赖）。
func NewJTI() (string, error) {
	return randomString(16)
}

// HmacHex 返回 HMAC-SHA256 的十六进制字符串（64 字符）。
// refresh / 设备凭据都只存这个值，明文永不入库，也永不进日志。
func HmacHex(secret, raw string) string {
	m := hmac.New(sha256.New, []byte(secret))
	_, _ = m.Write([]byte(raw))
	return hex.EncodeToString(m.Sum(nil))
}
