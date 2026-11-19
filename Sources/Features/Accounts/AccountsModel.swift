import Foundation
import KontorUI

/// A cash account or a depot — the two kinds of entity this feature shows.
enum AccountsEntity: Hashable, Sendable {
    case account(UUID)
    case depot(UUID)

    var focus: Route.Focus {
        switch self {
        case .account(let id): .account(id)
        case .depot(let id): .depot(id)
        }
    }

    var id: UUID {
        switch self {
        case .account(let id), .depot(let id): id
        }
    }
}

// MARK: - Cash balances

/// Running cash balances of one account in the account's own currency.
///
/// The engine values accounts in the reporting currency; statements and balance charts need the
/// account's own currency. The only rule involved is the model's sign convention
/// (`Transaction.cashEffect(on:)`), summed in the ledger's chronological order.
enum CashBalances {
    /// Balance at the end of every day of `start … end` (index 0 = end of `start`).
    static func daily(_ transactions: [Transaction], account: UUID, from start: Day, to end: Day) -> [Int64] {
        let count = max(0, start.distance(to: end)) + 1
        var result = [Int64](repeating: 0, count: count)
        var balance: Int64 = 0
        var next = 0
        for index in 0..<count {
            let day = start.advanced(by: index)
            while next < transactions.count, transactions[next].date <= day {
                balance += transactions[next].cashEffect(on: account)
                next += 1
            }
            result[index] = balance
        }
        return result
    }

    /// Balance at the end of `day`.
    static func balance(_ transactions: [Transaction], account: UUID, on day: Day) -> Int64 {
        var balance: Int64 = 0
        for t in transactions {
            if t.date > day { break }
            balance += t.cashEffect(on: account)
        }
        return balance
    }
}

/// Picks at most `maxPoints` evenly spaced indices of `0..<count`, always including the first and last.
func sampledIndices(count: Int, maxPoints: Int) -> [Int] {
    guard count > maxPoints, maxPoints > 1 else { return Array(0..<max(count, 0)) }
    var result = [Int]()
    result.reserveCapacity(maxPoints)
    let step = Double(count - 1) / Double(maxPoints - 1)
    for i in 0..<maxPoints {
        let index = min(count - 1, Int((Double(i) * step).rounded()))
        if result.last != index { result.append(index) }
    }
    return result
}

// MARK: - Things the totals leave out

/// Balances and positions that the engine counts as zero because they cannot be converted or
/// priced. Totals that contain such a gap must say so instead of looking complete.
struct ValuationGaps: Sendable, Equatable {
    /// Account balances without an exchange rate, summed per currency (sorted by currency).
    var balances: [Money]
    /// Positions without a price or without an exchange rate.
    var positions: Int

    var isEmpty: Bool { balances.isEmpty && positions == 0 }
    var hasCashGap: Bool { !balances.isEmpty }
    var hasSecuritiesGap: Bool { positions > 0 }

    init(balances: [Money] = [], positions: Int = 0) {
        var sums = [CurrencyCode: Int64]()
        for balance in balances { sums[balance.currency, default: 0] += balance.minor }
        self.balances = sums.keys.sorted().map { Money(minor: sums[$0] ?? 0, currency: $0) }
        self.positions = positions
    }

    /// "excludes 5.950,00 CHF (no exchange rate)" — nil when cash is complete.
    var cashNote: String? {
        guard hasCashGap else { return nil }
        return "excludes \(balances.map { Fmt.money($0) }.joined(separator: " + ")) (no exchange rate)"
    }

    /// "excludes 2 positions without a price" — nil when every position is valued.
    var securitiesNote: String? {
        guard hasSecuritiesGap else { return nil }
        return "excludes \(Fmt.integer(positions)) position\(positions == 1 ? "" : "s") without a price or rate"
    }

