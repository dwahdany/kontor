import SwiftUI
import KontorUI

// Sendable view models of the Allocation tab. Built off the main actor inside `analysisTask`; every
// number comes from the engine's `TaxonomyAllocation` / `ClassificationPerformance`.

/// One line of the allocation tree: a classification, a vehicle assigned to it, the "Unassigned"
/// bucket, or a vehicle inside that bucket.
struct AllocationRow: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case classification(UUID)
        /// `classification` nil = inside the unassigned bucket.
        case item(classification: UUID?, vehicle: AllocationVehicle)
        case unassigned
    }

    static let unassignedID = "unassigned"

    var id: String
    var kind: Kind
    var name: String
    var depth: Int
    var color: Color?
    /// Minor units of the reporting currency.
    var value: Int64
    /// Share of the classified value (0…1) — the base the targets refer to. nil for the
    /// unassigned bucket, which is outside that base.
    var share: Double?
    var targetShare: Double?
    /// actual − target (positive = overweight).
    var deltaShare: Double?
    var deltaValue: Int64?
    /// Items: the part of the vehicle counted here, in basis points.
    var weight: Int?
    /// Items: shares held (securities only; not multiplied by the weight).
    var shares: Shares?
    var children: [AllocationRow]

    var classificationID: UUID? {
        if case .classification(let id) = kind { id } else { nil }
    }

    var vehicle: AllocationVehicle? {
        if case .item(_, let vehicle) = kind { vehicle } else { nil }
    }

    var isItem: Bool { vehicle != nil }

    static func id(classification: UUID) -> String { classification.uuidString }
    static func id(classification: UUID?, vehicle: AllocationVehicle) -> String {
        "\(classification?.uuidString ?? unassignedID)/\(vehicle.token)"
    }

    var flattened: [AllocationRow] { [self] + children.flatMap(\.flattened) }
}

/// What an `AllocationModel` depends on besides the document, the scope and the period.
struct AllocationKey: Hashable, Sendable {
    var taxonomy: UUID
    /// Set when the window's scope is a classification of this very taxonomy.
    var scopeRoot: UUID?
}

extension PortfolioStore {
    /// The cache key of the allocation of `taxonomy` in this window.
    func allocationKey(for taxonomy: Taxonomy) -> AllocationKey {
        if case .classification(let scoped, let id) = scopeSelection, scoped == taxonomy.id, taxonomy.contains(id) {
            return AllocationKey(taxonomy: taxonomy.id, scopeRoot: id)
        }
        return AllocationKey(taxonomy: taxonomy.id, scopeRoot: nil)
    }
}

struct AllocationModel: Sendable {
    /// A line of the "Target vs. Actual" view.
    struct Bar: Identifiable, Sendable {
        var id: String
        var name: String
        var depth: Int
        var color: Color
        var actual: Double?
        var target: Double?
        var deltaValue: Int64?
    }

    struct Drift: Sendable {
        var name: String
        var deltaShare: Double
        var deltaValue: Int64
    }

    var taxonomyID: UUID
    var currency: CurrencyCode
    var day: Day
    var totalValue: Int64
    var classifiedValue: Int64
    var unassignedValue: Int64
    var unassignedShare: Double?
    var unassignedCount: Int
    /// Name of the classification of this taxonomy the scope is narrowed to; targets are then
    /// relative to it (see `rebased`).
    var scopeRootName: String?
    var classificationCount: Int
    var hasTargets: Bool
    /// Names of vehicles assigned with more than 100 % in total (the engine scales them down).
    var overAssigned: [String]
    /// The classification furthest from its target.
    var largestDrift: Drift?

    var rows: [AllocationRow]
    var slices: [ChartSlice]
    var sunburst: [ChartNode]
    var treemap: [ChartNode]
    var bars: [Bar]
    var barMaximum: Double

    var hasValue: Bool { totalValue > 0 }

    /// The taxonomy with targets relative to one of its classifications: that classification and
    /// its ancestors count as 100 %, everything outside it has no target. Used when the scope *is*
    /// that classification — the whole-portfolio targets ("Equity 60 %") say nothing about a
    /// scope that consists of Equity only, but the targets below it ("75 % developed") still do.
    static func rebased(_ taxonomy: Taxonomy, onto id: UUID) -> Taxonomy? {
        guard let path = taxonomy.path(to: id) else { return nil }
        func clear(_ node: inout Classification) {
            node.targetWeight = nil
            for i in node.children.indices { clear(&node.children[i]) }
        }
        func visit(_ nodes: inout [Classification]) {
            for i in nodes.indices {
                guard path.contains(nodes[i].id) else {
                    clear(&nodes[i])
                    continue
                }
                nodes[i].targetWeight = 10_000
                if nodes[i].id != id { visit(&nodes[i].children) }
            }
        }
        var copy = taxonomy
        visit(&copy.root)
        return copy
    }

