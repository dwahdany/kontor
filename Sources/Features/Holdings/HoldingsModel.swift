import Foundation
import SwiftUI
import KontorUI

// MARK: - Grouping

/// How the statement of assets is grouped.
enum HoldingsGrouping: Hashable, Sendable {
    case none
    /// One group per depot (its positions plus its reference account), remaining accounts last.
    case depot
    /// One group per currency of the security / account.
    case currency
    /// One group per classification of a taxonomy; split assignments appear in several groups.
    case taxonomy(UUID)

    /// Stable text form (scene storage, `--state group=…`).
    var key: String {
        switch self {
        case .none: "none"
        case .depot: "depot"
        case .currency: "currency"
        case .taxonomy(let id): "taxonomy:\(id.uuidString)"
        }
    }

    /// Parses `none`, `depot`, `currency`, `taxonomy` (the first taxonomy), `taxonomy:<uuid>` or
    /// `taxonomy:<name>` / a bare taxonomy name (case-insensitive).
    init?(key: String, taxonomies: [Taxonomy]) {
        let text = key.trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "none", "flat": self = .none
        case "depot", "depots", "account", "accounts": self = .depot
        case "currency", "currencies": self = .currency
        case "taxonomy":
            guard let first = taxonomies.first else { return nil }
            self = .taxonomy(first.id)
        default:
            let name = text.lowercased().hasPrefix("taxonomy:") ? String(text.dropFirst("taxonomy:".count)) : text
            if let id = UUID(uuidString: name), taxonomies.contains(where: { $0.id == id }) {
                self = .taxonomy(id)
            } else if let match = taxonomies.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                self = .taxonomy(match.id)
            } else {
                return nil
            }
        }
    }
}

// MARK: - Rows

/// One line of the holdings table: a position, a cash balance, a position closed during the period,
/// a group subtotal or the grand total. Plain values, built off the main actor.
struct HoldingRow: Identifiable, Sendable {
    enum Kind: Int, Sendable { case position, cash, closed, group, total }

    var id: String
    var kind: Kind
    var securityID: UUID?
    var accountID: UUID?
    /// The depot of a per-depot row (depot grouping); otherwise the depot holding most of the position.
    var depotID: UUID?
    var name: String
    /// Secondary line: ticker · ISIN, "Cash · EUR", "3 positions".
    var detail: String
    /// Everything the quick filter searches.
    var searchText: String
    /// Currency of the security or account.
    var currency: CurrencyCode
    /// Part of the position shown in this row in basis points (taxonomy grouping), nil = all of it.
    var assignedWeight: Int?
    var shares: Shares?
    var price: Price?
    var priceDay: Day?
    var isStale = false
    var isValued = true
    /// Why the line has no value (`isValued == false`).
    var valuationIssue: ValuationIssue?
    /// Change of the market value in the reporting currency since `dayChangeSince`, with unchanged
    /// shares: price move and exchange-rate move together (fraction of the earlier value).
    var dayChange: Double?
    /// The same as an amount in the reporting currency. Lines without a move of their own (cash in
    /// the reporting currency) carry 0 and no `dayChange`.
    var dayChangeAmount: Int64?
    /// The day the change is measured from: the previous quote's day (securities) or the day
    /// before the statement day (foreign cash).
    var dayChangeSince: Day?
    /// Securities: the quote's own change in the security's currency (fraction).
    var quoteChange: Double?
    /// Market value in `currency` (minor units).
    var localValue: Int64?
    /// Market value in the reporting currency (minor units).
    var value: Int64 = 0
    /// Share of the scope's total value (0…1).
    var weight: Double?
    var costBasis: Int64?
    /// Average purchase price per share, reporting currency.
    var purchasePrice: Price?
    var gain: Int64?
    var gainFraction: Double?
    var ttwror: Double?
    var irr: Double?
    /// Dividends of the reporting period (gross).
    var dividends: Int64?
    /// Dividends of the twelve months ending on the statement day (gross) — the numerator of
    /// `yieldOnCost`; independent of the reporting period.
    var trailingDividends: Int64?
    /// `trailingDividends` ÷ cost basis: an annual yield, whatever period the window shows.
    var yieldOnCost: Double?
    /// Gains realized in the period (after fees, before taxes).
    var realized: Int64?
    /// Daily price levels of the last 90 days in the security's currency.
    var spark: [Double] = []
    /// Group rows: stored classification color and palette fallback.
    var colorHex: String?
    var colorIndex: Int?
    /// Group / total rows: number of lines below.
    var count = 0
    /// The id of the subtotal line this row sits under (grouped tables).
    var groupID: String?

    enum ValuationIssue: Sendable, Equatable {
        case noPrice
        /// No exchange rate from the line's currency into the reporting currency.
        case noExchangeRate
    }

    var isEntity: Bool { kind == .position || kind == .cash || kind == .closed }
    var isSummary: Bool { kind == .group || kind == .total }

