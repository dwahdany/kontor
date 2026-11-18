import Foundation
import KontorModel

/// How a rebalancing proposal is computed.
public struct RebalancingOptions: Sendable, Hashable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Buy and sell so that every targeted classification reaches its target.
        case buyAndSell
        /// Never sell: new cash goes to the most underweight classifications first ("water
        /// filling"), which brings the allocation as close to the targets as possible without a
        /// sale. With negative cash (a withdrawal) the mirror image applies: only sales, taken
        /// from the most overweight classifications first, never a purchase.
        case noSales
    }

    /// Fresh money to invest (> 0) or to take out (< 0), in minor units of the reporting currency.
    public var cash: Int64
    public var mode: Mode
    /// Round every security order down to whole shares at the latest price.
    public var wholeShares: Bool

    public init(cash: Int64 = 0, mode: Mode = .buyAndSell, wholeShares: Bool = false) {
        self.cash = cash
        self.mode = mode
        self.wholeShares = wholeShares
    }
}

/// A set of orders that moves an allocation towards its targets.
///
/// **Model.** Targets are relative to the parent classification. Among siblings, those with a
/// target share the value of that group in proportion to their target weights (weights that do not
/// sum to 100 % are normalized); siblings without a target, vehicles assigned directly to a parent
/// and the unassigned bucket are left untouched. Where a level has no targets at all, money is
/// spread in proportion to the current values. Within a leaf classification the amount is
/// distributed over its vehicles in proportion to their current values, or equally if it is empty.
///
/// **Invariants.** `Σ orders.amount + residualCash == cash` exactly. In `.noSales` mode no order
/// has a sign opposite to `cash`. With `.buyAndSell`, fractional shares and every vehicle assigned
/// to exactly one classification at 100 %, each targeted classification ends exactly on target
/// (up to one minor unit of rounding).
public struct RebalancingProposal: Sendable {
    /// The proposal for one classification.
    public struct Node: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let name: String
        public let depth: Int
        /// Value before the proposal.
        public let value: Int64
        /// Target as a fraction of the classified value, after normalizing sibling weights; nil if
        /// this node or an ancestor has no target.
        public let targetShare: Double?
        /// The amount the algorithm wants to add to (+) or remove from (−) this classification.
        public let amount: Int64
        /// Value after executing `orders` (reflects whole-share rounding and split assignments).
        public let resultingValue: Int64
        /// `resultingValue / Σ resulting value of all root classifications`.
        public let resultingShare: Double?
        public let items: [Item]
        public let children: [Node]

        /// This node followed by all descendants, depth first.
        public var flattened: [Node] { [self] + children.flatMap(\.flattened) }
    }

    /// The part of a classification's amount that falls on one of its vehicles.
    public struct Item: Sendable, Hashable, Identifiable {
        public var id: AllocationVehicle { vehicle }
        public let vehicle: AllocationVehicle
        public let name: String
        public let value: Int64
        public let amount: Int64
    }

    /// One order: buy (+) or sell (−) a security, or add to / take from a cash account.
    public struct Order: Sendable, Hashable, Identifiable {
        public var id: AllocationVehicle { vehicle }
        public let vehicle: AllocationVehicle
        public let name: String
        /// Signed order value in minor units (after whole-share rounding).
        public let amount: Int64
        /// Signed number of shares; nil for accounts and for securities without a price.
        public let shares: Shares?
        /// Price used, in minor units of the reporting currency per share.
        public let pricePerShare: Double?

        public var isBuy: Bool { amount > 0 }
    }

    public enum Warning: Sendable, Hashable {
        /// No classification among these siblings (nil = root level) has a target; the amount was
        /// spread in proportion to current values.
        case noTargets(parent: UUID?)
        /// The sibling targets do not sum to 100 % and were normalized.
        case targetsNormalized(parent: UUID?, sum: Int)
        /// A classification should receive money but has nothing assigned to it.
        case noVehicles(classification: UUID)
        /// The vehicle is split over several classifications or only partly assigned, so an order
        /// also moves other buckets; affected classifications may miss their target.
        case sharedVehicle(AllocationVehicle)
        /// No price: the order has no share count and is not rounded to whole shares.
        case missingPrice(securityID: UUID)
        /// A sale larger than the holdings was requested; the excess is in `residualCash`.
        case insufficientHoldings(classification: UUID?)
    }

    public let currency: CurrencyCode
    public let options: RebalancingOptions
    /// Classified value before / after the proposal.
    public let valueBefore: Int64
    public let valueAfter: Int64
    /// The tree, mirroring the allocation.
    public let nodes: [Node]
    /// Net order per vehicle, in order of first appearance in the taxonomy; zero orders are omitted.
    public let orders: [Order]
    /// Σ of positive / |negative| order amounts.
    public let totalBuys: Int64
    public let totalSells: Int64
    /// `cash − (totalBuys − totalSells)`: money left over because of whole-share rounding or
    /// because it could not be placed.
    public let residualCash: Int64
    public let warnings: [Warning]

    /// All nodes, depth first.
    public var flattened: [Node] { nodes.flatMap(\.flattened) }
    public func node(_ id: UUID) -> Node? { flattened.first { $0.id == id } }
}

