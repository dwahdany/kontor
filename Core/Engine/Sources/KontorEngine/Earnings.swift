import Foundation
import KontorModel

/// Income and cost categories, in minor units of the reporting currency.
///
/// Definitions match `PerformanceBreakdown` over the same interval and scope exactly:
/// `dividends == breakdown.dividends`, `interest − interestCharges == breakdown.interest`,
/// `fees == breakdown.fees`, `taxes == breakdown.taxes`.
public struct EarningsAmounts: Sendable, Hashable {
    /// Gross dividends (before fees and taxes).
    public var dividends: Int64 = 0
    /// Gross interest received (before taxes).
    public var interest: Int64 = 0
    /// Interest paid (positive = cost).
    public var interestCharges: Int64 = 0
    /// Fees net of refunds, including the fees embedded in buys, sells, deliveries and dividends.
    public var fees: Int64 = 0
    /// Taxes net of refunds, including the taxes embedded in buys, sells, dividends and interest.
    public var taxes: Int64 = 0

    public init() {}

    /// `dividends + interest − interestCharges`.
    public var earnings: Int64 { dividends + interest - interestCharges }
    /// `fees + taxes`.
    public var costs: Int64 { fees + taxes }
    /// `earnings − costs`.
    public var net: Int64 { earnings - costs }
    public var isZero: Bool { dividends == 0 && interest == 0 && interestCharges == 0 && fees == 0 && taxes == 0 }

    public subscript(metric: EarningsMetric) -> Int64 {
        switch metric {
        case .dividends: return dividends
        case .interest: return interest
        case .interestCharges: return interestCharges
        case .fees: return fees
        case .taxes: return taxes
        case .earnings: return earnings
        case .costs: return costs
        case .net: return net
        }
    }

    public static func += (a: inout EarningsAmounts, b: EarningsAmounts) {
        a.dividends += b.dividends
        a.interest += b.interest
        a.interestCharges += b.interestCharges
        a.fees += b.fees
        a.taxes += b.taxes
    }

    public static func + (a: EarningsAmounts, b: EarningsAmounts) -> EarningsAmounts {
        var sum = a
        sum += b
        return sum
    }
}

/// Selects one figure of `EarningsAmounts` (the five categories plus three derived totals).
public enum EarningsMetric: String, Sendable, CaseIterable, Codable {
    case dividends, interest, interestCharges, fees, taxes
    /// `dividends + interest − interestCharges`
    case earnings
    /// `fees + taxes`
    case costs
    /// `earnings − costs`
    case net
}

/// One calendar month.
public struct EarningsMonth: Sendable, Hashable, Identifiable {
    /// `year × 12 + month − 1`, unique and ascending.
    public var id: Int { year * 12 + month - 1 }
    public let year: Int
    /// 1…12
    public let month: Int
    public let amounts: EarningsAmounts
}

/// One calendar quarter.
public struct EarningsQuarter: Sendable, Hashable, Identifiable {
    /// `year × 4 + quarter − 1`, unique and ascending.
    public var id: Int { year * 4 + quarter - 1 }
    public let year: Int
    /// 1…4
    public let quarter: Int
    public let amounts: EarningsAmounts
}

/// One calendar year: a row of the year × month matrix.
public struct EarningsYear: Sendable, Hashable, Identifiable {
    public var id: Int { year }
    public let year: Int
    /// Always 12 elements (January first); months outside the interval are zero.
    public let months: [EarningsAmounts]
    public let total: EarningsAmounts

    /// The twelve monthly values of one metric.
    public func values(_ metric: EarningsMetric) -> [Int64] { months.map { $0[metric] } }
}

/// Earnings and costs attributed to one security.
public struct SecurityEarnings: Sendable, Hashable, Identifiable {
    public var id: UUID { securityID }
    public let securityID: UUID
    public let amounts: EarningsAmounts
    /// Number of dividend payments in the interval.
    public let dividendCount: Int
}

/// Earnings and costs booked on one cash account.
public struct AccountEarnings: Sendable, Hashable, Identifiable {
    public var id: UUID { accountID }
    public let accountID: UUID
    public let amounts: EarningsAmounts
}

/// One dividend payment.
public struct DividendPayment: Sendable, Hashable, Identifiable {
    public var id: UUID { transactionID }
    public let transactionID: UUID
    public let securityID: UUID
    public let accountID: UUID
    public let day: Day
    /// Shares the dividend was paid for: the transaction's share count, or — if it carries none —
    /// the in-scope position before the payment. Zero if unknown.
    public let shares: Shares
    /// Gross amount (before fees and taxes), weighted by the scope.
    public let gross: Int64
    public let fees: Int64
    public let taxes: Int64
    /// Gross dividend per share in the reporting currency; nil if the share count is unknown.
    public let perShare: Price?
    /// Gross dividend divided by the market value of `shares` on the payment day; nil if unknown.
    public let yield: Double?

    /// `gross − fees − taxes`.
    public var net: Int64 { gross - fees - taxes }
}

