# KeepRich 项目交接文档

> 交接时间：2026-11-09 · 项目根目录：`/Users/rongsec/Developer/finance`
> 当前版本：**v0.3.1（0.3.1+4）**，CI 全绿，云上服务正常。
> **安全提示**：本文含开发/演示口令与密钥路径。若要随仓库交接，先把「账号口令 / MySQL 与 JWT 开发密钥 / 分享码」替换为占位符再提交；或加入 `.gitignore`，通过单独的安全通道传递。

---

## 一、换账号前必须带走的 6 样东西

| # | 资产 | 位置 / 标识 | 丢了会怎样 |
|---|------|-------------|-----------|
| 1 | **Android 正式签名密钥** | `app/android/app/upload-keystore.jks` + `app/android/key.properties`（均**不入库**） | 新包签名不同，**无法覆盖安装**，只能卸载重装（用户数据会丢） |
| 2 | **GitHub 仓库 + Secrets** | `https://github.com/RongSec/KeepRich`；Secrets：`KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS`(upload) / `KEY_PASSWORD` | CI 打出的 APK 变 debug 签名，在线更新链路失效 |
| 3 | **云应用与访问码** | appId `wbapp_Wb18t2EDvXDMyVcNeOC4nZ`；域名 `family-finance-34705.app.workbuddy.host`；`sharecode=VAUEWKAZSR` | 换账号后**应用与 sharecode 都会变**，需重新部署并通知所有端改地址 |
| 4 | **云上数据备份** | 最新：`docs/backups/finance-backup-20261109.json`（209KB / 725 行 / 18 表）；上一版 `…-20261108.json`；随时可用 `GET /api/admin/backup` 导出 | 沙箱重启后运行期新增数据不可恢复 |
| 5 | **本地配置与口令** | `backend/config/config.yaml`（MySQL/JWT 开发密钥）、`admin/admin123456` | 本地起服务/登管理后台会卡住 |
| 6 | **构建产物与部署目录** | `cloud/finance-server/`（双架构二进制 + Web + admin + apk）、`永远富裕-v0.3.1-arm64.apk` | 新账号要重新构建一遍才能发布 |

**迁移顺序（建议）**：备份数据 → 带走密钥 → 新账号获得仓库权限/transfer → 重配 4 个 Secrets → 用 `cloud/finance-server` 重新发布 → 恢复数据 → 各端改服务端地址（Web 登录页二维码会自动跟着新域名变，App 扫码即可）。

---

## 二、系统全景与访问地址

| 模块 | 技术栈 | 说明 |
|------|--------|------|
| `backend/` | Go + Gin + GORM | REST API / JWT+MFA / WebSocket / 安全响应头；本地 MySQL，云上 SQLite |
| `app/` | Flutter 3.47.8 | Android + Web 主应用；在线更新、扫码连服务端、金沙背景 |
| `admin/` | Flutter Web | 管理后台（用户/家庭/审计/版本），构建需 `--base-href=/admin/` |
| `cloud/` | 部署目录 + `sync.sh` | 云沙箱发布物（Go 二进制 linux amd64/arm64 + 静态资源 + 分发 APK） |
| `deploy/` + `docker-compose.yml` | MySQL 8 + Nginx | 自有服务器一键部署（数据持久化的正式方案） |
| `.github/workflows/` | `ci.yml` / `release.yml` / `deploy.yml` | 见第四节 |

| 入口 | 地址 |
|------|------|
| 主应用 Web（登录） | `https://family-finance-34705.app.workbuddy.host/?sharecode=VAUEWKAZSR` |
| 管理后台 | `https://family-finance-34705.app.workbuddy.host/admin/?sharecode=VAUEWKAZSR` |
| GitHub Releases | `https://github.com/RongSec/KeepRich/releases/latest`（当前 **v0.3.1**，3 个 ABI APK + SHA256SUMS） |
| 健康检查 | `GET /healthz` |
| 版本检查 / 下载 | `GET /api/app/version?platform=android&current=X&build=N&abi=...`、`GET /api/app/download?abi=...` |
| 数据备份 / 恢复 | `GET /api/admin/backup`、`POST /api/admin/backup/restore`（body：`{"tables": ...}`，按主键查-插，幂等） |

**账号（均为演示默认，接手后立刻改密）**

| 用途 | 账号 | 口令 |
|------|------|------|
| 管理员 / App / Web / 后台 | `admin` | `admin123456` |
| 双账号验收用 | `webuser` | `Web@12345` |
| 本地 MySQL | `finance` | `finance_pass`（库 `family_finance`，端口 3306） |

当前云上家庭：`永远富裕之家`，家庭码 `V7K3BFZL`（**沙箱重置后会变，以 `GET /api/family` 为准**）。

---

## 三、本地开发与常用命令

