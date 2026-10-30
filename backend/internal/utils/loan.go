package utils

import (
	"math"
	"time"
)

// LoanCalculator 贷款计算工具
//
// 方法说明：
//   - equal_payment: 等额本息（每月固定金额）
//   - equal_capital: 等额本金（每月本金相同，利息递减）
//   - interest_free: 无息（仅用于借款，每月还固定本金）
type LoanCalculator struct{}

// MonthlyEqualPayment 等额本息：每月固定还款额
//   P   本金
//   r   月利率（年利率 / 12 / 100）
//   n   期数（月）
// 返回：每月固定还款额
func MonthlyEqualPayment(P, r float64, n int) float64 {
	if n <= 0 {
		return 0
	}
	if r <= 0 {
		return P / float64(n)
	}
	factor := math.Pow(1+r, float64(n))
	return P * r * factor / (factor - 1)
}

// RemainingMonthsEqualPayment 等额本息下，剩余月数
//   P           贷款总额
//   paidMonths  已还月数
//   r           月利率
//   totalMonths 总期数
// 返回：剩余月数
func RemainingMonthsEqualPayment(P float64, paidMonths int, r float64, totalMonths int) int {
	if totalMonths <= 0 {
		return 0
	}
	monthly := MonthlyEqualPayment(P, r, totalMonths)
	if monthly <= 0 {
		return 0
	}
	if paidMonths >= totalMonths {
		return 0
	}
	// 已还本金：用公式反推
	_ = P
	// 简化：剩余月数 = 总月数 - 已还月数
	return totalMonths - paidMonths
}

// RemainingPrincipalEqualPayment 等额本息下，当前剩余本金
//   P, r, paidMonths, totalMonths
// 返回：剩余本金
func RemainingPrincipalEqualPayment(P, r float64, paidMonths, totalMonths int) float64 {
	if totalMonths <= 0 {
		return 0
	}
	if r <= 0 {
		return P * float64(totalMonths-paidMonths) / float64(totalMonths)
	}
	monthly := MonthlyEqualPayment(P, r, totalMonths)
	// 剩余本金 = P * (1+r)^(totalMonths-paidMonths) - monthly*((1+r)^(totalMonths-paidMonths)-1)/r
	remainingN := totalMonths - paidMonths
	if remainingN <= 0 {
		return 0
	}
	factor := math.Pow(1+r, float64(remainingN))
	return P*factor - monthly*(factor-1)/r
}

// EqualCapitalMonthlyPayment 等额本金下，第 i 月的还款额（i 从 1 开始）
//   P/n + (P - P*(i-1)/n) * r
func EqualCapitalMonthlyPayment(P, r float64, n, i int) float64 {
	if n <= 0 || i <= 0 || i > n {
		return 0
	}
	return P/float64(n) + (P-P*float64(i-1)/float64(n))*r
}

// EqualCapitalTotalPayment 等额本金，总还款额
func EqualCapitalTotalPayment(P, r float64, n int) float64 {
	if n <= 0 {
		return 0
	}
	// 总利息 = P*r*(n+1)/2
	totalInterest := P * r * float64(n+1) / 2
	return P + totalInterest
}

// RemainingPrincipalEqualCapital 等额本金下，已还 paidMonths 期的剩余本金
func RemainingPrincipalEqualCapital(P float64, paidMonths, totalMonths int) float64 {
	if totalMonths <= 0 {
		return 0
	}
	if paidMonths >= totalMonths {
		return 0
	}
	// 剩余本金 = P - (P/totalMonths) * paidMonths
	return P - P*float64(paidMonths)/float64(totalMonths)
}

// InterestFreeMonthlyPayment 无息借款：每月还固定本金
func InterestFreeMonthlyPayment(P float64, n int) float64 {
	if n <= 0 {
		return 0
	}
	return P / float64(n)
}

// MonthlyRate 年利率转月利率（百分比形式）
func MonthlyRate(annualRatePercent float64) float64 {
	return annualRatePercent / 12.0 / 100.0
}

