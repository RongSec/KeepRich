# 家庭财务管理系统 · 全面审计报告

> 审计日期：2026-10-30 ｜ 范围：backend(Go) + app(Flutter) + admin(Flutter Web) + CI/CD
> 标记 ★ 的条目已由人工复核源码确认，非子代理误报。

---

## 〇、修复状态（2026-10-30 v0.1.0）

- **P0 ×5**：✅ 全部修复（commits 627be93 / 1e6b297）
- **P1 ×9**：✅ 全部修复（1e6b297），含冷静期/审批状态机/限流/tokenVersion/WS 并发写/密钥强校验
- **前端 P0/P1**：✅ 全部修复（1e6b297），secure_storage、401 refresh、WS 鉴权、崩溃三连
- **P2**：✅ 已修 8 项（UpdateProfile 部分更新、SavePlan 校验、FutureFinance 规划口径、
  投资幂等、CheckBigPurchase、登录竞态、除零、createdAt 字段名）；其余见 §7 Phase 3/4
- **CI**：✅ 工具链对齐（Go 1.26 / Flutter 3.47.8），deploy 改手动触发

---

## 一、项目设计理解

- **定位**：个人/家庭双空间记账 + 财务规划系统。四桶模型（储蓄/投资/应急/养老）+ 大件购买 + 贷款（公积金/商业/无息借款）+ 未来利益（保险/理财）。
- **架构**：Go(Gin+GORM) 后端 `/api`；Flutter App（Android+Web）；Flutter Admin 管理端；MySQL 8 + Nginx + Docker Compose 部署；GitHub Actions CI（web 构建）+ Deploy（镜像推送+SSH 发布）。
- **核心口径**（docs/ESTIMATION_ALGORITHMS.md）：无顾虑单笔、应急/养老剩余月数、大件可购买月数、等额本息/本金、投资月度结算（超额 30% 入硬储）、总财富含未来利益折现、删除家庭 7 天冷静期。
- **总体判断**：功能覆盖面和文档意识都不错，但 **实现与文档大面积脱节**，账务聚合口径存在多处致命级计算错误，安全层（token/审计/MFA/限流）漏洞密集。建议按下方路线图修复后再做功能升级。

---

## 二、P0 致命（账算错 / 数据丢失 / 密钥泄露）

| # | 位置 | 问题 | 修复方向 |
|---|------|------|----------|
| P0-1 ★ | `middleware/audit.go:108-126` | 审计中间件把改密/重置密码/MFA 请求体**明文入库**（audit_logs.detail 含明文密码/验证码），DB 泄露=全量密码泄露 | 对 password/code/secret 字段脱敏，或只记元数据 |
| P0-2 ★ | `services/family_merge.go:41-65` + `handlers/transaction.go:210-211` + `services/finance.go:24-38` | 家庭合并把个人流水**复制**为 family 副本，而家庭聚合是「成员个人流水 + family 流水」并集 → **家庭账目双倍计算**，总览/图表/桶余额/无顾虑单笔全翻倍 | 副本打 `merged_from_tx_id` 标记并在聚合时排除；或合并改为迁移而非复制 |
| P0-3 ★ | `services/family_merge.go:67-76` | 同步删除逻辑把**家庭空间原生记的账**（无个人对应）当副本删掉 → 数据丢失；被编辑过的副本 key 不匹配也被删 | 只删带合并标记的副本，不碰家庭原生流水；全程事务 |
| P0-4 ★ | `services/finance.go:196-218` | 家庭 scope 年薪：工资总额按全家聚合，但 `activeMonths` 只数 family 空间的工资月数（成员工资在个人空间）→ 月数=0 强制为 1，**年薪虚增最高 12 倍**，污染无顾虑单笔/大件预估 | activeMonths 与 salaryIncome 用同一聚合口径（applyScopeQuery） |
| P0-5 ★ | `services/finance.go:217` + `handlers/transaction.go:163-169,239-243,341-379` | 无顾虑单笔公式产出值是**万元**（÷10000），却直接与**元**金额比较 → 超支提醒/筛选/OverWorry 全面失真（>250 元即报超支） | 比较前 ×10000 转元，或 API 明确 `worryFreePerBuyWan` 由前端换算 |

## 三、P1 严重（安全 / 权限 / 核心公式）