```bash
# 环境：Flutter 3.47.8 / Go 1.26（云部署目录为 1.22）/ MySQL 8 / Android SDK
cd /Users/rongsec/Developer/finance

# 后端（本地 MySQL，端口 28080 由 APP_PORT 指定）
cd backend && go build ./... && APP_PORT=28080 go run .

# App：本地联调（模拟器默认 10.0.2.2:28080，真机需在「设置→服务端地址」填局域网 IP 或云地址）
cd app && flutter pub get && flutter run -d emulator-5554
flutter build apk --release --split-per-abi --no-pub      # 依赖没变时加 --no-pub 绕开 pub.dev 代理 502
flutter build web --release --no-pub

# 管理后台
cd admin && flutter build web --release --base-href=/admin/

# 静态分析（CI 用 --no-fatal-infos，warning 会挂 CI）
cd app && flutter analyze --no-pub

# 同步云部署目录（重编双架构二进制 + Web + admin + 分发 APK 清单）
bash cloud/sync.sh        # 必须成功输出 SYNC_OK
```

发布云上用 WorkBuddy 发布能力（或平台面板），参数：

```
directory = cloud/finance-server
appId     = wbapp_Wb18t2EDvXDMyVcNeOC4nZ   # 换账号后重新分配
startCmd  = sh -c 'if [ "$(uname -m)" = "aarch64" ]; then exec ./finance-app-arm64; else exec ./finance-app-x64; fi'
installCmd= echo skip-install
```

**发布前后必做的数据保险**（沙箱会重置运行期数据）：

```bash
BASE="https://<域名>"; SC="sharecode=<分享码>"
T=$(curl -s -X POST "$BASE/api/auth/login?$SC" -H 'Content-Type: application/json' \
     -d '{"username":"admin","password":"admin123456"}' | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['accessToken'])")
curl -s "$BASE/api/admin/backup?$SC" -H "X-Finance-Token: $T" > /tmp/backup.json
# ... 发布 ...
python3 -c "import json; d=json.load(open('/tmp/backup.json'))['data']; json.dump({'tables':d['tables']},open('/tmp/restore.json','w'))"
curl -s -X POST "$BASE/api/admin/backup/restore?$SC" -H "X-Finance-Token: $T" \
     -H 'Content-Type: application/json' --data-binary @/tmp/restore.json
```

---

## 四、CI 与发版（铁律）

| Workflow | 触发 | 作用 |
|----------|------|------|
| `ci.yml` | push main/develop、PR | Go build/vet + App/Admin analyze + Web 构建，**只检查不产 APK** |
| `release.yml` | push `v*` tag | 校验 tag 与 pubspec 版本一致 → 构建 3 ABI APK → 自动创建 GitHub Release |
| `deploy.yml` | 仅 `workflow_dispatch` | Docker 镜像部署，**Secrets 未配置、未启用** |

**发版铁律**：只要 APK 内容变了，就必须升 `app/pubspec.yaml` 的 `version: X.Y.Z+N`（`Z` 和 `N` 都递增）并打**新 tag**。曾因一直用 `v0.3.0` 反复 `--clobber` 覆盖资产，导致已装 0.3.0 的用户永远收到「当前已是最新版本」（2026-11-09 已修复并发 v0.3.1）。

```bash
# 1. 改版本号  2. 提交推代码  3. 打 tag 触发 CI
vim app/pubspec.yaml                 # version: 0.3.2+5
git add -A && git commit -m "release: v0.3.2" && git push origin main
git tag v0.3.2 && git push origin v0.3.2
# 4. 本地构建 + 同步云端分发（sync.sh 生成 apk/version.json，含 buildNumber 与 sha256）
cd app && flutter build apk --release --split-per-abi --no-pub && cd .. && bash cloud/sync.sh
# 5. CI 变绿后，用云端 apk/ 的同一构建覆盖 Release 资产（保证三端 sha256 一致）
cd cloud/finance-server/apk && sha256sum app-*-release.apk > SHA256SUMS.txt
gh release upload v0.3.2 --repo RongSec/KeepRich app-*-release.apk SHA256SUMS.txt --clobber
# 6. 发布云上（记得先导出/后恢复数据），再验收：
#    旧版本 -> updateAvailable=true；新版本+build -> false；云端下载 sha256 == GitHub asset digest
```

版本判定细节见 `docs/RELEASE.md`：服务端按 `version + buildNumber` 比较，**buildNumber 需按 ABI 换算**（Flutter 拆包给 versionCode 加前缀：armeabi-v7a=1000 / arm64-v8a=2000 / x86_64=4000，`+4` 在 arm64 设备上是 `2004`）。在线更新为 **GitHub 直连优先、云服务端 `/api/app/download` 兜底**（读随部署分发的本地 APK，不做实时代理）。

---

