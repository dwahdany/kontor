import Foundation
import KontorModel

/// Something a taxonomy can classify: a security or a cash account.
public enum AllocationVehicle: Hashable, Sendable, Codable {
    case security(UUID)
    case account(UUID)

    /// The id of the security or account.
    public var id: UUID {
        switch self {
        case .security(let id), .account(let id): return id
        }
    }
}

/// The part of one vehicle that is assigned to a classification (or left unassigned).
public struct AllocationItem: Sendable, Hashable, Identifiable {
    public var id: AllocationVehicle { vehicle }
    public let vehicle: AllocationVehicle
    /// Name of the security or account.
    public let name: String
    /// Share of the vehicle counted here, in basis points. Assignments of a vehicle whose weights
    /// exceed 100 % in total are scaled down proportionally (see `TaxonomyAllocation.overAssigned`).
    public let weight: Int
    /// The weighted part of the vehicle's value, in minor units of the reporting currency.
    public let value: Int64
    /// Securities: total shares held in the scope (not multiplied by `weight`); zero if not held.
    public let shares: Shares?
    /// Securities: the price of one share on the allocation day in minor units of the reporting
    /// currency; nil without a price or exchange rate.
    public let pricePerShare: Double?
}

/// One classification with its actual and target allocation.
public struct AllocationNode: Sendable, Hashable, Identifiable {
    /// The classification's id.
    public let id: UUID
    public let name: String
    /// "#RRGGBB"
    public let color: String
    /// 0 for root classifications.
    public let depth: Int
    /// Actual value: own assignments plus all descendants.
    public let value: Int64
    /// The part of `value` assigned directly to this classification.
    public let ownValue: Int64
    /// `value / total value` of the allocation; nil if the total is not positive.
    public let share: Double?
    /// `value / parent value` (root nodes: same as `share`).
    public let shareOfParent: Double?
    /// Target relative to the parent in basis points, as stored in the taxonomy.
    public let targetWeight: Int?
    /// Absolute target as a fraction of the target base: the product of the target weights along
    /// the path from the root. Nil if this node or one of its ancestors has no target.
    public let targetShare: Double?
    /// `target base × targetShare`.
    public let targetValue: Int64?
    /// `value − targetValue` (positive = overweight).
    public let deltaValue: Int64?
    /// `value / target base − targetShare` (positive = overweight).
    public let deltaShare: Double?
    /// Vehicles assigned directly to this classification (also those currently worth nothing).
    public let items: [AllocationItem]
    public let children: [AllocationNode]

    /// This node followed by all descendants, depth first.
    public var flattened: [AllocationNode] { [self] + children.flatMap(\.flattened) }
}

/// The allocation of a scope across a taxonomy at one day.
///
/// Invariants (exact, in minor units): every node's `value` is the sum of its `items` and
/// `children`; `classifiedValue == Σ roots.value`; `totalValue == classifiedValue + unassignedValue`,
/// and `totalValue` equals the snapshot's total value.
public struct TaxonomyAllocation: Sendable {
    public let taxonomyID: UUID
    public let taxonomyName: String
    public let day: Day
    public let currency: CurrencyCode
    /// Value of everything in scope.
    public let totalValue: Int64
    /// Σ value of the root classifications.
    public let classifiedValue: Int64
    /// The tree, mirroring `Taxonomy.root`.
    public let roots: [AllocationNode]
    /// The not (fully) assigned remainder of each security and account, with the remaining weight.
    public let unassigned: [AllocationItem]
    public let unassignedValue: Int64
    /// The value targets refer to: `classifiedValue`, or `totalValue` if the allocation was
    /// requested with `includeUnassignedInTargets`.
    public let targetBase: Int64
    /// Vehicles whose assignment weights exceed 100 %; their weights were scaled down to sum to 100 %.
    public let overAssigned: [AllocationVehicle]
    public let diagnostics: [EngineDiagnostic]

