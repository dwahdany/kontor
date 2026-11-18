import Foundation
import KontorModel

/// Daily valuation of a scope over an interval, in minor units of the reporting currency.
///
/// Index `i` corresponds to day `interval.start + i`; index 0 is the baseline (its flows are zero).
/// `values[i]` is the value at the end of the day. `inflows[i]` / `outflows[i]` are the external
/// flows of that day (both non-negative), see `Scope` for what counts as external.
public struct ValuationSeries: Sendable {
    public let interval: DayInterval
    public let currency: CurrencyCode
    /// Total value (securities + cash) at the end of each day.
    public let values: [Int64]
    /// The cash part of `values`.
    public let cashValues: [Int64]
    /// Value that entered the scope on each day (≥ 0).
    public let inflows: [Int64]
    /// Value that left the scope on each day (≥ 0).
    public let outflows: [Int64]
    public let diagnostics: [EngineDiagnostic]

    /// Number of points (`interval.dayCount + 1`).
    public var count: Int { values.count }
    public func day(at index: Int) -> Day { interval.start.advanced(by: index) }
    /// Index of `day`, or nil if it lies outside the interval.
    public func index(of day: Day) -> Int? {
        let i = interval.start.distance(to: day)
        return i >= 0 && i < values.count ? i : nil
    }

    public var initialValue: Int64 { values.first ?? 0 }
    public var finalValue: Int64 { values.last ?? 0 }
    public var totalInflows: Int64 { inflows.reduce(0, +) }
    public var totalOutflows: Int64 { outflows.reduce(0, +) }
    /// Net external flow of day `index` (inflows − outflows).
    public func netFlow(at index: Int) -> Int64 { inflows[index] - outflows[index] }
    /// Gain in the interval that is not explained by external flows:
    /// `final − initial − inflows + outflows`.
    public var absolutePerformance: Int64 { finalValue - initialValue - totalInflows + totalOutflows }

    /// The securities part of the value on day `index`.
    public func securitiesValue(at index: Int) -> Int64 { values[index] - cashValues[index] }
}

/// Per-security by-product of the daily pass.
struct SecurityAccumulator: Sendable {
    var touched = false
    var initialValue: Int64 = 0
    var finalValue: Int64 = 0
    var inflows: Int64 = 0
    var outflows: Int64 = 0
    /// Compounded time-weighted growth factor.
    var factor: Double = 1
    /// Net external flows by day index (for the IRR).
    var flows: [(index: Int32, amount: Int64)] = []
}

/// Swap-remove set of the holdings that currently have a non-zero in-scope position.
private struct ActiveSet {
    var list: [Int32] = []
    var slot: [Int32]

    init(count: Int) { slot = [Int32](repeating: -1, count: count) }

    @inline(__always)
    mutating func update(_ holding: Int, active: Bool) {
        let at = slot[holding]
        if active {
            if at < 0 {
                slot[holding] = Int32(list.count)
                list.append(Int32(holding))
            }
        } else if at >= 0 {
            let last = list[list.count - 1]
            list[Int(at)] = last
            slot[Int(last)] = at
            list.removeLast()
            slot[holding] = -1
        }
    }
}

extension Ledger {
    /// Daily values and external flows of `scope` over `interval`.
    ///
    /// Computed incrementally in a single pass over days × open positions: positions and balances are
    /// rolled forward transaction by transaction, quotes and exchange rates advance with cursors.
    /// Twenty years of a 60-security portfolio take a few milliseconds.
    public func valuation(in interval: DayInterval, scope: Scope = .portfolio) -> ValuationSeries {
        dailyPass(interval, ResolvedScope(scope, ledger: self), perSecurity: false).series
    }

