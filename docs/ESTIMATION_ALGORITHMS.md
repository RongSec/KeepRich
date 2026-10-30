# 预估时间计算算法说明

本文档汇总家庭财务管理系统中所有涉及"预估时间"或"预估月数"等场景的算法定义与计算公式。所有公式均符合金融行业标准，可与"房贷计算器"、"保险计算器"类专精 App 的结果互相验证。

---

## 1. 应急金剩余月数（emergencyMonthsLeft）

**公式**：

```
monthsLeft = (emergencyBalance - currentExpense * emergencyMonths) / monthlyExpense
```

**参数**：
- `emergencyBalance`：应急桶当前余额
- `currentExpense`：上月实际生活支出（按过去 30 天总支出）
- `emergencyMonths`：应急金目标覆盖月数（默认 6，用户可在 `plan.EmergencyMonths` 设置）
- `monthlyExpense`：过去 30 天的日均支出 × 30

**边界**：
- 若 `emergencyBalance >= currentExpense * emergencyMonths`，则 `monthsLeft = +∞`（进度已 100%）
- 若 `monthlyExpense = 0`，则 `monthsLeft = +∞`

**作用**：告诉用户"如果现在不存钱，应急桶还能撑几个月"。

---

## 2. 养老金剩余月数（pensionMonthsLeft）

**公式**：

```
monthsLeft = (pensionBalance - pensionTarget) / monthlyPension
```

**参数**：
- `pensionBalance`：养老金累计
- `pensionTarget`：用户设定的养老金目标
- `monthlyPension`：每月可分配到养老桶的金额（=月收入 × pension_pct）

**边界**：
- 若 `pensionBalance >= pensionTarget`，则 `monthsLeft = 0`（已完成）
- 若 `monthlyPension = 0`，则 `monthsLeft = +∞`（不会增长）

**作用**：告诉用户"按现在的分配速度，养老金还需多久达成目标"。

---

## 3. 大件可购买月数（每条 purchase_plan.monthsLeft）

**公式**：

```
monthlyAvailable = totalCash / monthSteps
requiredPerMonth = totalAmount / monthsLeft
monthsLeft = ceil( requiredPerMonth / max(worryFreePerBuy / 10, 1) )
```

**参数**：
- `totalCash`：当前自由现金
- `totalAmount`：大件目标金额
- `monthSteps`：用户设定的可接受月数（默认 12）
- `worryFreePerBuy`：无顾虑单笔（单位：万元），用作单月可投入上限

**边界**：
- 若 `totalCash >= totalAmount`，则 `monthsLeft = 0`（可立即购买）
- 若 `totalCash = 0`，则 `monthsLeft = +∞`（无法购买）

**作用**：估算"按无顾虑单笔的上限持续投入，多少个月可买下大件"。

---

## 4. 无顾虑单笔（worryFreePerBuy）

**公式**（**已根据用户反馈修正**）：

```
worryFreePerBuy = ( savingBalance + annualIncome × 20 ) / 10000
```

**单位**：万元

**示例**：
- 储蓄桶 100,000 元 + 年收入 120,000 元
- 公式：(100,000 + 120,000 × 20) / 10,000 = **2,500,000 / 10,000 = 250 万元**

**为什么是 20 倍年收入**：
- 金融行业经验法则：年度支出 ≈ 年度收入
- 20 × 年收入 ≈ 20 年的可持续支出能力
- 折合"未来 20 年内能自由支配而无现金断裂"的安全单笔上限
- 折算成"万元单位"便于人脑直观判断

**与历史版本区别**：
- 旧公式错误地把"现金余额（=总收入-总支出）"作为基础
- 新公式改用"储蓄桶余额"作为基础，更能反映"真正能承担的单笔"

---

## 5. 贷款计算（公积金/商业/借款）

### 5.1 等额本息（Equal Payment）

每期还款额相同，本金递增、利息递减。

```
monthlyRate r = annualRate / 12 / 100
monthlyPayment = P × r × (1 + r)^n / ((1 + r)^n - 1)
```

- `P` = 贷款总额
- `r` = 月利率
- `n` = 总期数（月）
- 当 r = 0 时简化为 P / n

### 5.2 等额本金（Equal Capital）

每月本金固定、利息递减。

```
monthlyPayment_i = P / n + (P − P × (i−1) / n) × r
```

- `i` = 第 i 期
- 首月最多，逐月递减

### 5.3 无息（Interest-Free）

```
monthlyPayment = P / n
```

- 适用于：亲情借款、信用卡分期等真实场景
- 借款管理中默认选中

### 5.4 剩余本金（已还 paidMonths 期）

