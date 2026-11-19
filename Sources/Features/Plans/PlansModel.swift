import Foundation
import KontorUI

// Plain, Sendable values behind the Plans screen. Everything here is built off the main actor
// (`ledgerTask` / `store.compute`) from the engine's plan API: `InvestmentPlan.dueDates`,
// `Ledger.planStatus`, `Ledger.planTransactions` and — for the performance of a purchase plan — the
// engine's daily valuation of the plan's own executions.

/// Where a plan stands today.
enum PlanState: Hashable, Sendable {
    /// The plan cannot be executed as configured.
    case problem(String)
    /// Executions that are due but not booked yet.
    case due(Int)
    case upToDate
    /// Starts in the future.
    case scheduled
    /// The end date has passed (also how a plan is paused).
    case ended

    /// Sort key: what needs attention first.
    var rank: Int {
        switch self {
        case .problem: 0
        case .due: 1
        case .upToDate: 2
        case .scheduled: 3
        case .ended: 4
        }
    }

    var title: String {
        switch self {
        case .problem: "Needs attention"
        case .due(let count): count == 1 ? "1 execution due" : "\(Fmt.integer(count)) executions due"
        case .upToDate: "Up to date"
        case .scheduled: "Not started"
        case .ended: "Ended"
        }
    }

    var symbol: String {
        switch self {
        case .problem: "exclamationmark.triangle.fill"
        case .due: "clock.badge.exclamationmark"
        case .upToDate: "checkmark.circle"
        case .scheduled: "calendar"
        case .ended: "pause.circle"
        }
    }
}

enum PlanText {
    /// "Monthly", "Every 2 months", "Quarterly", …
    static func interval(_ months: Int) -> String {
        switch months {
        case 1: "Monthly"
        case 3: "Quarterly"
        case 12: "Yearly"
        default: "Every \(Fmt.integer(months)) months"
        }
    }

    /// "month", "2 months", "quarter", "year" — for "€500.00 per month".
    static func per(_ months: Int) -> String {
        switch months {
        case 1: "month"
        case 3: "quarter"
        case 12: "year"
        default: "\(Fmt.integer(months)) months"
        }
    }

    static func symbol(_ kind: InvestmentPlan.Kind) -> String {
        switch kind {
        case .purchase: "cart"
        case .deposit: "arrow.down.to.line"
        case .withdrawal: "arrow.up.to.line"
        }
    }

    /// Plain-language reason why a plan (or one execution) cannot be booked.
    static func problem(_ problem: PlanProblem, security: String? = nil) -> String {
        switch problem {
        case .invalidInterval: "The interval is not valid."
        case .invalidAmount: "The amount must be positive and larger than the fees."
        case .missingAccount: "No cash account is selected."
        case .missingDepot: "No depot is selected."
        case .missingSecurity: "No security is selected."
        case .currencyMismatch(let expected): "The amount must be in \(expected), the currency of the account."
        case .noPrice: "No price for \(security ?? "the security") on or before this date."
        case .noExchangeRate(let from, let to): "No exchange rate \(from) → \(to) for this date."
        }
    }

    /// "in 5 days", "tomorrow", "today".
    static func distance(from today: Day, to day: Day) -> String {
        let days = today.distance(to: day)
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let d where d > 0: return "in \(Fmt.duration(days: d))"
        default: return "\(Fmt.duration(days: -days)) ago"
        }
    }
}

/// One row of the plan list.
struct PlanRow: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: InvestmentPlan.Kind
    var kindTitle: String
    /// What the plan buys or which account it books on.
    var target: String
    var securityID: UUID?
    var accountID: UUID?
    var amount: Money
    var amountMinor: Int64 { amount.minor }
    var intervalMonths: Int
    var start: Day
    var end: Day?
    var nextDue: Day?
    /// Sorts plans without a next date last.
    var nextDueKey: Int32 { nextDue?.rawValue ?? .max }
    var executions: Int
    /// Sum of the amounts of all executions, in the plan's currency.
    var total: Int64
    var missing: [Day]
    var skipped: Int
    var state: PlanState
    var stateRank: Int { state.rank * 10_000 - missing.count }
    var problem: String?
}

struct PlansModel: Sendable {
    var rows: [PlanRow] = []
    /// Open executions over all plans that can be generated.
    var dueCount = 0
    /// Names of the plans with open executions ("ETF Plan (2)").
    var dueSummary: [String] = []
    /// What the active plans move per month, in the reporting currency.
    var monthlyPurchases: Int64 = 0
    var monthlyDeposits: Int64 = 0
    var monthlyWithdrawals: Int64 = 0
    var activeCount = 0
    var currency: CurrencyCode = ""

    struct Query: Hashable, Sendable {
        var today: Day
        var sortOrder: [KeyPathComparator<PlanRow>]
    }

    init() {}

