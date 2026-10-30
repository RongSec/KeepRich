# 发版与在线更新手册

App 在线更新 = **GitHub Releases 分发** + **后端灰度/强更控制**。

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
- **Web**：刷新即最新，无需更新机制
