# 阶段一：构建
FROM golang:1.25-alpine AS builder

WORKDIR /src
RUN apk add --no-cache git ca-certificates tzdata

# 国内代理
ENV GOPROXY=https://goproxy.cn,direct

COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# 安装 swag 并生成 Swagger 文档（可选）
RUN go install github.com/swaggo/swag/cmd/swag@v1.16.2
RUN swag init -g main.go -o docs || true

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server .

# 阶段二：运行
FROM alpine:3.19
WORKDIR /app
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -H -u 10001 app
ENV TZ=Asia/Shanghai
COPY --from=builder /out/server /app/server
COPY config /app/config
USER app
EXPOSE 8080
ENTRYPOINT ["/app/server"]