## 五、必须知道的坑（都真实踩过）

| 坑 | 表现 / 规避 |
|----|-------------|
| **云网关覆盖 `Authorization`** | 所有鉴权请求必须同时带 `X-Finance-Token: <裸 token>`；App 与 admin 的 api.dart 都已加双头 |
| **必须带 sharecode** | 云托管每个请求都要 `?sharecode=XXX`（或 `X-Share-Code`），否则 403 HTML；网关返回的 HTML 会让 dio 把 body 落成 String → type cast 报错，已有 `decodeStringResponseBody` 兜底 |
| **沙箱无持久化磁盘** | SQLite 运行期副本在 `/tmp`，**每次重新发布/沙箱重启都会重置回部署快照**。历史快照数据不丢，运行期新增靠备份流程保住 |
| **云数据库开而未用** | WorkBuddy 云服务已开通，但其数据库是 PostgREST/前端 JS SDK 直连，**没有给 Go 服务端的 SQL 连接串**；要把数据层真正持久化，需自建服务器（MySQL，代码已支持）或重写成前端直连 |
| **WebSocket 不可用** | 云网关不支持 WS 升级，前端已静默降级为轮询（失败 5 次停止重连） |
| **静态资源挂载** | 管理后台产物必须放 `web/admin/` 随 web 上传（独立 `admin_dist` 目录被上传规则过滤）；`cp -R` 到已存在目录会产生 `web/web/` 嵌套，先 `rm -rf` 再拷 |
| **CSP** | `app/web/index.html` 与 `admin/web/index.html` 必须含 `unsafe-inline` / `wasm-unsafe-eval` / `fonts.gstatic.com`；缺 gstatic 会导致 Web **有画面没文字** |
| **沙箱架构** | 是 ARM，但部署目录同时带 amd64/arm64 双二进制，startCmd 按 `uname -m` 选择 |
| **模拟器自动化** | 真实分辨率 1080x2400，ViewImage 显示会缩放；用 TalkBack + `uiautomator dump` 拿精确 bounds；传感器注入 `adb emu sensor set acceleration x:y:z`；AVD 崩溃残留锁文件需删 `~/.android/avd/Pixel_7.avd/*.lock` |
| **pub.dev 代理 502** | 依赖没变时构建/分析加 `--no-pub` |
| **已移除 FLAG_SECURE** | 正式包现在允许截屏/录屏（曾为安全加过，按需求移除） |

---

## 六、当前状态快照（2026-11-09）

| 项 | 值 |
|----|----|
| 代码 | `main` @ `f1e481f`；tag `v0.3.1` @ `88c20ff`；`git push` 已同步 |
| CI | `release v0.3.1` 与 `ci main` 均 success |
| APK | `永远富裕-v0.3.1-arm64.apk`（27,474,908 B，sha256 `fe14095e…`），`…-v0.3.0-arm64.apk` 已作废 |
| 云端分发 | `cloud/finance-server/apk/version.json` = 0.3.1 + build 4；GitHub asset digest 与云端下载哈希一致 |
| 在线更新 | 模拟器用 0.3.0 实测：自动弹窗 / 手动检查 / 下载+sha256 / 安装 → `versionCode 2003→2004` 全通 |
| 云上数据 | 用户 `admin`、`webuser`；家庭 `永远富裕之家`（码 `V7K3BFZL`）；最新备份 `docs/backups/finance-backup-20261109.json` |
| 本地服务 | `localhost:28080` **当前未运行**（云上服务 200 正常）；本地 MySQL 与云上 SQLite **数据不互通** |

## 七、待办 / 已知不一致

1. `app/lib/config.dart` 的 `appVersion` 默认值仍写死 `0.3.0`（实际版本取自 `PackageInfo`，不影响功能）——下次发版顺手同步/改成读 pubspec。
2. `deploy.yml`（Docker 镜像部署）未启用，缺 `REGISTRY_*` / `SSH_*` Secrets。
3. 数据持久化终极方案未落地：建议自有服务器 + MySQL（代码已完整支持），或把后端数据层重写为云数据库前端直连。
4. 云服务已开通但后端未接入其数据库/认证/存储（见第五节）。
5. 默认管理员口令为演示值，**正式使用必须改密**；`backend/config/config.yaml` 的 JWT/数据库密钥同理。

## 八、历史上下文索引

- `.workbuddy/memory/2026-10-30.md` ~ `2026-11-09.md`：按日工作日志（含每次 bug 根因与修复、验收数据）
- `docs/RELEASE.md`：发版与在线更新手册（铁律、灰度/强更、资产命名）
- `docs/AUDIT_REPORT_2026-10-30.md`：早期代码审计报告
- `docs/ESTIMATION_ALGORITHMS.md`：财务估算口径说明
- `README.md`：项目功能与快速开始