    // Sort keys (missing values sort first ascending, last descending).
    var sharesSort: Double { shares?.doubleValue ?? -.infinity }
    var priceSort: Double { price?.doubleValue ?? -.infinity }
    var dayChangeSort: Double { dayChange ?? -.infinity }
    var localValueSort: Double { localValue.map(Double.init) ?? -.infinity }
    var weightSort: Double { weight ?? -.infinity }
    var costSort: Double { costBasis.map(Double.init) ?? -.infinity }
    var purchasePriceSort: Double { purchasePrice?.doubleValue ?? -.infinity }
    var gainSort: Double { gain.map(Double.init) ?? -.infinity }
    var gainFractionSort: Double { gainFraction ?? -.infinity }
    var ttwrorSort: Double { ttwror ?? -.infinity }
    var irrSort: Double { irr ?? -.infinity }
    var dividendsSort: Double { dividends.map(Double.init) ?? -.infinity }
    var yieldSort: Double { yieldOnCost ?? -.infinity }
    var realizedSort: Double { realized.map(Double.init) ?? -.infinity }
    /// Change over the sparkline's 90 days.
    var trendSort: Double {
        guard let first = spark.first, let last = spark.last, first > 0 else { return -.infinity }
        return last / first - 1
    }
}

// MARK: - Stage 1: everything derived from the engine

/// What the base model depends on besides the document, the scope and the interval.
struct HoldingsQuery: Hashable, Sendable {
    var grouping: HoldingsGrouping
    /// The taxonomy value for `.taxonomy` grouping (so edits of assignments invalidate the model).
    var taxonomy: Taxonomy?
    /// The statement day; nil = the end of the analysis interval. It lies after the interval when
    /// a fixed period ended before it (see `HoldingsStatementPeriod`).
    var day: Day?
    /// False when the period has no figures for this statement day: the interval is then only a
    /// carrier for the statement and nothing period-related is derived from it.
    var hasPeriodFigures = true
}

// MARK: - Arithmetic

/// Pure helpers of the statement, kept apart from the engine plumbing so they can be tested alone.
enum HoldingsMath {
    /// Splits `total` in proportion to `weights` so that the parts add up to `total` exactly
    /// (largest remainder; ties go to the earlier part). Negative weights count as zero; without
    /// any positive weight the first part takes everything.
    static func apportion(_ total: Int64, _ weights: [Int64]) -> [Int64] {
        guard !weights.isEmpty else { return [] }
        let clean = weights.map { UInt64(max($0, 0)) }
        let sum = clean.reduce(0, +)
        var parts = [Int64](repeating: 0, count: weights.count)
        guard sum > 0 else {
            parts[0] = total
            return parts
        }
        let magnitude = total.magnitude
        var floors = [UInt64](repeating: 0, count: clean.count)
        var remainders = [UInt64](repeating: 0, count: clean.count)
        var assigned: UInt64 = 0
        for (index, weight) in clean.enumerated() {
            let (quotient, remainder) = sum.dividingFullWidth(magnitude.multipliedFullWidth(by: weight))
            floors[index] = quotient
            remainders[index] = remainder
            assigned += quotient
        }
        var left = Int(magnitude - assigned)
        if left > 0 {
            let order = clean.indices.sorted { remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : $0 < $1 }
            for index in order where left > 0 {
                floors[index] += 1
                left -= 1
            }
        }
        for index in parts.indices {
            parts[index] = total < 0 ? -Int64(floors[index]) : Int64(floors[index])
        }
        return parts
    }

    /// The change of a market value since an earlier valuation with unchanged shares, in the
    /// reporting currency: `value` is today's value, the earlier one is derived from the ratio of
    /// price × exchange rate then and now. Nil when the inputs do not allow a ratio.
    static func change(value: Int64, price: Double = 1, rate: Double, previousPrice: Double = 1, previousRate: Double) -> (amount: Int64, fraction: Double?)? {
        let now = price * rate, before = previousPrice * previousRate
        guard now.isFinite, before.isFinite, now > 0, before >= 0 else { return nil }
        let earlier = FixedMath.saturatingInt64(Double(value) * before / now)
        let amount = value - earlier
        return (amount, earlier > 0 ? Double(amount) / Double(earlier) : nil)
    }

    /// Dividends of twelve months relative to the cost basis of what is held; nil without a cost.
    static func yieldOnCost(trailingDividends: Int64?, costBasis: Int64?) -> Double? {
        guard let trailingDividends, let costBasis, costBasis > 0 else { return nil }
        return Double(trailingDividends) / Double(costBasis)
    }
}

/// The statement of assets at `day` with the period figures of `interval`, grouped but neither
/// filtered nor sorted. Built by `HoldingsBase.init(_:query:)` inside the store's analysis layer.
struct HoldingsBase: Sendable {
    struct Group: Sendable, Identifiable {
        var id: String
        var title: String
        /// Path of the parent classifications ("Equity"), empty at the top level.
        var parent = ""
        var colorHex: String?
        var colorIndex: Int?
        var rows: [HoldingRow]
        /// Return of the group as a scope of its own over the period (whole-portfolio scope only).
        var ttwror: Double?
        var irr: Double?
        /// The engine scope that contains exactly this group's rows, if one exists.
        var scope: Scope?
    }