    /// Both notes, for totals that contain cash and securities.
    var note: String? {
        let parts = [cashNote, securitiesNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Which bookings a statement lists.
enum LedgerRange: String, CaseIterable, Identifiable, Sendable {
    /// The window's reporting period.
    case period
    /// Everything ever booked.
    case all

    var id: String { rawValue }
}

/// A table's selection can outlive the rows it was made on (quick filter, period switch, undo).
/// Everything that acts on a selection — delete, copy, sums, the footer count — uses the part of
/// it that is still listed.
enum TableSelection {
    static func effective<ID: Hashable>(_ selection: Set<ID>, visible: Set<ID>) -> Set<ID> {
        // Iterate the smaller side: selections are tiny, statements can have tens of thousands of rows.
        selection.count <= visible.count ? selection.filter(visible.contains) : visible.filter(selection.contains)
    }
}

// MARK: - Overview

/// Everything the overview shows. Built off the main actor from the shared whole-portfolio analysis.
struct AccountsOverview: Sendable {
    struct AccountRow: Identifiable, Sendable {
        var id: UUID
        var name: String
        var note: String
        var isRetired: Bool
        /// Balance today in the account's own currency.
        var balance: Money
        /// The same balance in the reporting currency.
        var value: Money
        /// False if the balance could not be converted (missing exchange rate).
        var isValued: Bool
        /// Weekly balances of the last year in the account's own currency.
        var sparkline: [Double]
        var firstActivity: Day?
        var lastActivity: Day?
        var transactionCount: Int
    }

    struct DepotRow: Identifiable, Sendable {
        var id: UUID
        var name: String
        var note: String
        var isRetired: Bool
        var referenceAccountID: UUID?
        var referenceAccountName: String?
        /// Market value today in the reporting currency.
        var value: Money
        var positionCount: Int
        /// TTWROR of the depot over the reporting period; nil if it held nothing in the period.
        var ttwror: Double?
        /// Absolute performance over the reporting period (reporting currency).
        var gain: Money
        /// Positions that count as zero in `value` because a price or an exchange rate is missing.
        var unvaluedPositions: Int
        var firstActivity: Day?
        var lastActivity: Day?
        var transactionCount: Int
    }

    var currency: CurrencyCode
    var today: Day
    var interval: DayInterval
    var accounts: [AccountRow]
    var depots: [DepotRow]
    var cashTotal: Money
    var depotTotal: Money
    var netWorth: Money
    /// What the totals leave out because it cannot be valued (missing exchange rate or price).
    var gaps: ValuationGaps
    /// Value over the period, stacked by depot and account.
    var chart: StackedAreaData

    var isEmpty: Bool { accounts.isEmpty && depots.isEmpty }
    var hasForeignCurrency: Bool { accounts.contains { $0.balance.currency != currency } }
    var activeAccounts: [AccountRow] { accounts.filter { !$0.isRetired } }
    var retiredAccounts: [AccountRow] { accounts.filter(\.isRetired) }
    var activeDepots: [DepotRow] { depots.filter { !$0.isRetired } }
    var retiredDepots: [DepotRow] { depots.filter(\.isRetired) }

    init(_ analysis: Analysis, today: Day) {
        let ledger = analysis.ledger
        let interval = analysis.interval
        let currency = ledger.reportingCurrency
        let snapshot = ledger.snapshot(on: today)
        self.currency = currency
        self.today = today
        self.interval = interval

        let yearStart = today.addingYears(-1)
        var accountRows = [AccountRow]()
        var series = [StackedAreaData.Series]()
        let sample = sampledIndices(count: interval.dayCount + 1, maxPoints: 360)

        // Depots first: they are the base of the stacked chart.
        var valueByDepot = [UUID: Int64]()
        var positionsByDepot = [UUID: Int]()
        var unvaluedByDepot = [UUID: Int]()
        for position in snapshot.positions {
            for holding in position.holdings where !holding.shares.isZero {
                valueByDepot[holding.depotID, default: 0] += holding.value.minor
                positionsByDepot[holding.depotID, default: 0] += 1
                if !position.isValued { unvaluedByDepot[holding.depotID, default: 0] += 1 }
            }
        }
        var depotRows = [DepotRow]()
        for depot in ledger.depots {
            let valuation = ledger.valuation(in: interval, scope: .depot(depot.id))
            let held = valuation.values.contains { $0 != 0 } || valuation.totalInflows != 0 || valuation.totalOutflows != 0
            let transactions = ledger.transactions(forDepot: depot.id)
            depotRows.append(DepotRow(
                id: depot.id, name: depot.name, note: depot.note, isRetired: depot.isRetired,
                referenceAccountID: depot.referenceAccountID,
                referenceAccountName: depot.referenceAccountID.flatMap { ledger.account($0)?.name },
                value: Money(minor: valueByDepot[depot.id] ?? 0, currency: currency),
                positionCount: positionsByDepot[depot.id] ?? 0,
                ttwror: held ? valuation.returns().total : nil,
                gain: Money(minor: valuation.absolutePerformance, currency: currency),
                unvaluedPositions: unvaluedByDepot[depot.id] ?? 0,
                firstActivity: transactions.first?.date, lastActivity: transactions.last?.date, transactionCount: transactions.count))
            if held {
                series.append(.init(id: "depot:\(depot.id.uuidString)", name: depot.name, values: sample.map { Double(valuation.values[$0]) }))
            }
        }

        for account in ledger.accounts {
            let transactions = ledger.transactions(forAccount: account.id)
            let cash = snapshot.cash(account.id)
            let balance = cash?.balance ?? Money(minor: CashBalances.balance(transactions, account: account.id, on: today), currency: account.currency)
            let year = CashBalances.daily(transactions, account: account.id, from: yearStart, to: today)
            let weekly = stride(from: year.count - 1, through: 0, by: -7).reversed().map { Double(year[$0]) }
            accountRows.append(AccountRow(
                id: account.id, name: account.name, note: account.note, isRetired: account.isRetired,
                balance: balance, value: cash?.value ?? .zero(currency), isValued: cash?.isValued ?? true,
                sparkline: weekly, firstActivity: transactions.first?.date, lastActivity: transactions.last?.date,
                transactionCount: transactions.count))
            let valuation = ledger.valuation(in: interval, scope: .account(account.id))
            if valuation.values.contains(where: { $0 != 0 }) {
                series.append(.init(id: "account:\(account.id.uuidString)", name: account.name, values: sample.map { Double(valuation.values[$0]) }))
            }
        }

        accounts = accountRows
        depots = depotRows
        cashTotal = snapshot.cashValue
        depotTotal = snapshot.securitiesValue
        netWorth = snapshot.totalValue
        gaps = ValuationGaps(
            balances: accountRows.filter { !$0.isValued && $0.balance.minor != 0 }.map(\.balance),
            positions: snapshot.positions.filter { !$0.isValued }.count)
        chart = StackedAreaData(days: sample.map { interval.start.advanced(by: $0) }, series: StackedAreaData.folded(series), currency: currency)
    }

    /// Tab-separated balances for the clipboard.
    var tsv: String {
        // A balance without an exchange rate has no value: the cell stays empty instead of claiming 0.
        var rows = accounts.map {
            ["Account", $0.name, $0.balance.currency, TSV.number($0.balance.decimalValue), $0.isValued ? TSV.number($0.value.decimalValue) : ""]
        }
        rows += depots.map { ["Depot", $0.name, currency, TSV.number($0.value.decimalValue), TSV.number($0.value.decimalValue)] }
        return TSV.string(header: ["Type", "Name", "Currency", "Balance", "Value (\(currency))"], rows: rows)
    }
}

// MARK: - Account detail

/// What an account earned and what it cost in a period, **in the account's own currency** and as
/// it was booked: the net amounts are exactly the credits of the statement, the gross amounts add
/// back what was withheld. Same categories as the engine's `EarningsAmounts` (fees and taxes
/// include those inside purchases, sales, dividends and interest, net of refunds), so for an
/// account in the reporting currency the gross figures equal `EarningsReport.byAccount`.
struct AccountIncome: Sendable, Equatable {
    /// Interest credited (after withheld tax), before interest charges.
    var interestReceived: Int64 = 0
    /// Interest before tax.
    var interestGross: Int64 = 0
    /// Interest the account was charged (≥ 0).
    var interestCharges: Int64 = 0
    /// Dividends credited (after fees and withheld tax).
    var dividendsReceived: Int64 = 0
    /// Dividends before fees and tax.
    var dividendsGross: Int64 = 0
    var fees: Int64 = 0
    var taxes: Int64 = 0

    /// What interest added to the balance: credits minus charges. Reconciles with the statement.
    var interestNet: Int64 { interestReceived - interestCharges }
    /// Tax (and fees) withheld from interest.
    var interestWithheld: Int64 { interestGross - interestReceived }
    var dividendsWithheld: Int64 { dividendsGross - dividendsReceived }

    init() {}

    /// Bookings on `account` dated within `interval` (`start < date <= end`).
    init(_ transactions: [Transaction], account: UUID, in interval: DayInterval) {
        for t in transactions where t.accountID == account && interval.contains(t.date) {
            switch t.kind {
            case .buy, .sell:
                fees += t.fees
                taxes += t.taxes
            case .dividend:
                dividendsReceived += t.amount.minor
                dividendsGross += t.grossMinor
                fees += t.fees
                taxes += t.taxes
            case .interest:
                interestReceived += t.amount.minor
                interestGross += t.grossMinor
                fees += t.fees
                taxes += t.taxes
            case .interestCharge: interestCharges += t.amount.minor
            case .fee: fees += t.amount.minor
            case .feeRefund: fees -= t.amount.minor
            case .tax: taxes += t.amount.minor
            case .taxRefund: taxes -= t.amount.minor
            case .deposit, .withdrawal, .cashTransfer, .deliveryIn, .deliveryOut, .securityTransfer: break
            }
        }
    }

    /// One line under the interest figure: what else arrived, and what was withheld.
    func interestFootnote(currency: CurrencyCode) -> String {
        func money(_ minor: Int64) -> String { Fmt.money(minor: minor, currency: currency) }
        if dividendsReceived != 0 { return "plus \(money(dividendsReceived)) net dividends" }
        if interestWithheld > 0 { return "gross \(money(interestGross)) − \(money(interestWithheld)) tax" }
        if interestCharges > 0 { return "after \(money(interestCharges)) interest charged" }
        return "credited to this account"
    }

    /// One line under the fees figure.
    func feesFootnote(currency: CurrencyCode) -> String {
        func money(_ minor: Int64) -> String { Fmt.money(minor: minor, currency: currency) }
        if taxes < 0 { return "\(money(-taxes)) taxes refunded" }
        return "plus \(money(taxes)) taxes"
    }
}

struct AccountDetailModel: Sendable {
    struct Month: Sendable, Identifiable {
        var year: Int
        var month: Int
        /// Money booked onto / off the account in that month, own currency, both ≥ 0.
        var moneyIn: Int64
        var moneyOut: Int64
        var id: Int { year * 12 + month - 1 }
    }

    var id: UUID
    var currency: CurrencyCode
    var reportingCurrency: CurrencyCode
    var interval: DayInterval
    /// Balance today (own currency) and its value in the reporting currency.
    var balance: Money
    var value: Money
    var isValued: Bool
    /// Balance at the end of every day of the period, own currency; index 0 = baseline day.
    var balances: [Int64]
    var moneyIn: Int64
    var moneyOut: Int64
    var months: [Month]
    /// Interest, dividends, fees and taxes booked on this account in the period, own currency.
    var income: AccountIncome
    var transactionCount: Int

    var periodChange: Int64 { (balances.last ?? 0) - (balances.first ?? 0) }

    init?(_ analysis: Analysis, account id: UUID, today: Day) {
        let ledger = analysis.ledger
        guard let account = ledger.account(id) else { return nil }
        let interval = analysis.interval
        let transactions = ledger.transactions(forAccount: id)
        self.id = id
        currency = account.currency
        reportingCurrency = ledger.reportingCurrency
        self.interval = interval
        let cash = ledger.snapshot(on: today, scope: .account(id)).cash(id)
        balance = cash?.balance ?? Money(minor: CashBalances.balance(transactions, account: id, on: today), currency: account.currency)
        value = cash?.value ?? .zero(ledger.reportingCurrency)
        isValued = cash?.isValued ?? true
        balances = CashBalances.daily(transactions, account: id, from: interval.start, to: interval.end)
        transactionCount = transactions.count

        var monthIndex = [Int: Int]()
        var months = [Month]()
        var cursor = interval.firstDay.startOfMonth
        while cursor <= interval.end {
            monthIndex[cursor.year * 12 + cursor.month - 1] = months.count
            months.append(Month(year: cursor.year, month: cursor.month, moneyIn: 0, moneyOut: 0))
            cursor = cursor.addingMonths(1)
        }
        var totalIn: Int64 = 0, totalOut: Int64 = 0
        for t in transactions where interval.contains(t.date) {
            let effect = t.cashEffect(on: id)
            guard effect != 0, let index = monthIndex[t.date.year * 12 + t.date.month - 1] else { continue }
            if effect > 0 {
                months[index].moneyIn += effect
                totalIn += effect
            } else {
                months[index].moneyOut -= effect
                totalOut -= effect
            }
        }
        self.months = months
        moneyIn = totalIn
        moneyOut = totalOut
        income = AccountIncome(transactions, account: id, in: interval)
    }
}

/// One line of an account statement.
struct StatementRow: Identifiable, Sendable {
    let id: UUID
    /// Position in booking order (ties on one day keep their order when sorting by date).
    var order: Int
    var date: Day
    var kind: Transaction.Kind
    var kindTitle: String
    /// Security, or the other account of a transfer.
    var counterpart: String
    var note: String
    /// Signed change of the balance, own currency.
    var amount: Int64
    /// Balance after this booking.
    var balance: Int64

    /// Every booking of the account that matches `filter`, in booking order.
    static func rows(_ ledger: Ledger, account id: UUID, filter: QuickFilter) -> [StatementRow] {
        Statement(ledger, account: id, interval: nil, filter: filter).rows
    }
}

/// An account statement: the bookings of a period (or all of them) between an opening and a
/// closing balance. Built off the main actor; carries everything the table chrome needs so the
/// view never goes back to the store for counts.
struct Statement: Sendable {
    /// Bookings in range that match the quick filter, in booking order.
    var rows: [StatementRow]
    /// Ids of `rows`, to reconcile the table's selection with what is listed.
    var ids: Set<UUID>
    /// Bookings in range, before the quick filter.
    var rangeCount: Int
    /// All bookings of the account.
    var totalCount: Int
    /// The period the statement covers; nil = everything.
    var interval: DayInterval?
    /// Balance before the first booking in range (end of `interval.start`) and after the last one.
    var opening: Int64
    var closing: Int64
    /// Changes whenever the statement was rebuilt (cheap to compare, unlike the rows).
    var stamp = UUID()

    init(_ ledger: Ledger, account id: UUID, interval: DayInterval?, filter: QuickFilter) {
        let transactions = ledger.transactions(forAccount: id)
        var rows = [StatementRow]()
        var balance: Int64 = 0, opening: Int64 = 0, inRange = 0
        for (order, t) in transactions.enumerated() {
            if let interval {
                if t.date <= interval.start {
                    balance += t.cashEffect(on: id)
                    opening = balance
                    continue
                }
                if t.date > interval.end { break }
            }
            let effect = t.cashEffect(on: id)
            balance += effect
            inRange += 1
            let counterpart: String
            if t.kind == .cashTransfer {
                if t.accountID == id {
                    counterpart = "To " + (t.counterAccountID.flatMap { ledger.account($0)?.name } ?? "another account")
                } else {
                    counterpart = "From " + (t.accountID.flatMap { ledger.account($0)?.name } ?? "another account")
                }
            } else {
                counterpart = t.securityID.flatMap { ledger.security($0)?.name } ?? ""
            }
            let title = t.kind.title
            guard filter.isEmpty || filter.matches(title, counterpart, t.note, t.date.iso) else { continue }
            rows.append(StatementRow(
                id: t.id, order: order, date: t.date, kind: t.kind, kindTitle: title, counterpart: counterpart,
                note: t.note, amount: effect, balance: balance))
        }
        self.rows = rows
        ids = Set(rows.map(\.id))
        rangeCount = inRange
        totalCount = transactions.count
        self.interval = interval
        self.opening = opening
        closing = balance
    }

    /// The statement as tab-separated text. With `ids` only those rows, in the listed order; without,
    /// everything listed — and when that is a whole period (no quick filter), in booking order and
    /// framed by its opening and closing balance, so that it can be filed as that period's statement.
    func tsv(only ids: Set<UUID>, currency: CurrencyCode) -> String {
        func number(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: currency).decimalValue) }
        func line(_ row: StatementRow) -> [String] {
            [row.date.iso, row.kindTitle, row.counterpart, row.note, number(row.amount), number(row.balance), currency]
        }
        let header = ["Date", "Type", "Details", "Note", "Amount", "Balance", "Currency"]
        if !ids.isEmpty { return TSV.string(header: header, rows: rows.filter { ids.contains($0.id) }.map(line)) }
        guard let interval, rows.count == rangeCount else { return TSV.string(header: header, rows: rows.map(line)) }
        var lines = [[interval.start.iso, "Opening balance", "", "", "", number(opening), currency]]
        lines += rows.sorted { $0.order < $1.order }.map(line)
        lines.append([interval.end.iso, "Closing balance", "", "", "", number(closing), currency])
        return TSV.string(header: header, rows: lines)
    }
}

// MARK: - Depot detail

struct DepotDetailModel: Sendable {
    struct Position: Identifiable, Sendable {
        /// Where the price that values a position comes from.
        enum Pricing: Sendable, Equatable {
            /// A quote of the security's price history.
            case quoted
            /// No quotes: the engine falls back to the price of the security's own transactions.
            case derived
            /// No price or no exchange rate at all: the position counts as zero.
            case missing
        }