    /// All nodes, depth first.
    public var flattened: [AllocationNode] { roots.flatMap(\.flattened) }
    /// Finds a node by classification id.
    public func node(_ id: UUID) -> AllocationNode? { flattened.first { $0.id == id } }
    /// `unassignedValue / totalValue`.
    public var unassignedShare: Double? { totalValue > 0 ? Double(unassignedValue) / Double(totalValue) : nil }
}

/// Time-weighted and money-weighted performance of one classification.
public struct ClassificationPerformance: Sendable, Hashable, Identifiable {
    public var id: UUID { classificationID }
    public let classificationID: UUID
    public let initialValue: Int64
    public let finalValue: Int64
    public let inflows: Int64
    public let outflows: Int64
    public let ttwror: Double
    public let ttwrorAnnualized: Double?
    public let irr: Double?

    /// `finalValue − initialValue − inflows + outflows`.
    public var absolutePerformance: Int64 { finalValue - initialValue - inflows + outflows }
}

// MARK: - Assignment weights

/// Sum of assignment weights per vehicle across a whole taxonomy (negative weights count as 0).
func assignmentWeightTotals(_ taxonomy: Taxonomy) -> [AllocationVehicle: Int] {
    var totals: [AllocationVehicle: Int] = [:]
    func visit(_ c: Classification) {
        for a in c.assignments {
            guard let vehicle = AllocationVehicle(a) else { continue }
            totals[vehicle, default: 0] += max(a.weight, 0)
        }
        for child in c.children { visit(child) }
    }
    for c in taxonomy.root { visit(c) }
    return totals
}

/// The weight an assignment effectively carries once over-assigned vehicles are scaled to 100 %.
@inline(__always)
func effectiveWeight(_ weight: Int, total: Int) -> Int {
    let w = max(weight, 0)
    return total > 10_000 ? Int(mulDiv(Int64(w), 10_000, Int64(total))) : w
}

extension AllocationVehicle {
    /// The vehicle an assignment refers to; nil if it names neither a security nor an account.
    init?(_ assignment: Classification.Assignment) {
        if let id = assignment.securityID {
            self = .security(id)
        } else if let id = assignment.accountID {
            self = .account(id)
        } else {
            return nil
        }
    }
}

extension Taxonomy {
    /// Finds a classification anywhere in the tree.
    public func classification(_ id: UUID) -> Classification? {
        func find(_ nodes: [Classification]) -> Classification? {
            for c in nodes {
                if c.id == id { return c }
                if let hit = find(c.children) { return hit }
            }
            return nil
        }
        return find(root)
    }

    /// The weighted `Scope` covering everything assigned to a classification (and, by default, to
    /// its descendants). Weights of over-assigned vehicles are scaled exactly like in
    /// `TaxonomyAllocation`. Nil if the classification does not exist.
    public func scope(forClassification id: UUID, includingChildren: Bool = true) -> Scope? {
        guard let node = classification(id) else { return nil }
        let totals = assignmentWeightTotals(self)
        var securities: [UUID: Int] = [:], accounts: [UUID: Int] = [:]
        func collect(_ c: Classification) {
            for a in c.assignments {
                guard let vehicle = AllocationVehicle(a) else { continue }
                let w = effectiveWeight(a.weight, total: totals[vehicle] ?? 0)
                switch vehicle {
                case .security(let sid): securities[sid] = min(securities[sid, default: 0] + w, 10_000)
                case .account(let aid): accounts[aid] = min(accounts[aid, default: 0] + w, 10_000)
                }
            }
            if includingChildren { for child in c.children { collect(child) } }
        }
        collect(node)
        return .weighted(securities: securities, accounts: accounts)
    }
}

// MARK: - Allocation

