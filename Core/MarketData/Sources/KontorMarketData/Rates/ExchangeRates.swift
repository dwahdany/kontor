import Foundation
import KontorModel

/// Pure helpers around the exchange-rate series stored in a `PortfolioFile`.
///
/// Storage convention used by Kontor's market-data layer: for every foreign currency `X` the
/// file holds the ECB series `EUR → X`. If the file's base currency `B` is not the euro, the
/// derived cross rates `B → X` (and `B → EUR`) are stored as well, so that consumers always
/// find a direct series from the base currency to every other currency.
public enum ExchangeRates {
    /// The currency all downloaded rates are quoted against.
    public static let pivot: CurrencyCode = "EUR"

    /// The cross rate `base → quote` computed from two pivot-based series
    /// (`pivot → base` and `pivot → quote`) on the days both have a rate. Pass nil for the leg
    /// that *is* the pivot currency.
    public static func triangulate(
        base: CurrencyCode, quote: CurrencyCode, pivotToBase: ExchangeRateSeries?, pivotToQuote: ExchangeRateSeries?
    ) -> ExchangeRateSeries {
        var result = ExchangeRateSeries(base: base, quote: quote)
        switch (pivotToBase, pivotToQuote) {
        case (nil, nil):
            break
        case (let b?, nil): // quote is the pivot: invert
            for (day, rate) in zip(b.days, b.rates) where isUsable(rate) && isUsable(1 / rate) {
                result.days.append(day)
                result.rates.append(1 / rate)
            }
        case (nil, let q?): // base is the pivot
            for (day, rate) in zip(q.days, q.rates) where isUsable(rate) {
                result.days.append(day)
                result.rates.append(rate)
            }
        case (let b?, let q?):
            var days = [Int32](), rates = [Double]()
            days.reserveCapacity(min(b.days.count, q.days.count))
            rates.reserveCapacity(min(b.days.count, q.days.count))
            var i = 0, j = 0
            while i < b.days.count, j < q.days.count {
                if b.days[i] < q.days[j] {
                    i += 1
                } else if b.days[i] > q.days[j] {
                    j += 1
                } else {
                    // A zero or damaged rate on either leg yields no cross rate for that day.
                    let cross = q.rates[j] / b.rates[i]
                    if isUsable(b.rates[i]), isUsable(q.rates[j]), isUsable(cross) {
                        days.append(b.days[i])
                        rates.append(cross)
                    }
                    i += 1
                    j += 1
                }
            }
            result.days = days
            result.rates = rates
        }
        return result
    }

    /// A rate that can be stored and divided by: finite and greater than zero. (A zero rate would
    /// turn into infinity in a derived series, and JSON cannot hold that: the file could no longer
    /// be saved.)
    public static func isUsable(_ rate: Double) -> Bool { rate.isFinite && rate > 0 }

    /// The rate `from → to` on `day` using whatever the file holds: identity, a direct series,
    /// an inverse series, or triangulation through the euro. nil if the rate cannot be derived.
    public static func rate(from: CurrencyCode, to: CurrencyCode, on day: Day, in file: PortfolioFile) -> Double? {
        if from == to { return 1 }
        func direct(_ a: CurrencyCode, _ b: CurrencyCode) -> Double? {
            if a == b { return 1 }
            for series in file.exchangeRates {
                if series.base == a, series.quote == b, let r = series.rate(on: day) { return r }
                if series.base == b, series.quote == a, let r = series.rate(on: day), r != 0 { return 1 / r }
            }
            return nil
        }
        if let r = direct(from, to) { return r }
        guard let a = direct(pivot, from), let b = direct(pivot, to), a != 0 else { return nil }
        return b / a
    }

    /// Brings the derived `base → X` series of a file whose base currency is not the pivot in
    /// line with its pivot-based series. Derived rates are *merged* into an existing series
    /// (replacing the value of the same day), so rates from other sources — imported files,
    /// days before the ECB's history — survive. Does nothing for euro-based files.
    ///
    /// - Returns: the number of derived rates that were added or changed.
    @discardableResult
    public static func refreshCrossRates(in file: inout PortfolioFile) -> Int {
        let base = file.settings.baseCurrency
        guard base != pivot else { return 0 }
        var pivotSeries = [CurrencyCode: ExchangeRateSeries]()
        for series in file.exchangeRates where series.base == pivot { pivotSeries[series.quote] = series }
        guard let pivotToBase = pivotSeries[base] else { return 0 }

        var index = [CurrencyCode: Int]()
        for (i, series) in file.exchangeRates.enumerated() where series.base == base { index[series.quote] = i }
        var changed = 0
        for quote in file.currencies where quote != base {
            let pivotToQuote = quote == pivot ? nil : pivotSeries[quote]
            guard quote == pivot || pivotToQuote != nil else { continue }
            let cross = triangulate(base: base, quote: quote, pivotToBase: pivotToBase, pivotToQuote: pivotToQuote)
            guard !cross.days.isEmpty else { continue }
            if let i = index[quote] {
                let differing = countChanges(of: cross, against: file.exchangeRates[i])
                guard differing > 0 else { continue }
                file.exchangeRates[i].merge(zip(cross.days, cross.rates).lazy.map { (day: Day(rawValue: $0.0), rate: $0.1) })
                changed += differing
            } else {
                index[quote] = file.exchangeRates.count
                file.exchangeRates.append(cross)
                changed += cross.days.count
            }
        }
        return changed
    }
}
