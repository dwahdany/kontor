import Foundation
import KontorModel

/// The return of one calendar month (possibly partial at the edges of the interval).
public struct MonthReturn: Sendable, Hashable, Identifiable {
    /// `year × 12 + month − 1`, unique and ascending.
    public var id: Int { year * 12 + month - 1 }
    public let year: Int
    public let month: Int
    public let value: Double

    public init(year: Int, month: Int, value: Double) {
        self.year = year
        self.month = month
        self.value = value
    }
}

/// The return of one calendar year (possibly partial at the edges of the interval).
public struct YearReturn: Sendable, Hashable, Identifiable {
    public var id: Int { year }
    public let year: Int
    public let value: Double

    public init(year: Int, value: Double) {
        self.year = year
        self.value = value
    }
}

extension ReturnSeries {
    /// Compounded returns per calendar month, in chronological order.
    public func monthlyReturns() -> [MonthReturn] {
        var out: [MonthReturn] = []
        guard count > 1 else { return out }
        var current = day(at: 1).ymd
        var factor = 1.0
        var nextMonthStart = day(at: 1).endOfMonth.rawValue + 1
        for i in 1..<count {
            let raw = interval.start.rawValue + Int32(i)
            if raw >= nextMonthStart {
                out.append(MonthReturn(year: current.year, month: current.month, value: factor - 1))
                let d = Day(rawValue: raw)
                current = d.ymd
                nextMonthStart = d.endOfMonth.rawValue + 1
                factor = 1
            }
            factor *= 1 + daily[i]
        }
        out.append(MonthReturn(year: current.year, month: current.month, value: factor - 1))
        return out
    }

    /// Compounded returns per calendar year, in chronological order.
    public func yearlyReturns() -> [YearReturn] {
        var out: [YearReturn] = []
        var factor = 1.0
        var year: Int?
        for m in monthlyReturns() {
            if let y = year, y != m.year {
                out.append(YearReturn(year: y, value: factor - 1))
                factor = 1
            }
            year = m.year
            factor *= 1 + m.value
        }
        if let y = year { out.append(YearReturn(year: y, value: factor - 1)) }
        return out
    }

    /// Drawdown from the running peak for each day (0 at a peak, e.g. 0.25 = 25 % below the peak).
    public func drawdowns() -> [Double] {
        var out = [Double](repeating: 0, count: count)
        var peak = 1.0
        for i in 0..<count {
            let wealth = 1 + cumulative[i]
            if wealth > peak { peak = wealth }
            out[i] = peak > 0 ? 1 - wealth / peak : 0
        }
        return out
    }
}

/// Risk figures derived from a daily return series.
public struct RiskMetrics: Sendable, Hashable {
    /// The deepest peak-to-trough decline.
    public struct Drawdown: Sendable, Hashable {
        /// Depth as a positive fraction (0.25 = −25 %).
        public let depth: Double
        public let peak: Day
        public let trough: Day
        /// First day after the trough on which the peak level was reached again; nil if not recovered.
        public let recovery: Day?

        public init(depth: Double, peak: Day, trough: Day, recovery: Day?) {
            self.depth = depth
            self.peak = peak
            self.trough = trough
            self.recovery = recovery
        }

        /// Days from peak to trough.
        public var declineDays: Int { peak.distance(to: trough) }
        /// Days from peak to recovery; nil if not recovered.
        public var durationDays: Int? { recovery.map { peak.distance(to: $0) } }
    }

    public struct DayReturn: Sendable, Hashable {
        public let day: Day
        public let value: Double

        public init(day: Day, value: Double) {
            self.day = day
            self.value = value
        }
    }

    /// Maximum drawdown; nil if the series never fell below a previous peak.
    public let maxDrawdown: Drawdown?
    /// Annualized volatility: sample standard deviation of weekday returns × √tradingDaysPerYear.
    public let volatility: Double
    /// Annualized downside volatility: like `volatility`, but only returns below the mean contribute
    /// to the sum of squares (same denominator, n − 1).
    public let semiVolatility: Double
    /// `(annualized return − riskFreeRate) / volatility`; nil if volatility is 0 or the return is undefined.
    public let sharpeRatio: Double?
    public let bestDay: DayReturn?
    public let worstDay: DayReturn?
    public let bestMonth: MonthReturn?
    public let worstMonth: MonthReturn?

    /// Computes the metrics. Saturdays and Sundays are excluded from the volatility sample (markets
    /// are closed, the return is structurally 0). `riskFreeRate` is annual (0.02 = 2 %).
    public init(returns: ReturnSeries, riskFreeRate: Double = 0, tradingDaysPerYear: Double = 252) {
        let n = returns.count

        // Drawdown.
        var peak = 1.0, peakIndex = 0
        var worst = 0.0, worstPeak = 0, worstTrough = 0, worstPeakLevel = 1.0
        for i in 0..<n {
            let wealth = 1 + returns.cumulative[i]
            if wealth > peak {
                peak = wealth
                peakIndex = i
            } else if peak > 0 {
                let depth = 1 - wealth / peak
                if depth > worst {
                    worst = depth
                    worstPeak = peakIndex
                    worstTrough = i
                    worstPeakLevel = peak
                }
            }
        }
        if worst > 0 {
            var recovery: Day?
            var i = worstTrough + 1
            while i < n {
                if 1 + returns.cumulative[i] >= worstPeakLevel {
                    recovery = returns.day(at: i)
                    break
                }
                i += 1
            }
            maxDrawdown = Drawdown(
                depth: worst, peak: returns.day(at: worstPeak), trough: returns.day(at: worstTrough), recovery: recovery)
        } else {
            maxDrawdown = nil
        }

        // Volatility over weekdays; best / worst day over all days.
        var sum = 0.0, samples = 0
        var best: DayReturn?, worstDay: DayReturn?
        var weekday = n > 1 ? returns.day(at: 1).weekday : 1
        for i in 1..<max(n, 1) {
            let r = returns.daily[i]
            if weekday < 6 {
                sum += r
                samples += 1
            }
            if best == nil || r > best!.value { best = DayReturn(day: returns.day(at: i), value: r) }
            if worstDay == nil || r < worstDay!.value { worstDay = DayReturn(day: returns.day(at: i), value: r) }
            weekday = weekday == 7 ? 1 : weekday + 1
        }
        var variance = 0.0, downside = 0.0
        if samples > 1 {
            let mean = sum / Double(samples)
            weekday = returns.day(at: 1).weekday
            for i in 1..<n {
                if weekday < 6 {
                    let d = returns.daily[i] - mean
                    variance += d * d
                    if d < 0 { downside += d * d }
                }
                weekday = weekday == 7 ? 1 : weekday + 1
            }
            variance /= Double(samples - 1)
            downside /= Double(samples - 1)
        }
        volatility = (variance * tradingDaysPerYear).squareRoot()
        semiVolatility = (downside * tradingDaysPerYear).squareRoot()
        if volatility > 0, let annual = returns.annualized {
            sharpeRatio = (annual - riskFreeRate) / volatility
        } else {
            sharpeRatio = nil
        }
        bestDay = best
        self.worstDay = worstDay

        let months = returns.monthlyReturns()
        bestMonth = months.max { $0.value < $1.value }
        worstMonth = months.min { $0.value < $1.value }
    }
}