    /// Changes whenever the model was rebuilt.
    let stamp = UUID()
    var day: Day
    /// The stretch the period figures cover. It ends on `day`, or earlier when a fixed period
    /// ended before the statement day.
    var interval: DayInterval
    /// False when the period has no figures for this statement day (`ttwror` etc. are then nil).
    var hasPeriodFigures: Bool
    var currency: CurrencyCode
    var grouping: HoldingsGrouping
    /// One group with an empty id when ungrouped.
    var groups: [Group]
    /// Positions that were closed within the period.
    var closed: [HoldingRow]
    var totalValue: Int64
    var securitiesValue: Int64
    var cashValue: Int64
    var costBasis: Int64
    var ttwror: Double?
    var irr: Double?
    var absolutePerformance: Int64?
    var positionCount: Int
    var cashCount: Int
    var staleCount: Int
    /// Names of positions that could not be valued (no price or no exchange rate).
    var unvalued: [String]
    var hasTransactions: Bool

    static let closedGroupID = "g:closed"
    /// Days without a new quote after which a price counts as stale.
    static let staleAfterDays = 7
    /// The yield on cost always refers to the twelve months ending on the statement day.
    static func trailingYear(endingOn day: Day) -> DayInterval { DayInterval(start: day.addingYears(-1), end: day) }

    var isEmpty: Bool { groups.allSatisfy(\.rows.isEmpty) }

