import Foundation
import KontorUI

// Pure building blocks of the rebalancing proposal that the engine does not provide: applying the
// user's exclusions to the taxonomy, target shares that stay meaningful next to untouched
// classifications, what a set of orders really does to every classification, and keeping
// whole-share orders within the money that is available.

/// The taxonomy the engine is asked to rebalance: the stored one with exclusions applied.
///
/// * An excluded classification loses its target **together with everything below it**, so the
///   engine leaves the whole subtree alone (an untargeted sibling keeps its value).
/// * When every targeted member of a sibling group is excluded, nothing in that group can move, so
///   the parent is frozen too — up to the top level (`isEverythingFrozen`).
/// * An excluded vehicle is *pinned*: it still counts towards its classification but is neither
///   bought nor sold. The engine leaves vehicles assigned directly to a node with targeted children
///   untouched, so the other vehicles (and sub-classifications) move into a synthetic 100 % child
///   (`wrappers`) that absorbs the classification's whole amount.
/// * Vehicles that cannot be traded in the current scope (`unavailable`: cash accounts outside the
///   scope, retired or benchmark-only securities that are not held) are dropped; a targeted leaf
///   that has nothing else — or nothing assigned at all — is frozen.
struct RebalancingPlan: Sendable, Equatable {
    enum Freeze: Sendable, Hashable {
        /// Unchecked by the user, or below an unchecked classification.
        case excluded
        /// Everything that could move inside it is excluded.
        case implied
        /// Its only vehicles cannot be traded in this scope.
        case unavailable
        /// It has a target but nothing is assigned to it, so nothing could be bought.
        case empty
    }

    var taxonomy: Taxonomy
    var frozen: [UUID: Freeze] = [:]
    /// Synthetic classification → the real classification it stands in for.
    var wrappers: [UUID: UUID] = [:]
    /// Nothing at all may move: every targeted top-level classification is frozen.
    var isEverythingFrozen = false

    init(
        _ source: Taxonomy, excludedClassifications: Set<UUID> = [], excludedVehicles: Set<AllocationVehicle> = [],
        unavailable: Set<AllocationVehicle> = []
    ) {
        var frozen: [UUID: Freeze] = [:]
        var wrappers: [UUID: UUID] = [:]
        func isUnavailable(_ a: Classification.Assignment) -> Bool { AllocationVehicle(a).map(unavailable.contains) ?? false }
        func isPinned(_ a: Classification.Assignment) -> Bool { AllocationVehicle(a).map(excludedVehicles.contains) ?? false }

        /// The subtree without any target.
        func strip(_ node: Classification, reason: Freeze) -> Classification {
            var n = node
            frozen[n.id] = reason
            n.targetWeight = nil
            n.assignments.removeAll(where: isUnavailable)
            n.children = n.children.map { strip($0, reason: .excluded) }
            return n
        }

        /// One sibling group. `isFrozen`: it had targets and none of them is left.
        func process(_ nodes: [Classification]) -> (nodes: [Classification], isFrozen: Bool) {
            let hadTargets = nodes.contains { $0.targetWeight != nil }
            var live = 0
            var out: [Classification] = []
            for node in nodes {
                if node.targetWeight != nil, excludedClassifications.contains(node.id) {
                    out.append(strip(node, reason: .excluded))
                    continue
                }
                var n = node
                n.assignments.removeAll(where: isUnavailable)
                if n.targetWeight != nil, n.children.isEmpty, n.assignments.isEmpty {
                    // Giving it its target would mean selling elsewhere for money that cannot be
                    // placed; the classifications that can trade share everything instead.
                    out.append(strip(node, reason: node.assignments.isEmpty ? .empty : .unavailable))
                    continue
                }
                let below = process(n.children)
                n.children = below.nodes
                if below.isFrozen {
                    // Its sub-classifications cannot move and directly assigned vehicles never do.
                    if n.targetWeight != nil { frozen[n.id] = .implied }
                    n.targetWeight = nil
                } else if n.assignments.contains(where: isPinned), !n.children.contains(where: { $0.targetWeight != nil }) {
                    let others = n.assignments.filter { !isPinned($0) }
                    if others.isEmpty, n.children.isEmpty {
                        if n.targetWeight != nil { frozen[n.id] = .implied }
                        n.targetWeight = nil
                    } else {
                        let id = Self.wrapperID(for: n.id)
                        wrappers[id] = n.id
                        n.children = [Classification(
                            id: id, name: n.name, color: n.color, targetWeight: 10_000, children: n.children, assignments: others)]
                        n.assignments.removeAll { !isPinned($0) }
                    }
                }
                if n.targetWeight != nil { live += 1 }
                out.append(n)
            }
            return (out, hadTargets && live == 0)
        }

        let result = process(source.root)
        var copy = source
        copy.root = result.nodes
        taxonomy = copy
        self.frozen = frozen
        self.wrappers = wrappers
        isEverythingFrozen = result.isFrozen
    }

