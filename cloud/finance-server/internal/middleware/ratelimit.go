package middleware

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yourname/family-finance/backend/internal/utils"
)

// 内存固定窗口限流器（单实例部署适用）
type fixedWindow struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}
type bucket struct {
	count int
	reset time.Time
}

var limiter = &fixedWindow{buckets: make(map[string]*bucket)}

func init() {
	// 定期清理过期桶，防止内存泄漏
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			limiter.mu.Lock()
			now := time.Now()
			for k, b := range limiter.buckets {
				if now.After(b.reset) {
					delete(limiter.buckets, k)
				}
			}
			limiter.mu.Unlock()
		}
	}()
}

// Allow 判断 key 在 window 窗口内是否未超过 max 次；每次调用计数 +1
func Allow(key string, window time.Duration, max int) bool {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	now := time.Now()
	b, ok := limiter.buckets[key]
	if !ok || now.After(b.reset) {
		b = &bucket{reset: now.Add(window)}
		limiter.buckets[key] = b
	}
	b.count++
	return b.count <= max
}

// RateLimit IP 维度限流中间件
func RateLimit(window time.Duration, max int, keyPrefix string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !Allow(keyPrefix+":"+c.ClientIP(), window, max) {
			utils.Fail(c, http.StatusTooManyRequests, utils.CodeForbidden, "请求过于频繁，请稍后再试")
			c.Abort()
			return
		}
		c.Next()
	}
}
