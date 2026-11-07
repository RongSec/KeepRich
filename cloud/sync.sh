#!/bin/bash
# 从 backend 源同步云部署目录（SQLite 构建）
# 用法：bash cloud/sync.sh
set -euo pipefail

ROOT=/Users/rongsec/Developer/finance
SRC=$ROOT/backend
DST=$ROOT/cloud/finance-server
WEB=$ROOT/app/build/web

# 旧目录整个搬走（不 rm），数据文件从旧目录拿回
if [ -d "$DST" ]; then
  OLD=/tmp/finance-server-old-$(date +%s)
  mv "$DST" "$OLD"
  if [ -f "$OLD/data/finance.db" ]; then
    mkdir -p "$DST/data"
    cp "$OLD/data/finance.db" "$DST/data/finance.db"
  fi
  if [ -d "$OLD/web" ] && [ ! -d "$WEB" ]; then
    echo "WARN: web build missing, reusing old"
  fi
fi

mkdir -p "$DST/data"
cp "$SRC/main.go" "$SRC/go.mod" "$SRC/go.sum" "$DST/"
cp -R "$SRC/config" "$DST/config"
cp -R "$SRC/internal" "$DST/internal"
# 剔除 MySQL：部署目录只保留 SQLite 实现，并去掉其构建标签
rm -f "$DST/internal/database/database_mysql.go"
python3 - "$DST/internal/database/database_sqlite.go" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace('//go:build sqlite\n\n', '', 1)
open(p, 'w', encoding='utf-8').write(s)
PY

# Web 构建产物
if [ -d "$WEB" ]; then
  cp -R "$WEB" "$DST/web"
fi

# 配置：SQLite 不读 database 段，清掉本地连接信息
python3 - "$DST/config/config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'database:\n(  .*\n)+', 'database: {}\n', s, count=1)
open(p, 'w', encoding='utf-8').write(s)
PY

cd "$DST"
# go 指令降到 1.22：沙箱自带 Go 即可编译，避免现场下载 go1.26 工具链超时
python3 "$ROOT/cloud/set_go.py" "$DST/go.mod"
# x/* 新版本要求 go 1.26，钉回兼容 go 1.22 的版本（避免沙箱下载新工具链超时）
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  GOFLAGS=-mod=mod GOPROXY=https://goproxy.cn,direct \
  go get golang.org/x/crypto@v0.31.0 golang.org/x/net@v0.33.0 \
         golang.org/x/sys@v0.28.0 golang.org/x/text@v0.21.0
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  GOFLAGS=-mod=mod GOPROXY=https://goproxy.cn,direct go mod tidy
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  GOFLAGS=-mod=mod GOPROXY=https://goproxy.cn,direct go mod vendor

# 验证：无 mysql 残留
if grep -q "go-sql-driver/mysql\|driver/mysql" go.mod; then
  echo "FAIL: go.mod 仍有 mysql 依赖"; exit 1
fi

# 本地交叉编译 Linux 双架构二进制随包发布：沙箱不再需要 Go 工具链
# （沙箱内 go build 曾因 go1.26 工具链下载 / MVS 依赖版本反复超时）
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-mod=vendor \
  go build -o "$DST/finance-app-x64" .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOFLAGS=-mod=vendor \
  go build -o "$DST/finance-app-arm64" .
echo "SYNC_OK"
