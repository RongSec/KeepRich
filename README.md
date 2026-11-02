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

## 本地开发（Android Studio / Web）

```bash
./scripts/dev_local.sh
```

脚本会用 Docker 起 MySQL、把后端跑在本机 `28080`，并打印当前电脑的局域网 IP。
另开一个终端跑 App：

```bash
cd app
flutter pub get
flutter run                    # Android 模拟器（默认连 10.0.2.2:28080）
flutter run -d chrome          # Web（同源 /api 走代理或注入了地址时直连）
```

服务端地址按优先级生效，**不需要改代码**：

1. App 内「登录页底部 / 设置 → 服务端地址」手动填写（存本地，重启有效）
2. 构建注入：`--dart-define=API_BASE_URL=http://192.168.1.8:28080`
3. 平台默认：Android 模拟器 `10.0.2.2:28080`，Web/桌面 `127.0.0.1:28080`

> 真机调试：手机和电脑连同一个 WiFi，在 App 的「服务端地址」里填电脑的局域网 IP
> （`./scripts/dev_local.sh` 会打印），点「测试连接」通过后保存。

## 业务算法

核心公式（无顾虑单笔、剩余月数、等额本息/本金、投资月度结算、总财富折现等）见 [docs/ESTIMATION_ALGORITHMS.md](docs/ESTIMATION_ALGORITHMS.md)。

## ⚠️ 部署安全提示

仓库内置配置均为**开发默认值**，生产部署必须修改：

- `backend/config/config.yaml`：`accessSecret` / `refreshSecret` / 数据库密码
- `.env`：`ADMIN_PASSWORD`、`JWT_*_SECRET`

## 在线更新

两种载体分别支持"直接用新版本"：

| 载体 | 机制 |
|------|------|
| Android APK | GitHub Release 下载 + sha256 校验 + 系统安装；服务端可控制灰度与强更（`docs/RELEASE.md`） |
| Web | 后端 `/api/app/web-version` 返回当前部署版本；页面启动/每 10 分钟/回到前台时比对，发现更新在顶部弹出「立即刷新」，点击后清 CacheStorage + 注销 Service Worker 再重载 |

Web 构建与上线：

```bash
./scripts/build_web.sh --deploy     # 产物 → deploy/nginx/html/app，同时生成 version.json
export WEB_VERSION=0.3.0 WEB_BUILD=3 WEB_NOTES="本次更新说明"   # 或在管理后台加 platform=web 版本记录
```

后端也可以直接托管 Web 产物：把构建结果放到 `./web`（或设 `WEB_DIST`），访问后端根路径即是 App Web 版。

## License

[MIT](LICENSE)
