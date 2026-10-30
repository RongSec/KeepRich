# KeepRich · 家庭财务管理系统

个人/家庭双空间记账 + 财务规划。四桶模型（储蓄 / 投资 / 应急 / 养老）、大件购买计划、三类贷款（公积金 / 商业 / 无息借款）、未来利益折现、家庭协作记账。

## 架构

| 模块 | 技术栈 | 说明 |
|------|--------|------|
| `backend/` | Go (Gin + GORM) | REST API，JWT + MFA，WebSocket 通知 |
| `app/` | Flutter | 移动端（Android）+ Web，记账/规划/家庭 |
| `admin/` | Flutter Web | 管理后台（用户/家庭/审计/错误） |
| `deploy/` | MySQL 8 + Nginx | Docker Compose 一键部署 |

## 快速开始

```bash
cp .env.example .env   # 按需修改数据库/JWT 密钥
docker compose up -d
# 后端: http://localhost:28080  管理端: http://localhost:18000
```

本地开发：

```bash
cd backend && go run main.go
cd app && flutter pub get && flutter run
```

## 业务算法

核心公式（无顾虑单笔、剩余月数、等额本息/本金、投资月度结算、总财富折现等）见 [docs/ESTIMATION_ALGORITHMS.md](docs/ESTIMATION_ALGORITHMS.md)。

## ⚠️ 部署安全提示

仓库内置配置均为**开发默认值**，生产部署必须修改：

- `backend/config/config.yaml`：`accessSecret` / `refreshSecret` / 数据库密码
- `.env`：`ADMIN_PASSWORD`、`JWT_*_SECRET`

## 在线更新

App 支持在线更新（GitHub Releases 分发 + 服务端灰度/强更控制），发版方式见 `docs/RELEASE.md`。

## License

[MIT](LICENSE)