        let id: UUID
        var name: String
        var symbol: String
        var shares: Shares
        var price: Price?
        var priceDay: Day?
        var priceCurrency: CurrencyCode
        var pricing: Pricing
        var value: Int64
        /// Share of the depot's market value, 0…1.
        var weight: Double
        var costBasis: Int64
        var gain: Int64
        var gainFraction: Double?
        var isValued: Bool

        /// Days after which a quote no longer counts as current (the consistency check's threshold).
        static let staleAfterDays = 10

        /// Age of the price in days on `day`, if it is a quote older than `staleAfterDays`.
        func staleDays(on day: Day) -> Int? {
            guard pricing == .quoted, let priceDay else { return nil }
            let age = priceDay.distance(to: day)
            return age > Self.staleAfterDays ? age : nil
        }

        /// Explains a price that is not a current quote; nil for an ordinary one.
        func priceWarning(on day: Day) -> String? {
            switch pricing {
            case .missing: return "No price or exchange rate — this position counts as zero."
            case .derived: return "No quotes for this security — valued at the price of its last transaction\(priceDay.map { " (\(Fmt.day($0, style: .medium)))" } ?? ""), not at a market price."
            case .quoted:
                guard staleDays(on: day) != nil, let priceDay else { return nil }
                return "Last quote from \(Fmt.day(priceDay, style: .medium))."
            }
        }
    }