| # | 位置 | 问题 | 修复方向 |
|---|------|------|----------|
| P1-1 | `handlers/auth.go:101-118`, `middleware/auth.go:32-75` | refresh 不查库校验用户状态/最新角色；删号/停用/降权后旧 token 30 天内仍有效；改密不失效 | refresh 时查库取最新 role；tokenVersion 或黑名单 |
| P1-2 | `handlers/auth.go:40-64` | 登录/MFA/refresh 无速率限制，TOTP 6 位可无限暴力破解；`mfa.cooldownDays` 配置全库无人用 | IP+账号限流、失败锁定 |
| P1-3 | `handlers/future.go:740-766` | `ForceDeleteFamily` 注释说"冷静期到期后"，实际**无任何时间/投票校验**，管理员随时一键解散；且不清理关联交易/贷款 | 实现文档 §11 的 7 天冷静期；解散时级联清理 |
| P1-4 | `handlers/family.go:175-215` | ApproveJoin 不校验 `status=pending`，重复审批 → 重复成员记录 + 反复触发合并（叠加 P0-2/3）；family_members 无唯一索引 | 状态抢占式更新 + `(family_id,user_id)` 唯一索引 + 事务 |
| P1-5 ★ | `utils/loan.go:58-73` | 等额本息剩余本金公式用 `(1+r)^(剩余期数)`，应为 `(1+r)^已还期数`（文档 §5.4）；实测 P=1200,r=1%,n=12,已还3期：正确≈913，代码≈313 → 图表负债严重失真 | `P*((1+r)^n-(1+r)^paid)/((1+r)^n-1)` |
| P1-6 | `handlers/purchase.go:194-258` | 投资月度入账靠 note 字符串识别旧流水，改备注即重复入账；清零不冲销；无事务并发双记 | 自动流水加 record_id 关联，事务内删旧插新 |
| P1-7 | `handlers/purchase.go:399-442` | CheckBigPurchase 忽略 BigPurchaseRatio，且把"可购买"永久标 Achieved；通知只发本人 | 可购买/已购买分状态；按文档 §3 公式；广播全体成员 |
| P1-8 | `config/config.yaml:19-22`, `Dockerfile:28`, `.env` | 默认 JWT 密钥 `dev-access-secret` 随镜像分发；`.env` 含 `ADMIN_PASSWORD=admin123456` → 可伪造任意 uid/role token | 启动强校验非默认密钥；secret 走环境注入 |
| P1-9 | `services/notification.go:41-58` | WSHub 读锁内并发写同一 websocket 连接（gorilla 禁止并发写）→ 帧损坏/panic；写网络时持锁阻塞注册 | 每连接写 goroutine + 发送队列 |

## 四、P2 一般（摘要，共 20+ 项）

1. **UpdateProfile map 全量更新**：只发 nickname 会清空 email/phone/avatar（user.go:122）。
2. **SavePlan 比例校验不全**：允许负比例；BigPurchaseRatio/InvestAnnualRate 无范围校验（plan.go:98）。
3. **三套默认规划互相矛盾**（models/plan.go、finance.go:789、handlers/plan.go:155）——同一用户在不同页看到不同默认值。
4. **PutTx 编辑流水**：不更新 sourceBucket/sourceDetails（前端改来源无效）；备注无法清空；无日期修改（future.go:819-860）。
5. **loan_repay 流水与 PaidMonths 无联动**，LoanRef 不校验存在/归属；PaidMonths 可为负。
6. **FutureFinance 计划查询用 uid 而非 target_id**（future.go:491）→ 家庭非创建者成员拿到全零规划，未来利益按 80 年折现严重虚高。
7. **未来财务 family scope 只查自己**（future.go:513-558 死代码分支），与总览全家聚合口径打架。
8. **图表与总览口径三处不一致**（桶余额/待还款/总财富公式），文档 §9 的 scale 回填因子未实现（finance.go:470-566）。
9. **息金收入在总财富中重复计入**（finance.go:147-150,188-191,352）。
10. **投资结算三处三个口径**（expectGain 公式、扣补方式、跨年本金不计），与文档 §7 不符。
11. **未来利益折现硬编码 r=0.03**，未用 plan.InvestAnnualRate，与文档 §6/§8 模型完全不同（loan.go:218-328）。
12. **家庭合并丢字段**：流水副本不带 SourceBucket/SourceDetails；家庭 plan 漏 LoanRatio；合并无事务（family_merge.go）。
13. **MonthlyInvestmentCheck 每次调用都推送**，无 7 天去重，type 用 "system" 而非 investment_settlement（future.go:771-817）。
14. **多处写操作非事务**：TransferAdmin、CreateFamily、ForceDeleteFamily（部分失败产生无主/双管理员家庭）。
15. **UpdateFamilyMember 可制造多管理员**（future.go:696-700）。
16. **删用户/删家庭清理不全**：不处理 family_members、漏删 7 类关联表；用户名被软删占用无法重注册（user.go:81-112, admin.go:246-272）。
17. **ListFamilyMembers 原生 SQL 绕过软删除**（family.go:457）。
18. **BindForever 终身绑定约束完全未实现**（Bound 字段只写不读）。
19. **MFA 缺陷**：secret 走不安全 cookie（secure=false、无 SameSite）、禁用只验 TOTP 不验密码、无备份码逻辑（mfa.go）。
20. **RequestDeleteFamily 忽略绑定错误，MFACode 字段从不校验**；单人家庭投票永不自执行；投票计票无锁（family.go:243-287）。
21. **WS CheckOrigin 全放行（CSWSH）**；审计 io.ReadAll 无 body 上限。
22. **配置加载**：.env 多数变量（DB_CHARSET/PLAN_*/NOTIFY_* 等）无 BindEnv 被静默忽略，与 .env.example 承诺不符（config.go:64-98）。

