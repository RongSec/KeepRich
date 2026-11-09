#!/bin/bash
# 从 backend 源同步云部署目录（SQLite 构建）
# 用法：bash cloud/sync.sh
set -euo pipefail

ROOT=/Users/rongsec/Developer/finance
SRC=$ROOT/backend
DST=$ROOT/cloud/finance-server
WEB=$ROOT/app/build/web

# 旧目录整个搬走（不 rm）。
# ⚠️ 不再沿用旧 data/finance.db：v0.4.0 起数据以云端快照为唯一事实源，
# 每次发布都必须是全新空库。否则部署目录里带一版旧行，云端新数据导入时
# 会因"同主键跳过"被整批丢弃（R14，会静默丢账）。
if [ -d "$DST" ]; then
  OLD=/tmp/finance-server-old-$(date +%s)
  mv "$DST" "$OLD"
  if [ -f "$OLD/data/finance.db" ]; then
    echo "data/finance.db: 旧库已归档到 ${OLD}，本轮从空库启动"
  fi
  if [ -d "$OLD/web" ] && [ ! -d "$WEB" ]; then
    echo "WARN: web build missing, reusing old"
  fi
fi

mkdir -p "$DST/data"
# 0 字节是合法的空 SQLite 库：首启自动建表，再由云端快照 / 一次性接续灌数据
: > "$DST/data/finance.db"
cp "$SRC/main.go" "$SRC/go.mod" "$SRC/go.sum" "$DST/"
cp -R "$SRC/config" "$DST/config"
cp -R "$SRC/internal" "$DST/internal"
# 部署目录是发布产物，不携带单元测试（_test.go 里会引用仓库内 docs/ 下的数据文件）
find "$DST/internal" -name '*_test.go' -delete
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
  rm -rf "$DST/web"
  cp -R "$WEB" "$DST/web"
fi

# 管理后台构建产物（--base-href=/admin/）：放进 web/admin 随 web 一起上传
ADMIN_BUILD=$ROOT/admin/build/web
if [ -d "$ADMIN_BUILD" ]; then
  rm -rf "$DST/web/admin"
  cp -R "$ADMIN_BUILD" "$DST/web/admin"
fi

# 在线更新：随部署分发 release APK + version.json 清单。
# 设备访问不了 GitHub 时，云服务端自己就能完成版本检查与安装包下载（兜底自包含）。
APK_BUILD=$ROOT/app/build/app/outputs/flutter-apk
if ls "$APK_BUILD"/app-*-release.apk >/dev/null 2>&1; then
  rm -rf "$DST/apk"
  mkdir -p "$DST/apk"
  cp "$APK_BUILD"/app-*-release.apk "$DST/apk/"
  python3 - "$APK_BUILD" "$DST/apk/version.json" "$ROOT/app/pubspec.yaml" <<'PY'
import glob, hashlib, json, os, re, sys

build, out, pubspec = sys.argv[1], sys.argv[2], sys.argv[3]
version = re.search(r'^version:\s*([0-9.]+)', open(pubspec).read(), re.M).group(1)
bm = re.search(r'^version:\s*[0-9.]+\+(\d+)', open(pubspec).read(), re.M)
build_number = int(bm.group(1)) if bm else 0
abis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'}
assets = []
for path in sorted(glob.glob(os.path.join(build, 'app-*-release.apk'))):
    name = os.path.basename(path)
    abi = next((a for a in abis if a in name), '')
    if not abi:
        continue
    data = open(path, 'rb').read()
    assets.append({'abi': abi, 'file': name,
                   'sha256': hashlib.sha256(data).hexdigest(),
                   'size': len(data)})
json.dump({'version': version, 'buildNumber': build_number,
           'repo': 'RongSec/KeepRich',
           'notes': 'v%s 新版本：可在 App 内直接更新（设备访问不了 GitHub 时走云服务分发）' % version,
           'assets': assets}, open(out, 'w'), ensure_ascii=False, indent=2)
print('bundle: %s+%d, %d apks' % (version, build_number, len(assets)))
PY
fi

# 配置：SQLite 不读 database 段，清掉本地连接信息
python3 - "$DST/config/config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'database:\n(  .*\n)+', 'database: {}\n', s, count=1)
open(p, 'w', encoding='utf-8').write(s)
PY

# ---- 云端快照 sidecar 注入（密钥永不进 git）----
# 必须放在 `cp -R "$SRC/config"` 之后（否则会被源目录覆盖掉）。
# 母本放在 cloud/secrets/（不入库），因为它不在 $DST 里，
# 不会被执行开头的 `mv "$DST" "$OLD"` 搬走。
SIDECAR_SRC="$ROOT/cloud/secrets/cloudsync.local.yaml"
SIDECAR_DST="$DST/config/cloudsync.local.yaml"
mkdir -p "$DST/config"
if [ -f "$SIDECAR_SRC" ]; then
  cp "$SIDECAR_SRC" "$SIDECAR_DST"
  echo "cloudsync sidecar: installed ($(grep -c apiKey "$SIDECAR_DST") apiKey line)"
else
  echo "WARN: $SIDECAR_SRC 不存在 → 云端快照同步将 disabled，沙箱重启后新增数据会丢"
  echo "      修复：cp cloud/secrets/cloudsync.local.yaml.example cloud/secrets/cloudsync.local.yaml 并填 key"
fi

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

# ---- 硬校验：sidecar 不能还是模板占位符（避免漏填 key 就打发布）----
if [ -f "$SIDECAR_DST" ] && grep -q 'apiKey: "<publishableKey' "$SIDECAR_DST"; then
  echo "FAIL: cloudsync.local.yaml 仍是模板占位符 → 请填真实 key（${SIDECAR_SRC}）"
  exit 1
fi

echo "SYNC_OK"
