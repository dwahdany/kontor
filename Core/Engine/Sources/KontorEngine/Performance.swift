import Foundation
import KontorModel

/// Explains how a scope's value moved from `initialValue` to `finalValue` over an interval.
/// All amounts are minor units of `currency`.
///
/// **Reconciliation invariant** (exact, in minor units):
///
///     finalValue = initialValue
///                + deposits + deliveriesIn + transfersIn
///                − withdrawals − deliveriesOut − transfersOut
///                + realizedGains + unrealizedGains
///                + dividends + interest − fees − taxes
///                + cashCurrencyGains + roundingResidue
///
/// Definitions:
/// * Capital gains are measured against the *period basis*: positions that existed at the start of
///   the interval are based at their market value on the start day, later purchases at their gross
///   cost. They are **before fees and taxes** — every fee and tax of the period (including those
///   embedded in buys, sells and dividends) appears in `fees` / `taxes` instead.
/// * `dividends` and `interest` are gross (before fees and taxes); interest charges are netted
///   into `interest`.
/// * `realizedCurrencyGains` / `unrealizedCurrencyGains` are the exchange-rate part *included in*
///   `realizedGains` / `unrealizedGains` for securities quoted in a foreign currency.
/// * `cashCurrencyGains` is the exchange-rate effect on foreign-currency cash balances (plus
///   spreads of cross-currency cash transfers).
/// * `roundingResidue` collects sub-cent rounding from currency conversion and scope weights. It is
///   exactly 0 for single-currency, unweighted scopes.
public struct PerformanceBreakdown: Sendable, Hashable {
    public var currency: CurrencyCode
    public var initialValue: Int64 = 0
    public var finalValue: Int64 = 0
    /// Cash deposits (≥ 0).
    public var deposits: Int64 = 0
    /// Cash withdrawals (≥ 0).
    public var withdrawals: Int64 = 0
    /// Value of securities delivered in (≥ 0).
    public var deliveriesIn: Int64 = 0
    /// Value of securities delivered out (≥ 0).
    public var deliveriesOut: Int64 = 0
    /// Value that entered a partial scope from the rest of the portfolio (≥ 0), see `Scope`.
    public var transfersIn: Int64 = 0
    /// Value that left a partial scope into the rest of the portfolio (≥ 0).
    public var transfersOut: Int64 = 0
    public var realizedGains: Int64 = 0
    public var unrealizedGains: Int64 = 0
    public var realizedCurrencyGains: Int64 = 0
    public var unrealizedCurrencyGains: Int64 = 0
    public var dividends: Int64 = 0
    public var interest: Int64 = 0
    /// Fees paid, net of refunds (positive = cost).
    public var fees: Int64 = 0
    /// Taxes paid, net of refunds (positive = cost).
    public var taxes: Int64 = 0
    public var cashCurrencyGains: Int64 = 0
    public var roundingResidue: Int64 = 0

    public init(currency: CurrencyCode) { self.currency = currency }

    /// All value that entered the scope.
    public var inflows: Int64 { deposits + deliveriesIn + transfersIn }
    /// All value that left the scope.
    public var outflows: Int64 { withdrawals + deliveriesOut + transfersOut }
    public var capitalGains: Int64 { realizedGains + unrealizedGains }
    /// Dividends plus interest.
    public var earnings: Int64 { dividends + interest }
    /// All exchange-rate effects (on securities and on cash).
    public var currencyGains: Int64 { realizedCurrencyGains + unrealizedCurrencyGains + cashCurrencyGains }
    /// The gain not explained by external flows: `finalValue − initialValue − inflows + outflows`.
    public var absolutePerformance: Int64 { finalValue - initialValue - inflows + outflows }
    /// Sum of all performance components; equals `absolutePerformance` by construction.
    public var componentSum: Int64 {
        realizedGains + unrealizedGains + dividends + interest - fees - taxes + cashCurrencyGains + roundingResidue
    }

    /// One line of the breakdown for display.
    public enum Line: String, Sendable, CaseIterable, Codable {
        case initialValue, deposits, deliveriesIn, transfersIn, withdrawals, deliveriesOut, transfersOut
        case realizedGains, unrealizedGains, dividends, interest, fees, taxes, cashCurrencyGains
        case roundingResidue, finalValue
    }

