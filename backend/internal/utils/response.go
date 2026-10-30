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