## 五、前端 P0/P1（摘要）

| 级别 | 位置 | 问题 |
|------|------|------|
| P0 | `app/services/biometric.dart:37-38,83-84` | **明文密码写入 SharedPreferences**（生物识别），root/备份可直接读走 |
| P1 | `app/services/api.dart:29-60`, `admin/lib/api.dart` | refresh token 从未使用、无 401 拦截 → access 过期（1h）后全 App 报错，需手动重登 |
| P1 | `app/services/notify.dart:55-74` | WebSocket 握手不带 Authorization（后端挂在 JWT 中间件下）→ **实时通知永远连不上**且 5 秒永久重连循环；Web 端 header 方案不可行需 ?token= |
| P1 | `app/pages/overview_page.dart:547` | 「年」视图 label="2026" 调 `substring(5)` → RangeError 白屏 |
| P1 | `app/services/api.dart:314-317` | 内置管理端错误页把 Map 强转 List → TypeError 永久转圈 |
| P1 | `app/pages/admin/admin_home_page.dart:384,477` | ISO 时间串强转 num → 错误/审计 tab 渲染即崩 |
| P2 | `app/config.dart:9` + AndroidManifest | Android 9+ 默认禁明文 HTTP，未声明 usesCleartextTraffic → **Android 端全部请求失败**；且 app(28080)/admin(8080) baseUrl 端口不一致 |
| P2 | 多数页面 `_load()` | 网络异常未捕获 → loading 永久卡死；await 后 setState 缺 mounted 检查（≥8 处） |
| P2 | `bookkeeping_page` + 后端 PutTx | 编辑账单来源桶/备注被后端静默丢弃；编辑贷款把 startMonth 清零（future_finance_page.dart:778） |
| P2 | `login_page.dart:50-61` | 登录 timeout 竞态；me() 失败仍返回 true → "登录成功又闪回" |
| P2 | `loan_calculator_page.dart:99` | 月收入为 0 除零 → Infinity 崩溃 |
| P2 | `admin/lib` 多处 | created_at/createdAt 字段名错（时间列恒空）；密码校验 6 位 vs 后端 8 位；pushNamed 与 GoRouter 不兼容（快捷按钮全失效）；登录无角色校验、不支持 MFA（开启 MFA 的管理员无法登录 admin） |
| P2 | `app/pubspec.yaml:41` | assets/images/ 目录不存在 → flutter build 失败；.ico 图标 Flutter 无法解码（图标从未显示） |
| P2 | 全链路 | token/密码明文存 SharedPreferences（应改 flutter_secure_storage）；金额 double 浮点漂移；Tab 切换销毁重建丢状态；reportError/checkPurchase/investmentCheck 死代码未接线 |

## 六、P3 建议（速览）

- 金额改整数"分"或 decimal 传输，消灭浮点累加误差。
- 登录错误文案统一防账号枚举；CreateUser 角色白名单；LIKE 转义；CORS 白名单化。
- 审计 action 前缀匹配误标（/family/sync→family.create 等），改精确路由表。
- GoRouter 在 build 内创建（main.dart:81）应持久化；TextEditingController 大面积不 dispose。
- 后端 timezone 配置未生效（无 LoadLocation、compose 未设 TZ）→ 每月 1 日 0-8 点统计错位。
- 文档 §1/§2/§3/§6/§9 的公式与实现语义完全不同，修复实现后同步更新文档。