    init(_ analysis: Analysis, query: HoldingsQuery) {
        let ledger = analysis.ledger
        let hasPeriod = query.hasPeriodFigures
        // The statement is the snapshot of the statement day — not necessarily the end of the
        // period (a fixed period may have ended before it).
        let day = query.day ?? analysis.interval.end
        let snapshot = day == analysis.interval.end ? analysis.snapshot : ledger.snapshot(on: day, scope: analysis.scope)
        let total = snapshot.totalValue.minor
        let reporting = analysis.currency
        let records = hasPeriod ? analysis.securities : []
        let performance = Dictionary(records.map { ($0.securityID, $0) }, uniquingKeysWith: { a, _ in a })
        let sparkInterval = DayInterval(start: day.advanced(by: -90), end: day)
        let trailingYear = Self.trailingYear(endingOn: day)
        let trailing = Dictionary(
            ledger.earnings(in: trailingYear, scope: analysis.scope).bySecurity.map { ($0.securityID, $0.amounts.dividends) },
            uniquingKeysWith: { a, _ in a })
        let converter = ledger.converter
        func rate(_ currency: CurrencyCode, on day: Day) -> Double? {
            currency == reporting ? 1 : converter.rate(from: currency, to: reporting, on: day)
        }

        func share(_ value: Int64) -> Double? { total > 0 ? Double(value) / Double(total) : nil }

        // One row per security held in the scope, all depots combined.
        func positionRow(_ p: Snapshot.Position) -> HoldingRow? {
            guard let security = ledger.security(p.securityID) else { return nil }
            var row = HoldingRow(
                id: "s:\(security.id.uuidString)", kind: .position, securityID: security.id, name: security.name,
                detail: Self.detail(of: security), searchText: Self.searchText(of: security), currency: security.currency)
            row.depotID = p.holdings.max { $0.value.minor < $1.value.minor }?.depotID
            // A weighted scope (a classification) holds only part of the position: its value and
            // cost are scaled by the engine, so the shares shown must be scaled as well.
            if p.weight != 10_000 {
                row.assignedWeight = p.weight
                row.shares = Shares(raw: FixedMath.weighted(p.shares.raw, Int32(clamping: p.weight)))
            } else {
                row.shares = p.shares
            }
            row.price = p.price
            row.priceDay = p.priceDay
            row.isValued = p.isValued
            if !p.isValued { row.valuationIssue = p.price == nil ? .noPrice : .noExchangeRate }
            row.isStale = p.priceDay.map { $0.distance(to: day) > Self.staleAfterDays } ?? true
            row.localValue = p.valueInSecurityCurrency.minor
            row.value = p.value.minor
            row.weight = share(p.value.minor)
            row.costBasis = p.costBasis.minor
            row.purchasePrice = p.purchasePrice
            row.gain = p.unrealizedGain.minor
            row.gainFraction = p.unrealizedGainFraction
            // "Day": the value now against the value at the previous quote, shares unchanged, both
            // in the reporting currency — so a foreign position's exchange-rate move is part of it.
            // Not shown when the quote is stale or the previous one is far back: that is no day's move.
            if p.isValued, !row.isStale, let current = ledger.price(of: security.id, on: day),
               let previous = ledger.price(of: security.id, on: current.day.advanced(by: -1)),
               previous.day < current.day, previous.day.distance(to: current.day) <= Self.staleAfterDays,
               previous.price.raw > 0, current.price.raw > 0,
               let rateNow = rate(security.currency, on: day), let rateBefore = rate(security.currency, on: previous.day),
               let change = HoldingsMath.change(
                   value: p.value.minor, price: Double(current.price.raw), rate: rateNow,
                   previousPrice: Double(previous.price.raw), previousRate: rateBefore) {
                row.dayChange = change.fraction
                row.dayChangeAmount = change.amount
                row.dayChangeSince = previous.day
                row.quoteChange = Double(current.price.raw) / Double(previous.price.raw) - 1
            }
            row.spark = ledger.priceLevels(securityID: security.id, in: sparkInterval, basis: .securityCurrency) ?? []
            Self.apply(performance[security.id], to: &row)
            row.trailingDividends = trailing[security.id]
            row.yieldOnCost = HoldingsMath.yieldOnCost(trailingDividends: row.trailingDividends, costBasis: row.costBasis)
            return row
        }

        func cashRow(_ c: Snapshot.CashBalance) -> HoldingRow? {
            guard let account = ledger.account(c.accountID), c.balance.minor != 0 || c.value.minor != 0 else { return nil }
            var row = HoldingRow(
                id: "a:\(account.id.uuidString)", kind: .cash, accountID: account.id, name: account.name,
                detail: "Cash · \(account.currency)", searchText: "\(account.name) cash \(account.currency)", currency: account.currency)
            row.isValued = c.isValued
            if !c.isValued { row.valuationIssue = .noExchangeRate }
            row.localValue = c.balance.minor
            row.value = c.value.minor
            row.weight = share(c.value.minor)
            // Cash moves only with its exchange rate: none in the reporting currency.
            if c.isValued {
                let before = day.advanced(by: -1)
                if account.currency == reporting {
                    row.dayChangeAmount = 0
                } else if let rateNow = rate(account.currency, on: day), let rateBefore = rate(account.currency, on: before),
                          let change = HoldingsMath.change(value: c.value.minor, rate: rateNow, previousRate: rateBefore) {
                    // An unchanged rate (weekend) is no figure worth showing.
                    row.dayChange = change.amount == 0 ? nil : change.fraction
                    row.dayChangeAmount = change.amount
                    row.dayChangeSince = change.amount == 0 ? nil : before
                }
            }
            return row
        }

        let positions = snapshot.positions.compactMap(positionRow)
        let cash = snapshot.cash.compactMap(cashRow)
        let held = Set(snapshot.positions.map(\.securityID))

        closed = records.compactMap { record in
            guard record.shares.isZero, !held.contains(record.securityID), let security = ledger.security(record.securityID) else { return nil }
            var row = HoldingRow(
                id: "c:\(security.id.uuidString)", kind: .closed, securityID: security.id, name: security.name,
                detail: Self.detail(of: security), searchText: Self.searchText(of: security), currency: security.currency)
            Self.apply(record, to: &row)
            return row
        }

        switch query.grouping {
        case .none:
            groups = [Group(id: "", title: "", rows: positions + cash)]

        case .currency:
            var byCurrency: [CurrencyCode: [HoldingRow]] = [:]
            for row in positions + cash { byCurrency[row.currency, default: []].append(row) }
            groups = byCurrency
                .map { code, rows in Group(id: "g:currency:\(code)", title: Self.currencyTitle(code), rows: rows, scope: Self.weightedScope(of: rows)) }
                .sorted { a, b in
                    let va = a.rows.reduce(0) { $0 + $1.value }, vb = b.rows.reduce(0) { $0 + $1.value }
                    return va != vb ? va > vb : a.id < b.id
                }

        case .depot:
            // Period figures per depot come from the engine with the depot as scope; that is only
            // possible when the window's scope is not weighted. Otherwise a position held in a
            // single depot keeps the figures of the whole position and split ones show none.
            let canScopeDepots: Bool
            switch analysis.scope {
            case .portfolio, .subset: canScopeDepots = true
            default: canScopeDepots = false
            }
            let wholePortfolio = analysis.scope == .portfolio
            var result: [Group] = []
            var usedAccounts = Set<UUID>()
            let cashByAccount = Dictionary(cash.map { ($0.accountID!, $0) }, uniquingKeysWith: { a, _ in a })
            // Phase 1: what each depot group contains.
            struct DepotPlan: Sendable {
                var depot: Depot
                var members: [Snapshot.Position]
                var referenceRow: HoldingRow?
            }
            var plans: [DepotPlan] = []
            for depot in ledger.depots {
                let members = snapshot.positions.filter { p in p.holdings.contains { $0.depotID == depot.id } }
                var referenceRow: HoldingRow?
                if let reference = depot.referenceAccountID, !usedAccounts.contains(reference), let row = cashByAccount[reference] {
                    usedAccounts.insert(reference)
                    referenceRow = row
                }
                if !(members.isEmpty && referenceRow == nil) { plans.append(DepotPlan(depot: depot, members: members, referenceRow: referenceRow)) }
            }
            // Phase 2: one engine pass per depot, side by side — each is a full daily valuation.
            let interval = analysis.interval
            let figures: [(records: [SecurityPerformance], ttwror: Double?, irr: Double?, trailing: [UUID: Int64])] = Self.concurrentMap(plans) { plan in
                let isSplit = plan.members.contains { $0.holdings.count > 1 }
                // Twelve-month dividends of the depot's part of positions held in several depots.
                var trailing: [UUID: Int64] = [:]
                if canScopeDepots, isSplit {
                    for entry in ledger.earnings(in: trailingYear, scope: .depot(plan.depot.id)).bySecurity {
                        trailing[entry.securityID] = entry.amounts.dividends
                    }
                }
                guard hasPeriod else { return ([], nil, nil, trailing) }
                if wholePortfolio {
                    // One report gives both the group's return and the per-depot figures of
                    // positions that are split across depots.
                    let report = ledger.performance(in: interval, scope: .depot(plan.depot.id, account: plan.referenceRow?.accountID))
                    return (report.securities, report.ttwror, report.irr, trailing)
                } else if canScopeDepots, isSplit {
                    return (ledger.securityPerformance(in: interval, scope: .depot(plan.depot.id)), nil, nil, trailing)
                }
                return ([], nil, nil, trailing)
            }
            for (plan, figure) in zip(plans, figures) {
                let depot = plan.depot, members = plan.members, referenceRow = plan.referenceRow
                var rows: [HoldingRow] = []
                let depotPerformance = Dictionary(figure.records.map { ($0.securityID, $0) }, uniquingKeysWith: { a, _ in a })
                let groupReturn = figure.ttwror.map { (ttwror: $0, irr: figure.irr) }
                for p in members {
                    guard var row = positions.first(where: { $0.securityID == p.securityID }),
                          let holdingIndex = p.holdings.firstIndex(where: { $0.depotID == depot.id }) else { continue }
                    let holding = p.holdings[holdingIndex]
                    row.depotID = depot.id
                    if p.holdings.count > 1 {
                        row.id = "s:\(p.securityID.uuidString)@\(depot.id.uuidString)"
                        row.shares = p.weight != 10_000 ? Shares(raw: FixedMath.weighted(holding.shares.raw, Int32(clamping: p.weight))) : holding.shares
                        row.localValue = holding.valueInSecurityCurrency.minor
                        row.value = holding.value.minor
                        row.weight = share(holding.value.minor)
                        row.costBasis = holding.costBasis.minor
                        row.gain = holding.value.minor - holding.costBasis.minor
                        row.gainFraction = holding.costBasis.minor > 0 ? Double(holding.value.minor - holding.costBasis.minor) / Double(holding.costBasis.minor) : nil
                        row.purchasePrice = p.weight == 0 ? nil : Price(minor: mulDiv(holding.costBasis.minor, 10_000, Int64(p.weight)), per: holding.shares)
                        // The position's day amount, split so that the depots add up to it exactly.
                        row.dayChangeAmount = row.dayChangeAmount.map { HoldingsMath.apportion($0, p.holdings.map(\.value.minor))[holdingIndex] }
                        row.ttwror = nil
                        row.irr = nil
                        row.dividends = nil
                        row.realized = nil
                        Self.apply(depotPerformance[p.securityID], to: &row)
                        row.trailingDividends = canScopeDepots ? figure.trailing[p.securityID] ?? 0 : nil
                        row.yieldOnCost = HoldingsMath.yieldOnCost(trailingDividends: row.trailingDividends, costBasis: row.costBasis)
                    }
                    rows.append(row)
                }
                if let referenceRow { rows.append(referenceRow) }
                if !rows.isEmpty {
                    var group = Group(id: "g:depot:\(depot.id.uuidString)", title: depot.name, rows: rows)
                    group.ttwror = groupReturn?.ttwror
                    group.irr = groupReturn?.irr
                    result.append(group)
                }
            }
            let others = cash.filter { !usedAccounts.contains($0.accountID!) }
            if !others.isEmpty {
                result.append(Group(
                    id: "g:accounts", title: result.isEmpty ? "Accounts" : "Other Accounts", rows: others,
                    scope: .subset(depots: [], accounts: Set(others.compactMap(\.accountID)))))
            }
            groups = result

        case .taxonomy:
            guard let taxonomy = query.taxonomy else {
                groups = [Group(id: "", title: "", rows: positions + cash)]
                break
            }
            let allocation = ledger.allocation(for: taxonomy, snapshot: snapshot)
            var base: [AllocationVehicle: HoldingRow] = [:]
            for row in positions { base[.security(row.securityID!)] = row }
            for row in cash { base[.account(row.accountID!)] = row }

            func isShown(_ item: AllocationItem) -> Bool { base[item.vehicle] != nil && (item.value != 0 || item.weight != 0) }

            // A vehicle assigned to several classifications appears once per classification. Its
            // additive figures are split by the assignment weights so that the parts add up to the
            // position to the cent (rounding each part on its own would not).
            var partWeights: [AllocationVehicle: [Int64]] = [:]
            func collect(_ items: [AllocationItem]) {
                for item in items where isShown(item) && item.weight != 10_000 {
                    partWeights[item.vehicle, default: []].append(Int64(item.weight))
                }
            }
            func collect(_ node: AllocationNode) {
                collect(node.items)
                for child in node.children { collect(child) }
            }
            for root in allocation.roots { collect(root) }
            collect(allocation.unassigned)
            var nextPart: [AllocationVehicle: Int] = [:]

            // Same traversal order as `collect`, so the n-th row of a vehicle takes its n-th part.
            func rows(of items: [AllocationItem], suffix: String) -> [HoldingRow] {
                items.compactMap { item in
                    guard isShown(item), var row = base[item.vehicle] else { return nil }
                    guard item.weight != 10_000 else { return row }
                    let whole = row
                    let weights = partWeights[item.vehicle] ?? [Int64(item.weight)]
                    let index = nextPart[item.vehicle, default: 0]
                    nextPart[item.vehicle] = index + 1
                    func part(_ total: Int64?) -> Int64? {
                        total.map { index < weights.count ? HoldingsMath.apportion($0, weights)[index] : 0 }
                    }
                    row.id += "#\(suffix)"
                    // Part of the whole position: the scope's weight times the assignment's.
                    row.assignedWeight = Int((Int64(whole.assignedWeight ?? 10_000) * Int64(item.weight) + 5_000) / 10_000)
                    row.shares = part(whole.shares?.raw).map { Shares(raw: $0) }
                    row.localValue = part(whole.localValue)
                    row.value = item.value
                    row.weight = share(item.value)
                    row.costBasis = part(whole.costBasis)
                    row.gain = row.costBasis.map { item.value - $0 }
                    row.dayChangeAmount = part(whole.dayChangeAmount)
                    row.dividends = part(whole.dividends)
                    row.trailingDividends = part(whole.trailingDividends)
                    row.realized = part(whole.realized)
                    return row
                }
            }

            var result: [Group] = []
            func visit(_ node: AllocationNode, path: String, rootIndex: Int, inherited: String) {
                let color = node.color.isEmpty ? inherited : node.color
                let members = rows(of: node.items, suffix: node.id.uuidString)
                if !members.isEmpty {
                    result.append(Group(
                        id: "g:class:\(node.id.uuidString)", title: node.name, parent: path, colorHex: color, colorIndex: rootIndex, rows: members,
                        scope: Self.weightedScope(of: members)))
                }
                let childPath = path.isEmpty ? node.name : "\(path) ▸ \(node.name)"
                for child in node.children { visit(child, path: childPath, rootIndex: rootIndex, inherited: color) }
            }
            for (index, root) in allocation.roots.enumerated() { visit(root, path: "", rootIndex: index, inherited: "") }
            let unassigned = rows(of: allocation.unassigned, suffix: "unassigned")
            if !unassigned.isEmpty {
                result.append(Group(id: "g:unassigned", title: "Not Assigned", colorHex: nil, colorIndex: Int.max, rows: unassigned, scope: Self.weightedScope(of: unassigned)))
            }
            groups = result
        }

        // Period return per group: each group valued as a scope of its own (one daily pass each).
        // Only meaningful when the window shows the whole portfolio — scopes cannot be intersected.
        if analysis.scope == .portfolio, hasPeriod {
            for index in groups.indices {
                guard let scope = groups[index].scope else { continue }
                let valuation = ledger.valuation(in: analysis.interval, scope: scope)
                groups[index].ttwror = valuation.returns().total
                groups[index].irr = valuation.irr()
            }
        }

        self.day = day
        interval = analysis.interval
        hasPeriodFigures = hasPeriod
        currency = reporting
        grouping = query.grouping
        totalValue = total
        securitiesValue = snapshot.securitiesValue.minor
        cashValue = snapshot.cashValue.minor
        costBasis = snapshot.costBasis.minor
        ttwror = hasPeriod ? analysis.ttwror : nil
        irr = hasPeriod ? analysis.irr : nil
        absolutePerformance = hasPeriod ? analysis.absolutePerformance : nil
        positionCount = positions.count
        cashCount = cash.count
        staleCount = positions.count(where: \.isStale)
        unvalued = (positions + cash).filter { !$0.isValued }.map(\.name)
        hasTransactions = !ledger.transactions.isEmpty
    }

