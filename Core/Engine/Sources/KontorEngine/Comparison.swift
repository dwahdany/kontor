import Foundation
import KontorModel

/// The currency in which a benchmark's price performance is measured.
public enum PriceBasis: String, Sendable, Codable, CaseIterable {
    /// Converted into the ledger's reporting currency at each day's rate (includes currency effects).
    case reportingCurrency
    /// In the security's own quote currency.
    case securityCurrency
}

extension Ledger {
    /// Normalized price performance of a security over `interval`, on the same day axis as
    /// `valuation(in:)` and `ValuationSeries.returns()`: `cumulative[i] = P(start + i) / P(start) − 1`.
    ///
    /// Prices use last-known semantics (weekends and holidays are flat; before the first quote the
    /// first quote applies). Returns nil if the security is unknown, has no prices, or — for
    /// `.reportingCurrency` — its currency cannot be converted.
    public func benchmark(
        securityID: UUID, in interval: DayInterval, basis: PriceBasis = .reportingCurrency
    ) -> ReturnSeries? {
        guard let levels = priceLevels(securityID: securityID, in: interval, basis: basis) else { return nil }
        return ReturnSeries(interval: interval, levels: levels)
    }

    /// Daily price levels (as floating-point currency units) of a security over `interval`.
    public func priceLevels(
        securityID: UUID, in interval: DayInterval, basis: PriceBasis = .reportingCurrency
    ) -> [Double]? {
        guard let s = securityIndex(securityID) else { return nil }
        let n = interval.dayCount + 1
        let start = interval.start.rawValue
        var cursor = priceIndex(s, on: start)
        guard cursor >= 0 else { return nil }
        var rates: [Double]?
        let currency = Int(securityCurrency[s])
        if basis == .reportingCurrency, currency != 0 {
            guard let path = currencyPaths[currency] else { return nil }
            rates = converter.dailyRates(along: path, from: interval.start, count: n)
        }
        let end = priceOffsets[s + 1]
        var levels = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let day = start + Int32(i)
            while cursor + 1 < end, priceDays[cursor + 1] <= day { cursor += 1 }
            let price = Double(priceValues[cursor]) / Double(Scale.price)
            levels[i] = rates.map { price * $0[i] } ?? price
        }
        return levels
    }
}

/// Reduces long daily series to a bounded number of points for charting.
public enum Downsampler {
    /// Indices of at most `maxPoints` elements of `values` that preserve the visual shape: the first
    /// and last element are always kept, and the range in between is divided into equal buckets from
    /// each of which the minimum and the maximum are kept (so global extrema always survive).
    /// Indices are strictly ascending. If `values.count <= maxPoints` all indices are returned.
    public static func indices<T: Comparable>(_ values: [T], maxPoints: Int) -> [Int] {
        let n = values.count
        let limit = max(maxPoints, 2)
        if n <= limit { return Array(0..<n) }
        let buckets = max((limit - 2) / 2, 1)
        var out: [Int] = [0]
        out.reserveCapacity(limit)
        let interior = n - 2
        if limit >= 4 {
            for b in 0..<buckets {
                let lo = 1 + b * interior / buckets
                let hi = 1 + (b + 1) * interior / buckets
                guard lo < hi else { continue }
                var minIndex = lo, maxIndex = lo
                for i in (lo + 1)..<hi {
                    if values[i] < values[minIndex] { minIndex = i }
                    if values[i] > values[maxIndex] { maxIndex = i }
                }
                if minIndex == maxIndex {
                    out.append(minIndex)
                } else {
                    out.append(min(minIndex, maxIndex))
                    out.append(max(minIndex, maxIndex))
                }
            }
        }
        out.append(n - 1)
        return out
    }

    /// The selected elements themselves.
    public static func downsample<T: Comparable>(_ values: [T], maxPoints: Int) -> [T] {
        indices(values, maxPoints: maxPoints).map { values[$0] }
    }
}

/// A point of a chart line (identified by its day, which is unique within one line).
public struct ChartPoint<Value: Sendable>: Sendable, Identifiable {
    public var id: Day { day }
    public let day: Day
    public let value: Value

    public init(day: Day, value: Value) {
        self.day = day
        self.value = value
    }
}

extension ValuationSeries {
    /// The value line reduced to at most `maxPoints` points (see `Downsampler`).
    public func chartPoints(maxPoints: Int) -> [ChartPoint<Int64>] {
        Downsampler.indices(values, maxPoints: maxPoints).map { ChartPoint(day: day(at: $0), value: values[$0]) }
    }
}

extension ReturnSeries {
    /// The cumulative-return line reduced to at most `maxPoints` points (see `Downsampler`).
    public func chartPoints(maxPoints: Int) -> [ChartPoint<Double>] {
        Downsampler.indices(cumulative, maxPoints: maxPoints).map { ChartPoint(day: day(at: $0), value: cumulative[$0]) }
    }
}