---

## 七、升级优化路线图（建议顺序）

**Phase 1 — 止血（先修 P0，账务可信）**
1. 家庭合并改为"标记副本 + 聚合去重"，同步删除只删副本（P0-2/3）。
2. 统一金额单位与年薪口径（P0-4/5）；修等额本息公式（P1-5）。
3. 审计日志脱敏（P0-1）；JWT 密钥移出仓库（P1-8）。

**Phase 2 — 安全与权限**
4. refresh 查库 + tokenVersion；登录/MFA 限流（P1-1/2）。
5. 家庭审批状态机 + 唯一索引 + 冷静期真正落地（P1-3/4）。
6. 前端：密码/token 改 flutter_secure_storage；WS 鉴权（?token=）；Android 明文流量配置。

**Phase 3 — 契约与体验**
7. 修前端崩溃三连（年视图 substring、错误页 List 强转、ISO 时间解析）；统一 created_at/createdAt、密码长度、baseUrl 用 --dart-define 注入。
8. 全局错误处理：ApiClient 统一返回 ApiResponse + 401 拦截 + reportError 接线。
9. Tab 保活（IndexedStack）、mounted 检查、dispose 补齐。

**Phase 4 — 架构升级（"全面升级"落点）**
10. 金额整数化（分）；时间统一 time.Local=Asia/Shanghai。
11. 投资结算/未来利益/图表口径与文档对齐（或以实现为准重写文档，二者只能留一个）。
12. CI 增加 APK 构建（见下）+ go test / flutter test 门禁；compose 补 app-web 服务与 /api 反代。

---

## 八、Git 两问解答

### Q1：Git 能否在多台电脑登录？

**可以，无数量限制。** Git 是分布式版本控制，每台电脑 clone 同一仓库即可协同：

| 方式 | 做法 | 适用 |
|------|------|------|
| HTTPS + PAT | 每台机器 `gh auth login`（或 git clone 时输 Personal Access Token），凭证存 keychain | 最省事 |
| SSH Key | **每台机器**生成自己的密钥对，公钥全部添加到同一账号 → 任意台都能推拉 | 推荐，一机一钥可单独吊销 |

注意：
- 同一 GitHub/Gitea/GitLab 账号可在多台电脑、多个 IDE 同时登录，互不冲突。
- 每台机器各自配 `git config user.name / user.email`（作者信息跟机器走，与登录无关）。
- **当前这个目录还不是 git 仓库**（`git status` 报 not a git repository，但已有 .github/workflows），需要先初始化：

```bash
cd /Users/rongsec/Developer/finance
git init -b main
git add .
git commit -m "init: family finance system"
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

### Q2：Git 自动构建能否打包 APK？

**可以。** GitHub Actions 用 Flutter 官方 action 即可自动构建 APK，产物可下载或挂到 Release。在现有 `.github/workflows/ci.yml` 基础上加一个 job：

```yaml
  apk:
    name: App (Android APK)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.5'
      - name: Pub get
        working-directory: app
        run: flutter pub get
      - name: Build APK (split per ABI)
        working-directory: app
        run: flutter build apk --release --split-per-abi
      - name: Upload APK
        uses: actions/upload-artifact@v4
        with:
          name: family-finance-apk
          path: app/build/app/outputs/flutter-apk/*.apk
```

要点：
- **打 tag 自动发版**：把触发改成 `tags: ['v*']`，再用 `softprops/action-gh-release@v2` 把 APK 附到 GitHub Release，手机直接下载安装。
- **正式签名**：把 keystore 转 base64 存入仓库 Secret，CI 解码后写 `android/key.properties` 并配 `signingConfig`；否则产出的是 debug 签名 APK，无法覆盖安装正式版。
- **资源前置**：先补上缺失的 `app/assets/images/`（当前 pubspec 声明了但目录不存在，build 会直接失败）。
- **费用**：GitHub 私有仓库每月免费 2000 分钟（Linux runner），一次 Flutter APK 构建约 5-10 分钟，完全够用；Gitea/GitLab CI 同理，自建 Runner 则无限制。
- 本地打包也可以在 `pack.sh` 里加 `flutter build apk --release` 一条命令出包。

---

*报告完。修复建议按 Phase 顺序执行，每阶段完成后回归验证对应公式与聚合口径。*