extension Ledger {
    /// The allocation of `scope` across `taxonomy` at the end of `day`.
    ///
    /// - Parameter includeUnassignedInTargets: if false (default) target values refer to the
    ///   classified value only; if true to the total value, i.e. unassigned holdings count as
    ///   deviation from the targets.
    public func allocation(
        for taxonomy: Taxonomy, on day: Day, scope: Scope = .portfolio, includeUnassignedInTargets: Bool = false
    ) -> TaxonomyAllocation {
        allocation(
            for: taxonomy, snapshot: snapshot(on: day, scope: scope),
            includeUnassignedInTargets: includeUnassignedInTargets)
    }

    /// The allocation of an existing snapshot across `taxonomy` (no ledger replay).
    public func allocation(
        for taxonomy: Taxonomy, snapshot: Snapshot, includeUnassignedInTargets: Bool = false
    ) -> TaxonomyAllocation {
        struct Remaining {
            var value: Int64
            var weight: Int64
        }
        let totals = assignmentWeightTotals(taxonomy)
        var positions = [UUID: Snapshot.Position](minimumCapacity: snapshot.positions.count)
        for p in snapshot.positions { positions[p.securityID] = p }
        var remaining = [AllocationVehicle: Remaining](minimumCapacity: positions.count + snapshot.cash.count)
        for p in snapshot.positions {
            remaining[.security(p.securityID)] = Remaining(
                value: p.value.minor, weight: Int64(max(totals[.security(p.securityID)] ?? 0, 10_000)))
        }
        for c in snapshot.cash {
            remaining[.account(c.accountID)] = Remaining(
                value: c.value.minor, weight: Int64(max(totals[.account(c.accountID)] ?? 0, 10_000)))
        }
        let dayRaw = snapshot.day.rawValue

        func pricePerShare(_ index: Int) -> Double? {
            let pi = priceIndex(index, on: dayRaw)
            guard pi >= 0 else { return nil }
            let rate = rateToReporting(securityCurrency[index], on: dayRaw)
            guard !rate.isNaN else { return nil }
            return Double(priceValues[pi]) / Double(Scale.price) * rate * Double(Scale.amount)
        }

        /// Takes the next assignment's part out of the vehicle's remaining value. Sequential
        /// division with a running remainder keeps Σ parts + unassigned == value exactly.
        func take(_ vehicle: AllocationVehicle, weight: Int) -> Int64 {
            guard var r = remaining[vehicle], r.weight > 0 else { return 0 }
            let w = min(Int64(max(weight, 0)), r.weight)
            let part = mulDiv(r.value, w, r.weight)
            r.value -= part
            r.weight -= w
            remaining[vehicle] = r
            return part
        }

        func item(_ vehicle: AllocationVehicle, weight: Int, value: Int64) -> AllocationItem? {
            switch vehicle {
            case .security(let id):
                guard let index = securityIndex(id) else { return nil }
                return AllocationItem(
                    vehicle: vehicle, name: securities[index].name, weight: weight, value: value,
                    shares: positions[id]?.shares ?? .zero, pricePerShare: pricePerShare(index))
            case .account(let id):
                guard let index = accountIndex(id) else { return nil }
                return AllocationItem(
                    vehicle: vehicle, name: accounts[index].name, weight: weight, value: value, shares: nil,
                    pricePerShare: nil)
            }
        }

        // Pass 1 (depth first, taxonomy order): values.
        struct Raw {
            var source: Classification
            var items: [AllocationItem]
            var own: Int64
            var value: Int64
            var children: [Raw]
        }
        func measure(_ c: Classification) -> Raw {
            var items: [AllocationItem] = []
            var own: Int64 = 0
            for a in c.assignments {
                guard let vehicle = AllocationVehicle(a) else { continue }
                let value = take(vehicle, weight: a.weight)
                guard let entry = item(
                    vehicle, weight: effectiveWeight(a.weight, total: totals[vehicle] ?? 0), value: value)
                else { continue }
                items.append(entry)
                own += value
            }
            let children = c.children.map(measure)
            return Raw(source: c, items: items, own: own, value: children.reduce(own) { $0 + $1.value }, children: children)
        }
        let raw = taxonomy.root.map(measure)

        // Unassigned remainders, in ledger order.
        var unassigned: [AllocationItem] = []
        var unassignedValue: Int64 = 0
        func rest(_ vehicle: AllocationVehicle) {
            guard let r = remaining[vehicle], r.value != 0, let entry = item(vehicle, weight: Int(r.weight), value: r.value)
            else { return }
            unassigned.append(entry)
            unassignedValue += r.value
        }
        for p in snapshot.positions { rest(.security(p.securityID)) }
        for c in snapshot.cash { rest(.account(c.accountID)) }

        // Pass 2: shares and targets.
        let classified = raw.reduce(Int64(0)) { $0 + $1.value }
        let total = classified + unassignedValue
        let base = includeUnassignedInTargets ? total : classified
        func finish(_ r: Raw, depth: Int, parentValue: Int64, parentTarget: (share: Double, value: Int64)?) -> AllocationNode {
            var target: (share: Double, value: Int64)?
            if let parentTarget, let w = r.source.targetWeight {
                target = (parentTarget.share * Double(w) / 10_000, mulDiv(parentTarget.value, Int64(w), 10_000))
            }
            return AllocationNode(
                id: r.source.id, name: r.source.name, color: r.source.color, depth: depth, value: r.value,
                ownValue: r.own,
                share: total > 0 ? Double(r.value) / Double(total) : nil,
                shareOfParent: parentValue > 0 ? Double(r.value) / Double(parentValue) : nil,
                targetWeight: r.source.targetWeight, targetShare: target?.share, targetValue: target?.value,
                deltaValue: target.map { r.value - $0.value },
                deltaShare: target.flatMap { t in base > 0 ? Double(r.value) / Double(base) - t.share : nil },
                items: r.items,
                children: r.children.map { finish($0, depth: depth + 1, parentValue: r.value, parentTarget: target) })
        }
        let roots = raw.map { finish($0, depth: 0, parentValue: total, parentTarget: (1, base)) }

        return TaxonomyAllocation(
            taxonomyID: taxonomy.id, taxonomyName: taxonomy.name, day: snapshot.day, currency: snapshot.currency,
            totalValue: total, classifiedValue: classified, roots: roots, unassigned: unassigned,
            unassignedValue: unassignedValue, targetBase: base,
            overAssigned: totals.filter { $0.value > 10_000 }.map(\.key).sorted { $0.id.uuidString < $1.id.uuidString },
            diagnostics: snapshot.diagnostics)
    }