    init(_ ledger: Ledger, plans: [InvestmentPlan], query: Query) {
        let today = query.today
        currency = ledger.reportingCurrency
        let tagged = PlanExecutions(ledger)
        for plan in plans {
            let status = ledger.planStatus(plan, through: today)
            let executions = tagged.transactions(of: plan)
            let security = plan.securityID.flatMap { ledger.security($0) }
            let account = plan.accountID.flatMap { ledger.account($0) }
            let target: String = switch plan.kind {
            case .purchase: security?.name ?? ""
            case .deposit, .withdrawal: account?.name ?? ""
            }
            let state = Self.state(plan, status: status, today: today, security: security?.name)
            var row = PlanRow(
                id: plan.id, name: plan.name, kind: plan.kind, kindTitle: plan.kind.title, target: target,
                securityID: plan.securityID, accountID: plan.accountID, amount: plan.amount,
                intervalMonths: plan.intervalMonths, start: plan.start, end: plan.end, nextDue: status.nextDue,
                executions: executions.count, total: executions.reduce(0) { $0 + $1.amount.minor },
                missing: status.problem == nil ? status.missing : [], skipped: status.skipped.count, state: state)
            if case .problem(let text) = state { row.problem = text }
            rows.append(row)

            if !row.missing.isEmpty {
                dueCount += row.missing.count
                dueSummary.append(row.missing.count == 1 ? plan.name : "\(plan.name) (\(Fmt.integer(row.missing.count)))")
            }
            if status.nextDue != nil, status.problem == nil, plan.intervalMonths > 0 {
                activeCount += 1
                let converted = ledger.converter.convert(
                    minor: plan.amount.minor, from: plan.amount.currency, to: currency, on: today) ?? 0
                let perMonth = Int64((Double(converted) / Double(plan.intervalMonths)).rounded())
                switch plan.kind {
                case .purchase: monthlyPurchases += perMonth
                case .deposit: monthlyDeposits += perMonth
                case .withdrawal: monthlyWithdrawals += perMonth
                }
            }
        }
        rows.sort(using: query.sortOrder)
    }

    static func state(_ plan: InvestmentPlan, status: PlanStatus, today: Day, security: String?) -> PlanState {
        if let problem = status.problem { return .problem(PlanText.problem(problem, security: security)) }
        if !status.missing.isEmpty { return .due(status.missing.count) }
        if status.nextDue == nil { return .ended }
        if status.dueDates.isEmpty && status.skipped.isEmpty && plan.start > today { return .scheduled }
        return .upToDate
    }
}

/// The plan executions found in the ledger: transactions whose `source` is a plan's tag.
struct PlanExecutions {
    private var bySource: [String: [Transaction]] = [:]

    init(_ ledger: Ledger) {
        for transaction in ledger.transactions {
            guard let source = transaction.source, source.hasPrefix("plan:") || source.hasPrefix("PLAN:") else { continue }
            bySource[source.lowercased(), default: []].append(transaction)
        }
    }

    /// Chronological (ledger order).
    func transactions(of plan: InvestmentPlan) -> [Transaction] {
        bySource[plan.sourceTag.lowercased()] ?? []
    }
}

// MARK: - Detail of one plan

struct PlanTimelineEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A transaction of this plan (matched to a due date where possible).
        case executed(transactionID: UUID)
        /// Due, but nothing booked.
        case missing
        /// Skipped by the user.
        case skipped
        /// A future date.
        case upcoming
    }

    var id: String
    var kind: Kind
    /// The scheduled day (for executions outside the schedule: the booking day).
    var due: Day
    /// The day the transaction was booked on.
    var booked: Day?
    var shares: Shares?
    var price: Price?
    var priceCurrency: CurrencyCode?
    var amount: Money?
}

/// What a purchase plan has achieved: the engine's valuation of the plan's own executions, as if
/// every share bought through the plan were still held.
struct PlanPerformance: Hashable, Sendable {
    var currency: CurrencyCode
    var invested: Int64
    var value: Int64
    var gain: Int64 { value - invested }
    var gainFraction: Double? { invested > 0 ? Double(gain) / Double(invested) : nil }
    var irr: Double?
    var shares: Shares
    /// Average purchase price incl. fees, in the plan's currency.
    var averagePrice: Price?
    var priceCurrency: CurrencyCode
    var isValued: Bool

    var chartStart: Day
    /// Dense daily series from `chartStart`.
    var investedSeries: [Int64]
    var valueSeries: [Int64]
}

struct PlanDetail: Sendable {
    var planID: UUID
    var kind: InvestmentPlan.Kind
    var state: PlanState
    var problem: String?
    /// The next dates, nearest first.
    var upcoming: [PlanTimelineEntry]
    /// Everything up to today, newest first.
    var history: [PlanTimelineEntry]
    var executions: Int
    var missing: [Day]
    var skipped: [Day]
    var total: Money
    var firstExecution: Day?
    var nextDue: Day?
    var performance: PlanPerformance?
    /// Booked amounts per calendar year, oldest first (plan currency).
    var yearly: [YearTotal]

    /// Whether there is anything to chart yet.
    var hasChart: Bool { performance != nil || !yearly.isEmpty }

    struct YearTotal: Hashable, Sendable {
        var year: Int
        var total: Int64
    }

