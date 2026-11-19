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
    /// Change of the latest quote against the one before it (fraction).
    var dayChange: Double?
    /// That change applied to the market value, reporting currency.
    var dayChangeAmount: Int64?
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
    var dividends: Int64?
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
    var interval: DayInterval
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
    var ttwror: Double
    var irr: Double?
    var absolutePerformance: Int64
    var positionCount: Int
    var cashCount: Int
    var staleCount: Int
    /// Names of positions that could not be valued (no price or no exchange rate).
    var unvalued: [String]
    var hasTransactions: Bool

    static let closedGroupID = "g:closed"
    /// Days without a new quote after which a price counts as stale.
    static let staleAfterDays = 7

    var isEmpty: Bool { groups.allSatisfy(\.rows.isEmpty) }

    init(_ analysis: Analysis, query: HoldingsQuery) {
        let ledger = analysis.ledger
        let snapshot = analysis.snapshot
        let day = snapshot.day
        let total = snapshot.totalValue.minor
        let reporting = analysis.currency
        let performance = Dictionary(analysis.securities.map { ($0.securityID, $0) }, uniquingKeysWith: { a, _ in a })
        let sparkInterval = DayInterval(start: day.advanced(by: -90), end: day)

        func share(_ value: Int64) -> Double? { total > 0 ? Double(value) / Double(total) : nil }

        // One row per security held in the scope, all depots combined.
        func positionRow(_ p: Snapshot.Position) -> HoldingRow? {
            guard let security = ledger.security(p.securityID) else { return nil }
            var row = HoldingRow(
                id: "s:\(security.id.uuidString)", kind: .position, securityID: security.id, name: security.name,
                detail: Self.detail(of: security), searchText: Self.searchText(of: security), currency: security.currency)
            row.depotID = p.holdings.max { $0.value.minor < $1.value.minor }?.depotID
            row.shares = p.shares
            row.price = p.price
            row.priceDay = p.priceDay
            row.isValued = p.isValued
            row.isStale = p.priceDay.map { $0.distance(to: day) > Self.staleAfterDays } ?? true
            row.localValue = p.valueInSecurityCurrency.minor
            row.value = p.value.minor
            row.weight = share(p.value.minor)
            row.costBasis = p.costBasis.minor
            row.purchasePrice = p.purchasePrice
            row.gain = p.unrealizedGain.minor
            row.gainFraction = p.unrealizedGainFraction
            if p.isValued, let current = ledger.price(of: security.id, on: day),
               let previous = ledger.price(of: security.id, on: current.day.advanced(by: -1)),
               previous.day < current.day, previous.price.raw > 0 {
                let change = Double(current.price.raw) / Double(previous.price.raw) - 1
                row.dayChange = change
                row.dayChangeAmount = FixedMath.saturatingInt64(Double(p.value.minor) * change / (1 + change))
            }
            row.spark = ledger.priceLevels(securityID: security.id, in: sparkInterval, basis: .securityCurrency) ?? []
            Self.apply(performance[security.id], to: &row)
            return row
        }

        func cashRow(_ c: Snapshot.CashBalance) -> HoldingRow? {
            guard let account = ledger.account(c.accountID), c.balance.minor != 0 || c.value.minor != 0 else { return nil }
            var row = HoldingRow(
                id: "a:\(account.id.uuidString)", kind: .cash, accountID: account.id, name: account.name,
                detail: "Cash · \(account.currency)", searchText: "\(account.name) cash \(account.currency)", currency: account.currency)
            row.isValued = c.isValued
            row.localValue = c.balance.minor
            row.value = c.value.minor
            row.weight = share(c.value.minor)
            return row
        }

        let positions = snapshot.positions.compactMap(positionRow)
        let cash = snapshot.cash.compactMap(cashRow)
        let held = Set(snapshot.positions.map(\.securityID))

        closed = analysis.securities.compactMap { record in
            guard record.shares.isZero, !held.contains(record.securityID), let security = ledger.security(record.securityID) else { return nil }
            var row = HoldingRow(
                id: "c:\(security.id.uuidString)", kind: .closed, securityID: security.id, name: security.name,
                detail: Self.detail(of: security), searchText: Self.searchText(of: security), currency: security.currency)
            Self.apply(record, to: &row)
            row.yieldOnCost = nil
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
            let figures: [(records: [SecurityPerformance], ttwror: Double?, irr: Double?)] = Self.concurrentMap(plans) { plan in
                if wholePortfolio {
                    // One report gives both the group's return and the per-depot figures of
                    // positions that are split across depots.
                    let report = ledger.performance(in: interval, scope: .depot(plan.depot.id, account: plan.referenceRow?.accountID))
                    return (report.securities, report.ttwror, report.irr)
                } else if canScopeDepots, plan.members.contains(where: { $0.holdings.count > 1 }) {
                    return (ledger.securityPerformance(in: interval, scope: .depot(plan.depot.id)), nil, nil)
                }
                return ([], nil, nil)
            }
            for (plan, figure) in zip(plans, figures) {
                let depot = plan.depot, members = plan.members, referenceRow = plan.referenceRow
                var rows: [HoldingRow] = []
                let depotPerformance = Dictionary(figure.records.map { ($0.securityID, $0) }, uniquingKeysWith: { a, _ in a })
                let groupReturn = figure.ttwror.map { (ttwror: $0, irr: figure.irr) }
                for p in members {
                    guard var row = positions.first(where: { $0.securityID == p.securityID }),
                          let holding = p.holdings.first(where: { $0.depotID == depot.id }) else { continue }
                    row.depotID = depot.id
                    if p.holdings.count > 1 {
                        row.id = "s:\(p.securityID.uuidString)@\(depot.id.uuidString)"
                        let fraction = p.value.minor != 0 ? Double(holding.value.minor) / Double(p.value.minor) : 0
                        row.shares = holding.shares
                        row.localValue = holding.valueInSecurityCurrency.minor
                        row.value = holding.value.minor
                        row.weight = share(holding.value.minor)
                        row.costBasis = holding.costBasis.minor
                        row.gain = holding.value.minor - holding.costBasis.minor
                        row.gainFraction = holding.costBasis.minor > 0 ? Double(holding.value.minor - holding.costBasis.minor) / Double(holding.costBasis.minor) : nil
                        row.purchasePrice = p.weight == 0 ? nil : Price(minor: mulDiv(holding.costBasis.minor, 10_000, Int64(p.weight)), per: holding.shares)
                        row.dayChangeAmount = row.dayChangeAmount.map { FixedMath.saturatingInt64(Double($0) * fraction) }
                        row.ttwror = nil
                        row.irr = nil
                        row.dividends = nil
                        row.yieldOnCost = nil
                        row.realized = nil
                        Self.apply(depotPerformance[p.securityID], to: &row)
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
            let allocation = analysis.allocation(for: taxonomy)
            var base: [AllocationVehicle: HoldingRow] = [:]
            for row in positions { base[.security(row.securityID!)] = row }
            for row in cash { base[.account(row.accountID!)] = row }

            func rows(of items: [AllocationItem], suffix: String) -> [HoldingRow] {
                items.compactMap { item in
                    guard var row = base[item.vehicle], item.value != 0 || item.weight != 0 else { return nil }
                    guard item.weight != 10_000 else { return row }
                    let w = Int32(clamping: item.weight)
                    row.id += "#\(suffix)"
                    row.assignedWeight = item.weight
                    row.shares = row.shares.map { Shares(raw: FixedMath.weighted($0.raw, w)) }
                    row.localValue = row.localValue.map { FixedMath.weighted($0, w) }
                    row.value = item.value
                    row.weight = share(item.value)
                    row.costBasis = row.costBasis.map { FixedMath.weighted($0, w) }
                    row.gain = row.costBasis.map { item.value - $0 }
                    row.dayChangeAmount = row.dayChangeAmount.map { FixedMath.weighted($0, w) }
                    row.dividends = row.dividends.map { FixedMath.weighted($0, w) }
                    row.realized = row.realized.map { FixedMath.weighted($0, w) }
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
        if analysis.scope == .portfolio {
            for index in groups.indices {
                guard let scope = groups[index].scope else { continue }
                let valuation = ledger.valuation(in: analysis.interval, scope: scope)
                groups[index].ttwror = valuation.returns().total
                groups[index].irr = valuation.irr()
            }
        }

        self.day = day
        interval = analysis.interval
        currency = reporting
        grouping = query.grouping
        totalValue = total
        securitiesValue = snapshot.securitiesValue.minor
        cashValue = snapshot.cashValue.minor
        costBasis = snapshot.costBasis.minor
        ttwror = analysis.ttwror
        irr = analysis.irr
        absolutePerformance = analysis.absolutePerformance
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
        row.yieldOnCost = record.dividendYieldOnCost
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
                summary.detail = "\(Fmt.integer(all.count)) \(all.count == 1 ? "line" : "lines")"
            } else {
                summary.detail = "of \(Fmt.integer(all.count)) shown"
            }
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

    /// Sums of the additive columns; ratios are recomputed from the sums.
    static func summary(of rows: [HoldingRow], id: String, kind: HoldingRow.Kind, name: String, currency: CurrencyCode) -> HoldingRow {
        var row = HoldingRow(id: id, kind: kind, name: name, detail: "", searchText: "", currency: currency)
        row.count = rows.count
        row.detail = "\(Fmt.integer(rows.count)) \(rows.count == 1 ? "line" : "lines")"
        var value: Int64 = 0, weight = 0.0, hasWeight = false
        var cost: Int64 = 0, gain: Int64 = 0, hasCost = false
        var day: Int64 = 0, hasDay = false, dayBase: Int64 = 0
        var dividends: Int64 = 0, hasDividends = false, yieldCost: Int64 = 0, yieldDividends: Int64 = 0
        var realized: Int64 = 0, hasRealized = false
        var local: Int64 = 0, localCurrency: CurrencyCode?, localIsUniform = true
        for r in rows {
            value += r.value
            if let w = r.weight { weight += w; hasWeight = true }
            if let c = r.costBasis { cost += c; gain += r.gain ?? 0; hasCost = true }
            if let d = r.dayChangeAmount { day += d; dayBase += r.value - d; hasDay = true }
            if let d = r.dividends {
                dividends += d
                hasDividends = true
                if r.kind == .position, let c = r.costBasis, c > 0 { yieldCost += c; yieldDividends += d }
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
            row.dayChangeAmount = day
            row.dayChange = dayBase > 0 ? Double(day) / Double(dayBase) : nil
        }
        if hasDividends {
            row.dividends = dividends
            row.yieldOnCost = yieldCost > 0 ? Double(yieldDividends) / Double(yieldCost) : nil
        }
        if hasRealized { row.realized = realized }
        if localIsUniform, let localCurrency {
            row.localValue = local
            row.currency = localCurrency
        }
        return row
    }
}
