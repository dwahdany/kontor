import Foundation
import KontorUI

// MARK: - Earnings of a scope

/// What the Earnings screen reads of an engine `EarningsReport`: the same aggregates, as plain
/// values the feature can also assemble itself.
///
/// For every scope but a single cash account this is a copy of `Ledger.earnings(in:scope:)`.
/// For a **cash account** the engine's scope answers a different question ("how did this account
/// perform as a cash vehicle": a dividend arriving is an inflow there, not income), so its report
/// contains no dividends and no fees or taxes of securities. The Earnings screen has to show what
/// was *booked on* that account instead. `EarningsData` therefore composes it from whole-portfolio
/// engine reports — `EarningsReport.byAccount` attributes every booking to the account it was
/// booked on — without doing any conversion or rounding of its own:
///
/// * total, account row and payments: one portfolio report of the interval;
/// * months: one portfolio report per calendar month that has bookings;
/// * per security: one single-security report per security with bookings.
///
/// Every part is an exact engine figure, so the parts add up to the total to the cent.
struct EarningsData: Sendable {
    struct Month: Sendable, Hashable {
        var year: Int
        /// 1…12
        var month: Int
        var amounts: EarningsAmounts
        /// `year × 12 + month − 1`
        var index: Int { year * 12 + month - 1 }
    }

    struct Year: Sendable {
        var year: Int
        /// Always twelve (January first); months outside the interval are zero.
        var months: [EarningsAmounts]
        var total: EarningsAmounts
    }

    struct SecurityEntry: Sendable, Hashable {
        var securityID: UUID
        var amounts: EarningsAmounts
        /// Number of dividend bookings.
        var dividendCount: Int
    }

    struct AccountEntry: Sendable, Hashable {
        var accountID: UUID
        var amounts: EarningsAmounts
    }

    var interval: DayInterval
    var total: EarningsAmounts
    /// Every calendar month touched by the interval, in order.
    var months: [Month]
    var bySecurity: [SecurityEntry]
    var withoutSecurity: EarningsAmounts
    var byAccount: [AccountEntry]
    /// Dividend bookings, chronological.
    var payments: [DividendPayment]

    init(_ report: EarningsReport) {
        interval = report.interval
        total = report.total
        months = report.months.map { Month(year: $0.year, month: $0.month, amounts: $0.amounts) }
        bySecurity = report.bySecurity.map {
            SecurityEntry(securityID: $0.securityID, amounts: $0.amounts, dividendCount: $0.dividendCount)
        }
        withoutSecurity = report.withoutSecurity
        byAccount = report.byAccount.map { AccountEntry(accountID: $0.accountID, amounts: $0.amounts) }
        payments = report.payments
    }

    /// The cash account of a scope that consists of exactly one account and nothing else.
    static func bookedAccount(of scope: Scope) -> UUID? {
        guard case .subset(let depots, let accounts) = scope, depots.isEmpty, accounts.count == 1 else { return nil }
        return accounts.first
    }

    /// The earnings of `scope` in `interval`. `detailed: false` leaves `months` amounts and
    /// `bySecurity` out for an account scope (they cost one engine pass each) — enough for totals
    /// and payments.
    static func make(ledger: Ledger, scope: Scope, interval: DayInterval, detailed: Bool = true) -> EarningsData {
        guard let account = bookedAccount(of: scope) else {
            return EarningsData(ledger.earnings(in: interval, scope: scope))
        }
        return bookedOn(account: account, ledger: ledger, interval: interval, detailed: detailed)
    }

    /// Like `make`, reusing the report an `Analysis` has already computed for its own scope and interval.
    static func make(_ analysis: Analysis, detailed: Bool = true) -> EarningsData {
        guard let account = bookedAccount(of: analysis.scope) else { return EarningsData(analysis.earnings) }
        return bookedOn(account: account, ledger: analysis.ledger, interval: analysis.interval, detailed: detailed)
    }