/// A rolling twelve-month sum ending in (and including) `month`.
public struct TrailingEarnings: Sendable, Hashable, Identifiable {
    /// `year × 12 + month − 1`, unique and ascending.
    public var id: Int { year * 12 + month - 1 }
    public let year: Int
    public let month: Int
    public let value: Int64
    /// False while fewer than twelve months of the interval are available.
    public let isComplete: Bool
}

/// A yearly figure and its change against the previous year.
public struct EarningsGrowth: Sendable, Hashable, Identifiable {
    public var id: Int { year }
    public let year: Int
    public let value: Int64
    /// `value / previous − 1`; nil for the first year or if the previous value is not positive.
    public let growth: Double?
}

/// Dividends, interest, fees and taxes of a scope over an interval, aggregated along time, by
/// security and by account. Produced by `Ledger.earnings(in:scope:)` in a single pass over the
/// interval's transactions.
public struct EarningsReport: Sendable {
    public let interval: DayInterval
    public let currency: CurrencyCode
    public let total: EarningsAmounts
    /// Every calendar month touched by the interval, in order (months without bookings are zero).
    public let months: [EarningsMonth]
    /// Per security, in the order of `Ledger.securities`; only securities with bookings.
    public let bySecurity: [SecurityEarnings]
    /// The part of `total` that is not tied to a security (interest, general fees and taxes).
    public let withoutSecurity: EarningsAmounts
    /// Per account the amounts were booked on, in the order of `Ledger.accounts`. Fees and taxes
    /// of deliveries touch no account and are therefore only part of `total`.
    public let byAccount: [AccountEarnings]
    /// All dividend payments of the interval, chronological.
    public let payments: [DividendPayment]
    public let diagnostics: [EngineDiagnostic]

    /// Calendar quarters touched by the interval.
    public var quarters: [EarningsQuarter] {
        var out: [EarningsQuarter] = []
        for m in months {
            let q = (m.month - 1) / 3 + 1
            if let last = out.last, last.year == m.year, last.quarter == q {
                out[out.count - 1] = EarningsQuarter(year: m.year, quarter: q, amounts: last.amounts + m.amounts)
            } else {
                out.append(EarningsQuarter(year: m.year, quarter: q, amounts: m.amounts))
            }
        }
        return out
    }

    /// The year × month matrix: one row per calendar year touched by the interval.
    public var years: [EarningsYear] {
        var out: [EarningsYear] = []
        var row = [EarningsAmounts](repeating: EarningsAmounts(), count: 12)
        var total = EarningsAmounts()
        var year: Int?
        for m in months {
            if let y = year, y != m.year {
                out.append(EarningsYear(year: y, months: row, total: total))
                row = [EarningsAmounts](repeating: EarningsAmounts(), count: 12)
                total = EarningsAmounts()
            }
            year = m.year
            row[m.month - 1] = m.amounts
            total += m.amounts
        }
        if let y = year { out.append(EarningsYear(year: y, months: row, total: total)) }
        return out
    }

    /// Rolling twelve-month sums of `metric`, one per month of the interval.
    public func trailingTwelveMonths(_ metric: EarningsMetric) -> [TrailingEarnings] {
        var out: [TrailingEarnings] = []
        out.reserveCapacity(months.count)
        var sum: Int64 = 0
        for (i, m) in months.enumerated() {
            sum += m.amounts[metric]
            if i >= 12 { sum -= months[i - 12].amounts[metric] }
            out.append(TrailingEarnings(year: m.year, month: m.month, value: sum, isComplete: i >= 11))
        }
        return out
    }

    /// Yearly totals of `metric` with the growth against the previous year. The first and last
    /// year may be partial if the interval does not align with calendar years.
    public func yearOverYear(_ metric: EarningsMetric) -> [EarningsGrowth] {
        var out: [EarningsGrowth] = []
        var previous: Int64?
        for y in years {
            let value = y.total[metric]
            let growth = previous.flatMap { $0 > 0 ? Double(value) / Double($0) - 1 : nil }
            out.append(EarningsGrowth(year: y.year, value: value, growth: growth))
            previous = value
        }
        return out
    }

    /// Dividend payments of one security, chronological.
    public func dividendHistory(for securityID: UUID) -> [DividendPayment] {
        payments.filter { $0.securityID == securityID }
    }
}