    init(_ analysis: Analysis, taxonomy: Taxonomy, scopeRoot: UUID? = nil) {
        // One base on every tab: targets — and therefore shares and deviations — refer to the
        // classified value, exactly as the rebalancing proposal does (it can only move what is
        // classified). "actual − target = Δ" holds on every line; what is unassigned is listed
        // separately, outside that base.
        let rebased = scopeRoot.flatMap { Self.rebased(taxonomy, onto: $0) }
        let allocation = rebased.map { analysis.ledger.allocation(for: $0, snapshot: analysis.snapshot) } ?? analysis.allocation(for: taxonomy)
        scopeRootName = rebased == nil ? nil : scopeRoot.flatMap { taxonomy.classification($0)?.name }
        taxonomyID = taxonomy.id
        currency = allocation.currency
        day = allocation.day
        totalValue = allocation.totalValue
        classifiedValue = allocation.classifiedValue
        unassignedValue = allocation.unassignedValue
        unassignedShare = allocation.unassignedShare
        unassignedCount = allocation.unassigned.count
        let flat = allocation.flattened
        classificationCount = flat.count
        hasTargets = flat.contains { $0.targetShare != nil }
        let names = Dictionary(
            flat.flatMap(\.items).map { ($0.vehicle, $0.name) } + allocation.unassigned.map { ($0.vehicle, $0.name) },
            uniquingKeysWith: { a, _ in a })
        overAssigned = allocation.overAssigned.compactMap { names[$0] }
        largestDrift = flat
            .compactMap { node in
                guard let delta = node.deltaShare, let value = node.deltaValue else { return nil }
                return Drift(name: node.name, deltaShare: delta, deltaValue: value)
            }
            .max { abs($0.deltaShare) < abs($1.deltaShare) }

        let base = allocation.classifiedValue
        func share(_ value: Int64) -> Double? { base > 0 ? Double(value) / Double(base) : nil }

        func itemRow(_ item: AllocationItem, classification: UUID?, depth: Int) -> AllocationRow {
            AllocationRow(
                id: AllocationRow.id(classification: classification, vehicle: item.vehicle),
                kind: .item(classification: classification, vehicle: item.vehicle), name: item.name, depth: depth,
                color: nil, value: item.value, share: classification == nil ? nil : share(item.value), targetShare: nil, deltaShare: nil,
                deltaValue: nil, weight: item.weight, shares: item.shares, children: [])
        }
        func row(_ node: AllocationNode, index: Int) -> AllocationRow {
            AllocationRow(
                id: AllocationRow.id(classification: node.id), kind: .classification(node.id), name: node.name,
                depth: node.depth, color: ChartColors.classification(node.color, fallbackIndex: index),
                value: node.value, share: share(node.value), targetShare: node.targetShare, deltaShare: node.deltaShare,
                deltaValue: node.deltaValue, weight: nil, shares: nil,
                children: node.children.enumerated().map { row($1, index: $0) }
                    + node.items.map { itemRow($0, classification: node.id, depth: node.depth + 1) })
        }
        var rows = allocation.roots.enumerated().map { row($1, index: $0) }
        if !allocation.unassigned.isEmpty {
            rows.append(AllocationRow(
                id: AllocationRow.unassignedID, kind: .unassigned, name: "Unassigned", depth: 0, color: ChartColors.other,
                value: allocation.unassignedValue, share: nil, targetShare: nil, deltaShare: nil,
                deltaValue: nil, weight: nil, shares: nil,
                children: allocation.unassigned.map { itemRow($0, classification: nil, depth: 1) }))
        }
        self.rows = rows

        slices = ChartSlice.slices(from: allocation)
        sunburst = ChartNode.nodes(from: allocation)
        treemap = ChartNode.nodes(from: allocation, includesItems: true)

        var bars: [Bar] = []
        func collect(_ node: AllocationNode, index: Int, color: Color?) {
            let own = color ?? ChartColors.classification(node.color, fallbackIndex: index)
            if node.targetShare != nil || node.depth == 0 {
                bars.append(Bar(
                    id: node.id.uuidString, name: node.name, depth: node.depth, color: own, actual: share(node.value),
                    target: node.targetShare, deltaValue: node.deltaValue))
            }
            for (i, child) in node.children.enumerated() where child.targetShare != nil { collect(child, index: i, color: own) }
        }
        for (i, root) in allocation.roots.enumerated() { collect(root, index: i, color: nil) }
        self.bars = bars
        barMaximum = max(0.05, bars.reduce(0) { max($0, $1.actual ?? 0, $1.target ?? 0) })
    }
}

/// Period return per classification (TTWROR of the weighted scope, incl. descendants).
struct ClassificationReturns: Sendable {
    var ttwror: [UUID: Double]
    /// False when the window is narrowed to a depot/account/classification: the engine measures
    /// classification performance on the whole portfolio, so nothing is shown then.
    var isAvailable: Bool

    init(_ analysis: Analysis, taxonomy: Taxonomy) {
        guard analysis.scope == .portfolio else {
            ttwror = [:]
            isAvailable = false
            return
        }
        let results = analysis.ledger.classificationPerformance(of: taxonomy, in: analysis.interval)
        ttwror = Dictionary(results.map { ($0.classificationID, $0.ttwror) }, uniquingKeysWith: { a, _ in a })
        isAvailable = true
    }
}

// MARK: - Copy

extension AllocationModel {
    /// The whole tree (or the selected lines) as tab-separated text for spreadsheets.
    func tsv(only ids: Set<String>? = nil, returns: [UUID: Double] = [:]) -> String {
        let lines = rows.flatMap(\.flattened).filter { ids == nil || ids!.isEmpty || ids!.contains($0.id) }
        func percent(_ value: Double?) -> String { value.map { TSV.number(Decimal($0 * 100).rounded(4)) } ?? "" }
        func money(_ minor: Int64?) -> String { minor.map { TSV.number(Money(minor: $0, currency: currency).decimalValue) } ?? "" }
        return TSV.string(
            header: ["Name", "Level", "Value", "Currency", "Actual %", "Target %", "Δ pp", "Δ Value", "Return %", "Assigned %"],
            rows: lines.map { line in
                [
                    line.name, String(line.depth), money(line.value), currency, percent(line.share), percent(line.targetShare),
                    percent(line.deltaShare), money(line.deltaValue), percent(line.classificationID.flatMap { returns[$0] }),
                    line.weight.map { TSV.number(Decimal($0) / 100) } ?? "",
                ]
            })
    }
}

extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
