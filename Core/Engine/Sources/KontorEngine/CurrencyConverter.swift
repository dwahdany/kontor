import Foundation
import KontorModel

/// Converts between currencies using the exchange-rate series stored in a `PortfolioFile`.
///
/// Lookup order for `from → to`:
/// 1. identity (same currency, rate 1),
/// 2. a direct series (`base == from`, `quote == to`),
/// 3. the inverse of a series (`base == to`, `quote == from`),
/// 4. triangulation through a pivot currency — the file's base currency, then EUR, then USD —
///    where each leg may itself be direct or inverse.
///
/// Rates follow *last-known* semantics: the most recent rate on or before the requested day is used;
/// before the first data point of a series its first rate applies (mirrors `ExchangeRateSeries.rate(on:)`).
/// If no path exists the conversion is *unavailable*: lookups return nil, and engine calculations
/// exclude the amount and report `EngineDiagnostic.missingExchangeRate`.
public struct CurrencyConverter: Sendable {
    /// A resolved conversion route. Resolve once with `path(from:to:)`, then evaluate for many days.
    public struct Path: Hashable, Sendable {
        struct Step: Hashable, Sendable {
            var series: Int32
            var inverted: Bool
        }
        var first: Step?
        var second: Step?

        /// True for a same-currency conversion (rate is always 1).
        public var isIdentity: Bool { first == nil }
        /// Number of series involved (0 = identity, 1 = direct/inverse, 2 = triangulated).
        public var legCount: Int { (first == nil ? 0 : 1) + (second == nil ? 0 : 1) }

        static let identity = Path(first: nil, second: nil)
    }

    private struct Pair: Hashable, Sendable {
        var base: CurrencyCode
        var quote: CurrencyCode
    }

    private struct Series: Sendable {
        var days: [Int32]
        var rates: [Double]

        /// Index of the applicable data point: the last one on or before `day`, else the first.
        @inline(__always)
        func index(on day: Int32) -> Int {
            var lo = 0, hi = days.count
            while lo < hi {
                let mid = (lo &+ hi) >> 1
                if days[mid] <= day { lo = mid &+ 1 } else { hi = mid }
            }
            return lo == 0 ? 0 : lo - 1
        }
    }

    /// The pivot tried first when triangulating.
    public let baseCurrency: CurrencyCode
    private let series: [Series]
    private let index: [Pair: Int32]
    private let pivots: [CurrencyCode]

    /// Builds the converter. Empty series and non-positive / non-finite rates are ignored; several
    /// series for the same pair are merged (later ones win on equal days).
    public init(series input: [ExchangeRateSeries], baseCurrency: CurrencyCode) {
        self.baseCurrency = baseCurrency
        var stored: [Series] = []
        var lookup: [Pair: Int32] = [:]
        for s in input {
            var days: [Int32] = []
            var rates: [Double] = []
            days.reserveCapacity(s.days.count)
            rates.reserveCapacity(s.days.count)
            var ascending = true
            for i in 0..<min(s.days.count, s.rates.count) {
                let r = s.rates[i]
                guard r.isFinite, r > 0 else { continue }
                if let last = days.last, s.days[i] <= last { ascending = false }
                days.append(s.days[i])
                rates.append(r)
            }
            guard !days.isEmpty, s.base != s.quote else { continue }
            let pair = Pair(base: s.base, quote: s.quote)
            if let existing = lookup[pair] {
                ascending = false
                days = stored[Int(existing)].days + days
                rates = stored[Int(existing)].rates + rates
            }
            if !ascending {
                var merged = [Int32: Double](minimumCapacity: days.count)
                for i in days.indices { merged[days[i]] = rates[i] }
                let sorted = merged.sorted { $0.key < $1.key }
                days = sorted.map(\.key)
                rates = sorted.map(\.value)
            }
            if let existing = lookup[pair] {
                stored[Int(existing)] = Series(days: days, rates: rates)
            } else {
                lookup[pair] = Int32(stored.count)
                stored.append(Series(days: days, rates: rates))
            }
        }
        self.series = stored
        self.index = lookup
        var pivots: [CurrencyCode] = []
        for p in [baseCurrency, "EUR", "USD"] where !pivots.contains(p) { pivots.append(p) }
        self.pivots = pivots
    }