    struct Key: Hashable, Sendable {
        var planID: UUID
        var today: Day
    }

    static let upcomingCount = 4

    init(_ ledger: Ledger, plan: InvestmentPlan, today: Day, exchangeRates: [ExchangeRateSeries]) {
        planID = plan.id
        kind = plan.kind
        let status = ledger.planStatus(plan, through: today)
        let security = plan.securityID.flatMap { ledger.security($0) }
        state = PlansModel.state(plan, status: status, today: today, security: security?.name)
        if case .problem(let text) = state { problem = text }
        nextDue = status.nextDue
        missing = status.problem == nil ? status.missing : []
        skipped = status.skipped

        let transactions = PlanExecutions(ledger).transactions(of: plan)
        executions = transactions.count
        total = Money(minor: transactions.reduce(0) { $0 + $1.amount.minor }, currency: plan.amount.currency)
        firstExecution = transactions.first?.date

        let dueByTransaction = Dictionary(status.executions.map { ($0.transactionID, $0.due) }, uniquingKeysWith: { a, _ in a })
        var entries: [PlanTimelineEntry] = transactions.map { t in
            PlanTimelineEntry(
                id: "t-\(t.id.uuidString)", kind: .executed(transactionID: t.id), due: dueByTransaction[t.id] ?? t.date,
                booked: t.date, shares: t.shares.isZero ? nil : t.shares, price: t.grossPrice,
                priceCurrency: t.amount.currency, amount: t.amount)
        }
        entries += missing.map { PlanTimelineEntry(id: "m-\($0.iso)", kind: .missing, due: $0, amount: plan.amount) }
        entries += skipped.map { PlanTimelineEntry(id: "s-\($0.iso)", kind: .skipped, due: $0) }
        history = entries.sorted { ($0.due, $0.id) > ($1.due, $1.id) }

        // The next dates: the schedule up to a horizon that surely contains them, skipped ones included.
        upcoming = []
        if plan.intervalMonths > 0 {
            let horizon = today.addingMonths(max(plan.intervalMonths, 1) * (Self.upcomingCount + 2))
            let skippedSet = Set(plan.skippedDueDates(through: horizon))
            upcoming = plan.dueDates(through: horizon, includingSkipped: true)
                .filter { $0 > today }
                .prefix(Self.upcomingCount)
                .map {
                    skippedSet.contains($0)
                        ? PlanTimelineEntry(id: "s-\($0.iso)", kind: .skipped, due: $0)
                        : PlanTimelineEntry(id: "u-\($0.iso)", kind: .upcoming, due: $0, amount: plan.amount)
                }
        }
        yearly = []
        for transaction in transactions {
            if yearly.last?.year == transaction.date.year {
                yearly[yearly.count - 1].total += transaction.amount.minor
            } else {
                yearly.append(YearTotal(year: transaction.date.year, total: transaction.amount.minor))
            }
        }

        performance = Self.performance(
            ledger, plan: plan, security: security, transactions: transactions, today: today, exchangeRates: exchangeRates)
    }

    /// Values the plan's executions on their own with the engine: a ledger that contains nothing
    /// but these purchases, looked at through the security's scope. Buys are the inflows
    /// ("invested"), the final value is "what those shares are worth today", the IRR follows from
    /// both. Splits, currencies and price lookups are the engine's business this way.
    static func performance(
        _ ledger: Ledger, plan: InvestmentPlan, security: Security?, transactions: [Transaction], today: Day,
        exchangeRates: [ExchangeRateSeries]
    ) -> PlanPerformance? {
        guard plan.kind == .purchase, let security else { return nil }
        let purchases = transactions.filter { $0.securityID == security.id && $0.kind.sharesSign > 0 && $0.date <= today }
        guard let first = purchases.first else { return nil }
        let file = PortfolioFile(
            settings: ledger.settings, securities: [security], accounts: ledger.accounts, depots: ledger.depots,
            transactions: purchases, exchangeRates: exchangeRates)
        let own = Ledger(file, reportingCurrency: ledger.reportingCurrency)
        let interval = DayInterval(start: first.date.advanced(by: -1), end: max(today, first.date))
        let scope = Scope.security(security.id)
        let valuation = own.valuation(in: interval, scope: scope)
        let snapshot = own.snapshot(on: interval.end, scope: scope)
        let shares = purchases.reduce(Shares.zero) { $0 + $1.shares }
        let paid = purchases.reduce(0) { $0 + $1.amount.minor }
        return PlanPerformance(
            currency: valuation.currency, invested: valuation.totalInflows - valuation.totalOutflows,
            value: valuation.finalValue, irr: valuation.irr(),
            shares: snapshot.position(security.id)?.shares ?? shares,
            averagePrice: Price(minor: paid, per: snapshot.position(security.id)?.shares ?? shares),
            priceCurrency: plan.amount.currency,
            isValued: snapshot.position(security.id)?.isValued ?? false,
            chartStart: interval.start, investedSeries: valuation.investedCapital(), valueSeries: valuation.values)
    }
}
