#!/usr/bin/env bash
# 构建 Flutter Web 并生成版本文件，用于"Web 端在线更新"
#
#   ./scripts/build_web.sh            # 只构建到 app/build/web
#   ./scripts/build_web.sh --deploy   # 同时复制到 deploy/nginx/html/app
#
# 版本号取自 app/pubspec.yaml（0.2.0+2 → version=0.2.0 build=2）。
# 部署新版本后，客户端的 /api/app/web-version 会返回更高版本，
# 已打开页面的用户会看到"新版本，立即刷新"。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"

VERSION_LINE="$(grep -E '^version:' "$APP/pubspec.yaml" | head -1 | sed 's/version:[[:space:]]*//')"
NAME="${VERSION_LINE%%+*}"
BUILD="${VERSION_LINE##*+}"
if [ -z "$BUILD" ] || [ "$BUILD" = "$NAME" ]; then
  BUILD=1
fi

echo "==> 构建 Flutter Web v$NAME+$BUILD"
cd "$APP"
flutter build web --release \
  --base-href=/app/ \
  --pwa-strategy=none \
  --dart-define=APP_VERSION="$NAME" \
  --dart-define=APP_BUILD_NUMBER="$BUILD"

OUT="$APP/build/web"
cat > "$OUT/version.json" <<EOF
{"version":"$NAME","buildNumber":$BUILD,"builtAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

if [ "${1:-}" = "--deploy" ]; then
  DEST="$ROOT/deploy/nginx/html/app"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$OUT/." "$DEST/"
  echo "==> 已复制到 deploy/nginx/html/app"
  echo "    重启 nginx：docker compose up -d nginx"
fi

echo "==> 完成"
echo "    产物目录：$OUT"
echo "    让后端/客户端感知新版本："
echo "      export WEB_VERSION=$NAME WEB_BUILD=$BUILD WEB_NOTES=\"本次更新说明\""
echo "      （或在管理后台新增一条 platform=web 的版本记录）"
