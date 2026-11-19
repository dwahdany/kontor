import Foundation
import KontorModel
import KontorEngine

/// A linear value axis with "nice" bounds and ticks (multiples of 1, 2, 2.5 or 5 × 10ⁿ).
public struct LinearScale: Sendable, Hashable {
    public var lower: Double
    public var upper: Double
    public var step: Double
    public var ticks: [Double]

    /// A scale covering `min … max` with about `targetTicks` ticks.
    /// - Parameters:
    ///   - includeZero: extends the range to contain 0 (bars, areas, returns).
    ///   - padding: fraction of the span added on open ends (not on an end that sits at 0), so
    ///     marks do not touch the plot edge.
    ///   - tight: `true` keeps the padded data range as the bounds and places ticks at the round
    ///     values inside it (no wasted plot area); `false` rounds the bounds outwards to ticks.
    public static func nice(
        min: Double, max: Double, targetTicks: Int = 5, includeZero: Bool = false, padding: Double = 0, tight: Bool = false
    ) -> LinearScale {
        var lo = min.isFinite ? min : 0, hi = max.isFinite ? max : 1
        if lo > hi { swap(&lo, &hi) }
        if includeZero {
            lo = Swift.min(lo, 0)
            hi = Swift.max(hi, 0)
        }
        let anchoredLow = includeZero && lo == 0, anchoredHigh = includeZero && hi == 0
        if hi - lo < 1e-12 * Swift.max(1, abs(hi)) {
            // Flat data: open a window around the value (upwards from zero).
            let pad = abs(hi) > 0 ? abs(hi) * 0.1 : 1
            if anchoredLow { hi += pad } else if anchoredHigh { lo -= pad } else {
                lo -= pad
                hi += pad
            }
        } else if padding > 0 {
            let pad = (hi - lo) * padding
            if !anchoredLow { lo -= pad }
            if !anchoredHigh { hi += pad }
        }
        let target = Double(Swift.max(2, targetTicks))
        let raw = (hi - lo) / target
        let magnitude = pow(10, floor(log10(raw)))
        // The round step whose tick count comes closest to the target.
        var step = magnitude
        var bestDistance = Double.infinity
        for factor in [1, 2, 2.5, 5, 10] {
            let distance = abs((hi - lo) / (factor * magnitude) - target)
            if distance < bestDistance - 1e-9 {
                bestDistance = distance
                step = factor * magnitude
            }
        }
        let first = tight ? ceil(lo / step - 1e-9) : floor(lo / step + 1e-9)
        let last = tight ? floor(hi / step + 1e-9) : ceil(hi / step - 1e-9)
        var ticks = [Double]()
        var k = first
        while k <= last + 0.5 {
            let v = k * step
            // Snap float dust to zero so "0" is exactly 0.
            ticks.append(abs(v) < step * 1e-9 ? 0 : v)
            k += 1
        }
        if tight { return LinearScale(lower: lo, upper: hi, step: step, ticks: ticks) }
        let lower = first * step, upper = Swift.max(last * step, first * step + step)
        if ticks.count < 2 { ticks = [lower, upper] }
        return LinearScale(lower: lower, upper: upper, step: step, ticks: ticks)
    }

    /// 0 (lower) … 1 (upper); unclamped.
    public func position(_ value: Double) -> Double {
        upper > lower ? (value - lower) / (upper - lower) : 0.5
    }
}

/// One tick of a day axis.
public struct DayTick: Sendable, Hashable {
    public var day: Day
    public var label: String
}

/// Tick placement for a day axis: picks days, weeks, months, quarters, half-years or years so that
/// at most `maxTicks` labels are shown, and labels them through `Fmt`.
public enum DayAxis {
    public enum Unit: Sendable, Hashable {
        case days(Int), months(Int), years(Int)
    }

    /// The coarsest-necessary unit for the span.
    public static func unit(from start: Day, to end: Day, maxTicks: Int) -> Unit {
        let span = Swift.max(1, start.distance(to: end))
        let n = Double(Swift.max(2, maxTicks))
        let candidates: [(Unit, Double)] = [
            (.days(1), 1), (.days(2), 2), (.days(7), 7), (.days(14), 14),
            (.months(1), 30.44), (.months(2), 60.9), (.months(3), 91.3), (.months(6), 182.6),
            (.years(1), 365.25), (.years(2), 730.5), (.years(5), 1826), (.years(10), 3652), (.years(25), 9131),
        ]
        for (unit, days) in candidates where Double(span) / days <= n { return unit }
        return .years(50)
    }

    /// Ticks inside `start … end`, at most `maxTicks`.
    public static func ticks(from start: Day, to end: Day, maxTicks: Int) -> [DayTick] {
        guard end > start else { return [DayTick(day: start, label: Fmt.day(start, style: .dayMonth))] }
        var result = [DayTick]()
        switch unit(from: start, to: end, maxTicks: maxTicks) {
        case .days(let step):
            // Anchor multi-day steps on Mondays so weekly ticks look regular.
            var day = start
            if step >= 7 { while day.weekday != 1 { day = day.advanced(by: 1) } }
            while day <= end {
                result.append(DayTick(day: day, label: Fmt.day(day, style: .dayMonth)))
                day = day.advanced(by: step)
            }
        case .months(let step):
            var c = start.ymd
            if c.day > 1 {
                c.month += 1
                if c.month > 12 { c = (c.year + 1, 1, 1) }
            }
            // Align to multiples of the step within the year (Jan/Apr/Jul/Oct for quarters).
            while (c.month - 1) % step != 0 {
                c.month += 1
                if c.month > 12 { c = (c.year + 1, 1, 1) }
            }
            var day = Day(year: c.year, month: c.month, day: 1)
            while day <= end {
                result.append(DayTick(day: day, label: Fmt.month(year: day.year, month: day.month)))
                day = day.addingMonths(step)
            }
        case .years(let step):
            var year = start.year + (start == start.startOfYear ? 0 : 1)
            while year % step != 0 { year += 1 }
            var day = Day(year: year, month: 1, day: 1)
            while day <= end {
                result.append(DayTick(day: day, label: String(day.year)))
                year += step
                day = Day(year: year, month: 1, day: 1)
            }
        }
        return result
    }
}

