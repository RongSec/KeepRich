#!/usr/bin/env bash
# 本地一键联调：MySQL 用 Docker，后端跑在宿主机（方便 go run 改代码即时生效）
#
#   ./scripts/dev_local.sh
#
# 依赖：docker、go 1.26+、flutter
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MYSQL_CT="finance-mysql"

if ! command -v docker >/dev/null 2>&1; then
  echo "✗ 未检测到 docker。请先安装 Docker Desktop，或自备 MySQL 后手动执行："
  echo "  cd backend && APP_PORT=28080 DB_HOST=127.0.0.1 DB_PORT=3306 go run ."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker 未运行，请先启动 Docker Desktop"
  exit 1
fi

echo "==> 启动 MySQL 容器（首次会拉镜像，稍等）"
docker compose -f "$ROOT/docker-compose.yml" up -d mysql >/dev/null

echo "==> 等待 MySQL 就绪"
ready=0
for _ in $(seq 1 60); do
  if docker exec "$MYSQL_CT" mysqladmin ping -h127.0.0.1 -uroot -proot_pass --silent >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != "1" ]; then
  echo "✗ MySQL 启动超时，查看日志：docker logs $MYSQL_CT"
  exit 1
fi
echo "    MySQL 已就绪"

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"

cat <<EOF

==================== 本地联调信息 ====================
后端            http://127.0.0.1:28080        （探活 /healthz）
局域网          http://$LAN_IP:28080
MySQL           127.0.0.1:33060  user=finance  pwd=finance_pass  db=family_finance
默认管理员      admin / admin123456

Android Studio / 模拟器：App 默认就连 10.0.2.2:28080，直接 Run 即可
真机调试：      手机与电脑同一 WiFi，App 登录页底部「服务端地址」填
                http://$LAN_IP:28080
Web 调试：      cd app && flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:28080
=====================================================

EOF

cd "$ROOT/backend"
export APP_PORT=28080
export DB_HOST=127.0.0.1
export DB_PORT=33060
exec go run .
