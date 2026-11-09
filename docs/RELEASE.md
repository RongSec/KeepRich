# 发版与在线更新手册

App 在线更新 = **GitHub Releases 分发** + **后端灰度/强更控制**。

## v0.5.0 发版说明

版本 `0.5.0+7`（`app/pubspec.yaml`），`AppConfig.appVersion = 0.5.0`。本版把登录从
「一次性表单」升级为「这台设备认识你」：24 小时不活跃才失效、指纹一键登录、
本机多账号卡、邀请码注册。

### 1. 升级后首次打开可能需要重新验证一次身份

会话语义从「refresh 固定 7 天」改为「连续 24 小时无任何请求才失效」；access
15 分钟过期时静默续期并**轮换** refresh（客户端必须落盘新 refresh）。
v0.4.1 用户若在升级前已超过 24 小时未活跃，首次打开会落回登录页（账号卡仍在，
指纹或密码都能重新进入）——**属预期行为**，请在发版公告与客服话术里提前说明。

### 2. 上线前管理员必须先生成一批邀请码备用

新注册从此必须有邀请码，**没有码就完全无法建号**。发布前先至少生成 2 个：

```bash
ADMIN_TOKEN=<管理员 accessToken> bash scripts/invite-codes.sh gen -n 2 -u 1 -d 7 -m "v0.5.0 首发"
```

把生成的码线下发给家人；`list` 查状态、`revoke <id>` 撤销未使用的码。
邀请码由服务端生成（8 位、剔除易混字符），不接受自定义码串，App 内也没有管理入口。
**邀请码不携带任何家庭信息**：注册出的账号是「无家庭」普通用户，加入家庭仍走
既有的「加入申请 → 管理员审批」流程，本版不改该流程。
已存在的账号登录不需要邀请码，零影响。

### 3. 旧客户端注册会被拒

v0.4.1 及更早客户端调用旧的「仅邮箱注册」路径会被拒绝，返回中文提示
「请输入邀请码」/ 引导升级，不会误导用户。请提示升级到 v0.5.0 后用邀请码注册；
**老账号（含 v0.4.0「邮箱即用户名」账号）登录完全不受影响**，不补码、
不强制改用户名、不强制补昵称。

### 其它运维注意

- 后端 `config.yaml` 新增 `auth` 段（纯时效数值，无密钥），`jwt.refreshTTL` 改为 `86400`。
- 会话 / 设备凭据 / 邀请码四张新表已进入云端快照（18 → 22 表），重启沙箱不会把全端踢下线、
  已用配额也不会归零；部署前必须重新执行 `bash cloud/sync.sh`。
- 本机不再保存明文密码：v0.4.1 遗留的旧指纹密码凭据在升级后**首次成功登录时**被清除。
- 改密会撤销该账号全部会话与设备凭据，客户端会主动回登录页提示
  「登录已失效，请重新登录」。

## 架构

```
打 tag v1.2.3 ──► GitHub Actions ──► 构建 APK ──► 挂到 GitHub Release
                                                      │
App 启动 ──► GET /api/app/version?platform=android&current=x.y.z&did=设备ID
                     │
             后端查 app_versions 表（灰度/强更/下载地址/sha256）
                     │
             返回 {updateAvailable, forceUpdate, apkUrl, sha256, notes}
                     │
             App 弹窗 → 下载 APK → sha256 校验 → 调起系统安装
```

## 铁律：版本号必须递增，禁止同号覆盖

App 判定更新的依据是 `version`（三段数字）+ `buildNumber`。**只要版本号没变，已安装该版本的用户就收不到更新**——即便把 GitHub Release 里的 APK 覆盖成新构建也一样。曾因一直用 `v0.3.0` 反复 `--clobber` 覆盖资产，导致用户点「检查更新」始终显示「当前已是最新版本」。

因此每次交付新 APK 都必须：

1. `app/pubspec.yaml` 的 `version: X.Y.Z+N` **递增**（改内容就升 `Z`，`N` 也 +1）
2. 打**新的** `vX.Y.Z` tag（release workflow 会校验 tag 与 pubspec 一致，不一致直接失败）
3. 跑 `cloud/sync.sh` 重新生成云端 `apk/version.json`（含 buildNumber 与 sha256）并发布
4. 云端清单与 GitHub Release **必须是同一次构建**（sha256 一致）

buildNumber 是第二道保险：即使版本号被误复用，只要 `N` 递增，后端仍会判定为可更新。

注意口径：Flutter `--split-per-abi` 会给 Android `versionCode` 加架构前缀（armeabi-v7a=1000、arm64-v8a=2000、x86_64=4000），所以 `+4` 在 arm64 设备上读到的 `PackageInfo.buildNumber` 是 `2004`。`version.json` 里只写基础号 `4`，由后端 `splitBuildNumber()` 按请求的 `abi` 换算成设备口径后再比较，App 端无需特殊处理。

## GitHub Release 与云端分发必须同构建

`cloud/sync.sh` 会用**本地构建产物**生成云端 `apk/`（3 个 ABI + `version.json`，含 buildNumber 与 sha256），这是在线更新的唯一真源。打 tag 触发的 `release` workflow 会在校验通过后自动创建 Release 骨架并上传它自己构建的 APK；**发版收尾时必须用 `cloud/finance-server/apk/` 里的资产 `--clobber` 覆盖 Release 资产**，否则 GitHub 直连与云服务兜底会给出两份 sha256 不同的包。

```bash
cd cloud/finance-server/apk
gh release upload vX.Y.Z --repo RongSec/KeepRich \
  app-arm64-v8a-release.apk app-armeabi-v7a-release.apk app-x86_64-release.apk \
  SHA256SUMS.txt --clobber
```