    private static func bookedOn(account: UUID, ledger: Ledger, interval: DayInterval, detailed: Bool) -> EarningsData {
        func amounts(_ report: EarningsReport) -> EarningsAmounts {
            report.byAccount.first { $0.accountID == account }?.amounts ?? EarningsAmounts()
        }
        let whole = ledger.earnings(in: interval, scope: .portfolio)
        var data = EarningsData(whole)
        data.total = amounts(whole)
        data.payments = whole.payments.filter { $0.accountID == account }
        data.byAccount = data.total.isZero ? [] : [AccountEntry(accountID: account, amounts: data.total)]
        data.bySecurity = []
        data.withoutSecurity = EarningsAmounts()
        for i in data.months.indices { data.months[i].amounts = EarningsAmounts() }
        guard detailed, !data.total.isZero || !data.payments.isEmpty else { return data }

        // Months: the account's row of a portfolio report of just that month (clipped to the interval).
        for (i, month) in whole.months.enumerated() where !month.amounts.isZero {
            let first = Day(year: month.year, month: month.month, day: 1)
            let part = DayInterval(start: max(interval.start, first.advanced(by: -1)), end: min(interval.end, first.endOfMonth))
            data.months[i].amounts = amounts(ledger.earnings(in: part, scope: .portfolio))
        }
        // Securities: the account's row of each security's own report. The rest is not tied to one.
        var attributed = EarningsAmounts()
        var counts: [UUID: Int] = [:]
        for payment in data.payments { counts[payment.securityID, default: 0] += 1 }
        for entry in whole.bySecurity {
            let own = amounts(ledger.earnings(in: interval, scope: .security(entry.securityID)))
            let count = counts[entry.securityID] ?? 0
            guard !own.isZero || count > 0 else { continue }
            data.bySecurity.append(SecurityEntry(securityID: entry.securityID, amounts: own, dividendCount: count))
            attributed += own
        }
        var rest = data.total
        rest.dividends -= attributed.dividends
        rest.interest -= attributed.interest
        rest.interestCharges -= attributed.interestCharges
        rest.fees -= attributed.fees
        rest.taxes -= attributed.taxes
        data.withoutSecurity = rest
        return data
    }

    /// The year × month matrix: one row per calendar year touched by the interval.
    var years: [Year] {
        var out: [Year] = []
        for month in months {
            if out.last?.year != month.year {
                out.append(Year(year: month.year, months: [EarningsAmounts](repeating: EarningsAmounts(), count: 12), total: EarningsAmounts()))
            }
            out[out.count - 1].months[month.month - 1] = month.amounts
            out[out.count - 1].total += month.amounts
        }
        return out
    }

    /// Rolling twelve-month sums of `metric`, one per month; nil while fewer than twelve months
    /// of the interval are available.
    func trailingTwelveMonths(_ metric: EarningsMetric) -> [Int64?] {
        var out: [Int64?] = []
        out.reserveCapacity(months.count)
        var sum: Int64 = 0
        for (i, month) in months.enumerated() {
            sum += month.amounts[metric]
            if i >= 12 { sum -= months[i - 12].amounts[metric] }
            out.append(i >= 11 ? sum : nil)
        }
        return out
    }
}

// MARK: - Small rules shared by the model and the views

enum EarningsRules {
    /// The largest growth that is still shown as a number (+1,000 %): beyond that the basis is so
    /// small that the percentage says nothing.
    static let largestGrowth = 10.0

    /// `value / previous − 1`. Defined only while both values are positive — a figure that changed
    /// its sign (a tax refund year, a net loss) has no growth rate — and while the result is not absurd.
    static func growth(_ value: Int64, over previous: Int64) -> Double? {
        guard value > 0, previous > 0 else { return nil }
        let growth = Double(value) / Double(previous) - 1
        return growth <= largestGrowth ? growth : nil
    }

    /// "Share of the total" only says something while no part has the opposite sign of the others
    /// (refunds among taxes, costs among net income): otherwise the shares exceed 100 %.
    static func sharesAreMeaningful(_ parts: some Sequence<Int64>) -> Bool {
        var positive = false, negative = false
        for part in parts {
            if part > 0 { positive = true } else if part < 0 { negative = true }
        }
        return positive != negative
    }

