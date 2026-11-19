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
        for position in snapshot.positions {
            for holding in position.holdings where !holding.shares.isZero {
                valueByDepot[holding.depotID, default: 0] += holding.value.minor
                positionsByDepot[holding.depotID, default: 0] += 1
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
                lastActivity: transactions.last?.date, transactionCount: transactions.count))
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
                sparkline: weekly, lastActivity: transactions.last?.date, transactionCount: transactions.count))
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
        chart = StackedAreaData(days: sample.map { interval.start.advanced(by: $0) }, series: StackedAreaData.folded(series), currency: currency)
    }

    /// Tab-separated balances for the clipboard.
    var tsv: String {
        var rows = accounts.map { ["Account", $0.name, $0.balance.currency, TSV.number($0.balance.decimalValue), TSV.number($0.value.decimalValue)] }
        rows += depots.map { ["Depot", $0.name, currency, TSV.number($0.value.decimalValue), TSV.number($0.value.decimalValue)] }
        return TSV.string(header: ["Type", "Name", "Currency", "Balance", "Value (\(currency))"], rows: rows)
    }
}

// MARK: - Account detail

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
    /// Booked on this account in the period, in the reporting currency (engine earnings report).
    var interest: Int64
    var dividends: Int64
    var fees: Int64
    var taxes: Int64
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

        let booked = ledger.earnings(in: interval).byAccount.first { $0.accountID == id }?.amounts ?? EarningsAmounts()
        interest = booked.interest - booked.interestCharges
        dividends = booked.dividends
        fees = booked.fees
        taxes = booked.taxes
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

    static func rows(_ ledger: Ledger, account id: UUID, filter: QuickFilter) -> [StatementRow] {
        let transactions = ledger.transactions(forAccount: id)
        var rows = [StatementRow]()
        rows.reserveCapacity(transactions.count)
        var balance: Int64 = 0
        for (order, t) in transactions.enumerated() {
            let effect = t.cashEffect(on: id)
            balance += effect
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
        return rows
    }
}

// MARK: - Depot detail

struct DepotDetailModel: Sendable {
    struct Position: Identifiable, Sendable {
        let id: UUID
        var name: String
        var symbol: String
        var shares: Shares
        var price: Price?
        var priceCurrency: CurrencyCode
        var value: Int64
        /// Share of the depot's market value, 0…1.
        var weight: Double
        var costBasis: Int64
        var gain: Int64
        var gainFraction: Double?
        var isValued: Bool
    }

    var id: UUID
    var currency: CurrencyCode
    var interval: DayInterval
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

    init?(_ analysis: Analysis, depot id: UUID, today: Day) {
        let ledger = analysis.ledger
        guard ledger.depot(id) != nil else { return nil }
        let currency = ledger.reportingCurrency
        self.id = id
        self.currency = currency
        interval = analysis.interval

        let snapshot = ledger.snapshot(on: today, scope: .depot(id))
        let total = snapshot.securitiesValue.minor
        positions = snapshot.positions.map { p in
            let security = ledger.security(p.securityID)
            return Position(
                id: p.securityID, name: security?.name ?? "Unknown security",
                symbol: security.map { $0.ticker.isEmpty ? $0.isin : $0.ticker } ?? "",
                shares: p.shares, price: p.price, priceCurrency: security?.currency ?? currency,
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

    static func rows(_ ledger: Ledger, depot id: UUID, filter: QuickFilter) -> [DepotTransactionRow] {
        let transactions = ledger.transactions(forDepot: id)
        var rows = [DepotTransactionRow]()
        rows.reserveCapacity(transactions.count)
        for (order, t) in transactions.enumerated() {
            let security = t.securityID.flatMap { ledger.security($0)?.name } ?? ""
            var title = t.kind.title
            if t.kind == .securityTransfer {
                let other = t.depotID == id ? t.counterDepotID : t.depotID
                let name = other.flatMap { ledger.depot($0)?.name } ?? "another depot"
                title = t.depotID == id ? "Transfer to \(name)" : "Transfer from \(name)"
            }
            guard filter.isEmpty || filter.matches(title, security, t.note, t.date.iso) else { continue }
            rows.append(DepotTransactionRow(
                id: t.id, order: order, date: t.date, kind: t.kind, kindTitle: title, security: security,
                shares: t.sharesEffect(on: id), amount: t.amount, note: t.note))
        }
        return rows
    }
}
