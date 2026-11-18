import Foundation
import KontorModel

/// A daily return series on the day axis of a `DayInterval`: index `i` is day `interval.start + i`.
public struct ReturnSeries: Sendable {
    public let interval: DayInterval
    /// Simple return of each day; `daily[0]` (the baseline) is 0.
    public let daily: [Double]
    /// Cumulative return since the baseline: `∏(1 + daily[1…i]) − 1`; `cumulative[0]` is 0.
    public let cumulative: [Double]

    /// Builds the series from daily returns (the first element is forced to 0).
    public init(interval: DayInterval, daily: [Double]) {
        var d = daily
        if !d.isEmpty { d[0] = 0 }
        var cumulative = [Double](repeating: 0, count: d.count)
        var factor = 1.0
        for i in d.indices.dropFirst() {
            factor *= 1 + d[i]
            cumulative[i] = factor - 1
        }
        self.interval = interval
        self.daily = d
        self.cumulative = cumulative
    }

    /// Builds the series from index levels (e.g. prices): `daily[i] = level[i] / level[i−1] − 1`.
    /// Non-positive previous levels yield a 0 return.
    public init(interval: DayInterval, levels: [Double]) {
        var daily = [Double](repeating: 0, count: levels.count)
        for i in levels.indices.dropFirst() where levels[i - 1] > 0 {
            daily[i] = levels[i] / levels[i - 1] - 1
        }
        self.init(interval: interval, daily: daily)
    }

    public var count: Int { daily.count }
    public func day(at index: Int) -> Day { interval.start.advanced(by: index) }
    /// Total return over the interval.
    public var total: Double { cumulative.last ?? 0 }
    /// Total return expressed per year, see `Returns.annualize`.
    public var annualized: Double? { Returns.annualize(total: total, days: interval.dayCount) }
}

/// Return mathematics: time-weighted returns, annualization and the internal rate of return.
public enum Returns {
    /// The time-weighted return of one day.
    ///
    /// **Convention:** inflows are invested at the *start* of the day, outflows leave at the *end*:
    ///
    ///     r = (V_t + outflows_t) / (V_{t−1} + inflows_t) − 1
    ///
    /// This is well-defined when a scope starts empty (`V_{t−1} = 0`, first purchase), when it is
    /// liquidated completely (`V_t = 0`), and for a same-day round trip. A return is only defined on
    /// a positive base: if the previous value is negative (overdrawn account, short position) or
    /// the denominator is not positive (nothing invested), the day's return is 0. A loss of more
    /// than the invested value is capped at −100 %.
    @inlinable
    public static func dailyReturn(previous: Int64, value: Int64, inflow: Int64, outflow: Int64) -> Double {
        growthFactor(previous: previous, value: value, inflow: inflow, outflow: outflow) - 1
    }

    /// `1 + dailyReturn(…)`, never negative.
    @inlinable
    public static func growthFactor(previous: Int64, value: Int64, inflow: Int64, outflow: Int64) -> Double {
        let denominator = Double(previous + inflow)
        guard previous >= 0, denominator > 0 else { return 1 }
        return max(Double(value + outflow) / denominator, 0)
    }

    /// Converts a total return over `days` into a yearly rate: `(1 + total)^(365 / days) − 1`.
    /// Nil for an empty interval; −1 for a total loss.
    public static func annualize(total: Double, days: Int) -> Double? {
        guard days > 0, total.isFinite else { return nil }
        if total <= -1 { return -1 }
        let value = pow(1 + total, 365 / Double(days)) - 1
        return value.isFinite ? value : nil
    }

    /// A dated cash flow for the IRR: `amount > 0` is money received by the investor,
    /// `amount < 0` money invested. `day` is an offset in days from an arbitrary origin.
    public struct CashFlow: Sendable, Hashable {
        public var day: Int
        public var amount: Double
        public init(day: Int, amount: Double) {
            self.day = day
            self.amount = amount
        }
    }