    /// Deterministic id of the synthetic child of a classification (stable across recomputations).
    static func wrapperID(for id: UUID) -> UUID {
        var bytes = id.uuid
        bytes.0 ^= 0xA5
        bytes.7 ^= 0x5A
        bytes.15 ^= 0xC3
        return UUID(uuid: bytes)
    }

    /// The real classification behind a node of `taxonomy`.
    func resolve(_ id: UUID) -> UUID { wrappers[id] ?? id }
}

enum RebalancingMath {
    /// The value every targeted classification should have once `total` is spread according to the
    /// targets. Among siblings, the targeted ones share what is left of their parent's value after
    /// the untouched ones (no target) and the parent's directly assigned vehicles keep theirs —
    /// exactly what the engine's buy-and-sell mode aims for. Without untouched siblings this is
    /// the plain product of the target weights along the path.
    static func targetValues(_ roots: [AllocationNode], total: Int64) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        func visit(_ nodes: [AllocationNode], available: Double) {
            let sum = nodes.reduce(0.0) { $0 + Double(max($1.targetWeight ?? 0, 0)) }
            guard sum > 0 else { return }
            let untouched = nodes.reduce(Int64(0)) { $0 + ($1.targetWeight == nil ? $1.value : 0) }
            let pool = max(available - Double(untouched), 0)
            for node in nodes {
                guard let weight = node.targetWeight else { continue }
                let value = pool * Double(max(weight, 0)) / sum
                result[node.id] = value
                visit(node.children, available: value - Double(node.ownValue))
            }
        }
        visit(roots, available: Double(max(total, 0)))
        return result
    }

    /// What a set of value changes does to one classification and its vehicles.
    struct Settled: Sendable, Equatable {
        var id: UUID
        /// Value after the changes (own vehicles + everything below).
        var resulting: Int64
        /// Change of each of `AllocationNode.items`, in the same order.
        var itemEffects: [Int64]
        var children: [Settled]
    }

    /// Applies `changes` (signed minor units per vehicle) to an allocation: every assignment of a
    /// vehicle receives its weight's part, the rest lands in the unassigned bucket. Sequential
    /// division with a running remainder, so the parts of one vehicle add up exactly.
    static func settle(_ roots: [AllocationNode], changes: [AllocationVehicle: Int64]) -> [Settled] {
        var left: [AllocationVehicle: (amount: Int64, weight: Int64)] = [:]
        for (vehicle, amount) in changes where amount != 0 { left[vehicle] = (amount, 10_000) }
        func effect(_ item: AllocationItem) -> Int64 {
            guard var rest = left[item.vehicle], rest.weight > 0 else { return 0 }
            let weight = min(Int64(max(item.weight, 0)), rest.weight)
            let part = mulDiv(rest.amount, weight, rest.weight)
            rest.amount -= part
            rest.weight -= weight
            left[item.vehicle] = rest
            return part
        }
        func visit(_ node: AllocationNode) -> Settled {
            let effects = node.items.map(effect)
            let children = node.children.map(visit)
            let resulting = node.ownValue + effects.reduce(0, +) + children.reduce(Int64(0)) { $0 + $1.resulting }
            return Settled(id: node.id, resulting: resulting, itemEffects: effects, children: children)
        }
        return roots.map(visit)
    }

    /// A purchase in whole shares.
    struct Purchase: Sendable, Equatable {
        /// Whole shares to buy.
        var shares: Int64
        /// Minor units per share.
        var price: Double
        /// Order value in minor units.
        var amount: Int64
    }

    /// Reduces whole-share purchases until they cost at most `shortfall` less — the engine rounds
    /// sales down to whole shares without reducing the purchases they were meant to pay for.
    /// Removes little more than needed: shares that fit into the gap, most expensive first, and at
    /// the end one share of the cheapest security that closes what is left.
    static func trim(_ purchases: [Purchase], shortfall: Int64) -> [Purchase] {
        var result = purchases
        var gap = shortfall
        func cost(_ p: Purchase, shares: Int64) -> Int64 {
            shares <= 0 ? 0 : min(p.amount, FixedMath.saturatingInt64(Double(shares) * p.price))
        }
        while gap > 0 {
            let candidates = result.indices.filter { result[$0].shares > 0 && result[$0].price > 0 }
            let unit: (Int) -> Int64 = { result[$0].amount - cost(result[$0], shares: result[$0].shares - 1) }
            // The most expensive share that still fits into the gap; once none fits, the cheapest
            // one that closes it.
            let fitting = candidates.filter { unit($0) > 0 && unit($0) <= gap }.max { unit($0) < unit($1) }
            let closing = candidates.filter { unit($0) >= gap }.min { unit($0) < unit($1) }
            guard let index = fitting ?? closing else { break }
            let step = unit(index)
            let count = fitting != nil ? min(result[index].shares, max(1, gap / step)) : 1
            let amount = cost(result[index], shares: result[index].shares - count)
            gap -= result[index].amount - amount
            result[index].shares -= count
            result[index].amount = amount
        }
        return result
    }

    /// The fractional counterpart of `trim`: reduces every purchase in proportion so that together
    /// they cost exactly `shortfall` less (or nothing at all). `shares` are raw units here.
    static func scaleDown(_ purchases: [Purchase], shortfall: Int64) -> [Purchase] {
        let total = purchases.reduce(Int64(0)) { $0 + max($1.amount, 0) }
        guard shortfall > 0, total > 0 else { return purchases }
        let parts = apportion(Int(max(total - shortfall, 0)), weights: purchases.map { Int(max($0.amount, 0)) })
        return zip(purchases, parts).map { purchase, part in
            let shares = purchase.price > 0
                ? FixedMath.saturatingInt64(Double(part) / purchase.price * Double(Scale.shares))
                : mulDiv(purchase.shares, Int64(part), max(purchase.amount, 1))
            return Purchase(shares: part == 0 ? 0 : shares, price: purchase.price, amount: Int64(part))
        }
    }

    /// Takes `shares` (raw units) out of `holdings`, largest first. In whole-share mode every leg
    /// is a whole number of shares; what cannot be taken that way is not sold.
    static func saleLegs(_ shares: Int64, holdings: [(depot: UUID, shares: Int64)], wholeShares: Bool) -> [(depot: UUID, shares: Int64)] {
        var legs: [(depot: UUID, shares: Int64)] = []
        var left = shares
        for holding in holdings where left > 0 && holding.shares > 0 {
            let available = wholeShares ? holding.shares / Scale.shares * Scale.shares : holding.shares
            let take = min(left, available)
            guard take > 0 else { continue }
            legs.append((holding.depot, take))
            left -= take
        }
        return legs
    }
}