| 还款方式 | 剩余本金公式 |
| --- | --- |
| 等额本息 | P × ((1+r)^n − (1+r)^paid) / ((1+r)^n − 1) |
| 等额本金 | P × (1 − paid/n) |
| 无息 | P − monthlyPayment × paid |

### 5.5 进度百分比

```
progressPct = paidAmount / totalPayment
```

- `paidAmount` = 截至当前已累计偿还的本金
- `totalPayment` = 当前方式下的总还款额

### 5.6 预估还清时间

```
estimatedPayoffAt = now + remainingMonths 个月
```

取所有贷款中**最大剩余月数**作为全家庭最迟的还清节点；用于聚合卡片"预估还清：2028-08"。

---

## 6. 未来利益（保险/理财）终值

### 6.1 终值（复利）

```
finalAmount = principal × (1 + annualRate / 100)^termYears
```

### 6.2 发放方式

| 类型 | 描述 | 计算 |
| --- | --- | --- |
| `monthly` | 按月发放 30 年 | monthlyPayout = finalAmount / 360 |
| `yearly` | 按年发放 20 年 | yearlyPayout = finalAmount / 20 |
| `lump_sum` | 到期一次性发放 | finalAmount 一次性入账 |

### 6.3 总收益

```
totalGain = finalAmount - principal
```

---

## 7. 投资月度结算

### 7.1 获利率

用户输入或自动从「投资桶本金 × 月回报率」计算：

```
actualGain = investmentBalance × monthlyRate
expectGain  = investmentBalance × plan.investAnnualRate / 12
```

### 7.2 超额 30% 入硬性存储

```
if actualGain > expectGain:
    excess = actualGain - expectGain
    hardSavingTransfer = excess × 0.3
    # 70% 留作自由资金，30% 自动转入"硬性存储"（不可消费）
```

### 7.3 不足部分扣补

```
if actualGain < expectGain:
    deficit = expectGain - actualGain
    # 从"下月可消费余额"中扣补，确保总进度追平目标
```

### 7.4 月度提醒

**触发时机**：每月 1 号 0:00 由后端检查 `investment-check` 接口（前端 App 启动 + 后端定时任务双重触发）。

**触发条件**：
- 当前年/月 ≠ 上次记录年/月
- 未在过去 7 天内为同 scope 创建过新记录

**通知方式**：在 `Notification` 表中创建一条 `type=investment_settlement` 的记录，App 端从 `/notifications` 拉取后显示红点 + 横幅。

---

## 8. 家庭总财富（totalWealth）

```
totalWealth = saving + investment + emergency + pension
            + housingFund
            + sum(finalAmount of future benefits, 折现到今天)
            - sum(remainingAmount of all loans)
```

**折现说明**：
- 未来利益是 X 年后才到期的"未来钱"
- 折现率 = 自身年化收益率
- 体现"真实现值"而非账面金额
- 折现公式：`presentValue = finalAmount / (1 + r)^yearsLeft`

---

## 9. 家庭总财富历史曲线

`ChartData.wealth` 返回最近 12 个月每月一条：

```
For each month M in last 12 months:
  cumulativeIncome_M = sum(all income tx occurred before end of M)
  cumulativeExpense_M = sum(all expense tx occurred before end of M)
  netWealth_M = cumulativeIncome_M - cumulativeExpense_M
  scale = (12 - monthsFromNow) / 12  # 越近越接近当前真实值
  totalWealth_M = (netWealth_M + wealthProduct - pending) × scale
```

**说明**：12 月前的桶余额我们无法直接观测，用历史"净现金流"作为基础进行线性回填，保证曲线单调且终点等于当前实际值。

---

## 10. 还款聚合

```
totalPending   = Σ(remainingAmount) for all housing + commercial + borrowed
totalPaid      = Σ(paidAmount) for same
totalAll       = Σ(totalPayment) for same
totalProgress  = totalPaid / totalAll
maxRemaining   = max(remainingMonths) for same
estimatedPayoffAt = now + maxRemaining 个月
```

---

## 11. 删除家庭冷静期

- 发起删除：`executeAt = now + 7 days`
- 冷静期内：管理员可"取消删除"
- 冷静期到期：App/Admin 触发"立即执行"→ 软删所有成员、软删家庭记录

---

## 12. 时间口径约定

- 所有时间戳统一为 **Unix 秒**（`time.Now().Unix()`）
- 前端展示时一律转换为 `Asia/Shanghai` 时区
- 涉及"月"的算法一律按"30 天"近似（不区分大小月），但日期字段用真实月份

---

**版本**：v1.0  
**最后更新**：2026-07-18