/// Exact integer apportionment helpers.
enum Apportion {
    /// Splits `total ≥ 0` in proportion to non-negative `weights` (largest-remainder method); the
    /// parts sum to `total` exactly. All zeros if the weights sum to zero.
    static func split(_ total: Int64, _ weights: [Double]) -> [Int64] {
        var out = [Int64](repeating: 0, count: weights.count)
        let sum = weights.reduce(0) { $0 + max($1, 0) }
        guard total > 0, sum > 0, sum.isFinite else { return out }
        var fractions = [Double](repeating: 0, count: weights.count)
        var assigned: Int64 = 0
        for i in weights.indices where weights[i] > 0 {
            let exact = Double(total) * (weights[i] / sum)
            let whole = min(Int64(exact.rounded(.down)), total)
            out[i] = whole
            fractions[i] = exact - Double(whole)
            assigned += whole
        }
        var left = total - assigned
        // Hand the remaining units to the largest fractions (ties: lowest index).
        let order = weights.indices.filter { weights[$0] > 0 }.sorted {
            fractions[$0] != fractions[$1] ? fractions[$0] > fractions[$1] : $0 < $1
        }
        var k = 0
        while left > 0, !order.isEmpty {
            out[order[k % order.count]] += 1
            left -= 1
            k += 1
        }
        k = order.count - 1
        while left < 0, !order.isEmpty { // floating-point overshoot; cannot exceed a few units
            let i = order[((k % order.count) + order.count) % order.count]
            if out[i] > 0 {
                out[i] -= 1
                left += 1
            }
            k -= 1
        }
        return out
    }

    /// Water filling: distributes `amount > 0` over buckets with current `values` and target
    /// `weights` so that the buckets furthest below their target ratio are raised to a common
    /// level first. No bucket receives a negative amount; buckets with weight 0 receive nothing.
    static func fill(_ amount: Int64, values: [Int64], weights: [Double]) -> [Int64] {
        let order = values.indices.filter { weights[$0] > 0 }
            .sorted { Double(values[$0]) / weights[$0] < Double(values[$1]) / weights[$1] }
        guard amount > 0, !order.isEmpty else { return [Int64](repeating: 0, count: values.count) }
        var sumV = 0.0, sumW = 0.0, level = 0.0
        for (k, i) in order.enumerated() {
            sumV += Double(values[i])
            sumW += weights[i]
            level = (Double(amount) + sumV) / sumW
            if k + 1 < order.count {
                let j = order[k + 1]
                if level <= Double(values[j]) / weights[j] { break }
            }
        }
        var ideal = [Double](repeating: 0, count: values.count)
        for i in order { ideal[i] = max(level * weights[i] - Double(values[i]), 0) }
        return split(amount, ideal)
    }