// LoanSummary 贷款汇总信息
type LoanSummary struct {
	MonthlyPayment    float64 `json:"monthlyPayment"`    // 当月应还
	TotalPayment      float64 `json:"totalPayment"`      // 累计应还总额
	PaidAmount        float64 `json:"paidAmount"`        // 已还总额
	RemainingAmount   float64 `json:"remainingAmount"`   // 剩余应还
	ProgressPct       float64 `json:"progressPct"`       // 进度 0-1
	RemainingMonths   int     `json:"remainingMonths"`   // 剩余月数
}

// ComputeLoanSummary 根据贷款配置与已还期数计算汇总
//   P          本金
//   annualRate 年利率百分比
//   n          总期数（月）
//   paidMonths 已还期数
//   method     equal_payment / equal_capital / interest_free
func ComputeLoanSummary(P, annualRate float64, n, paidMonths int, method string) LoanSummary {
	if n <= 0 || P <= 0 {
		return LoanSummary{}
	}
	r := MonthlyRate(annualRate)
	summary := LoanSummary{RemainingMonths: n - paidMonths}
	if summary.RemainingMonths < 0 {
		summary.RemainingMonths = 0
	}
	if paidMonths > n {
		paidMonths = n
	}

	switch method {
	case "equal_payment":
		summary.MonthlyPayment = MonthlyEqualPayment(P, r, n)
		summary.TotalPayment = summary.MonthlyPayment * float64(n)
		summary.PaidAmount = summary.MonthlyPayment * float64(paidMonths)
		summary.RemainingAmount = summary.MonthlyPayment * float64(summary.RemainingMonths)
	case "equal_capital":
		// 当月还款 = 第 paidMonths+1 期
		summary.MonthlyPayment = EqualCapitalMonthlyPayment(P, r, n, paidMonths+1)
		summary.TotalPayment = EqualCapitalTotalPayment(P, r, n)
		// 已还金额 = 每期之和
		paid := 0.0
		for i := 1; i <= paidMonths; i++ {
			paid += EqualCapitalMonthlyPayment(P, r, n, i)
		}
		summary.PaidAmount = paid
		summary.RemainingAmount = summary.TotalPayment - paid
	case "interest_free":
		summary.MonthlyPayment = InterestFreeMonthlyPayment(P, n)
		summary.TotalPayment = P
		summary.PaidAmount = summary.MonthlyPayment * float64(paidMonths)
		summary.RemainingAmount = P - summary.PaidAmount
	}

	if summary.TotalPayment > 0 {
		summary.ProgressPct = summary.PaidAmount / summary.TotalPayment
	}
	if summary.ProgressPct > 1 {
		summary.ProgressPct = 1
	}
	if summary.ProgressPct < 0 {
		summary.ProgressPct = 0
	}
	return summary
}

// RemainingPrincipalAny 根据贷款方法返回剩余本金（已还 paidMonths 期）
func RemainingPrincipalAny(P, annualRate float64, n, paidMonths int, method string) float64 {
	if n <= 0 || P <= 0 {
		return 0
	}
	if paidMonths >= n {
		return 0
	}
	r := MonthlyRate(annualRate)
	switch method {
	case "equal_payment":
		return RemainingPrincipalEqualPayment(P, r, paidMonths, n)
	case "equal_capital":
		return RemainingPrincipalEqualCapital(P, paidMonths, n)
	case "interest_free":
		return P - InterestFreeMonthlyPayment(P, n)*float64(paidMonths)
	}
	return 0
}