    /// Maps on several cores; the work must be pure. Order is preserved.
    private static func concurrentMap<Item: Sendable, Result: Sendable>(_ items: [Item], _ transform: @Sendable (Item) -> Result) -> [Result] {
        guard items.count > 1 else { return items.map(transform) }
        let box = ResultBox<Result>(count: items.count)
        withoutActuallyEscaping(transform) { transform in
            DispatchQueue.concurrentPerform(iterations: items.count) { index in
                box.set(index, transform(items[index]))
            }
        }
        return box.values
    }

    private final class ResultBox<Result: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result?]
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: Result) {
            lock.lock()
            storage[index] = value
            lock.unlock()
        }
        var values: [Result] { storage.compactMap { $0 } }
    }

    /// A scope holding exactly these rows, each with the part of the position it shows.
    private static func weightedScope(of rows: [HoldingRow]) -> Scope {
        var securities: [UUID: Int] = [:], accounts: [UUID: Int] = [:]
        for row in rows {
            if let id = row.securityID { securities[id, default: 0] += row.assignedWeight ?? 10_000 }
            if let id = row.accountID { accounts[id, default: 0] += row.assignedWeight ?? 10_000 }
        }
        return .weighted(securities: securities, accounts: accounts)
    }

    private static func apply(_ record: SecurityPerformance?, to row: inout HoldingRow) {
        guard let record else { return }
        row.ttwror = record.ttwror
        row.irr = record.irr
        row.dividends = record.dividends
        row.realized = record.realizedGain
    }

    private static func detail(of security: Security) -> String {
        var parts: [String] = []
        if !security.ticker.isEmpty { parts.append(security.ticker) }
        if !security.isin.isEmpty { parts.append(security.isin) } else if !security.wkn.isEmpty { parts.append(security.wkn) }
        if parts.isEmpty { parts.append(security.currency) }
        return parts.joined(separator: " · ")
    }

    private static func searchText(of security: Security) -> String {
        [security.name, security.ticker, security.isin, security.wkn, security.currency].joined(separator: " ")
    }

    private static func currencyTitle(_ code: CurrencyCode) -> String {
        let name = Currencies.name(code)
        return name.isEmpty || name == code ? code : "\(code) — \(name)"
    }
}

