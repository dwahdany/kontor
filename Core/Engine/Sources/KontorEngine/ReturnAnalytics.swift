import Foundation
import KontorModel

/// Calendar heatmap of time-weighted returns: one row per year, one cell per month.
public struct ReturnHeatmap: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: Int { year }
        public let year: Int
        /// Twelve cells, January first; nil for months outside the interval. Months at the edges
        /// of the interval may be partial.
        public let months: [Double?]
        /// Compounded return of the year's months inside the interval.
        public let total: Double
    }

    /// Chronological.
    public let rows: [Row]
    /// Smallest and largest monthly return (for a symmetric colour scale); nil if empty.
    public let monthlyRange: ClosedRange<Double>?

    /// The cell of one month; nil if outside the interval.
    public func value(year: Int, month: Int) -> Double? {
        guard (1...12).contains(month), let row = rows.first(where: { $0.year == year }) else { return nil }
        return row.months[month - 1]
    }
}

/// Returns over a sliding window of fixed length, on the day axis of the source series.
public struct RollingReturns: Sendable {
    public let interval: DayInterval
    /// Window length in days.
    public let windowDays: Int
    /// Whether values are expressed per year (`(1 + r)^(365 / window) − 1`).
    public let isAnnualized: Bool
    /// `values[i]` is the return over the `windowDays` days ending on day `interval.start + i`;
    /// nil for the first `windowDays` indices and where the window starts from a total loss.
    public let values: [Double?]
    public let best: Double?
    public let worst: Double?
    public let average: Double?
    /// Fraction of windows with a positive return.
    public let positiveShare: Double?

    public func day(at index: Int) -> Day { interval.start.advanced(by: index) }

    /// The defined values as chart points, reduced to at most `maxPoints` (see `Downsampler`).
    public func chartPoints(maxPoints: Int) -> [ChartPoint<Double>] {
        var days: [Int] = [], defined: [Double] = []
        for (i, v) in values.enumerated() {
            if let v {
                days.append(i)
                defined.append(v)
            }
        }
        return Downsampler.indices(defined, maxPoints: maxPoints).map { ChartPoint(day: day(at: days[$0]), value: defined[$0]) }
    }
}

extension ReturnSeries {
    /// The year × month heatmap of this series.
    public func heatmap() -> ReturnHeatmap {
        var rows: [ReturnHeatmap.Row] = []
        var cells = [Double?](repeating: nil, count: 12)
        var factor = 1.0
        var year: Int?
        var low = Double.infinity, high = -Double.infinity
        for m in monthlyReturns() {
            if let y = year, y != m.year {
                rows.append(ReturnHeatmap.Row(year: y, months: cells, total: factor - 1))
                cells = [Double?](repeating: nil, count: 12)
                factor = 1
            }
            year = m.year
            cells[m.month - 1] = m.value
            factor *= 1 + m.value
            low = min(low, m.value)
            high = max(high, m.value)
        }
        if let y = year { rows.append(ReturnHeatmap.Row(year: y, months: cells, total: factor - 1)) }
        return ReturnHeatmap(rows: rows, monthlyRange: low <= high ? low...high : nil)
    }

    /// Rolling returns over `windowDays` calendar days (365 = rolling one-year return).
    public func rollingReturns(windowDays: Int, annualized: Bool = false) -> RollingReturns {
        let window = max(windowDays, 1)
        var values = [Double?](repeating: nil, count: count)
        var best: Double?, worst: Double?
        var sum = 0.0, defined = 0, positive = 0
        let exponent = 365 / Double(window)
        if count > window {
            for i in window..<count {
                let base = 1 + cumulative[i - window]
                guard base > 0 else { continue }
                var r = (1 + cumulative[i]) / base - 1
                if annualized { r = r <= -1 ? -1 : pow(1 + r, exponent) - 1 }
                guard r.isFinite else { continue }
                values[i] = r
                best = max(best ?? r, r)
                worst = min(worst ?? r, r)
                sum += r
                defined += 1
                if r > 0 { positive += 1 }
            }
        }
        return RollingReturns(
            interval: interval, windowDays: window, isAnnualized: annualized, values: values, best: best, worst: worst,
            average: defined > 0 ? sum / Double(defined) : nil,
            positiveShare: defined > 0 ? Double(positive) / Double(defined) : nil)
    }
}

extension Ledger {
    /// TTWROR per calendar month and year of `scope` over `interval` (one daily valuation pass).
    public func returnHeatmap(in interval: DayInterval, scope: Scope = .portfolio) -> ReturnHeatmap {
        valuation(in: interval, scope: scope).returns().heatmap()
    }

    /// Rolling TTWROR of `scope` over `interval` (one daily valuation pass).
    public func rollingReturns(
        in interval: DayInterval, windowDays: Int, annualized: Bool = false, scope: Scope = .portfolio
    ) -> RollingReturns {
        valuation(in: interval, scope: scope).returns().rollingReturns(windowDays: windowDays, annualized: annualized)
    }
}