    /// The breakdown as signed lines: summing every line between `.initialValue` and `.finalValue`
    /// (inclusive of the former) yields the latter.
    public var lines: [(line: Line, amount: Int64)] {
        [
            (.initialValue, initialValue), (.deposits, deposits), (.deliveriesIn, deliveriesIn),
            (.transfersIn, transfersIn), (.withdrawals, -withdrawals), (.deliveriesOut, -deliveriesOut),
            (.transfersOut, -transfersOut), (.realizedGains, realizedGains), (.unrealizedGains, unrealizedGains),
            (.dividends, dividends), (.interest, interest), (.fees, -fees), (.taxes, -taxes),
            (.cashCurrencyGains, cashCurrencyGains), (.roundingResidue, roundingResidue), (.finalValue, finalValue),
        ]
    }
}

/// Performance figures of one security within a scope and interval. Money amounts are minor units
/// of the reporting currency and already multiplied by the scope weight.
public struct SecurityPerformance: Sendable, Hashable, Identifiable {
    public var id: UUID { securityID }
    public let securityID: UUID
    /// Shares held at the end of the interval (unweighted).
    public let shares: Shares
    public let initialValue: Int64
    /// Market value at the end of the interval.
    public let marketValue: Int64
    /// Share of the scope's final total value (0…1); nil if that total is not positive.
    public let portfolioWeight: Double?

    // Since purchase (per `Settings.costMethod`)
    /// Purchase value of the shares still held, including fees.
    public let costBasis: Int64
    /// Average purchase price per share in the reporting currency (incl. fees).
    public let purchasePrice: Price?
    /// `marketValue − costBasis`.
    public let unrealizedGain: Int64
    /// `unrealizedGain / costBasis`; nil without a positive cost basis.
    public let unrealizedGainFraction: Double?
    /// Gains realized by sales within the interval against the original cost, after fees, before taxes.
    public let realizedGain: Int64

    // Within the interval, period basis (see `PerformanceBreakdown`)
    public let periodRealizedGain: Int64
    public let periodUnrealizedGain: Int64
    /// Exchange-rate part included in the two period gains.
    public let periodCurrencyGain: Int64
    /// Gross dividends received in the interval.
    public let dividends: Int64
    public let dividendCount: Int
    /// Gross amount and day of the most recent dividend in the interval.
    public let lastDividend: Int64?
    public let lastDividendDay: Day?
    /// Dividends of the interval divided by the cost basis of the shares held at its end.
    public let dividendYieldOnCost: Double?
    /// Fees attributable to the security in the interval (trades, dividends, fee bookings − refunds).
    public let fees: Int64
    /// Taxes attributable to the security in the interval.
    public let taxes: Int64
    /// Purchases, inbound deliveries and other value entering the position (≥ 0).
    public let inflows: Int64
    /// Sales, dividends paid out and other value leaving the position (≥ 0).
    public let outflows: Int64
    /// True time-weighted return of the security over the interval.
    public let ttwror: Double
    public let ttwrorAnnualized: Double?
    /// Internal rate of return (annual); nil if undefined.
    public let irr: Double?

    /// Total gain of the security in the interval after fees and taxes:
    /// `marketValue − initialValue − inflows + outflows`.
    public var absolutePerformance: Int64 { marketValue - initialValue - inflows + outflows }
}

/// Everything the performance screens need for one scope and interval, from two linear passes.
public struct PerformanceReport: Sendable {
    public let interval: DayInterval
    public let currency: CurrencyCode
    public let valuation: ValuationSeries
    /// Daily and cumulative time-weighted returns.
    public let returns: ReturnSeries
    /// Internal rate of return (annual, money-weighted); nil if undefined.
    public let irr: Double?
    public let breakdown: PerformanceBreakdown
    /// One record per security that was held or had transactions in the interval, in the order of
    /// `Ledger.securities`.
    public let securities: [SecurityPerformance]
    public let risk: RiskMetrics
    public let diagnostics: [EngineDiagnostic]

    /// True time-weighted rate of return over the interval.
    public var ttwror: Double { returns.total }
    public var ttwrorAnnualized: Double? { returns.annualized }
    /// `final − initial − inflows + outflows`.
    public var absolutePerformance: Int64 { breakdown.absolutePerformance }
    public func security(_ id: UUID) -> SecurityPerformance? { securities.first { $0.securityID == id } }
}

