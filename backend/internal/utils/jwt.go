package utils

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	TokenTypeAccess  = "access"
	TokenTypeRefresh = "refresh"
)

// Claims v0.5.0 起多带 sid / jti：
//   - sid：服务端会话标识（auth_sessions.session_id），老 token 为空 → 走 legacy 分支
//   - jti：当前 refresh 的轮换标识（只用于日志排查，安全判定靠 HMAC 指纹）
//
// 两个字段都带 omitempty：v0.4.1 的旧 token 形状完全不变，升级期不会把老用户踢下线。
type Claims struct {
	UID          uint64 `json:"uid"`
	Role         string `json:"role"`
	TokenType    string `json:"tokenType"`
	TokenVersion int    `json:"tokenVersion"`
	SessionID    string `json:"sid,omitempty"`
	JTI          string `json:"jti,omitempty"`
	jwt.RegisteredClaims
}

// TokenOpts 签发参数（DESIGN §4.1：GenerateToken 收敛为结构体，handler 不再自己拼 claims）。
type TokenOpts struct {
	UID          uint64
	Role         string
	TokenType    string
	Secret       string
	TTL          int
	TokenVersion int
	SessionID    string
	JTI          string
}

// Sign 签发 HS256 JWT。TTL <= 0 时回落到 900s，避免配 0 导致 token 立刻过期。
func (o TokenOpts) Sign() (string, error) {
	ttl := o.TTL
	if ttl <= 0 {
		ttl = 900
	}
	now := time.Now()
	claims := Claims{
		UID:          o.UID,
		Role:         o.Role,
		TokenType:    o.TokenType,
		TokenVersion: o.TokenVersion,
		SessionID:    o.SessionID,
		JTI:          o.JTI,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Duration(ttl) * time.Second)),
			IssuedAt:  jwt.NewNumericDate(now),
		},
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return tok.SignedString([]byte(o.Secret))
}

// GenerateToken 保留 v0.4.1 签名（存量调用点与老链路零改动），内部委托 TokenOpts.Sign。
func GenerateToken(uid uint64, role, tokenType, secret string, ttl int, tokenVersion int) (string, error) {
	return TokenOpts{
		UID:          uid,
		Role:         role,
		TokenType:    tokenType,
		Secret:       secret,
		TTL:          ttl,
		TokenVersion: tokenVersion,
	}.Sign()
}

func ParseToken(tokenStr, secret string) (*Claims, error) {
	claims := &Claims{}
	tok, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, errors.New("unexpected signing method")
		}
		return []byte(secret), nil
	})
	if err != nil {
		return nil, err
	}
	if !tok.Valid {
		return nil, errors.New("invalid token")
	}
	return claims, nil
}