// MARK: - Stage 2: what the table shows

/// Filter, visibility and sort options applied to a `HoldingsBase` (cheap: a few hundred rows).
struct HoldingsDisplayOptions: Equatable, Sendable {
    var filter = ""
    var showsCash = true
    var includesClosed = false
    var sortOrder: [KeyPathComparator<HoldingRow>] = HoldingsDisplay.defaultSortOrder
}

/// The rows as displayed: filtered, sorted, with subtotals, the grand total and the chart inputs.
struct HoldingsDisplay: Sendable {
    struct Group: Sendable, Identifiable {
        var id: String
        /// Subtotal line; nil when the table is not grouped.
        var header: HoldingRow?
        var rows: [HoldingRow]
    }

    struct Segment: Sendable, Identifiable {
        var id: String
        var name: String
        var value: Int64
        var share: Double
        /// Index into the category palette; nil = neutral ("Other", cash).
        var colorIndex: Int?
        var rowID: String?
    }

    struct Concentration: Sendable {
        var segments: [Segment] = []
        var largest: Double?
        var topFive: Double?
        var topTen: Double?
        var positionCount = 0
    }

    static let defaultSortOrder = [KeyPathComparator(\HoldingRow.value, order: .reverse)]

    var groups: [Group] = []
    var isGrouped = false
    /// Identifies the table's structure (grouping and kinds of lines); the table view is rebuilt
    /// when it changes.
    var structureKey = ""
    var total: HoldingRow?
    /// Positions, cash balances and closed positions shown.
    var entityCount = 0
    /// The same before filtering.
    var unfilteredCount = 0
    /// Largest weight of a single line — scales the weight bars.
    var maxWeight = 0.0
    var treemap: [ChartNode] = []
    var concentration = Concentration()
    var rowsByID: [String: HoldingRow] = [:]
    /// Every visible line top to bottom (headers, rows, total) — for copy and export.
    var lines: [HoldingRow] = []