    /// The rows of `selection` that are still in the table.
    static func visible<ID: Hashable>(_ selection: Set<ID>, in rows: some Sequence<ID>) -> Set<ID> {
        guard !selection.isEmpty else { return [] }
        return selection.intersection(rows)
    }

    /// The months a chart bar covers, as `year × 12 + month − 1`: "2025-05" (a month), "2025-Q2"
    /// (a quarter) or "2025" (a year).
    static func months(ofBar id: String) -> ClosedRange<Int>? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard let year = parts.first.flatMap({ Int($0) }), (1...9999).contains(year) else { return nil }
        switch parts.count {
        case 1:
            return (year * 12)...(year * 12 + 11)
        case 2 where parts[1].hasPrefix("Q"):
            guard let quarter = Int(parts[1].dropFirst()), (1...4).contains(quarter) else { return nil }
            return (year * 12 + (quarter - 1) * 3)...(year * 12 + quarter * 3 - 1)
        case 2:
            guard let month = Int(parts[1]), (1...12).contains(month) else { return nil }
            return (year * 12 + month - 1)...(year * 12 + month - 1)
        default:
            return nil
        }
    }

    /// "May 2025", "Q2 2025", "2025", or "May 2025 – Jul 2025" for any other range.
    static func title(ofMonths months: ClosedRange<Int>) -> String {
        let first = months.lowerBound, last = months.upperBound
        if first == last { return Fmt.month(year: first / 12, month: first % 12 + 1, long: true) }
        if first / 12 == last / 12 {
            if first % 12 == 0, last % 12 == 11 { return String(first / 12) }
            if first % 3 == 0, last == first + 2 { return "Q\(first % 12 / 3 + 1) \(String(first / 12))" }
        }
        return "\(Fmt.month(year: first / 12, month: first % 12 + 1)) – \(Fmt.month(year: last / 12, month: last % 12 + 1))"
    }
}

// MARK: - Dividend payments (bookings of one security and day belong together)

/// One dividend payment of a security: all bookings of one day. A security held in several
/// depots is booked once per depot, but it is one payment with one amount per share.
struct DividendGroup: Sendable, Hashable {
    var securityID: UUID
    var day: Day
    /// Gross amount of the bookings (weighted by the scope, like every amount of the report).
    var gross: Int64
    /// The shares the payment was made for; zero if unknown.
    var shares: Shares
    /// Gross per share in the reporting currency at the payment day's rate (never weighted).
    var perShare: Price?
    var transactionIDs: [UUID]

    /// Dividend bookings without a share count: the engine then reports the *whole* position
    /// held before the payment for each of them.
    static func bookingsWithoutShares(in ledger: Ledger) -> Set<UUID> {
        var ids = Set<UUID>()
        for transaction in ledger.transactions where transaction.kind == .dividend && transaction.shares.isZero {
            ids.insert(transaction.id)
        }
        return ids
    }

    /// Merges bookings of the same security and day, chronological.
    ///
    /// Shares add up across the bookings — except for bookings in `withoutShares`, which each
    /// already stand for the whole position: then the payment covered that position once.
    static func groups(_ payments: [DividendPayment], withoutShares: Set<UUID>) -> [DividendGroup] {
        struct Key: Hashable {
            var securityID: UUID
            var day: Day
        }
        struct Sums {
            var gross: Int64 = 0
            var stated: Int64 = 0
            var position: Int64 = 0
            var unweightedGross: Int64 = 0
            var ids: [UUID] = []
        }
        var order: [Key] = []
        var sums: [Key: Sums] = [:]
        for payment in payments {
            let key = Key(securityID: payment.securityID, day: payment.day)
            var sum = sums[key] ?? {
                order.append(key)
                return Sums()
            }()
            sum.gross += payment.gross
            if withoutShares.contains(payment.transactionID) {
                sum.position = max(sum.position, payment.shares.raw)
            } else {
                sum.stated += payment.shares.raw
            }
            sum.unweightedGross += payment.perShare?.value(of: payment.shares) ?? 0
            sum.ids.append(payment.transactionID)
            sums[key] = sum
        }
        return order.map { key in
            let sum = sums[key]!
            let shares = Shares(raw: max(sum.stated, sum.position))
            return DividendGroup(
                securityID: key.securityID, day: key.day, gross: sum.gross, shares: shares,
                perShare: Price(minor: sum.unweightedGross, per: shares), transactionIDs: sum.ids)
        }
    }

