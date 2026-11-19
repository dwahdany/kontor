import Foundation
import KontorUI

// Pure rules of the Performance screen that are not engine results: how a figure is presented
// (annualized or not), which calendar units are complete, which depot a booking belongs to, and
// what the screen says about incomplete data. Everything here is `Sendable` and unit-tested.

// MARK: - Annualizing

/// The screen's one rule about "per year": a figure is annualized only when the interval is longer
/// than a year. Annualizing less than that extrapolates — a good month is not a 69 % year.
enum ReturnHorizon {
    static func isAnnualized(days: Int) -> Bool { days > 366 }

    /// The engine's IRR (always per year) as the screen shows it: per year for long intervals,
    /// otherwise the money-weighted return of the interval itself, `(1 + irr)^(days / 365) − 1` —
    /// the exact inverse of the engine's `Returns.annualize`.
    static func moneyWeighted(irr: Double?, days: Int) -> Double? {
        guard let irr, irr.isFinite else { return nil }
        guard !isAnnualized(days: days) else { return irr }
        guard days > 0 else { return nil }
        guard irr > -1 else { return -1 }
        return pow(1 + irr, Double(days) / 365) - 1
    }

    /// Caption of a money-weighted figure for an interval of `days`.
    static func moneyWeightedCaption(days: Int) -> String {
        isAnnualized(days: days) ? "per year, money-weighted" : "not annualized"
    }

    /// Figures that divide an annualized return (the Sharpe ratio) need at least a full year;
    /// exactly one year is fine — its annualized return is its return.
    static func hasFullYear(days: Int) -> Bool { days >= 365 }

    /// Volatility (and anything else estimated from daily returns) needs some history: a month.
    static func hasEnoughHistory(days: Int) -> Bool { days >= 30 }
}

// MARK: - Axis labels

enum PercentAxis {
    /// The fewest decimals (0…2) that show every tick exactly: 0 for 5 %, 10 %; 1 for 2.5 %, 7.5 %.
    /// (Labels rounded to whole percents would print "13 %" beside the 12.5 % line.)
    static func decimals(for ticks: [Double]) -> Int {
        for decimals in 0..<2 {
            let scale = 100 * pow(10, Double(decimals))
            if ticks.allSatisfy({ abs($0 * scale - ($0 * scale).rounded()) < 1e-6 }) { return decimals }
        }
        return 2
    }

    static func labels(for ticks: [Double]) -> [String] {
        let decimals = decimals(for: ticks)
        return ticks.map { Fmt.percent($0, decimals: decimals) }
    }
}

// MARK: - Calendar coverage

/// Which calendar months and years lie completely inside a period. A unit cut off by a period edge
/// is still a full unit when nothing existed before the period's first day (the portfolio's first
/// month and year), but never when the period ends inside it.
struct CalendarCoverage: Sendable, Hashable {
    /// First and last day whose returns the period contains.
    var first: Day
    var last: Day
    /// True when the file has no transaction before `first`: there is nothing the period leaves out.
    var startsAtInception: Bool

    init(interval: DayInterval, firstTransactionDay: Day?) {
        first = interval.firstDay
        last = interval.end
        startsAtInception = firstTransactionDay.map { $0 >= interval.firstDay } ?? true
    }

    private func covers(from unitStart: Day, to unitEnd: Day) -> Bool {
        (first <= unitStart || startsAtInception) && last >= unitEnd
    }

    func isComplete(year: Int, month: Int) -> Bool {
        let start = Day(year: year, month: month, day: 1)
        return covers(from: start, to: start.endOfMonth)
    }

    func isComplete(year: Int) -> Bool {
        covers(from: Day(year: year, month: 1, day: 1), to: Day(year: year, month: 12, day: 31))
    }

    /// The months of `year` the period touches, e.g. 7…12 for a period that starts on 1 July.
    func months(of year: Int) -> ClosedRange<Int> {
        let from = first.year == year && !startsAtInception ? first.month : 1
        let to = last.year == year ? last.month : 12
        return min(from, to)...to
    }

