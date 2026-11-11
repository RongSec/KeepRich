#!/usr/bin/env bash
# 发布后核验脚本：确认「构建成功 + 发布成功」，任一失败即 exit 1。
# 用法: bash scripts/verify_deploy.sh [BASE] [SHARECODE]
# 默认 BASE=https://keeprich-finance.app.workbuddy.host  SHARECODE=A2OVQW6LVY
set -uo pipefail

BASE="${1:-https://keeprich-finance.app.workbuddy.host}"
SC="${2:-A2OVQW6LVY}"
Q="sharecode=${SC}"
APK_TMP="$(mktemp -t kr_apk_XXXX.apk)"
FAIL=0

say() { printf '%s\n' "$*"; }
ok()  { say "  [PASS] $*"; }
bad() { say "  [FAIL] $*"; FAIL=1; }

say "=== 发布核验 $BASE ==="

# 1. 后端存活
code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' "$BASE/healthz")
[ "$code" = "200" ] && ok "healthz 200" || bad "healthz = $code"

# 2. Web 入口
code=$(curl -s -m 30 -o /tmp/kr_idx.html -w '%{http_code}' "$BASE/?$Q")
size=$(wc -c < /tmp/kr_idx.html | tr -d ' ')
title=$(grep -o '<title>[^<]*</title>' /tmp/kr_idx.html | head -1)
if [ "$code" = "200" ] && [ "$size" -gt 500 ] && echo "$title" | grep -q '永远富裕'; then
  ok "Web 入口 200 / ${size}B / $title"
else
  bad "Web 入口 code=$code size=$size title=$title"
fi

# 3. main.dart.js（Flutter Web 真正的产物）
code=$(curl -s -m 60 -o /dev/null -w '%{http_code} %{size_download}' "$BASE/main.dart.js?$Q")
echo "$code" | grep -q '^200 ' && ok "main.dart.js $code" || bad "main.dart.js $code"

# 4. APK 可下载 + 真 ZIP + 版本号
curl -s -m 120 -o "$APK_TMP" "$BASE/api/app/download?abi=arm64-v8a&$Q"
size=$(wc -c < "$APK_TMP" | tr -d ' ')
magic=$(head -c 2 "$APK_TMP")
if [ "$magic" = "PK" ] && [ "$size" -gt 10000000 ]; then
  ok "APK 下载 ${size}B（真 ZIP）"
else
  bad "APK 非法 magic=$magic size=$size"
fi

# 5. APK 内部版本号（不能只信清单）
AAPT=$(find "$HOME/Library/Android/sdk/build-tools" -name aapt -type f 2>/dev/null | sort | tail -1)
if [ -n "$AAPT" ]; then
  pkg_line=$("$AAPT" dump badging "$APK_TMP" 2>/dev/null | grep -m1 '^package:')
  vname=$(echo "$pkg_line" | grep -o "versionName='[^']*'" | head -1 | sed "s/versionName='//;s/'//")
  vcode=$(echo "$pkg_line" | grep -o "versionCode='[^']*'" | head -1 | sed "s/versionCode='//;s/'//")
  label=$("$AAPT" dump badging "$APK_TMP" 2>/dev/null | grep -m1 "application-label:")
  say "  APK 内部: versionName=$vname versionCode=$vcode | $label"
  if [ "$vname" = "0.5.2" ]; then
    ok "APK 版本 = $vname (code $vcode)"
  else
    bad "APK 版本不符: versionName=$vname (期望 0.5.2)"
  fi
else
  say "  [WARN] 未找到 aapt，跳过内部版本校验"
fi

# 6. sha256 与部署清单一致
dl_sha=$(shasum -a 256 "$APK_TMP" | awk '{print $1}')
ref_sha=$(grep arm64 /Users/rongsec/Developer/finance/cloud/finance-server/apk/SHA256SUMS.txt 2>/dev/null | awk '{print $1}')
if [ -n "$ref_sha" ] && [ "$dl_sha" = "$ref_sha" ]; then
  ok "sha256 与清单一致 ${dl_sha:0:12}…"
else
  bad "sha256 不一致 dl=$dl_sha ref=$ref_sha"
fi

# 7. 版本清单
curl -s -m 30 "$BASE/api/app/version?platform=android&current=0.5.1&build=2008&abi=arm64-v8a&$Q" -o /tmp/kr_ver.json
ver=$(python3 -c "import json;d=json.load(open('/tmp/kr_ver.json'))['data'];print(d['version'],d['buildNumber'],d['updateAvailable'])" 2>/dev/null)
echo "$ver" | grep -q '^0.5.2 2009' && ok "版本清单 $ver" || bad "版本清单 $ver"

# 8. 管理后台
code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' "$BASE/admin/?$Q")
[ "$code" = "200" ] && ok "管理后台 200" || bad "管理后台 $code"

rm -f "$APK_TMP"
say ""
if [ "$FAIL" = "0" ]; then
  say "=== 全部通过：构建成功 + 发布成功 ==="
  exit 0
else
  say "=== 存在失败项，发布未确认 ==="
  exit 1
fi