    /// Currency pairs for which a series is stored, as (base, quote).
    public var pairs: [(base: CurrencyCode, quote: CurrencyCode)] {
        index.keys.map { ($0.base, $0.quote) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    // MARK: Path resolution

    private func step(_ from: CurrencyCode, _ to: CurrencyCode) -> Path.Step? {
        if let i = index[Pair(base: from, quote: to)] { return Path.Step(series: i, inverted: false) }
        if let i = index[Pair(base: to, quote: from)] { return Path.Step(series: i, inverted: true) }
        return nil
    }

    /// Resolves the conversion route, or nil if the currencies cannot be converted.
    public func path(from: CurrencyCode, to: CurrencyCode) -> Path? {
        if from == to { return .identity }
        if let direct = step(from, to) { return Path(first: direct, second: nil) }
        for pivot in pivots where pivot != from && pivot != to {
            if let a = step(from, pivot), let b = step(pivot, to) { return Path(first: a, second: b) }
        }
        return nil
    }

    /// Whether amounts in `from` can be converted to `to`.
    public func canConvert(from: CurrencyCode, to: CurrencyCode) -> Bool { path(from: from, to: to) != nil }

    // MARK: Rates

    @inline(__always)
    private func rate(_ step: Path.Step, on day: Int32) -> Double {
        let s = series[Int(step.series)]
        let r = s.rates[s.index(on: day)]
        return step.inverted ? 1 / r : r
    }

    /// The rate along a resolved path on `day` (units of the target currency per unit of the source).
    public func rate(along path: Path, on day: Day) -> Double {
        guard let a = path.first else { return 1 }
        let ra = rate(a, on: day.rawValue)
        guard let b = path.second else { return ra }
        return ra * rate(b, on: day.rawValue)
    }

    /// The exchange rate `from → to` on `day`, or nil if unavailable.
    public func rate(from: CurrencyCode, to: CurrencyCode, on day: Day) -> Double? {
        path(from: from, to: to).map { rate(along: $0, on: day) }
    }

    /// Rates along `path` for `count` consecutive days starting at `start`, computed in one linear
    /// sweep (no per-day binary search). Element `i` equals `rate(along:on: start + i)` exactly.
    public func dailyRates(along path: Path, from start: Day, count: Int) -> [Double] {
        var out = [Double](repeating: 1, count: max(count, 0))
        guard count > 0, let a = path.first else { return out }
        fill(&out, step: a, start: start.rawValue, combine: false)
        if let b = path.second { fill(&out, step: b, start: start.rawValue, combine: true) }
        return out
    }

    private func fill(_ out: inout [Double], step: Path.Step, start: Int32, combine: Bool) {
        let s = series[Int(step.series)]
        var cursor = s.index(on: start)
        let last = s.days.count - 1
        var current = step.inverted ? 1 / s.rates[cursor] : s.rates[cursor]
        for i in 0..<out.count {
            let day = start &+ Int32(i)
            if cursor < last, s.days[cursor + 1] <= day {
                repeat { cursor += 1 } while cursor < last && s.days[cursor + 1] <= day
                current = step.inverted ? 1 / s.rates[cursor] : s.rates[cursor]
            }
            out[i] = combine ? out[i] * current : current
        }
    }

    // MARK: Amounts

    /// Converts an amount in minor units, rounding half away from zero. Nil if no rate is available.
    public func convert(minor: Int64, from: CurrencyCode, to: CurrencyCode, on day: Day) -> Int64? {
        guard let p = path(from: from, to: to) else { return nil }
        return p.isIdentity ? minor : FixedMath.convert(minor, rate: rate(along: p, on: day))
    }

    /// Converts `money` into `currency` at the rate of `day`. Nil if no rate is available.
    public func convert(_ money: Money, to currency: CurrencyCode, on day: Day) -> Money? {
        convert(minor: money.minor, from: money.currency, to: currency, on: day)
            .map { Money(minor: $0, currency: currency) }
    }
}