    /// "Jul–Dec" for a partial year; "Jul" when it is a single month.
    func monthsLabel(of year: Int) -> String {
        let range = months(of: year)
        let names = ChartLabels.shortMonths
        guard names.indices.contains(range.lowerBound - 1), names.indices.contains(range.upperBound - 1) else { return "" }
        return range.count == 1 ? names[range.lowerBound - 1] : "\(names[range.lowerBound - 1])–\(names[range.upperBound - 1])"
    }
}

// MARK: - Depot attribution

/// Where the position leg of every booking lies — the engine's convention for bookings that name a
/// security but no depot (Portfolio Performance books dividends, fees and taxes on the account
/// only): they belong to the depot holding the security at that time, after a complete sale to the
/// depot it was last moved in. Only while several depots hold it at once (or none ever did) a
/// booking stays unattributed and counts for every depot that was ever paired with the security.
///
/// This replays the ledger's chronological order exactly like the engine's indexing does; bookings
/// the engine skips as invalid are reported in `skipped`.
struct PositionAttribution: Sendable {
    enum Position: Sendable, Equatable {
        /// In this depot.
        case depot(UUID)
        /// Not attributable: counts for every depot that was ever paired with the security.
        case anyDepot(of: UUID)
        /// The booking has no position leg.
        case none
    }

    private var attributed: [UUID: UUID] = [:]
    private var unattributed = Set<UUID>()
    private var depotsBySecurity: [UUID: Set<UUID>] = [:]
    /// Transactions the engine ignores (missing or unknown security, account or depot).
    private(set) var skipped = Set<UUID>()
    /// Bookings that name a security the file does not contain; the engine books them on the account.
    private var unknownSecurity = Set<UUID>()

    init(_ ledger: Ledger) {
        struct Holding: Hashable { var security: UUID; var depot: UUID }
        var shares: [Holding: Int64] = [:]
        var lastMoved: [UUID: UUID] = [:]

        for t in ledger.transactions {
            let kind = t.kind
            let security = t.securityID.flatMap { ledger.security($0) != nil ? $0 : nil }
            if security == nil, kind.requiresSecurity { skipped.insert(t.id); continue }
            if kind.requiresAccount {
                guard let account = t.accountID, ledger.account(account) != nil else { skipped.insert(t.id); continue }
                if kind == .cashTransfer {
                    guard let counter = t.counterAccountID, ledger.account(counter) != nil else { skipped.insert(t.id); continue }
                }
            }
            var depot = t.depotID.flatMap { ledger.depot($0) != nil ? $0 : nil }
            var counterDepot: UUID?
            if kind.requiresDepot {
                guard depot != nil else { skipped.insert(t.id); continue }
                if kind == .securityTransfer {
                    guard let counter = t.counterDepotID, ledger.depot(counter) != nil else { skipped.insert(t.id); continue }
                    counterDepot = counter
                }
            }
            guard let security else {
                if t.securityID != nil { unknownSecurity.insert(t.id) }
                continue
            }
            if let depot { depotsBySecurity[security, default: []].insert(depot) }
            if let counterDepot { depotsBySecurity[security, default: []].insert(counterDepot) }

            if depot == nil {
                let holders = (depotsBySecurity[security] ?? []).filter { shares[Holding(security: security, depot: $0)] ?? 0 != 0 }
                if holders.count == 1 {
                    depot = holders.first
                } else if holders.isEmpty {
                    depot = lastMoved[security]
                }
                if let depot { attributed[t.id] = depot } else { unattributed.insert(t.id) }
            }
            let delta = kind.sharesSign * t.shares.raw
            if delta != 0, let depot {
                shares[Holding(security: security, depot: depot), default: 0] &+= delta
                lastMoved[security] = depot
            }
            if let counterDepot {
                shares[Holding(security: security, depot: counterDepot), default: 0] &+= t.shares.raw
                lastMoved[security] = counterDepot
            }
        }
    }