extension Ledger {
    /// Earnings and costs of `scope` within `interval` (transactions dated `start + 1 … end`).
    ///
    /// Amounts are converted to the reporting currency at each transaction day's rate and weighted
    /// by the scope exactly like `breakdown(in:scope:)`, so the totals equal the breakdown's
    /// dividend, interest, fee and tax lines. One pass over the transactions up to `interval.end`.
    public func earnings(in interval: DayInterval, scope: Scope = .portfolio) -> EarningsReport {
        let resolved = ResolvedScope(scope, ledger: self)
        let first = interval.firstDay
        let baseMonth = first.year * 12 + first.month - 1
        let monthCount = max(interval.end.year * 12 + interval.end.month - 1 - baseMonth + 1, 1)
        var months = [EarningsAmounts](repeating: EarningsAmounts(), count: monthCount)
        var bySecurity = [EarningsAmounts](repeating: EarningsAmounts(), count: securities.count)
        var dividendCount = [Int](repeating: 0, count: securities.count)
        var byAccount = [EarningsAmounts](repeating: EarningsAmounts(), count: accounts.count)
        var withoutSecurity = EarningsAmounts()
        var total = EarningsAmounts()
        var payments: [DividendPayment] = []
        var diagnostics = DiagnosticCollector()
        // In-scope share count per security, for dividends that do not state their shares.
        var held = [Int64](repeating: 0, count: securities.count)

        let startRaw = interval.start.rawValue, endRaw = interval.end.rawValue
        var monthIndex = 0
        var monthEnd = first.endOfMonth.rawValue

        for e in entries {
            if e.day > endRaw { break }
            let s = Int(e.security)
            if e.holding >= 0, e.sharesDelta != 0, resolved.holdingWeight[Int(e.holding)] != 0 { held[s] += e.sharesDelta }
            if e.counterHolding >= 0, resolved.holdingWeight[Int(e.counterHolding)] != 0 { held[s] += e.shares }
            guard e.day > startRaw else { continue }

            let pw = resolved.positionWeight(e)
            let aw = e.account >= 0 ? resolved.accountWeight[Int(e.account)] : 0
            var x = EarningsAmounts()
            var onSecurity = s >= 0
            switch e.kind {
            case .buy, .deliveryIn, .sell, .deliveryOut:
                x.fees = FixedMath.weighted(e.feesRep, pw)
                x.taxes = FixedMath.weighted(e.taxesRep, pw)
            case .dividend:
                x.dividends = FixedMath.weighted(e.amountRep + e.feesRep + e.taxesRep, pw)
                x.fees = FixedMath.weighted(e.feesRep, pw)
                x.taxes = FixedMath.weighted(e.taxesRep, pw)
                if pw != 0 {
                    dividendCount[s] += 1
                    let shares = e.shares > 0 ? e.shares : max(held[s], 0)
                    let unweighted = e.amountRep + e.feesRep + e.taxesRep
                    var yield: Double?
                    if shares > 0 {
                        let value = self.value(security: s, shares: shares, on: e.day)
                        if value.valued, value.rep > 0 { yield = Double(unweighted) / Double(value.rep) }
                    }
                    payments.append(DividendPayment(
                        transactionID: transactions[Int(e.transaction)].id, securityID: securities[s].id,
                        accountID: accounts[Int(e.account)].id, day: Day(rawValue: e.day), shares: Shares(raw: shares),
                        gross: x.dividends, fees: x.fees, taxes: x.taxes,
                        perShare: Price(minor: unweighted, per: Shares(raw: shares)), yield: yield))
                }
            case .interest:
                onSecurity = false
                x.interest = FixedMath.weighted(e.amountRep + e.feesRep + e.taxesRep, aw)
                x.fees = FixedMath.weighted(e.feesRep, aw)
                x.taxes = FixedMath.weighted(e.taxesRep, aw)
            case .interestCharge:
                onSecurity = false
                x.interestCharges = FixedMath.weighted(e.amountRep, aw)
            case .fee:
                x.fees = FixedMath.weighted(e.amountRep, onSecurity ? pw : aw)
            case .feeRefund:
                x.fees = -FixedMath.weighted(e.amountRep, onSecurity ? pw : aw)
            case .tax:
                x.taxes = FixedMath.weighted(e.amountRep, onSecurity ? pw : aw)
            case .taxRefund:
                x.taxes = -FixedMath.weighted(e.amountRep, onSecurity ? pw : aw)
            case .deposit, .withdrawal, .cashTransfer, .securityTransfer:
                continue
            }
            guard !x.isZero else { continue }
            if e.rateMissing {
                diagnostics.add(.missingExchangeRate(from: currencies[Int(e.currency)], to: reportingCurrency))
            }
            while e.day > monthEnd {
                monthIndex += 1
                monthEnd = Day(rawValue: monthEnd + 1).endOfMonth.rawValue
            }
            months[monthIndex] += x
            total += x
            if onSecurity { bySecurity[s] += x } else { withoutSecurity += x }
            if e.account >= 0 { byAccount[Int(e.account)] += x }
        }

        var monthRows: [EarningsMonth] = []
        monthRows.reserveCapacity(monthCount)
        for i in 0..<monthCount {
            let m = baseMonth + i
            monthRows.append(EarningsMonth(year: m / 12, month: m % 12 + 1, amounts: months[i]))
        }
        var securityRows: [SecurityEarnings] = []
        for s in securities.indices where !bySecurity[s].isZero || dividendCount[s] > 0 {
            securityRows.append(SecurityEarnings(
                securityID: securities[s].id, amounts: bySecurity[s], dividendCount: dividendCount[s]))
        }
        var accountRows: [AccountEarnings] = []
        for a in accounts.indices where !byAccount[a].isZero {
            accountRows.append(AccountEarnings(accountID: accounts[a].id, amounts: byAccount[a]))
        }
        return EarningsReport(
            interval: interval, currency: reportingCurrency, total: total, months: monthRows,
            bySecurity: securityRows, withoutSecurity: withoutSecurity, byAccount: accountRows,
            payments: payments, diagnostics: diagnostics.items)
    }
}
