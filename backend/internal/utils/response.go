package utils

import "github.com/gin-gonic/gin"

type Response struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

const (
	CodeOK           = 0
	CodeBadRequest   = 40000
	CodeUnauthorized = 40100
	CodeForbidden    = 40300
	CodeNotFound     = 40400
	CodeConflict     = 40900
	CodeServer       = 50000

	// v0.5.0 新增错误码：HTTP 状态不变，App 靠 code 选中文文案。
	CodeSessionIdle             = 40110 // 24h 不活跃失效
	CodeSessionRevoked          = 40111 // 撤销 / 改密 / 停用 / tokenVersion 失效 / refresh 重放
	CodeDeviceCredentialInvalid = 40112 // 设备凭据无效 / 过期 / 撤销
	CodeInviteInvalid           = 40010 // 邀请码空 / 格式 / 不存在 / 撤销 / 过期
)

// ---- v0.5.0 中文文案（PRD §4 / DESIGN §5.1 / §7.3）----
// 集中在这里，避免各 handler 手写漂移；**禁止出现英文、异常类名、HTTP 状态码**。
const (
	MsgSessionIdle             = "已超过 24 小时未使用，请重新验证身份"
	MsgSessionRevoked          = "登录已失效，请重新登录"
	MsgDeviceCredentialInvalid = "设备凭据已失效，请用密码登录"
	MsgAccountDisabled         = "账号已停用，请联系管理员"
	MsgBadCredentials          = "用户名或密码错误"
	MsgTokenInvalid            = "登录已失效，请重新登录"
	MsgRequestFormat           = "请求格式不正确"
	MsgRegisterFailed          = "注册失败，请稍后再试"

	MsgInviteEmpty     = "请输入邀请码"
	MsgInviteFormat    = "邀请码格式不正确"
	MsgInviteNotFound  = "邀请码无效，请向管理员确认"
	MsgInviteRevoked   = "邀请码已被撤销，请向管理员确认"
	MsgInviteExpired   = "邀请码已过期，请向管理员索取新的邀请码"
	MsgInviteExhausted = "邀请码已被用完，请联系管理员"
	MsgInviteRevokeOK  = "邀请码已撤销"

	MsgUsernameEmpty         = "请输入用户名"
	MsgUsernameLeading       = "用户名必须以英文字母开头"
	MsgUsernameChinese       = "用户名只能使用英文字母、数字和下划线，不能用中文"
	MsgUsernameCharset       = "用户名只能使用英文字母、数字和下划线"
	MsgUsernameLength        = "用户名需要 4 到 20 位"
	MsgUsernameTaken         = "该用户名已被占用，换一个试试"
	MsgPasswordEmpty         = "请输入密码"
	MsgTooShortPassword      = "密码至少 8 位"
	MsgWeakPassword          = "密码需同时包含字母和数字"
	MsgPasswordMismatch      = "两次输入的密码不一致"
	MsgNicknameEmpty         = "请输入昵称"
	MsgNicknameTooLong       = "昵称最多 16 个字"
	MsgNicknameBlank         = "昵称不能只包含空格"
	MsgEmailFormat           = "邮箱格式不正确"
	MsgEmailTooLong          = "邮箱长度不能超过 128 个字符"
	MsgTooFrequent           = "操作过于频繁，请稍后再试"
	MsgGenerateFrequent      = "生成过于频繁，请稍后再试"
	MsgNoteTooLong           = "备注最多 32 个字"
	MsgInviteCountRange      = "一次最多生成 5 个"
	MsgInviteTTLRange        = "有效期只能选择 1 天、7 天或 30 天"
	MsgInviteMaxUses         = "可用次数只能是 1 到 50"
	MsgInviteGenerated       = "邀请码已生成，请复制后发给家人"
	MsgInviteUsedNoRevoke    = "该邀请码已被使用，无法撤销"
	MsgInviteExpiredNoRevoke = "该邀请码已过期，无法撤销"
	MsgNoPermission          = "无权操作此功能"
)

func OK(c *gin.Context, data interface{}) {
	c.JSON(200, Response{Code: CodeOK, Message: "ok", Data: data})
}

func Fail(c *gin.Context, status, code int, msg string) {
	c.JSON(status, Response{Code: code, Message: msg})
}

func FailWithError(c *gin.Context, status, code int, msg string, _ error) {
	c.JSON(status, Response{Code: code, Message: msg})
}