    /// Whether `t` relates to a security of the file (a fee or tax then follows the position).
    func hasSecurity(_ t: KontorModel.Transaction) -> Bool {
        t.securityID != nil && !unknownSecurity.contains(t.id)
    }

    func position(of t: KontorModel.Transaction) -> Position {
        guard let security = t.securityID, hasSecurity(t) else { return .none }
        if let depot = attributed[t.id] { return .depot(depot) }
        if unattributed.contains(t.id) { return .anyDepot(of: security) }
        return t.depotID.map { .depot($0) } ?? .none
    }

    /// Whether the position leg of `t` lies in one of `depots`.
    func isPosition(of t: KontorModel.Transaction, in depots: Set<UUID>) -> Bool {
        switch position(of: t) {
        case .depot(let depot): depots.contains(depot)
        case .anyDepot(let security): !(depotsBySecurity[security] ?? []).isDisjoint(with: depots)
        case .none: false
        }
    }
}

// MARK: - Range selection in the main chart

/// The one place that knows which sub-range of the main chart is selected: dragged by the user, or
/// pinned from outside (launch state, "Show in Chart" of a drawdown). The newer of the two wins.
struct ChartRangeState: Equatable, Sendable {
    private(set) var dragged: DayInterval?
    private(set) var pinned: DayInterval?
    /// Identity of the chart view. The chart keeps its own drag selection; a new identity drops it.
    private(set) var generation = 0

    var active: DayInterval? { dragged ?? pinned }

    /// The chart reported a drag (nil: the user cleared it in the chart).
    mutating func drag(_ interval: DayInterval?) {
        dragged = interval
        if interval != nil { pinned = nil }
    }

    /// Shows `interval` instead of whatever is selected.
    mutating func pin(_ interval: DayInterval) {
        if dragged != nil {
            dragged = nil
            generation += 1
        }
        pinned = interval
    }

    mutating func clear() {
        guard active != nil else { return }
        dragged = nil
        pinned = nil
        generation += 1
    }
}

// MARK: - Incomplete data

/// Something the engine had to leave out or estimate — shown above the figures it changes.
struct DataWarning: Sendable, Identifiable, Hashable {
    enum Kind: String, Sendable { case missingExchangeRate, missingPrice, derivedPrices, ignoredTransactions, shortPositions }

    var kind: Kind
    var message: String
    var id: String { kind.rawValue + message }

