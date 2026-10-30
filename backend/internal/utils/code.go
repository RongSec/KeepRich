package utils

import (
	"crypto/rand"
	"errors"
	"math/big"
)

// GenerateFamilyCode 生成 8 位家庭码（数字+大写字母，去除易混字符 0/O/1/I）
func GenerateFamilyCode() (string, error) {
	const alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	const length = 8
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

var ErrEmptyInput = errors.New("empty input")