/// Histogram binning with nice bin edges.
public struct Histogram: Sendable, Hashable {
    public struct Bin: Sendable, Hashable, Identifiable {
        public var id: Int
        public var lower: Double
        public var upper: Double
        public var count: Int
    }

    public var bins: [Bin]
    public var total: Int
    public var mean: Double?
    public var median: Double?

    /// Bins `values` (non-finite ones are ignored) into about `targetBins` bins whose edges are
    /// round numbers and include 0 as an edge when the data crosses it.
    public init(_ values: [Double], targetBins: Int = 20) {
        let finite = values.filter(\.isFinite).sorted()
        total = finite.count
        guard let lo = finite.first, let hi = finite.last else {
            bins = []
            mean = nil
            median = nil
            return
        }
        mean = finite.reduce(0, +) / Double(finite.count)
        median = finite.count.isMultiple(of: 2) ? (finite[finite.count / 2 - 1] + finite[finite.count / 2]) / 2 : finite[finite.count / 2]
        let scale = LinearScale.nice(min: lo, max: hi, targetTicks: Swift.max(2, targetBins))
        let count = Swift.max(1, Int(((scale.upper - scale.lower) / scale.step).rounded()))
        var counts = [Int](repeating: 0, count: count)
        for v in finite {
            // The top edge belongs to the last bin.
            let i = Swift.min(count - 1, Swift.max(0, Int(floor((v - scale.lower) / scale.step + 1e-9))))
            counts[i] += 1
        }
        func edge(_ i: Int) -> Double {
            let v = scale.lower + Double(i) * scale.step
            return abs(v) < scale.step * 1e-9 ? 0 : v
        }
        bins = counts.enumerated().map { i, c in Bin(id: i, lower: edge(i), upper: edge(i + 1), count: c) }
        // Trim empty bins at both ends.
        while let first = bins.first, first.count == 0, bins.count > 1 { bins.removeFirst() }
        while let last = bins.last, last.count == 0, bins.count > 1 { bins.removeLast() }
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rectangles with areas proportional to the
/// weights and aspect ratios as close to 1 as possible.
public enum Treemap {
    /// - Parameter weights: non-negative; zero and non-finite weights get an empty rectangle.
    /// - Returns: one rectangle per weight, in the order given. Lay out in descending order for the
    ///   best aspect ratios (``TreemapChart`` does).
    public static func layout(weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let clean = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = clean.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let order = clean.indices.filter { clean[$0] > 0 }.sorted { clean[$0] > clean[$1] }
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { clean[$0] * scale }

        var free = rect
        var index = 0
        while index < areas.count {
            let side = Double(Swift.min(free.width, free.height))
            guard side > 0 else { break }
            // Grow the row while the worst aspect ratio improves.
            var end = index + 1
            var sum = areas[index]
            var worst = Self.worst(min: areas[index], max: areas[index], sum: sum, side: side)
            while end < areas.count {
                let next = sum + areas[end]
                let candidate = Self.worst(min: areas[end], max: areas[index], sum: next, side: side)
                if candidate > worst { break }
                worst = candidate
                sum = next
                end += 1
            }
            // Lay the row along the shorter side.
            let thickness = CGFloat(sum / side)
            var offset: CGFloat = 0
            for i in index..<end {
                let length = CGFloat(areas[i] / sum * side)
                if free.width >= free.height {
                    result[order[i]] = CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                } else {
                    result[order[i]] = CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                }
                offset += length
            }
            if free.width >= free.height {
                free = CGRect(x: free.minX + thickness, y: free.minY, width: Swift.max(0, free.width - thickness), height: free.height)
            } else {
                free = CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: Swift.max(0, free.height - thickness))
            }
            index = end
        }
        return result
    }

    private static func worst(min: Double, max: Double, sum: Double, side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }
}

/// Reduces a polyline to at most two points per horizontal pixel (min/max envelope), preserving
/// what would be visible. Charts call this per draw, so callers may pass daily data for decades.
enum ChartReducer {
    /// - Parameters:
    ///   - xs: ascending x positions in points.
    ///   - ys: y positions.
    /// - Returns: indices to keep, ascending.
    static func indices(xs: [CGFloat], ys: [CGFloat]) -> [Int] {
        let n = xs.count
        guard n > 2, let first = xs.first, let last = xs.last else { return Array(0..<n) }
        let columns = Swift.max(1, Int((last - first).rounded(.up)))
        guard n > columns * 3 else { return Array(0..<n) }
        var keep = [Int]()
        keep.reserveCapacity(columns * 2 + 2)
        var i = 0
        while i < n {
            let column = Int(xs[i] - first)
            var lo = i, hi = i, j = i
            while j < n, Int(xs[j] - first) == column {
                if ys[j] < ys[lo] { lo = j }
                if ys[j] > ys[hi] { hi = j }
                j += 1
            }
            // First, extremes in order, last of the column — keeps continuity between columns.
            var picks = [i, Swift.min(lo, hi), Swift.max(lo, hi), j - 1]
            picks.sort()
            for p in picks where keep.last != p { keep.append(p) }
            i = j
        }
        return keep
    }
}