    /// The single daily pass behind `valuation(in:scope:)` and the per-security performance figures.
    func dailyPass(
        _ interval: DayInterval, _ scope: ResolvedScope, perSecurity: Bool
    ) -> (series: ValuationSeries, securities: [SecurityAccumulator]) {
        let n = interval.dayCount + 1
        let start = interval.start.rawValue
        let full = FixedMath.fullWeight
        let holdingCount = holdingSecurity.count
        let securityCount = securities.count
        let accountCount = accounts.count
        var diagnostics = DiagnosticCollector()

        // Accounts: "simple" ones (reporting currency, 100 %) are summed incrementally.
        var accountSimple = [Bool](repeating: false, count: accountCount)
        var specialAccounts: [Int] = []
        for a in 0..<accountCount {
            let w = scope.accountWeight[a]
            if w == 0 { continue }
            if accountCurrency[a] == 0, w == full { accountSimple[a] = true } else { specialAccounts.append(a) }
        }

        // Dense exchange-rate tables for every foreign currency that can contribute to the value.
        var rateTables = [[Double]](repeating: [], count: currencies.count)
        var rateMissing = [Bool](repeating: false, count: currencies.count)
        var needed = [Bool](repeating: false, count: currencies.count)
        for h in 0..<holdingCount where scope.holdingWeight[h] != 0 {
            needed[Int(securityCurrency[Int(holdingSecurity[h])])] = true
        }
        for a in specialAccounts { needed[Int(accountCurrency[a])] = true }
        for c in 1..<max(currencies.count, 1) where needed[c] {
            if let path = currencyPaths[c] {
                rateTables[c] = converter.dailyRates(along: path, from: interval.start, count: n)
            } else {
                rateMissing[c] = true
            }
        }

        // Roll positions and balances forward to the baseline.
        var shares = [Int64](repeating: 0, count: holdingCount)
        var balances = [Int64](repeating: 0, count: accountCount)
        let entryCount = entries.count
        var ei = 0
        while ei < entryCount, entries[ei].day <= start {
            let e = entries[ei]
            ei += 1
            if e.holding >= 0 { shares[Int(e.holding)] += e.sharesDelta }
            if e.counterHolding >= 0 { shares[Int(e.counterHolding)] += e.shares }
            if e.account >= 0 { balances[Int(e.account)] += e.cashDelta }
            if e.counterAccount >= 0 { balances[Int(e.counterAccount)] += e.counterCashDelta }
        }
        var simpleCash: Int64 = 0
        for a in 0..<accountCount where accountSimple[a] { simpleCash += balances[a] }
        var active = ActiveSet(count: holdingCount)
        for h in 0..<holdingCount where shares[h] != 0 && scope.holdingWeight[h] != 0 {
            active.update(h, active: true)
        }

        // Price cursors (per security) and per-holding value cache.
        var cursor = [Int](repeating: -2, count: securityCount) // −2 = not positioned, −1 = no prices
        var cachedCursor = [Int](repeating: -3, count: holdingCount)
        var cachedShares = [Int64](repeating: 0, count: holdingCount)
        var cachedValue = [Int64](repeating: 0, count: holdingCount)

        // Per-security accumulators.
        var accumulators = [SecurityAccumulator](repeating: SecurityAccumulator(), count: perSecurity ? securityCount : 0)
        var securityValue = [Int64](repeating: 0, count: perSecurity ? securityCount : 0)
        var securityPrevious = securityValue
        var securityIn = securityValue
        var securityOut = securityValue
        var stamp = [Int32](repeating: -1, count: perSecurity ? securityCount : 0)
        var dirty: [Int] = []

        var values = [Int64](repeating: 0, count: n)
        var cashValues = [Int64](repeating: 0, count: n)
        var inflows = [Int64](repeating: 0, count: n)
        var outflows = [Int64](repeating: 0, count: n)

        for i in 0..<n {
            let day = start &+ Int32(i)
            let stampValue = Int32(i)

            // 1. Transactions of the day (none on the baseline day: they are part of the baseline).
            if i > 0 {
                var dayIn: Int64 = 0, dayOut: Int64 = 0
                while ei < entryCount, entries[ei].day == day {
                    let e = entries[ei]
                    ei += 1
                    if e.holding >= 0, e.sharesDelta != 0 {
                        let h = Int(e.holding)
                        shares[h] += e.sharesDelta
                        active.update(h, active: shares[h] != 0 && scope.holdingWeight[h] != 0)
                    }
                    if e.counterHolding >= 0 {
                        let h = Int(e.counterHolding)
                        shares[h] += e.shares
                        active.update(h, active: shares[h] != 0 && scope.holdingWeight[h] != 0)
                    }
                    if e.account >= 0 {
                        let a = Int(e.account)
                        balances[a] += e.cashDelta
                        if accountSimple[a] { simpleCash += e.cashDelta }
                    }
                    if e.counterAccount >= 0 {
                        let a = Int(e.counterAccount)
                        balances[a] += e.counterCashDelta
                        if accountSimple[a] { simpleCash += e.counterCashDelta }
                    }
                    if e.rateMissing {
                        diagnostics.add(.missingExchangeRate(from: currencies[Int(e.currency)], to: reportingCurrency))
                    }
                    let legs = scope.flowLegs(e, self)
                    let flow = legs.position + legs.account
                    if flow > 0 { dayIn += flow } else { dayOut -= flow }
                    if perSecurity, e.security >= 0,
                       scope.positionWeight(e) != 0
                        || (e.counterHolding >= 0 && scope.holdingWeight[Int(e.counterHolding)] != 0) {
                        let s = Int(e.security)
                        if stamp[s] != stampValue {
                            stamp[s] = stampValue
                            dirty.append(s)
                        }
                        if legs.position > 0 { securityIn[s] += legs.position } else { securityOut[s] -= legs.position }
                    }
                }
                inflows[i] = dayIn
                outflows[i] = dayOut
            }

            // 2. Open positions at the day's closing price.
            var securitiesTotal: Int64 = 0
            for k in 0..<active.list.count {
                let h = Int(active.list[k])
                let s = Int(holdingSecurity[h])
                var c = cursor[s]
                if c == -2 { c = priceIndex(s, on: day) }
                if c >= 0 {
                    let end = priceOffsets[s + 1]
                    while c + 1 < end, priceDays[c + 1] <= day { c += 1 }
                }
                cursor[s] = c
                var v: Int64
                if c == cachedCursor[h], shares[h] == cachedShares[h] {
                    v = cachedValue[h]
                } else {
                    v = c >= 0 ? FixedMath.marketValue(priceRaw: priceValues[c], sharesRaw: shares[h]) : 0
                    cachedCursor[h] = c
                    cachedShares[h] = shares[h]
                    cachedValue[h] = v
                    if c < 0 { diagnostics.add(.missingPrice(securityID: securities[s].id)) }
                }
                let ci = Int(securityCurrency[s])
                if ci != 0 {
                    if rateMissing[ci] {
                        v = 0
                        diagnostics.add(.missingExchangeRate(from: currencies[ci], to: reportingCurrency))
                    } else {
                        v = FixedMath.convert(v, rate: rateTables[ci][i])
                    }
                }
                let w = scope.holdingWeight[h]
                if w != full { v = FixedMath.weighted(v, w) }
                securitiesTotal += v
                if perSecurity {
                    if stamp[s] != stampValue {
                        stamp[s] = stampValue
                        dirty.append(s)
                    }
                    securityValue[s] += v
                }
            }

            // 3. Cash.
            var cash = simpleCash
            for a in specialAccounts {
                let balance = balances[a]
                if balance == 0 { continue }
                let ci = Int(accountCurrency[a])
                var v = balance
                if ci != 0 {
                    if rateMissing[ci] {
                        diagnostics.add(.missingExchangeRate(from: currencies[ci], to: reportingCurrency))
                        continue
                    }
                    v = FixedMath.convert(balance, rate: rateTables[ci][i])
                }
                cash += FixedMath.weighted(v, scope.accountWeight[a])
            }
            values[i] = securitiesTotal + cash
            cashValues[i] = cash

            // 4. Per-security returns (same convention as `ValuationSeries.returns()`).
            if perSecurity {
                for s in dirty {
                    let v = securityValue[s]
                    if i == 0 {
                        accumulators[s].initialValue = v
                    } else {
                        let flowIn = securityIn[s], flowOut = securityOut[s]
                        accumulators[s].factor *= Returns.growthFactor(
                            previous: securityPrevious[s], value: v, inflow: flowIn, outflow: flowOut)
                        if flowIn != flowOut { accumulators[s].flows.append((stampValue, flowIn - flowOut)) }
                        accumulators[s].inflows += flowIn
                        accumulators[s].outflows += flowOut
                        securityIn[s] = 0
                        securityOut[s] = 0
                    }
                    accumulators[s].touched = true
                    securityPrevious[s] = v
                    securityValue[s] = 0
                }
                dirty.removeAll(keepingCapacity: true)
            }
        }
        if perSecurity {
            for s in 0..<securityCount { accumulators[s].finalValue = securityPrevious[s] }
        }

        let series = ValuationSeries(
            interval: interval, currency: reportingCurrency, values: values, cashValues: cashValues,
            inflows: inflows, outflows: outflows, diagnostics: diagnostics.items)
        return (series, accumulators)
    }
}
