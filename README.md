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

> **口径唯一性**：「无顾虑单笔」全项目只有一个实现 —— `services.WorryFreePerBuy`。
> 总览展示、超支提醒、超支筛选都必须调用它（或 `WorryFreePerBuyFor`），
> 禁止在任何地方再手写一遍公式。历史上通知侧另算了一份且漏了 `/10000`，
> 阈值被放大一万倍，导致超支提醒永不触发。

## 桌面小组件（Android）

2×2 / 4×2 两种尺寸，长按桌面 → 小组件 → 永远富裕 添加。

- **内容**：剩余可消费（大数字）+ 当月已消费 + 右下角记账加号
- **眼睛图标**：一键遮蔽金额（`¥ ••••••`），再点恢复
- **范围切换**：点「家庭 / 个人」切换口径，小卡片本地生效，App 无需在跑
- **加号直达**：冷启动与热启动都能直接弹出「记一笔」表单
  （冷启动走 `SplashPage` 读 intent，热启动走 `MainActivity.onNewIntent`
  → `EventChannel(foreverrich/widget_link)` → 路由跳转）
- **布局适配**：2×2 内容已收紧并强制单行，窄屏不会换行或裁切

## 登录与安全

- **生物识别**：指纹 / 面容（`biometricOnly: false`，兼容安卓的 weak 面容）；
  图标与文案按本机已录入类型自适应
- **15 分钟免验证宽限**：距上次验证通过 15 分钟内重新打开 App 直接静默登录，
  不再重复验证；主动退出登录或切换账号会清除该宽限
- **设备凭据**：本机不存明文密码，指纹/面容只解锁服务端签发的 opaque deviceToken，
  可随时在服务端按设备撤销

## 通知

五类可分别开关（设置 → 通知设置），文案模板可自定义：

| 类型 | 触发时机 |
|------|----------|
| 超支提醒 | 单笔支出超过「无顾虑单笔」 |
| 大件可购买 | 攒够某件大件计划的目标金额 |
| 家庭申请 | 有人申请加入你的家庭 |
| 申请结果 | 你的加入申请被处理 |
| 家庭成员记账 | 同家庭其他成员记了一笔账（不通知记录人自己） |

> 通知经 WebSocket 实时下发，需要 App 处于运行状态（前台/后台存活）。

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