    init() {}

    init(_ base: HoldingsBase, options: HoldingsDisplayOptions) {
        let filter = QuickFilter(options.filter)
        func visible(_ row: HoldingRow) -> Bool {
            (options.showsCash || row.kind != .cash) && filter.matches(row.searchText)
        }
        var source = base.groups
        if options.includesClosed, !base.closed.isEmpty {
            if base.grouping == .none, !source.isEmpty {
                source[0].rows += base.closed
            } else {
                source.append(HoldingsBase.Group(id: HoldingsBase.closedGroupID, title: "Closed in Period", colorIndex: Int.max, rows: base.closed))
            }
        }
        isGrouped = base.grouping != .none
        structureKey = "\(base.grouping.key)|\(options.showsCash)|\(options.includesClosed)"
        unfilteredCount = source.reduce(0) { $0 + $1.rows.count { options.showsCash || $0.kind != .cash } }

        var all: [HoldingRow] = []
        for group in source {
            var rows = group.rows.filter(visible).sorted(using: options.sortOrder)
            guard !rows.isEmpty else { continue }
            if isGrouped {
                for index in rows.indices { rows[index].groupID = group.id }
            }
            var header: HoldingRow?
            if isGrouped {
                var summary = Self.summary(of: rows, id: group.id, kind: .group, name: group.title, currency: base.currency)
                summary.detail = group.parent
                summary.colorHex = group.colorHex
                summary.colorIndex = group.colorIndex
                // The group's own return applies only while all of its rows are shown.
                if rows.count == group.rows.count {
                    summary.ttwror = group.ttwror
                    summary.irr = group.irr
                }
                header = summary
            }
            groups.append(Group(id: group.id, header: header, rows: rows))
            all += rows
        }
        entityCount = all.count
        maxWeight = all.reduce(0) { max($0, $1.weight ?? 0) }

        if !all.isEmpty {
            var summary = Self.summary(of: all, id: "total", kind: .total, name: "Total", currency: base.currency)
            // The scope's own return figures apply only when the total covers the whole scope.
            if filter.isEmpty, options.showsCash {
                summary.ttwror = base.ttwror
                summary.irr = base.irr
            }
            summary.detail = all.count == unfilteredCount
                ? Self.holdings(all.count)
                : "\(Fmt.integer(all.count)) of \(Self.holdings(unfilteredCount))"
            total = summary
        }

        for group in groups {
            if let header = group.header { lines.append(header) }
            lines += group.rows
        }
        if let total { lines.append(total) }
        rowsByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Treemap: area = market value, color = period TTWROR.
        func leaf(_ row: HoldingRow) -> ChartNode? {
            row.value > 0 ? ChartNode(row.name, id: row.id, value: Double(row.value), color: row.kind == .cash ? ChartColors.neutral : nil, change: row.ttwror) : nil
        }
        if isGrouped {
            treemap = groups.compactMap { group in
                let children = group.rows.compactMap(leaf)
                guard let header = group.header, !children.isEmpty else { return nil }
                let name = header.detail.isEmpty ? header.name : "\(header.detail) ▸ \(header.name)"
                return ChartNode(name, id: header.id, value: children.reduce(0) { $0 + $1.value }, change: header.ttwror, children: children)
            }
        } else {
            treemap = all.compactMap(leaf)
        }

        // Concentration: the ten largest positions (split rows combined), the rest, and cash.
        var bySecurity: [UUID: (name: String, value: Int64, rowID: String)] = [:]
        var order: [UUID] = []
        var cashValue: Int64 = 0
        for row in all where row.value > 0 {
            if row.kind == .cash {
                cashValue += row.value
            } else if let id = row.securityID {
                if bySecurity[id] == nil { order.append(id) }
                bySecurity[id, default: (row.name, 0, row.id)].value += row.value
            }
        }
        let ranked = order.compactMap { bySecurity[$0] }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
        let shown = ranked.reduce(0) { $0 + $1.value } + cashValue
        if shown > 0 {
            let fraction = { (value: Int64) in Double(value) / Double(shown) }
            var segments: [Segment] = []
            // The category palette has eight hues that must not be cycled: the first eight
            // positions get their own color, positions nine and ten share the "other" tone.
            for (index, entry) in ranked.prefix(10).enumerated() {
                segments.append(Segment(id: entry.rowID, name: entry.name, value: entry.value, share: fraction(entry.value), colorIndex: index < CategoryPalette.count ? index : nil, rowID: entry.rowID))
            }
            let rest = ranked.dropFirst(10).reduce(0) { $0 + $1.value }
            if rest > 0 {
                segments.append(Segment(id: "other", name: "\(Fmt.integer(ranked.count - 10)) other positions", value: rest, share: fraction(rest), colorIndex: nil, rowID: nil))
            }
            if cashValue > 0 {
                segments.append(Segment(id: "cash", name: "Cash", value: cashValue, share: fraction(cashValue), colorIndex: nil, rowID: nil))
            }
            let top = { (n: Int) -> Double? in ranked.isEmpty ? nil : fraction(ranked.prefix(n).reduce(0) { $0 + $1.value }) }
            concentration = Concentration(segments: segments, largest: top(1), topFive: top(5), topTen: top(10), positionCount: ranked.count)
        }
    }