    /// The mirror image of `fill`: takes `amount > 0` out of the buckets furthest above their
    /// target ratio (buckets with weight 0 are emptied first). Never takes more than a bucket
    /// holds; returns the (positive) amounts taken, which sum to `min(amount, Σ max(values, 0))`.
    static func drain(_ amount: Int64, values: [Int64], weights: [Double]) -> [Int64] {
        var out = [Int64](repeating: 0, count: values.count)
        let available = values.reduce(Int64(0)) { $0 + max($1, 0) }
        var needed = min(amount, available)
        guard needed > 0 else { return out }
        if needed == available { return values.map { max($0, 0) } }

        let untargeted = values.indices.filter { weights[$0] <= 0 && values[$0] > 0 }
        let untargetedValue = untargeted.reduce(Int64(0)) { $0 + values[$1] }
        if untargetedValue > 0 {
            if needed <= untargetedValue {
                return split(needed, values.indices.map { weights[$0] <= 0 ? Double(max(values[$0], 0)) : 0 })
            }
            for i in untargeted { out[i] = values[i] }
            needed -= untargetedValue
        }
        let order = values.indices.filter { weights[$0] > 0 && values[$0] > 0 }
            .sorted { Double(values[$0]) / weights[$0] > Double(values[$1]) / weights[$1] }
        var sumV = 0.0, sumW = 0.0, level = 0.0
        for (k, i) in order.enumerated() {
            sumV += Double(values[i])
            sumW += weights[i]
            level = (sumV - Double(needed)) / sumW
            if k + 1 < order.count {
                let j = order[k + 1]
                if level >= Double(values[j]) / weights[j] { break }
            }
        }
        var ideal = [Double](repeating: 0, count: values.count)
        for i in order { ideal[i] = min(max(Double(values[i]) - level * weights[i], 0), Double(values[i])) }
        let parts = split(needed, ideal)
        var overflow: Int64 = 0
        for i in order {
            out[i] = min(parts[i], values[i])
            overflow += parts[i] - out[i]
        }
        // Rounding may push a bucket one unit past its holdings; move that unit elsewhere.
        for i in order where overflow > 0 {
            let room = min(values[i] - out[i], overflow)
            out[i] += room
            overflow -= room
        }
        return out
    }
}