    /// The warnings that concern `analysis`. Call after the figures were computed: the engine
    /// collects diagnostics as it calculates.
    static func warnings(for analysis: Analysis) -> [DataWarning] {
        let ledger = analysis.ledger
        let diagnostics = analysis.diagnostics
        guard !diagnostics.isEmpty else { return [] }
        let currency = analysis.currency
        let inScope = Set(analysis.securities.map(\.securityID))
        let unvaluedCash = (analysis.initialSnapshot.cash + analysis.snapshot.cash).filter { !$0.isValued }
        let isWhole = analysis.scope == .portfolio

        var out: [DataWarning] = []
        var derived: [String] = [], unpriced: [String] = []
        var ignored = 0, short = Set<UUID>()
        for diagnostic in diagnostics {
            switch diagnostic {
            case .missingExchangeRate(let from, let to):
                guard to == currency else { continue }
                let securities = inScope.contains { ledger.security($0)?.currency == from }
                let accounts = unvaluedCash.contains { ledger.account($0.accountID)?.currency == from }
                guard isWhole || securities || accounts else { continue }
                // What is left out today, when it can be named exactly.
                let balance = analysis.snapshot.cash.filter { !$0.isValued && $0.balance.currency == from }
                    .reduce(Int64(0)) { $0 + $1.balance.minor }
                let amount = balance != 0 ? "\(Fmt.money(minor: balance, currency: from)) in cash and all other " : "All "
                out.append(DataWarning(kind: .missingExchangeRate,
                                       message: "No exchange rate from \(from) to \(to). \(amount)\(from) amounts are left out of every figure."))
            case .missingPrice(let id):
                if isWhole || inScope.contains(id) { unpriced.append(ledger.security(id)?.name ?? "A security") }
            case .pricesDerivedFromTransactions(let id):
                if inScope.contains(id) { derived.append(ledger.security(id)?.name ?? "A security") }
            case .invalidTransaction:
                ignored += 1
            case .shortPosition(let id, _, let day):
                if day <= analysis.interval.end, isWhole || inScope.contains(id) { short.insert(id) }
            }
        }
        if !unpriced.isEmpty {
            out.append(DataWarning(kind: .missingPrice, message: "\(list(unpriced)) \(unpriced.count == 1 ? "has" : "have") no price and \(unpriced.count == 1 ? "is" : "are") valued at zero."))
        }
        if !derived.isEmpty {
            out.append(DataWarning(kind: .derivedPrices, message: "\(list(derived)) \(derived.count == 1 ? "has" : "have") no quotes and \(derived.count == 1 ? "is" : "are") valued at the price of \(derived.count == 1 ? "its" : "their") own transactions — gains and returns only change when you trade."))
        }
        if ignored > 0 {
            out.append(DataWarning(kind: .ignoredTransactions, message: "\(Fmt.integer(ignored)) \(ignored == 1 ? "transaction is" : "transactions are") incomplete (missing account, depot or security) and ignored."))
        }
        if !short.isEmpty {
            let names = short.compactMap { ledger.security($0)?.name }.sorted()
            out.append(DataWarning(kind: .shortPositions, message: "More shares of \(list(names)) were sold than held; the figures treat this as a short position."))
        }
        return out
    }

    /// "A", "A and B", "A, B and 3 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]), \(names[1]) and \(Fmt.integer(names.count - 2)) more"
        }
    }
}

// MARK: - Nothing to measure

/// What the "Nothing to Measure" card says and offers — never a button that changes nothing.
struct NothingToMeasureAdvice: Equatable, Sendable {
    var message: String
    var offersAllTime: Bool
    var offersWholePortfolio: Bool
    var offersTransactions: Bool

    init(scopeTitle: String, isWholePortfolio: Bool, interval: DayInterval, allTime: DayInterval, firstTransactionDay: Day?, today: Day) {
        let isAllTime = interval == allTime
        let allInFuture = firstTransactionDay.map { $0 > today } ?? false
        offersWholePortfolio = !isWholePortfolio
        if allInFuture, let first = firstTransactionDay {
            message = "Every transaction is dated after today — the first one on \(Fmt.day(first, style: .medium)). Performance is measured up to today, so there is nothing to show yet."
            offersAllTime = false
            offersTransactions = true
            offersWholePortfolio = false
        } else if isAllTime {
            message = isWholePortfolio
                ? "The portfolio has held nothing so far."
                : "\(scopeTitle) has never held anything. Choose another scope."
            offersAllTime = false
            offersTransactions = isWholePortfolio
        } else {
            message = "\(scopeTitle) held nothing in this period (\(Fmt.interval(interval))). Choose a longer period\(isWholePortfolio ? "" : " or another scope")."
            offersAllTime = true
            offersTransactions = false
        }
    }
}

// MARK: - Selection in the line drill-down

enum LineSelection {
    /// The selected ids that still have a row.
    static func valid(_ selection: Set<UUID>, rows: [UUID]) -> Set<UUID> {
        selection.isEmpty ? selection : selection.intersection(rows)
    }

    /// The one selected row, if exactly one existing row is selected — the only case in which
    /// "Show in Transactions" has an unambiguous target.
    static func single(_ selection: Set<UUID>, rows: [UUID]) -> UUID? {
        let valid = valid(selection, rows: rows)
        return valid.count == 1 ? valid.first : nil
    }
}

// MARK: - Wording

enum Plural {
    /// "1 month", "3 months".
    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(Fmt.integer(n)) \(n == 1 ? singular : plural)"
    }
}