    var id: UUID
    var currency: CurrencyCode
    var interval: DayInterval
    /// The day `positions` and `marketValue` are valued on.
    var today: Day
    /// Positions today, largest first.
    var positions: [Position]
    var marketValue: Money
    var costBasis: Money
    var unrealizedGain: Money
    var valuePoints: [ChartPoint<Int64>]
    var invested: [Int64]
    var hasHistory: Bool
    var ttwror: Double
    var ttwrorAnnualized: Double?
    var irr: Double?
    var absolutePerformance: Money
    var dividends: Money
    var fees: Money

    /// "1 position valued at its purchase price" / "1 position without a price" — nil if every
    /// position has a real quote.
    var valuationWarning: String? {
        let missing = positions.filter { $0.pricing == .missing }.count
        let derived = positions.filter { $0.pricing == .derived }.count
        func count(_ n: Int) -> String { "\(Fmt.integer(n)) position\(n == 1 ? "" : "s")" }
        var parts = [String]()
        if missing > 0 { parts.append("\(count(missing)) without a price") }
        if derived > 0 { parts.append("\(count(derived)) at transaction price") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init?(_ analysis: Analysis, depot id: UUID, today: Day) {
        let ledger = analysis.ledger
        guard ledger.depot(id) != nil else { return nil }
        let currency = ledger.reportingCurrency
        self.id = id
        self.currency = currency
        self.today = today
        interval = analysis.interval

        var derived = Set<UUID>()
        for diagnostic in ledger.diagnostics {
            if case .pricesDerivedFromTransactions(let security) = diagnostic { derived.insert(security) }
        }
        let snapshot = ledger.snapshot(on: today, scope: .depot(id))
        let total = snapshot.securitiesValue.minor
        positions = snapshot.positions.map { p in
            let security = ledger.security(p.securityID)
            return Position(
                id: p.securityID, name: security?.name ?? "Unknown security",
                symbol: security.map { $0.ticker.isEmpty ? $0.isin : $0.ticker } ?? "",
                shares: p.shares, price: p.price, priceDay: p.priceDay, priceCurrency: security?.currency ?? currency,
                pricing: !p.isValued ? .missing : derived.contains(p.securityID) ? .derived : .quoted,
                value: p.value.minor, weight: total > 0 ? Double(p.value.minor) / Double(total) : 0,
                costBasis: p.costBasis.minor, gain: p.unrealizedGain.minor, gainFraction: p.unrealizedGainFraction,
                isValued: p.isValued)
        }
        .sorted { $0.value > $1.value }
        marketValue = snapshot.securitiesValue
        costBasis = snapshot.costBasis
        unrealizedGain = snapshot.securitiesValue - snapshot.costBasis

        let valuation = analysis.valuation
        hasHistory = valuation.values.contains { $0 != 0 }
        valuePoints = valuation.chartPoints(maxPoints: 900)
        invested = analysis.investedCapital
        ttwror = analysis.ttwror
        ttwrorAnnualized = analysis.ttwrorAnnualized
        irr = analysis.irr
        absolutePerformance = Money(minor: valuation.absolutePerformance, currency: currency)
        let breakdown = analysis.breakdown
        dividends = Money(minor: breakdown.dividends, currency: currency)
        fees = Money(minor: breakdown.fees, currency: currency)
    }
}

/// One booking of a depot.
struct DepotTransactionRow: Identifiable, Sendable {
    let id: UUID
    var order: Int
    var date: Day
    var kind: Transaction.Kind
    var kindTitle: String
    var security: String
    /// Signed change of the position in this depot.
    var shares: Shares
    var amount: Money
    var note: String
    /// A dividend booked on the account without naming a depot, which the engine counts for this
    /// depot because it held the security (see "Bookings without a depot" in the engine reference).
    var isAttributed = false

    static let attributedHelp = "Booked on the cash account without a depot. It counts for this depot because the depot held the security; if several depots held it at that time, it counts in full for each of them."

    /// Every booking of the depot that matches `filter`, in booking order.
    static func rows(_ ledger: Ledger, depot id: UUID, filter: QuickFilter) -> [DepotTransactionRow] {
        DepotLedger(ledger, depot: id, interval: nil, filter: filter).rows
    }
}

/// The bookings of a depot in a period (or all of them): everything that names the depot, plus the
/// dividends the engine attributes to it — the same set its gain and dividend figures are made of.
struct DepotLedger: Sendable {
    var rows: [DepotTransactionRow]
    var ids: Set<UUID>
    /// Bookings in range, before the quick filter.
    var rangeCount: Int
    /// All bookings of the depot.
    var totalCount: Int
    /// Attributed dividends among `rows`.
    var attributedCount: Int
    var interval: DayInterval?
    var stamp = UUID()

    init(_ ledger: Ledger, depot id: UUID, interval: DayInterval?, filter: QuickFilter) {
        let transactions = Self.transactions(ledger, depot: id)
        var rows = [DepotTransactionRow]()
        var inRange = 0, attributed = 0
        for (order, entry) in transactions.enumerated() {
            let t = entry.transaction
            if let interval {
                if t.date <= interval.start { continue }
                if t.date > interval.end { break }
            }
            inRange += 1
            let security = t.securityID.flatMap { ledger.security($0)?.name } ?? ""
            var title = t.kind.title
            if t.kind == .securityTransfer {
                let other = t.depotID == id ? t.counterDepotID : t.depotID
                let name = other.flatMap { ledger.depot($0)?.name } ?? "another depot"
                title = t.depotID == id ? "Transfer to \(name)" : "Transfer from \(name)"
            }
            guard filter.isEmpty || filter.matches(title, security, t.note, t.date.iso) else { continue }
            if entry.isAttributed { attributed += 1 }
            rows.append(DepotTransactionRow(
                id: t.id, order: order, date: t.date, kind: t.kind, kindTitle: title, security: security,
                shares: t.sharesEffect(on: id), amount: t.amount, note: t.note, isAttributed: entry.isAttributed))
        }
        self.rows = rows
        ids = Set(rows.map(\.id))
        rangeCount = inRange
        totalCount = transactions.count
        attributedCount = attributed
        self.interval = interval
    }

    /// The depot's own bookings merged, in ledger order, with the dividends that carry no depot but
    /// that the engine's earnings report counts for this depot. The attribution itself is the
    /// engine's — this only asks it which payments belong to the depot's scope.
    static func transactions(_ ledger: Ledger, depot id: UUID) -> [(transaction: Transaction, isAttributed: Bool)] {
        let own = ledger.transactions(forDepot: id)
        guard let first = ledger.firstTransactionDay, let last = ledger.lastTransactionDay else { return own.map { ($0, false) } }
        let everything = DayInterval(start: first.advanced(by: -1), end: last)
        let ownIDs = Set(own.map(\.id))
        let attributed = Set(ledger.earnings(in: everything, scope: .depot(id)).payments.map(\.transactionID)).subtracting(ownIDs)
        guard !attributed.isEmpty else { return own.map { ($0, false) } }
        // `ledger.transactions` is chronological, and so is `own`: one merge pass keeps that order.
        var result = [(transaction: Transaction, isAttributed: Bool)]()
        result.reserveCapacity(own.count + attributed.count)
        for t in ledger.transactions {
            if ownIDs.contains(t.id) {
                result.append((t, false))
            } else if attributed.contains(t.id) {
                result.append((t, true))
            }
        }
        return result
    }

    func tsv(only ids: Set<UUID>) -> String {
        let chosen = ids.isEmpty ? rows : rows.filter { ids.contains($0.id) }
        return TSV.string(
            header: ["Date", "Type", "Security", "Shares", "Amount", "Currency", "Note"],
            rows: chosen.map {
                [$0.date.iso, $0.isAttributed ? "\($0.kindTitle) (attributed)" : $0.kindTitle, $0.security,
                 TSV.number($0.shares.decimalValue), TSV.number($0.amount.decimalValue), $0.amount.currency, $0.note]
            })
    }
}