extension TaxonomyAllocation {
    /// Proposes orders that move this allocation towards its targets. Pure; see
    /// `RebalancingProposal` for the model and its invariants.
    public func rebalancing(_ options: RebalancingOptions = RebalancingOptions()) -> RebalancingProposal {
        var warnings: [RebalancingProposal.Warning] = []
        func warn(_ w: RebalancingProposal.Warning) { if !warnings.contains(w) { warnings.append(w) } }
        let noSales = options.mode == .noSales

        struct Plan {
            var node: AllocationNode
            var amount: Int64
            var targetShare: Double?
            var itemAmounts: [Int64]
            var children: [Plan]
        }

        /// Signed proportional spread; falls back to `fallback` weights if the primary ones are zero.
        func spread(_ amount: Int64, weights: [Double], fallback: [Double]?, at id: UUID?) -> [Int64] {
            guard amount != 0 else { return [Int64](repeating: 0, count: weights.count) }
            var w = weights
            if !w.contains(where: { $0 > 0 }) {
                if amount > 0, let fallback, fallback.contains(where: { $0 > 0 }) {
                    w = fallback
                } else {
                    if amount < 0 {
                        warn(.insufficientHoldings(classification: id))
                    } else if let id {
                        warn(.noVehicles(classification: id))
                    } else {
                        warn(.noTargets(parent: nil))
                    }
                    return [Int64](repeating: 0, count: weights.count)
                }
            }
            if amount > 0 { return Apportion.split(amount, w) }
            // Sales are limited to what is held.
            let available = Int64(w.reduce(0, +).rounded(.down))
            let sell = min(-amount, available)
            if sell < -amount { warn(.insufficientHoldings(classification: id)) }
            return Apportion.split(sell, w).map { -$0 }
        }

        /// Distributes `amount` over the children (and, where a level has no targets, the items)
        /// of one parent.
        func distribute(
            _ amount: Int64, children: [AllocationNode], items: [AllocationItem], parent: UUID?, parentShare: Double?
        ) -> (children: [Plan], itemAmounts: [Int64]) {
            let itemValues = items.map { Double(max($0.value, 0)) }
            if children.isEmpty {
                let equal = [Double](repeating: 1, count: items.count)
                return ([], spread(amount, weights: itemValues, fallback: equal, at: parent))
            }
            let weights = children.map { Double(max($0.targetWeight ?? 0, 0)) }
            let weightSum = weights.reduce(0, +)
            var childAmounts = [Int64](repeating: 0, count: children.count)
            var itemAmounts = [Int64](repeating: 0, count: items.count)
            var shares = [Double?](repeating: nil, count: children.count)

            if weightSum <= 0 {
                if amount != 0 { warn(.noTargets(parent: parent)) }
                let all = spread(
                    amount, weights: children.map { Double(max($0.value, 0)) } + itemValues,
                    fallback: [Double](repeating: 1, count: children.count) + [Double](repeating: 0, count: items.count),
                    at: parent)
                childAmounts = Array(all[..<children.count])
                itemAmounts = Array(all[children.count...])
            } else {
                let targetSum = children.reduce(0) { $0 + max($1.targetWeight ?? 0, 0) }
                if targetSum != 10_000 || children.contains(where: { $0.targetWeight == nil }) {
                    warn(.targetsNormalized(parent: parent, sum: targetSum))
                }
                for i in children.indices where children[i].targetWeight != nil {
                    shares[i] = parentShare.map { $0 * weights[i] / weightSum }
                }
                let targeted = children.indices.filter { children[$0].targetWeight != nil }
                let values = children.map(\.value)
                if noSales {
                    let targetedValues = children.indices.map { children[$0].targetWeight != nil ? values[$0] : 0 }
                    if amount > 0 {
                        childAmounts = Apportion.fill(amount, values: targetedValues, weights: weights)
                    } else if amount < 0 {
                        let taken = Apportion.drain(-amount, values: targetedValues, weights: weights)
                        childAmounts = taken.map { -$0 }
                        if amount + taken.reduce(0, +) != 0 { warn(.insufficientHoldings(classification: parent)) }
                    }
                } else {
                    let current = targeted.reduce(Int64(0)) { $0 + values[$1] }
                    var newTotal = current + amount
                    if newTotal < 0 {
                        warn(.insufficientHoldings(classification: parent))
                        newTotal = 0
                    }
                    let newValues = Apportion.split(newTotal, weights)
                    for i in targeted { childAmounts[i] = newValues[i] - values[i] }
                }
            }
            var plans: [Plan] = []
            plans.reserveCapacity(children.count)
            for (i, child) in children.enumerated() {
                let below = distribute(
                    childAmounts[i], children: child.children, items: child.items, parent: child.id,
                    parentShare: shares[i])
                plans.append(Plan(
                    node: child, amount: childAmounts[i], targetShare: shares[i], itemAmounts: below.itemAmounts,
                    children: below.children))
            }
            return (plans, itemAmounts)
        }

        let plans = distribute(options.cash, children: roots, items: [], parent: nil, parentShare: 1).children

        // Net ideal amount per vehicle, in order of first appearance.
        struct VehicleTotal {
            var name: String
            var amount: Int64 = 0
            var price: Double?
            var assignedWeight = 0
            var itemCount = 0
        }
        var vehicleOrder: [AllocationVehicle] = []
        var vehicles: [AllocationVehicle: VehicleTotal] = [:]
        func collect(_ plan: Plan) {
            for (i, item) in plan.node.items.enumerated() {
                if vehicles[item.vehicle] == nil {
                    vehicles[item.vehicle] = VehicleTotal(name: item.name, price: item.pricePerShare)
                    vehicleOrder.append(item.vehicle)
                }
                vehicles[item.vehicle]!.amount += plan.itemAmounts[i]
                vehicles[item.vehicle]!.assignedWeight += item.weight
                vehicles[item.vehicle]!.itemCount += 1
            }
            for child in plan.children { collect(child) }
        }
        for plan in plans { collect(plan) }

        // Orders, optionally rounded to whole shares (towards zero, so budgets are never exceeded).
        var orders: [RebalancingProposal.Order] = []
        var executed: [AllocationVehicle: Int64] = [:]
        var buys: Int64 = 0, sells: Int64 = 0
        for vehicle in vehicleOrder {
            guard let v = vehicles[vehicle], v.amount != 0 else { continue }
            var amount = v.amount
            var shares: Shares?
            if case .security(let id) = vehicle {
                if let price = v.price, price > 0 {
                    var count = Double(amount) / price
                    if options.wholeShares {
                        count = count.rounded(.towardZero)
                        amount = FixedMath.saturatingInt64(count * price)
                        if abs(amount) > abs(v.amount) { amount = v.amount } // rounding of the price itself
                    }
                    shares = Shares(raw: FixedMath.saturatingInt64(count * Double(Scale.shares)))
                } else {
                    warn(.missingPrice(securityID: id))
                }
            }
            if v.itemCount > 1 || v.assignedWeight < 10_000 { warn(.sharedVehicle(vehicle)) }
            executed[vehicle] = amount
            guard amount != 0 else { continue }
            if amount > 0 { buys += amount } else { sells -= amount }
            orders.append(RebalancingProposal.Order(
                vehicle: vehicle, name: v.name, amount: amount, shares: shares, pricePerShare: v.price))
        }

        // What each order really does to each classification: an order of X changes every
        // assignment of the vehicle by X × weight, the remainder lands in the unassigned bucket.
        var orderLeft: [AllocationVehicle: (amount: Int64, weight: Int64)] = [:]
        for (vehicle, amount) in executed { orderLeft[vehicle] = (amount, 10_000) }
        func effect(_ item: AllocationItem) -> Int64 {
            guard var left = orderLeft[item.vehicle], left.weight > 0 else { return 0 }
            let w = min(Int64(item.weight), left.weight)
            let part = mulDiv(left.amount, w, left.weight)
            left.amount -= part
            left.weight -= w
            orderLeft[item.vehicle] = left
            return part
        }
        struct Result {
            var plan: Plan
            var resulting: Int64
            var children: [Result]
        }
        func settle(_ plan: Plan) -> Result {
            var resulting = plan.node.ownValue
            for item in plan.node.items { resulting += effect(item) }
            let children = plan.children.map(settle)
            for c in children { resulting += c.resulting }
            return Result(plan: plan, resulting: resulting, children: children)
        }
        let results = plans.map(settle)
        let after = results.reduce(Int64(0)) { $0 + $1.resulting }
        func node(_ r: Result) -> RebalancingProposal.Node {
            let n = r.plan.node
            return RebalancingProposal.Node(
                id: n.id, name: n.name, depth: n.depth, value: n.value, targetShare: r.plan.targetShare,
                amount: r.plan.amount, resultingValue: r.resulting,
                resultingShare: after > 0 ? Double(r.resulting) / Double(after) : nil,
                items: n.items.enumerated().map {
                    RebalancingProposal.Item(
                        vehicle: $1.vehicle, name: $1.name, value: $1.value, amount: r.plan.itemAmounts[$0])
                },
                children: r.children.map(node))
        }

        return RebalancingProposal(
            currency: currency, options: options, valueBefore: classifiedValue, valueAfter: after,
            nodes: results.map(node), orders: orders, totalBuys: buys, totalSells: sells,
            residualCash: options.cash - (buys - sells), warnings: warnings)
    }
}

extension Ledger {
    /// Convenience: the allocation of `scope` across `taxonomy` on `day`, and the rebalancing
    /// proposal for it.
    public func rebalancing(
        for taxonomy: Taxonomy, on day: Day, options: RebalancingOptions = RebalancingOptions(),
        scope: Scope = .portfolio
    ) -> RebalancingProposal {
        allocation(for: taxonomy, on: day, scope: scope).rebalancing(options)
    }
}