验收三条：`current=旧版本` → `updateAvailable=true`；`current=新版本&build=N` → `false`；云端 `/api/app/download` 的文件 sha256 与 GitHub 资产一致。

## 发版步骤（vX.Y.Z）

1. **升版本号**：`app/pubspec.yaml` 的 `version: X.Y.Z+N`（N 为 buildNumber，每次发版 +1）
2. **打 tag 并推送**：
   ```bash
   git add app/pubspec.yaml && git commit -m "release: vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```
3. **等 CI**：Actions 的 `release` workflow 自动构建 APK 并创建 GitHub Release（含 SHA256SUMS.txt）
4. **登记版本**（管理端 / API）：向后端插入一条版本记录：
   ```bash
   curl -X POST https://<你的域名>/api/admin/app-versions \
     -H "Authorization: Bearer <admin_token>" -H "Content-Type: application/json" \
     -d '{
       "platform": "android",
       "version": "X.Y.Z",
       "buildNumber": N,
       "channel": "stable",
       "minSupported": "",
       "grayPercent": 100,
       "notes": "更新说明（App 弹窗展示）",
       "apkUrl": "https://github.com/RongSec/KeepRich/releases/download/vX.Y.Z/app-arm64-v8a-release.apk",
       "sha256": "<从 SHA256SUMS.txt 复制对应文件的哈希>",
       "sizeBytes": 0,
       "published": true
     }'
   ```

## 灰度与强更

| 字段 | 作用 |
|------|------|
| `grayPercent` | 灰度放量 0-100。设备按 `did` 哈希取模，稳定命中；先设 10 观察，再放 100 |
| `minSupported` | 低于此版本的客户端**强制更新**（弹窗不可取消）；留空不强更 |
| `published` | `false` 为草稿（客户端不可见），可先建草稿再发布 |
| `channel` | `stable` / `beta`，App 默认查 `stable` |

更新 `grayPercent` / `minSupported` / `published` 用 `PUT /api/admin/app-versions/:id`，即时生效（App 每次启动都会查询）。

## APK 资产命名

`--split-per-abi` 产出三个包，`apkUrl` 按用户主流设备选 `app-arm64-v8a-release.apk` 即可（现代手机几乎都是 arm64）：

- `app-arm64-v8a-release.apk`（主流）
- `app-armeabi-v7a-release.apk`（老旧 32 位）
- `app-x86_64-release.apk`（模拟器）

## 正式签名（已配置 ✓）

**2026-10-30 起 CI 自动签名**。当前状态：

| 项 | 位置 | 说明 |
| --- | --- | --- |
| keystore | `app/android/app/upload-keystore.jks`（**不入库**） | RSA 2048、有效期 10000 天、别名 `upload` |
| 本地配置 | `app/android/key.properties`（**不入库**） | Gradle 自动读取 |
| CI Secrets | `KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD` | release.yml 自动解码启用签名 |
| 服务端地址 | 仓库变量 `API_BASE_URL` | 构建时 `--dart-define` 注入，改服务器只需改这个变量 |

**⚠️ keystore 备份（必做）**：`upload-keystore.jks` + `key.properties` 中的密码务必离线备份
（如密码管理器/加密 U 盘）。丢失后无法对已安装用户覆盖升级（Android 要求同签名）。

**fork / 贡献者**：无需配置任何签名，Gradle 自动回退 debug 签名，构建照常可用。

更换 keystore（如泄露）：重新 `keytool -genkeypair` 生成 → 更新 `key.properties` →
`base64 < upload-keystore.jks` 更新 `KEYSTORE_BASE64` secret → 用新签名发新版本（用户需卸载重装一次）。

## iOS / Web

- **iOS**：受 App Store 政策限制不支持自更新，走商店发版
- **Web**：见下节，已实现主动更新提示

## Web 端在线更新

Web 不能像 APK 那样"替换安装包"，所以更新链条是：**部署新构建 → 服务端告知版本 → 页面提示刷新 → 清缓存重载**。

1. 构建（版本号取自 `app/pubspec.yaml` 的 `version: X.Y.Z+N`）：

   ```bash
   ./scripts/build_web.sh --deploy
   ```

   脚本会带上 `--dart-define=APP_VERSION=X.Y.Z --dart-define=APP_BUILD_NUMBER=N`，
   生成 `version.json`，并把产物复制到 `deploy/nginx/html/app`（nginx 已配置 `/app/` 路由）。

2. 让服务端知道"当前部署的是哪个版本"（二选一）：

   - 后台新增一条 `platform=web` 的版本记录（`/api/app/version` 同款表，可写更新说明、控制发布）；
   - 或启动后端时注入环境变量：`WEB_VERSION=0.3.0 WEB_BUILD=3 WEB_NOTES="..."`。

3. 客户端行为：页面启动、每 10 分钟、切回前台时请求 `GET /api/app/web-version?build=N`，
   若服务端版本更高，登录页 / 首页顶部出现「新版本 vX.Y.Z 已发布 → 立即刷新」。
   点击后清空 CacheStorage、注销 Service Worker，再带时间戳重载，确保拿到新构建。

> 缓存策略：`/app/index.html`、`flutter_bootstrap.js`、`main.dart.js` 全部 `no-cache`，
> 静态资源（canvaskit / assets）可长缓存。构建时使用 `--pwa-strategy=none`，
> 不再注册 Flutter 的 Service Worker，避免"发布了但用户永远拿旧包"。

后端也可以直接托管 Web 产物：把 `build/web` 放到后端工作目录的 `web/`（或用 `WEB_DIST` 指定），
访问 `http://后端地址/` 即是 App Web 版，路由未命中会回退到 `index.html`（SPA）。