extension Ledger {
    /// Full performance report for `scope` over `interval`.
    public func performance(in interval: DayInterval, scope: Scope = .portfolio) -> PerformanceReport {
        let resolved = ResolvedScope(scope, ledger: self)
        let daily = dailyPass(interval, resolved, perSecurity: true)
        let analysis = analyze(interval, resolved, accumulators: daily.securities)
        let returns = daily.series.returns()
        var diagnostics = DiagnosticCollector(daily.series.diagnostics)
        diagnostics.add(contentsOf: analysis.diagnostics)
        return PerformanceReport(
            interval: interval, currency: reportingCurrency, valuation: daily.series, returns: returns,
            irr: daily.series.irr(), breakdown: analysis.breakdown, securities: analysis.securities,
            risk: RiskMetrics(returns: returns, riskFreeRate: settings.riskFreeRate),
            diagnostics: diagnostics.items)
    }

    /// Full performance report for a reporting period.
    public func performance(for period: ReportingPeriod, today: Day = .today, scope: Scope = .portfolio) -> PerformanceReport {
        performance(in: period.interval(today: today, ledger: self), scope: scope)
    }

    /// Only the reconciling breakdown (skips the daily pass; a single pass over the transactions).
    public func breakdown(in interval: DayInterval, scope: Scope = .portfolio) -> PerformanceBreakdown {
        analyze(interval, ResolvedScope(scope, ledger: self), accumulators: []).breakdown
    }

    /// Per-security performance records for `scope` over `interval`.
    public func securityPerformance(in interval: DayInterval, scope: Scope = .portfolio) -> [SecurityPerformance] {
        let resolved = ResolvedScope(scope, ledger: self)
        let daily = dailyPass(interval, resolved, perSecurity: true)
        return analyze(interval, resolved, accumulators: daily.securities).securities
    }

    /// The cost-basis pass: breakdown and (if accumulators from the daily pass are given)
    /// per-security records.
    func analyze(
        _ interval: DayInterval, _ scope: ResolvedScope, accumulators: [SecurityAccumulator]
    ) -> (breakdown: PerformanceBreakdown, securities: [SecurityPerformance], diagnostics: [EngineDiagnostic]) {
        var replay = LotReplay(ledger: self, scope: scope)
        replay.beginPeriod(at: interval.start)
        replay.advance(through: interval.end)
        return analyze(interval, replay: replay, accumulators: accumulators)
    }