    /// TTWROR and IRR of one classification (including its descendants) over `interval`, measured
    /// on the weighted scope `Taxonomy.scope(forClassification:)`. Nil for an unknown classification.
    /// Costs one daily valuation pass.
    public func classificationPerformance(
        _ classificationID: UUID, of taxonomy: Taxonomy, in interval: DayInterval
    ) -> ClassificationPerformance? {
        guard let scope = taxonomy.scope(forClassification: classificationID) else { return nil }
        let series = valuation(in: interval, scope: scope)
        let returns = series.returns()
        return ClassificationPerformance(
            classificationID: classificationID, initialValue: series.initialValue, finalValue: series.finalValue,
            inflows: series.totalInflows, outflows: series.totalOutflows, ttwror: returns.total,
            ttwrorAnnualized: returns.annualized, irr: series.irr())
    }

    /// Performance of every classification of `taxonomy`, depth first (same order as
    /// `TaxonomyAllocation.flattened`). Costs one daily valuation pass per classification; for
    /// large taxonomies call `classificationPerformance(_:of:in:)` per node from concurrent tasks.
    public func classificationPerformance(of taxonomy: Taxonomy, in interval: DayInterval) -> [ClassificationPerformance] {
        var out: [ClassificationPerformance] = []
        func visit(_ c: Classification) {
            if let p = classificationPerformance(c.id, of: taxonomy, in: interval) { out.append(p) }
            for child in c.children { visit(child) }
        }
        for c in taxonomy.root { visit(c) }
        return out
    }
}