// BenefitSummary 未来利益汇总（用户直接填写发放时间/金额）
//   payoutDate       发放时间：一次性=发放日期；逐月/年/终身/自定义=开始发放时间
//   payoutAmount     发放额：一次性=总发放额；逐月=每月发放额；按年=每年发放额；终身=每月发放额；自定义=每月发放额
//   benefitType      monthly/yearly/lump_sum/lifetime/custom_years
//   currentAge       当前年龄（仅 lifetime 用）
//   lifeExpectancy   预期活到 X 岁（仅 lifetime 用，默认 80）
//   customYears      自定义年限（仅 custom_years 用）
// 返回：
//   - payoutDate
//   - payoutAmount
//   - type
//   - yearsLeft    距离首期发放剩余年数
//   - presentValue 折现到当下的总价值（按 3% 年化折现）
//   - description
func BenefitSummary(payoutDate int64, payoutAmount float64, benefitType string, currentAge, lifeExpectancy, customYears int) map[string]any {
	res := map[string]any{
		"payoutDate":   payoutDate,
		"payoutAmount": payoutAmount,
		"type":         benefitType,
		"yearsLeft":    0.0,
		"presentValue": payoutAmount,
		"description":  "",
	}
	if payoutDate <= 0 || payoutAmount <= 0 {
		switch benefitType {
		case "lump_sum":
			res["description"] = "一次性发放"
		case "monthly":
			res["description"] = "逐月发放"
		case "yearly":
			res["description"] = "按年发放"
		case "lifetime":
			res["description"] = "终身发放"
		case "custom_years":
			res["description"] = "自定义年限发放"
		}
		return res
	}
	const r = 0.03 // 家庭总财富折现年化（保守 3%）
	now := time.Now().Unix()
	if payoutDate > now {
		yearsLeft := float64(payoutDate-now) / (365.25 * 24 * 3600.0)
		res["yearsLeft"] = yearsLeft
	} else {
		res["yearsLeft"] = 0
	}
	switch benefitType {
	case "lump_sum":
		// 一次性：到期发放额 = payoutAmount；未到期则折现
		if payoutDate > now {
			res["presentValue"] = payoutAmount / math.Pow(1+r, res["yearsLeft"].(float64))
		} else {
			res["presentValue"] = payoutAmount
		}
		res["description"] = "一次性发放"
	case "monthly":
		// 逐月：活到 lifeExpectancy
		totalYears := lifeExpectancy - currentAge
		if totalYears <= 0 {
			totalYears = 30
		}
		totalMonths := float64(totalYears * 12)
		var pv float64
		for i := 0.0; i < totalMonths; i++ {
			t := res["yearsLeft"].(float64) + i/12.0
			if t < 0 {
				t = 0
			}
			pv += payoutAmount / math.Pow(1+r, t)
		}
		res["presentValue"] = pv
		res["description"] = "逐月发放至" + itoa(lifeExpectancy) + "岁"
	case "yearly":
		// 按年：活到 lifeExpectancy
		totalYears := lifeExpectancy - currentAge
		if totalYears <= 0 {
			totalYears = 30
		}
		years := float64(totalYears)
		var pv float64
		for i := 0.0; i < years; i++ {
			t := res["yearsLeft"].(float64) + i
			if t < 0 {
				t = 0
			}
			pv += payoutAmount / math.Pow(1+r, t)
		}
		res["presentValue"] = pv
		res["description"] = "按年发放至" + itoa(lifeExpectancy) + "岁"
	case "lifetime":
		// 终身：活到 lifeExpectancy（约）
		totalYears := lifeExpectancy - currentAge
		if totalYears <= 0 {
			totalYears = 30
		}
		totalMonths := float64(totalYears * 12)
		var pv float64
		for i := 0.0; i < totalMonths; i++ {
			t := res["yearsLeft"].(float64) + i/12.0
			if t < 0 {
				t = 0
			}
			pv += payoutAmount / math.Pow(1+r, t)
		}
		res["presentValue"] = pv
		res["description"] = "终身逐月（活到" + itoa(lifeExpectancy) + "岁）"
	case "custom_years":
		// 自定义年限
		if customYears <= 0 {
			customYears = 10
		}
		totalMonths := float64(customYears * 12)
		var pv float64
		for i := 0.0; i < totalMonths; i++ {
			t := res["yearsLeft"].(float64) + i/12.0
			if t < 0 {
				t = 0
			}
			pv += payoutAmount / math.Pow(1+r, t)
		}
		res["presentValue"] = pv
		res["description"] = "自定义发放" + itoa(customYears) + "年"
	}
	return res
}

// itoa 整数转字符串（避免引入 strconv 包的依赖膨胀）
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
