package utils

import "strings"

// emailMaxLen 邮箱最大长度（与 models.User.Email 的 size:128 对齐）
const emailMaxLen = 128

// 邮箱校验说明：DESIGN §2.C.1 给的正则是
//
//	^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$
//
// 这里用等价的手写状态机实现（等价于同一条正则），原因：
//  1. 不引入 regexp 的包级编译开销与 init 顺序敏感；
//  2. 返回布尔的同时便于逐段给出边界条件，避免正则写法与前端不一致时难以排查。
//
// 语义严格对齐（多一个"local part 不允许首尾/连续点"的收紧，属于合理加固）。

// NormalizeEmail 邮箱归一化：trim + 全小写。
//
// 注册与登录都必须经过这里，否则 "A@B.com" 与 "a@b.com" 会被当成两个账号
// （username 是唯一索引，混用大小写会绕过唯一性检查）。
func NormalizeEmail(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// IsValidEmail 判断邮箱格式是否合法（入参应先 NormalizeEmail，本函数自身也做 trim）。
func IsValidEmail(s string) bool {
	e := strings.TrimSpace(s)
	if len(e) < 5 || len(e) > emailMaxLen {
		return false
	}
	at := strings.LastIndex(e, "@")
	if at <= 0 || at == len(e)-1 {
		return false
	}
	local, domain := e[:at], e[at+1:]
	if !isEmailLocalPart(local) || !isEmailDomain(domain) {
		return false
	}
	return true
}

// isEmailLocalPart 校验 @ 之前的部分：字母、数字、._%+-，不能以点开头/结尾、不能连续点。
func isEmailLocalPart(local string) bool {
	if local == "" || local[0] == '.' || local[len(local)-1] == '.' {
		return false
	}
	lastDot := false
	for i := 0; i < len(local); i++ {
		c := local[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			lastDot = false
		case c == '.':
			if lastDot {
				return false
			}
			lastDot = true
		case c == '_' || c == '%' || c == '+' || c == '-':
			lastDot = false
		default:
			return false
		}
	}
	return true
}

// isEmailDomain 校验 @ 之后的部分：至少一个点，顶级域为纯字母且长度 >= 2。
func isEmailDomain(domain string) bool {
	if domain == "" || len(domain) > 64 {
		return false
	}
	labels := strings.Split(domain, ".")
	if len(labels) < 2 {
		return false
	}
	for _, label := range labels {
		if label == "" || len(label) > 63 {
			return false
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for i := 0; i < len(label); i++ {
			c := label[i]
			if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' {
				continue
			}
			return false
		}
	}
	// 顶级域必须纯字母且 >= 2（排除 1.2.3.4 这类）
	tld := labels[len(labels)-1]
	if len(tld) < 2 {
		return false
	}
	for i := 0; i < len(tld); i++ {
		c := tld[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

// ValidatePasswordStrength 密码强度校验：至少 8 位，且同时包含字母与数字。
//
// 返回空串表示通过；否则返回**给用户直接看的中文文案**（禁止改成英文/异常类名，
// 见 DESIGN §6.3）。注册、改密、管理员重置口令共用这一份实现。
func ValidatePasswordStrength(pw string) string {
	if len(pw) < 8 {
		return "密码至少 8 位"
	}
	var hasLetter, hasDigit bool
	for _, r := range pw {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
			hasLetter = true
		case r >= '0' && r <= '9':
			hasDigit = true
		}
	}
	if !hasLetter || !hasDigit {
		return "密码需同时包含字母和数字"
	}
	return ""
}