    /// What this payment would bring for `held` shares: the same amount per share. Based on the
    /// payment's own (scope-weighted) gross, so a weighted scope projects its own part.
    func expected(for held: Shares, sharesThen: Shares? = nil) -> Int64 {
        let then = sharesThen ?? shares
        guard then.raw > 0, held.raw > 0 else { return 0 }
        return mulDiv(gross, held.raw, then.raw)
    }
}

// MARK: - Bookings the engine could not convert

/// Earnings bookings in a currency without an exchange rate to the reporting currency. The engine
/// counts them as zero; the screen must say so instead of silently showing less.
struct UnconvertedBookings: Sendable, Hashable {
    var transactionIDs: Set<UUID> = []
    /// Sorted.
    var currencies: [CurrencyCode] = []

    var count: Int { transactionIDs.count }
    var isEmpty: Bool { transactionIDs.isEmpty }

    /// One sentence for the warning banner.
    func message(reportingCurrency: CurrencyCode) -> String {
        let noun = count == 1 ? "booking" : "bookings"
        return "\(Fmt.integer(count)) \(noun) in \(currencies.joined(separator: ", ")) \(count == 1 ? "is" : "are") missing from these figures: there is no exchange rate to \(reportingCurrency)."
    }

    static func find(ledger: Ledger, scope: Scope, interval: DayInterval) -> UnconvertedBookings {
        let reporting = ledger.reportingCurrency
        // Most files use one or two currencies: decide once per currency.
        var convertible: [CurrencyCode: Bool] = [reporting: true]
        var found = UnconvertedBookings()
        var currencies = Set<CurrencyCode>()
        for transaction in ledger.transactions {
            if transaction.date > interval.end { break }
            guard transaction.date > interval.start, carriesEarnings(transaction) else { continue }
            let currency = transaction.amount.currency
            let ok = convertible[currency] ?? {
                let ok = ledger.converter.canConvert(from: currency, to: reporting)
                convertible[currency] = ok
                return ok
            }()
            guard !ok, involves(scope, transaction) else { continue }
            found.transactionIDs.insert(transaction.id)
            currencies.insert(currency)
        }
        found.currencies = currencies.sorted()
        return found
    }

    /// Whether the booking contributes to dividends, interest, fees or taxes.
    private static func carriesEarnings(_ transaction: Transaction) -> Bool {
        switch transaction.kind {
        case .dividend, .interest, .interestCharge, .fee, .feeRefund, .tax, .taxRefund:
            transaction.amount.minor != 0 || transaction.fees != 0 || transaction.taxes != 0
        case .buy, .sell, .deliveryIn, .deliveryOut:
            transaction.fees != 0 || transaction.taxes != 0
        case .deposit, .withdrawal, .cashTransfer, .securityTransfer:
            false
        }
    }

    /// Whether the booking can belong to the scope. (A booking that names a security but no
    /// depot counts for every depot: better one warning too many than a silent gap.)
    private static func involves(_ scope: Scope, _ transaction: Transaction) -> Bool {
        switch scope {
        case .portfolio:
            return true
        case .subset(let depots, let accounts):
            if EarningsData.bookedAccount(of: scope) != nil || transaction.securityID == nil || transaction.kind == .interest {
                return transaction.accountID.map(accounts.contains) ?? false
            }
            return transaction.depotID.map(depots.contains) ?? !depots.isEmpty
        case .security(let id, let depot):
            guard transaction.securityID == id else { return false }
            return depot == nil || transaction.depotID == nil || transaction.depotID == depot
        case .weighted(let securities, let accounts):
            if let id = transaction.securityID, transaction.kind != .interest { return securities[id] != nil }
            return transaction.accountID.map { accounts[$0] != nil } ?? false
        }
    }
}
