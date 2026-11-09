package utils

import (
	"crypto/rand"
	"errors"
	"math/big"
)

// familyCodeAlphabet 沿用 v0.4.1 家庭码字符表（去 0/O/1/I，**含 L**）。
// 保持不变的原因：历史家庭码可能含 L，加入家庭时按码精确查询，不能因为收紧生成规则
// 让老码失效。生成规则与校验规则解耦即可。
const familyCodeAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

// inviteCodeAlphabet v0.5.0 邀请码字符表：在历史表基础上**额外剔除 L**（主理人拍板）。
// 8 位、大写字母 + 数字，剔除 0 / O / 1 / I / L 五个易混字符。
const inviteCodeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// generateCodeWithAlphabet 用 crypto/rand 逐位取字符，零新依赖（DESIGN 附录 A.2）。
func generateCodeWithAlphabet(length int, alphabet string) (string, error) {
	if length <= 0 || alphabet == "" {
		return "", ErrEmptyInput
	}
	out := make([]byte, length)
	for i := 0; i < length; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			return "", err
		}
		out[i] = alphabet[n.Int64()]
	}
	return string(out), nil
}

// GenerateCode 生成 n 位邀请码（严格字符集，服务端生成，调用方不可自定义）。
// 家庭码与邀请码共用同一套随机算法，只是字符表不同（DESIGN F13 的泛化）。
func GenerateCode(length int) (string, error) {
	return generateCodeWithAlphabet(length, inviteCodeAlphabet)
}

// GenerateFamilyCode 生成 8 位家庭码；字符集与 v0.4.1 完全一致，老行为不变。
func GenerateFamilyCode() (string, error) {
	return generateCodeWithAlphabet(8, familyCodeAlphabet)
}

// InviteCodeAlphabet 返回邀请码字符表（供 utils.Validate 的格式校验共用）。
func InviteCodeAlphabet() string {
	return inviteCodeAlphabet
}

var ErrEmptyInput = errors.New("empty input")
