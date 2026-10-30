# 部署脚本（在服务器上执行）

# 1. 复制项目到服务器（首次）
# scp -r . user@server:~/family-finance

# 2. 复制 .env.example 为 .env 并修改密钥
cd ~/family-finance
cp .env.example .env
# $EDITOR .env  # 修改 JWT 密钥、MFA 密钥、数据库密码等

# 3. 拉取镜像并启动
docker compose pull
docker compose up -d

# 4. 查看状态
docker compose ps
docker compose logs -f backend