    /// The internal rate of return (annual, money-weighted): the rate `r` with
    /// `Σ amount_i · (1 + r)^(−(day_i − day_0) / 365) = 0`.
    ///
    /// Robust solver: works on `x = ln(1 + r)`, brackets the root closest to 0 % on an expanding
    /// grid, then refines with safeguarded Newton (bisection fallback). Returns nil if the flows do
    /// not contain both signs, span no time, or no root exists for a growth factor `1 + r` between
    /// 10⁻¹² and 10¹² per year.
    public static func irr(_ flows: [CashFlow]) -> Double? {
        var hasPositive = false, hasNegative = false
        var origin = Int.max, last = Int.min
        for f in flows where f.amount != 0 {
            guard f.amount.isFinite else { return nil }
            if f.amount > 0 { hasPositive = true } else { hasNegative = true }
            origin = min(origin, f.day)
            last = max(last, f.day)
        }
        guard hasPositive, hasNegative, last > origin else { return nil }
        let times = flows.map { Double($0.day - origin) / 365 }
        let amounts = flows.map(\.amount)

        // f(x) = Σ a_i · e^(−x·t_i) and its derivative.
        func evaluate(_ x: Double) -> (f: Double, df: Double) {
            var f = 0.0, df = 0.0
            for i in amounts.indices where amounts[i] != 0 {
                let term = amounts[i] * exp(-x * times[i])
                f += term
                df -= times[i] * term
            }
            return (f, df)
        }

        let f0 = evaluate(0).f
        if f0 == 0 { return 0 }
        guard f0.isFinite else { return nil }

        // Expand outwards from x = 0 in both directions until the sign changes.
        let xMin = log(1e-12), xMax = log(1e12)
        var bracket: (lo: Double, hi: Double, flo: Double)?
        var up = (x: 0.0, f: f0, done: false), down = (x: 0.0, f: f0, done: false)
        var step = 0.02
        while bracket == nil, !(up.done && down.done) {
            if !up.done {
                let x = min(up.x + step, xMax)
                let f = evaluate(x).f
                if !f.isFinite { up.done = true }
                else if (f > 0) != (up.f > 0) || f == 0 { bracket = (up.x, x, up.f) }
                else {
                    up = (x, f, x >= xMax)
                }
            }
            if bracket == nil, !down.done {
                let x = max(down.x - step, xMin)
                let f = evaluate(x).f
                if !f.isFinite { down.done = true }
                else if (f > 0) != (down.f > 0) || f == 0 { bracket = (x, down.x, f) }
                else {
                    down = (x, f, x <= xMin)
                }
            }
            step *= 1.6
        }
        guard var b = bracket else { return nil }

        // Safeguarded Newton inside the bracket.
        var x = 0.5 * (b.lo + b.hi)
        for _ in 0..<200 {
            let (f, df) = evaluate(x)
            if f == 0 { break }
            if (f > 0) == (b.flo > 0) { b.lo = x; b.flo = f } else { b.hi = x }
            var next = df != 0 ? x - f / df : .nan
            if !(next > b.lo && next < b.hi) { next = 0.5 * (b.lo + b.hi) }
            if abs(next - x) < 1e-13 * max(1, abs(x)) { x = next; break }
            x = next
        }
        let r = expm1(x)
        return r.isFinite ? r : nil
    }
}

extension ValuationSeries {
    /// The true time-weighted rate of return (TTWROR) of the series: daily and cumulative returns
    /// using the convention documented at `Returns.dailyReturn`.
    public func returns() -> ReturnSeries {
        var daily = [Double](repeating: 0, count: values.count)
        for i in values.indices.dropFirst() {
            daily[i] = Returns.dailyReturn(
                previous: values[i - 1], value: values[i], inflow: inflows[i], outflow: outflows[i])
        }
        return ReturnSeries(interval: interval, daily: daily)
    }

    /// The internal rate of return (annual) of the interval: the baseline value is invested at the
    /// start, each day's net flow on its day, and the final value is received at the end.
    public func irr() -> Double? {
        guard values.count > 1 else { return nil }
        var flows: [Returns.CashFlow] = [.init(day: 0, amount: -Double(values[0]))]
        for i in values.indices.dropFirst() where inflows[i] != outflows[i] {
            flows.append(.init(day: i, amount: Double(outflows[i] - inflows[i])))
        }
        flows.append(.init(day: values.count - 1, amount: Double(values[values.count - 1])))
        return Returns.irr(flows)
    }

    /// Cumulative invested capital per day: the baseline value (optional) plus all net external
    /// flows up to and including that day. Plot it next to `values` to visualise gains.
    public func investedCapital(includingInitialValue: Bool = true) -> [Int64] {
        var out = [Int64](repeating: 0, count: values.count)
        var running = includingInitialValue ? initialValue : 0
        for i in values.indices {
            running += inflows[i] - outflows[i]
            out[i] = running
        }
        return out
    }
}