    /// Evaluates a replay whose period began at `interval.start` and that was advanced through
    /// `interval.end` (shared with `Analysis`, which also derives the closing snapshot from it).
    func analyze(
        _ interval: DayInterval, replay: LotReplay, accumulators: [SecurityAccumulator]
    ) -> (breakdown: PerformanceBreakdown, securities: [SecurityPerformance], diagnostics: [EngineDiagnostic]) {
        let scope = replay.scope
        let end = interval.end.rawValue

        struct SecurityTotals {
            var shares: Int64 = 0
            var value: Int64 = 0
            var cost: Int64 = 0
            var unweightedCost: Int64 = 0
            var realized: Int64 = 0
            var periodRealized: Int64 = 0
            var periodUnrealized: Int64 = 0
            var currencyGain: Int64 = 0
            var present = false
        }
        var totals = [SecurityTotals](repeating: SecurityTotals(), count: securities.count)
        var b = PerformanceBreakdown(currency: reportingCurrency)
        b.initialValue = replay.initialValue
        var finalValue: Int64 = 0

        for h in holdingSecurity.indices {
            let w = scope.holdingWeight[h]
            guard w != 0 else { continue }
            let s = Int(holdingSecurity[h])
            let state = replay.holdingState(h, on: end)
            let value = FixedMath.weighted(state.value, w)
            let unrealized = FixedMath.weighted(state.value - state.periodCost, w)
            let realized = FixedMath.weighted(replay.periodRealized[h], w)
            var unrealizedFX: Int64 = 0
            let currency = securityCurrency[s]
            if currency != 0, state.shares != 0 {
                let rate = rateToReporting(currency, on: end)
                if !rate.isNaN {
                    unrealizedFX = FixedMath.weighted(
                        FixedMath.convert(state.periodCostSec, rate: rate) - state.periodCost, w)
                }
            }
            let realizedFX = FixedMath.weighted(replay.periodRealizedFX[h], w)
            finalValue += value
            b.unrealizedGains += unrealized
            b.realizedGains += realized
            b.unrealizedCurrencyGains += unrealizedFX
            b.realizedCurrencyGains += realizedFX

            totals[s].shares += state.shares
            totals[s].value += value
            totals[s].cost += FixedMath.weighted(state.cost, w)
            totals[s].unweightedCost += state.cost
            totals[s].realized += FixedMath.weighted(replay.realizedNet[h], w)
            totals[s].periodRealized += realized
            totals[s].periodUnrealized += unrealized
            totals[s].currencyGain += unrealizedFX + realizedFX
            if state.shares != 0 || replay.periodRealized[h] != 0 || replay.realizedNet[h] != 0 { totals[s].present = true }
        }
        for a in accounts.indices {
            let w = scope.accountWeight[a]
            guard w != 0 else { continue }
            let endCash = cashValue(account: a, balance: replay.balances[a], on: end).rep
            finalValue += FixedMath.weighted(endCash, w)
            b.cashCurrencyGains += FixedMath.weighted(endCash - replay.startCash[a] - replay.cashTally[a], w)
        }
        b.cashCurrencyGains += replay.transferSpread
        b.finalValue = finalValue
        b.deposits = replay.deposits
        b.withdrawals = replay.withdrawals
        b.deliveriesIn = replay.deliveriesIn
        b.deliveriesOut = replay.deliveriesOut
        b.transfersIn = replay.transfersIn
        b.transfersOut = replay.transfersOut
        b.interest = replay.interest
        b.fees = replay.otherFees
        b.taxes = replay.otherTaxes
        for s in securities.indices {
            b.dividends += replay.dividends[s]
            b.fees += replay.fees[s]
            b.taxes += replay.taxes[s]
        }
        b.roundingResidue = b.absolutePerformance
            - (b.realizedGains + b.unrealizedGains + b.dividends + b.interest - b.fees - b.taxes + b.cashCurrencyGains)

        var records: [SecurityPerformance] = []
        if !accumulators.isEmpty {
            let lastIndex = interval.dayCount
            for s in securities.indices {
                let acc = accumulators[s]
                let t = totals[s]
                guard acc.touched || t.present || replay.touched[s] else { continue }
                let total = acc.factor - 1
                var flows: [Returns.CashFlow] = [.init(day: 0, amount: -Double(acc.initialValue))]
                for f in acc.flows { flows.append(.init(day: Int(f.index), amount: -Double(f.amount))) }
                flows.append(.init(day: lastIndex, amount: Double(acc.finalValue)))
                let hasDividend = replay.dividendCount[s] > 0
                records.append(SecurityPerformance(
                    securityID: securities[s].id, shares: Shares(raw: t.shares), initialValue: acc.initialValue,
                    marketValue: t.value,
                    portfolioWeight: finalValue > 0 ? Double(t.value) / Double(finalValue) : nil,
                    costBasis: t.cost,
                    purchasePrice: Price(minor: t.unweightedCost, per: Shares(raw: t.shares)),
                    unrealizedGain: t.value - t.cost,
                    unrealizedGainFraction: t.cost > 0 ? Double(t.value - t.cost) / Double(t.cost) : nil,
                    realizedGain: t.realized, periodRealizedGain: t.periodRealized,
                    periodUnrealizedGain: t.periodUnrealized, periodCurrencyGain: t.currencyGain,
                    dividends: replay.dividends[s], dividendCount: Int(replay.dividendCount[s]),
                    lastDividend: hasDividend ? replay.lastDividend[s] : nil,
                    lastDividendDay: hasDividend ? Day(rawValue: replay.lastDividendDay[s]) : nil,
                    dividendYieldOnCost: t.cost > 0 ? Double(replay.dividends[s]) / Double(t.cost) : nil,
                    fees: replay.fees[s], taxes: replay.taxes[s], inflows: acc.inflows, outflows: acc.outflows,
                    ttwror: total, ttwrorAnnualized: Returns.annualize(total: total, days: interval.dayCount),
                    irr: Returns.irr(flows)))
            }
        }
        return (b, records, replay.diagnostics.items)
    }
}