    /// "1 holding", "16 holdings" — the one noun used for lines of the statement.
    static func holdings(_ count: Int) -> String { "\(Fmt.integer(count)) \(count == 1 ? "holding" : "holdings")" }

    /// Sums of the additive columns; ratios are recomputed from the sums.
    static func summary(of rows: [HoldingRow], id: String, kind: HoldingRow.Kind, name: String, currency: CurrencyCode) -> HoldingRow {
        var row = HoldingRow(id: id, kind: kind, name: name, detail: "", searchText: "", currency: currency)
        row.count = rows.count
        row.detail = holdings(rows.count)
        var value: Int64 = 0, weight = 0.0, hasWeight = false
        var cost: Int64 = 0, gain: Int64 = 0, hasCost = false
        var day: Int64 = 0, hasDay = false, since: Day?
        var dividends: Int64 = 0, hasDividends = false, yieldCost: Int64 = 0, yieldDividends: Int64 = 0, hasYield = false
        var realized: Int64 = 0, hasRealized = false
        var local: Int64 = 0, localCurrency: CurrencyCode?, localIsUniform = true
        for r in rows {
            value += r.value
            if let w = r.weight { weight += w; hasWeight = true }
            if let c = r.costBasis { cost += c; gain += r.gain ?? 0; hasCost = true }
            if let d = r.dayChangeAmount {
                day += d
                if r.dayChange != nil { hasDay = true }
                if let s = r.dayChangeSince { since = min(since ?? s, s) }
            }
            if let d = r.dividends { dividends += d; hasDividends = true }
            if r.kind == .position, let c = r.costBasis, c > 0, let t = r.trailingDividends {
                yieldCost += c
                yieldDividends += t
                hasYield = true
            }
            if let x = r.realized { realized += x; hasRealized = true }
            if let l = r.localValue {
                local += l
                if let existing = localCurrency, existing != r.currency { localIsUniform = false }
                localCurrency = r.currency
            } else if r.kind != .closed {
                localIsUniform = false
            }
        }
        row.value = value
        row.weight = hasWeight ? weight : nil
        if hasCost {
            row.costBasis = cost
            row.gain = gain
            row.gainFraction = cost > 0 ? Double(gain) / Double(cost) : nil
        }
        if hasDay {
            // Relative to everything the line shows — cash and positions without a move of their
            // own included — so the percentage and the amount belong to the Value next to them.
            let before = value - day
            row.dayChangeAmount = day
            row.dayChange = before > 0 ? Double(day) / Double(before) : nil
            row.dayChangeSince = since
        }
        if hasDividends { row.dividends = dividends }
        if hasYield {
            row.trailingDividends = yieldDividends
            row.yieldOnCost = HoldingsMath.yieldOnCost(trailingDividends: yieldDividends, costBasis: yieldCost)
        }
        if hasRealized { row.realized = realized }
        if localIsUniform, let localCurrency {
            row.localValue = local
            row.currency = localCurrency
        }
        return row
    }
}
