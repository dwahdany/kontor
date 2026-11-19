import SwiftUI
import KontorUI

// The Rebalancing tab's model: the engine's `RebalancingProposal` shaped into table rows, readable
// warnings and draft transactions. Built off the main actor (`store.analyze` / `analysisTask`).
//
// One base everywhere: shares, targets and weights refer to the **classified value** in scope —
// the same base the Allocation tab uses. "After" columns show what the draft transactions really
// do, so `Current + Buy/Sell = After` on every line and the lines add up to the value in scope
// plus the money that is invested (or minus what is withdrawn).

/// One line of the "By Classification" table: a classification, a vehicle's part inside it, or the
/// unassigned remainder.
struct ProposalRow: Identifiable, Sendable, Hashable {
    var id: String
    var classificationID: UUID?
    var vehicle: AllocationVehicle?
    var name: String
    var depth: Int
    var color: Color?
    var value: Int64
    /// Share of the classified value before the proposal.
    var share: Double?
    /// Share of the classified value this classification should have afterwards.
    var targetShare: Double?
    /// What the orders add (+) or remove (−) here: `resultingValue − value`.
    var amount: Int64
    var resultingValue: Int64?
    var resultingShare: Double?
    /// Left untouched (unchecked, below an unchecked classification, or nothing in it can move).
    var isExcluded: Bool
    /// "excluded", "not in scope", … next to the name.
    var badge: String?
    /// Classifications only: whether the checkbox is meaningful (it has a target).
    var canExclude: Bool
    /// The "Unassigned" line: listed for completeness, never traded.
    var isUnassigned = false
    var children: [ProposalRow]

    var flattened: [ProposalRow] { [self] + children.flatMap(\.flattened) }
}

/// One line of the "By Security" table: the net order for a security or cash account.
struct VehicleRow: Identifiable, Sendable, Hashable {
    var id: String { vehicle.token }
    var vehicle: AllocationVehicle
    var name: String
    var classes: String
    /// Minor units of the reporting currency per share.
    var price: Double?
    var sharesHeld: Shares?
    /// The part of the position that is assigned in this taxonomy (normally all of it).
    var value: Int64
    var share: Double?
    /// Securities: the order. Accounts: what the transactions add to or take from the balance.
    var amount: Int64
    var orderShares: Shares?
    var resultingValue: Int64
    var resultingShare: Double?
    var isExcluded: Bool
}

/// A transaction the proposal would create, ready to be reviewed.
struct DraftTransaction: Identifiable, Sendable, Hashable {
    /// Stable across recomputations: kind + security + depot. The review sheet keys "unchecked" on
    /// it, so a recomputation (new quotes, another edit) never re-checks a draft.
    var id: String
    var kind: Transaction.Kind
    var securityName: String
    var depotName: String
    var accountName: String
    var shares: Shares?
    var amount: Money
    /// Set when the order cannot be turned into a booking (no price, no depot, …).
    var problem: String?
    /// nil when `problem` is set.
    var transaction: Transaction?
}

/// A cash account the drafts settle against, with everything needed to project its balance for
/// any selection of drafts.
struct AccountProjection: Identifiable, Sendable, Hashable {
    var id: UUID
    var name: String
    var currency: CurrencyCode
    /// Balance on the proposal's day, in the account's currency.
    var balance: Int64
    /// Draft id → signed change of the balance, in the account's currency.
    var effects: [String: Int64]
    /// Change by the optional deposit / withdrawal draft.
    var cashEffect: Int64

    func projected(skipping skipped: Set<String> = [], includesCash: Bool) -> Int64 {
        effects.reduce(balance + (includesCash ? cashEffect : 0)) { $0 + (skipped.contains($1.key) ? 0 : $1.value) }
    }
}

struct RebalancingWarning: Identifiable, Sendable, Hashable {
    enum Level: Sendable { case info, warning }
    var id: String
    var level: Level
    var text: String
}

struct RebalancingModel: Sendable {
    var taxonomyID: UUID
    var taxonomyName: String
    var currency: CurrencyCode
    var day: Day
    /// False for scopes a proposal cannot be booked for (a single account, a classification).
    var isScopeSupported = true
    var cash: Int64 = 0
    /// Purchases / sales of securities (positive magnitudes).
    var securityBuys: Int64 = 0
    var securitySells: Int64 = 0
    /// Net change the proposal plans for cash accounts that are part of the taxonomy (+ keep more).
    var accountChange: Int64 = 0
    var hasAccountOrders = false
    /// `cash − purchases + sales − accountChange`: > 0 is money that stays on the settlement
    /// accounts on top of the plan, < 0 is money the cash accounts give on top of the plan (sales
    /// rounded down to whole shares) or that cannot be raised at all (`unraisedCash`).
    var residualCash: Int64 = 0
    /// Withdrawals only: the part of the requested amount that neither sales nor the cash in scope
    /// can provide.
    var unraisedCash: Int64 = 0
    /// Classified value in scope before / after the transactions.
    var valueBefore: Int64 = 0
    var valueAfter: Int64 = 0
    /// Value in scope that is not assigned in this taxonomy (never traded).
    var unassignedValue: Int64 = 0
    var hasTargets = false
    var hasVehicles = false
    /// Largest |actual − target| over all targeted classifications, before and after.
    var driftBefore: Double?
    var driftAfter: Double?
    /// Exclusions that apply to this taxonomy.
    var exclusionCount = 0

    var classRows: [ProposalRow] = []
    var vehicleRows: [VehicleRow] = []
    var warnings: [RebalancingWarning] = []
    var drafts: [DraftTransaction] = []
    /// The cash accounts the drafts settle against (and the one the cash draft is booked on).
    var accounts: [AccountProjection] = []
    /// Optional booking of the money itself: a deposit of the cash to invest (or a withdrawal of
    /// what the proposal really raises) on the account most drafts settle against. Offered, never
    /// added by default.
    var cashDraft: DraftTransaction?

    /// Securities with an order.
    var orderCount: Int { vehicleRows.count { $0.vehicle.isSecurity && $0.amount != 0 } }
    var bookableDrafts: [DraftTransaction] { drafts.filter { $0.transaction != nil } }

    /// The taxonomy the engine sees for `inputs` (see `RebalancingPlan`).
    static func plan(_ taxonomy: Taxonomy, inputs: RebalancingInputs, unavailable: Set<AllocationVehicle> = []) -> RebalancingPlan {
        RebalancingPlan(
            taxonomy, excludedClassifications: inputs.excludedClassifications, excludedVehicles: inputs.excludedVehicles,
            unavailable: unavailable)
    }

    init(_ analysis: Analysis, taxonomy: Taxonomy, inputs rawInputs: RebalancingInputs, today: Day) {
        let ledger = analysis.ledger
        let snapshot = analysis.snapshot
        let inputs = rawInputs.sanitized(for: taxonomy)
        taxonomyID = taxonomy.id
        taxonomyName = taxonomy.name
        currency = snapshot.currency
        day = today
        cash = inputs.cash
        exclusionCount = inputs.exclusionCount
        hasTargets = taxonomy.hasTargets

        // Which depots the proposal may trade in. Buying and selling needs depots, and a weighted
        // slice of positions cannot be booked, so other scopes get no proposal.
        let scopeDepots: Set<UUID>?
        switch analysis.scope {
        case .portfolio:
            scopeDepots = nil
        case .subset(let depots, _) where !depots.isEmpty:
            scopeDepots = depots
        default:
            isScopeSupported = false
            return
        }
        let isNarrowed = scopeDepots != nil

        // What cannot be traded here: cash accounts outside the scope, and securities that are not
        // held and cannot sensibly be bought (retired, or a benchmark that was never traded).
        var unavailable = Set<AllocationVehicle>()
        let inScopeAccounts = Set(snapshot.cash.map(\.accountID))
        let benchmarks = Set(ledger.settings.benchmarkSecurityIDs)
        let held = Set(snapshot.positions.map(\.securityID))
        for vehicle in taxonomy.assignedWeights.keys {
            switch vehicle {
            case .account(let id):
                if !inScopeAccounts.contains(id) { unavailable.insert(vehicle) }
            case .security(let id):
                guard !held.contains(id), let security = ledger.security(id) else { continue }
                if security.isRetired || (benchmarks.contains(id) && ledger.transactions(forSecurity: id).isEmpty) {
                    unavailable.insert(vehicle)
                }
            }
        }

        let plan = Self.plan(taxonomy, inputs: inputs, unavailable: unavailable)
        let original = analysis.allocation(for: taxonomy)
        let allocation = plan.taxonomy == taxonomy ? original : ledger.allocation(for: plan.taxonomy, snapshot: snapshot)
        var options = inputs.options
        if plan.isEverythingFrozen { options.cash = 0 }
        let proposal = allocation.rebalancing(options)

        valueBefore = allocation.classifiedValue
        unassignedValue = original.unassignedValue
        hasVehicles = original.flattened.contains { !$0.items.isEmpty }
        let stored = Dictionary(taxonomy.flattened.map { ($0.classification.id, $0.classification) }, uniquingKeysWith: { a, _ in a })

        // MARK: Orders — whole-share legs per depot, and never more purchases than there is money.

        struct Order {
            var securityID: UUID
            var name: String
            var price: Double?
            /// Signed raw shares; nil without a price.
            var shares: Int64?
            /// Signed minor units.
            var amount: Int64
            var legs: [(depot: UUID, shares: Int64)] = []
            var problem: String?
        }
        let depotOrder = Dictionary(ledger.depots.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let buyFallback = ledger.depots.first { !$0.isRetired && (scopeDepots?.contains($0.id) ?? true) }
            ?? ledger.depots.first { scopeDepots?.contains($0.id) ?? true }
        var orders: [Order] = []
        for o in proposal.orders {
            guard case .security(let securityID) = o.vehicle else { continue }
            var order = Order(securityID: securityID, name: o.name, price: o.pricePerShare, shares: o.shares?.raw, amount: o.amount)
            // The snapshot is the scope's: only depots in scope hold anything here.
            let holdings = (snapshot.position(securityID)?.holdings ?? [])
                .map { (depot: $0.depotID, shares: $0.shares.raw) }
                .sorted { $0.shares != $1.shares ? $0.shares > $1.shares : (depotOrder[$0.depot] ?? 0) < (depotOrder[$1.depot] ?? 0) }
            if let shares = order.shares, shares != 0, let price = order.price, price > 0 {
                if shares > 0 {
                    if let depot = holdings.first?.depot ?? buyFallback?.id {
                        order.legs = [(depot: depot, shares: shares)]
                    } else {
                        order.problem = "No depot — add a depot first."
                    }
                } else {
                    order.legs = RebalancingMath.saleLegs(-shares, holdings: holdings, wholeShares: inputs.wholeShares)
                    let sold = order.legs.reduce(Int64(0)) { $0 + $1.shares }
                    if sold == 0 {
                        order.problem = "Not held in any depot."
                    } else if sold != -shares {
                        // A depot's fraction of a share cannot be part of a whole-share sale.
                        order.shares = -sold
                        order.amount = max(order.amount, -FixedMath.saturatingInt64(Double(sold) / Double(Scale.shares) * price))
                    }
                }
            } else {
                order.problem = "No price — enter this order by hand."
            }
            // An order that cannot be placed at all moves no money.
            if order.problem != nil, order.shares != nil { order.amount = 0 }
            orders.append(order)
        }

        let planned = proposal.orders.reduce(Int64(0)) { $0 + ($1.vehicle.isSecurity ? 0 : $1.amount) }
        // The engine rounds sales down (whole shares) or cannot sell as much as it planned (holdings
        // too small) without reducing the purchases those sales were meant to pay for. Purchases
        // are cut back until the orders need no more money than there is.
        let shortfall = orders.reduce(Int64(0)) { $0 + $1.amount } + planned - inputs.cash
        let buyable = orders.indices.filter { orders[$0].amount > 0 && orders[$0].problem == nil && (orders[$0].shares ?? 0) > 0 }
        if shortfall > 0, !buyable.isEmpty {
            let purchases = buyable.map {
                RebalancingMath.Purchase(shares: orders[$0].shares!, price: orders[$0].price ?? 0, amount: orders[$0].amount)
            }
            let trimmed = inputs.wholeShares
                ? RebalancingMath.trim(purchases.map { RebalancingMath.Purchase(shares: $0.shares / Scale.shares, price: $0.price, amount: $0.amount) }, shortfall: shortfall)
                    .map { RebalancingMath.Purchase(shares: $0.shares * Scale.shares, price: $0.price, amount: $0.amount) }
                : RebalancingMath.scaleDown(purchases, shortfall: shortfall)
            for (n, index) in buyable.enumerated() {
                orders[index].shares = trimmed[n].shares
                orders[index].amount = trimmed[n].amount
                orders[index].legs = orders[index].legs.prefix(1).map { (depot: $0.depot, shares: trimmed[n].shares) }
            }
        }
        securityBuys = orders.reduce(0) { $0 + max($1.amount, 0) }
        securitySells = orders.reduce(0) { $0 + max(-$1.amount, 0) }
        accountChange = planned
        hasAccountOrders = proposal.orders.contains { !$0.vehicle.isSecurity }
        residualCash = inputs.cash - (securityBuys - securitySells) - planned

        // MARK: Draft transactions

        var drafts: [DraftTransaction] = []
        /// Change of every settlement account: reporting currency (for the allocation) and the
        /// account's own currency per draft (for the balance projection).
        var accountEffect: [UUID: Int64] = [:]
        var accountDrafts: [UUID: [String: Int64]] = [:]
        let note = "Rebalancing — \(taxonomy.name)"
        for order in orders {
            let kind: Transaction.Kind = order.amount > 0 || (order.shares ?? 0) > 0 ? .buy : .sell
            func failed(_ problem: String, depot: UUID? = nil) -> DraftTransaction {
                DraftTransaction(
                    id: "\(kind.rawValue):\(order.securityID.uuidString):\(depot?.uuidString ?? "-")", kind: kind, securityName: order.name,
                    depotName: "", accountName: "", shares: order.shares.map { Shares(raw: abs($0)) },
                    amount: Money(minor: abs(order.amount), currency: currency), problem: problem, transaction: nil)
            }
            if let problem = order.problem {
                drafts.append(failed(problem))
                continue
            }
            guard order.amount != 0, order.shares != 0 else { continue }
            let totalShares = order.legs.reduce(Int64(0)) { $0 + $1.shares }
            var amountLeft = abs(order.amount)
            for (index, leg) in order.legs.enumerated() {
                // Split the order value over the legs in proportion to their shares (exact sum).
                let part = index == order.legs.count - 1 ? amountLeft : mulDiv(abs(order.amount), leg.shares, max(totalShares, 1))
                amountLeft -= part
                let depot = ledger.depot(leg.depot)
                let account = depot?.referenceAccountID.flatMap { ledger.account($0) }
                    ?? ledger.accounts.first { !$0.isRetired && $0.currency == currency }
                    ?? ledger.accounts.first { !$0.isRetired }
                guard let depot, let account else {
                    drafts.append(failed("No cash account to settle against.", depot: leg.depot))
                    continue
                }
                guard let settled = ledger.converter.convert(minor: part, from: currency, to: account.currency, on: today) else {
                    drafts.append(failed("No exchange rate \(currency) → \(account.currency).", depot: leg.depot))
                    continue
                }
                var gross: Money?
                if let security = ledger.security(order.securityID), security.currency != account.currency,
                   let converted = ledger.converter.convert(minor: part, from: currency, to: security.currency, on: today) {
                    gross = Money(minor: converted, currency: security.currency)
                }
                let amount = Money(minor: settled, currency: account.currency)
                let transaction = Transaction(
                    kind: kind, date: today, accountID: account.id, depotID: depot.id, securityID: order.securityID,
                    shares: Shares(raw: leg.shares), amount: amount, securityGross: gross, note: note, source: "rebalancing")
                let id = "\(kind.rawValue):\(order.securityID.uuidString):\(depot.id.uuidString)"
                drafts.append(DraftTransaction(
                    id: id, kind: kind, securityName: order.name, depotName: depot.name, accountName: account.name,
                    shares: Shares(raw: leg.shares), amount: amount, problem: nil, transaction: transaction))
                let sign: Int64 = kind == .buy ? -1 : 1
                accountEffect[account.id, default: 0] += sign * part
                accountDrafts[account.id, default: [:]][id] = sign * settled
            }
        }
        self.drafts = drafts

        // MARK: The money itself

        // The fresh money arrives on (the withdrawal leaves from) the account most drafts settle
        // against; ties and "no drafts" resolve in the ledger's account order, so the choice is
        // stable across recomputations.
        var usage: [UUID: Int] = [:]
        for draft in drafts { if let id = draft.transaction?.accountID { usage[id, default: 0] += 1 } }
        let scopeReference = ledger.depots.first { scopeDepots?.contains($0.id) ?? false }?.referenceAccountID
        let cashAccount = ledger.accounts.filter { usage[$0.id] != nil }.max { usage[$0.id]! < usage[$1.id]! }
            ?? scopeReference.flatMap { ledger.account($0) }
            ?? ledger.accounts.first { !$0.isRetired && $0.currency == currency && (!isNarrowed || inScopeAccounts.contains($0.id)) }
            ?? ledger.accounts.first { !$0.isRetired && $0.currency == currency }
            ?? ledger.accounts.first { !$0.isRetired }
        // A withdrawal is limited to what the sales and the cash in scope really provide. (What
        // whole-share rounding takes off the sales comes out of the cash accounts, if they have it.)
        let movedCash: Int64
        if plan.isEverythingFrozen {
            movedCash = 0
        } else if inputs.cash >= 0 {
            movedCash = inputs.cash
        } else {
            let availableCash = max(0, snapshot.cash.reduce(Int64(0)) { $0 + $1.value.minor })
            movedCash = -max(0, min(-inputs.cash, securitySells - securityBuys + availableCash))
        }
        unraisedCash = inputs.cash < 0 ? movedCash - inputs.cash : 0
        var cashSettled: Int64 = 0
        if let cashAccount, movedCash != 0,
           let amount = ledger.converter.convert(minor: abs(movedCash), from: currency, to: cashAccount.currency, on: today), amount > 0 {
            let kind: Transaction.Kind = movedCash > 0 ? .deposit : .withdrawal
            let money = Money(minor: amount, currency: cashAccount.currency)
            let transaction = Transaction(kind: kind, date: today, accountID: cashAccount.id, amount: money, note: note, source: "rebalancing")
            cashDraft = DraftTransaction(
                id: "cash:\(cashAccount.id.uuidString)", kind: kind, securityName: "", depotName: "", accountName: cashAccount.name,
                shares: nil, amount: money, problem: nil, transaction: transaction)
            accountEffect[cashAccount.id, default: 0] += movedCash
            cashSettled = movedCash > 0 ? amount : -amount
        }

        // Balances of the accounts involved (the scope's snapshot has no cash for a depot scope).
        let cashSnapshot = isNarrowed ? ledger.snapshot(on: today) : snapshot
        accounts = ledger.accounts.compactMap { account in
            let isCashAccount = account.id == cashAccount?.id && cashDraft != nil
            guard accountDrafts[account.id] != nil || isCashAccount else { return nil }
            return AccountProjection(
                id: account.id, name: account.name, currency: account.currency,
                balance: cashSnapshot.cash(account.id)?.balance.minor ?? 0, effects: accountDrafts[account.id] ?? [:],
                cashEffect: isCashAccount ? cashSettled : 0)
        }

        // MARK: What the transactions do to the allocation

        var changes: [AllocationVehicle: Int64] = [:]
        for order in orders where order.amount != 0 { changes[.security(order.securityID), default: 0] += order.amount }
        for (id, amount) in accountEffect { changes[.account(id), default: 0] += amount }
        let settled = RebalancingMath.settle(allocation.roots, changes: changes)
        valueAfter = settled.reduce(0) { $0 + $1.resulting }
        let before = valueBefore
        let after = valueAfter
        func share(_ value: Int64) -> Double? { before > 0 ? Double(value) / Double(before) : nil }
        func shareAfter(_ value: Int64) -> Double? { after > 0 ? Double(value) / Double(after) : nil }

        // Targets as a share of the classified value once the money has moved.
        let targetTotal = before + movedCash
        let targetValues = RebalancingMath.targetValues(allocation.roots, total: targetTotal)
        func target(_ id: UUID) -> Double? {
            guard plan.wrappers[id] == nil, targetTotal > 0, let value = targetValues[id] else { return nil }
            return value / Double(targetTotal)
        }

        // By classification — excluded vehicles and classifications stay where they are, greyed out.
        let assignmentOrder = Dictionary(taxonomy.flattened.map { entry in
            (entry.classification.id, entry.classification.assignments.compactMap(AllocationVehicle.init))
        }, uniquingKeysWith: { a, _ in a })
        var drifts: [(Double, Double)] = []
        var classifiedEffect: [AllocationVehicle: Int64] = [:]
        func row(_ node: AllocationNode, _ result: RebalancingMath.Settled, depth: Int, index: Int, inherited: Bool) -> ProposalRow {
            let freeze = plan.frozen[node.id]
            let excluded = inherited || freeze != nil
            var items = Array(zip(node.items, result.itemEffects))
            var below = Array(zip(node.children, result.children))
            // Splice the synthetic child that carries the tradable part back into its classification.
            if below.count == 1, plan.wrappers[below[0].0.id] != nil {
                items += Array(zip(below[0].0.items, below[0].1.itemEffects))
                below = Array(zip(below[0].0.children, below[0].1.children))
                let position = assignmentOrder[node.id] ?? []
                items = items.enumerated().sorted { a, b in
                    let x = position.firstIndex(of: a.element.0.vehicle) ?? .max, y = position.firstIndex(of: b.element.0.vehicle) ?? .max
                    return x != y ? x < y : a.offset < b.offset
                }.map(\.element)
            }
            let itemRows = items.enumerated().map { n, entry in
                let (item, effect) = entry
                classifiedEffect[item.vehicle, default: 0] += effect
                return ProposalRow(
                    id: "\(node.id.uuidString)/\(item.vehicle.token)\(n > 0 && items[..<n].contains { $0.0.vehicle == item.vehicle } ? "#\(n)" : "")",
                    classificationID: nil, vehicle: item.vehicle, name: item.name, depth: depth + 1, color: nil, value: item.value,
                    share: share(item.value), targetShare: nil, amount: effect, resultingValue: item.value + effect,
                    resultingShare: shareAfter(item.value + effect),
                    isExcluded: excluded || inputs.excludedVehicles.contains(item.vehicle), badge: nil, canExclude: false, children: [])
            }
            let targetShare = excluded ? nil : target(node.id)
            if let targetShare, let now = share(node.value), let then = shareAfter(result.resulting) {
                drifts.append((abs(now - targetShare), abs(then - targetShare)))
            }
            let badge: String? = switch freeze {
            case .unavailable: isNarrowed ? "not in scope" : "nothing to trade"
            case .empty: "nothing assigned"
            case .excluded, .implied: "excluded"
            case nil: inherited ? "excluded" : nil
            }
            return ProposalRow(
                id: node.id.uuidString, classificationID: node.id, vehicle: nil, name: node.name, depth: depth,
                color: ChartColors.classification(stored[node.id]?.color ?? node.color, fallbackIndex: index), value: node.value,
                share: share(node.value), targetShare: targetShare, amount: result.resulting - node.value,
                resultingValue: result.resulting, resultingShare: shareAfter(result.resulting), isExcluded: excluded, badge: badge,
                canExclude: !inherited && freeze != .unavailable && freeze != .empty && stored[node.id]?.targetWeight != nil,
                children: below.enumerated().map { row($1.0, $1.1, depth: depth + 1, index: $0, inherited: excluded) } + itemRows)
        }
        var rows = zip(allocation.roots, settled).enumerated().map { row($1.0, $1.1, depth: 0, index: $0, inherited: false) }
        if original.unassignedValue != 0 {
            rows.append(ProposalRow(
                id: AllocationRow.unassignedID, classificationID: nil, vehicle: nil, name: "Unassigned — not part of rebalancing",
                depth: 0, color: ChartColors.other, value: original.unassignedValue, share: nil, targetShare: nil, amount: 0,
                resultingValue: nil, resultingShare: nil, isExcluded: true, badge: nil, canExclude: false, isUnassigned: true, children: []))
        }
        classRows = rows
        driftBefore = drifts.map(\.0).max()
        driftAfter = drifts.map(\.1).max()

        // By security: every vehicle of the taxonomy with its assigned value and net order.
        struct Position {
            var name: String
            var value: Int64 = 0
            var price: Double?
            var shares: Shares?
            var classes: [String] = []
        }
        var sequence: [AllocationVehicle] = []
        var positions: [AllocationVehicle: Position] = [:]
        for node in original.flattened {
            for item in node.items {
                if positions[item.vehicle] == nil {
                    positions[item.vehicle] = Position(name: item.name, price: item.pricePerShare, shares: item.shares)
                    sequence.append(item.vehicle)
                }
                positions[item.vehicle]!.value += item.value
                if !positions[item.vehicle]!.classes.contains(node.name) { positions[item.vehicle]!.classes.append(node.name) }
            }
        }
        let securityOrders = Dictionary(orders.map { ($0.securityID, $0) }, uniquingKeysWith: { a, _ in a })
        vehicleRows = sequence.compactMap { vehicle in
            guard let p = positions[vehicle] else { return nil }
            var amount: Int64 = 0
            var orderShares: Shares?
            switch vehicle {
            case .security(let id):
                if let o = securityOrders[id], o.amount != 0 {
                    amount = o.amount
                    orderShares = o.shares.map { Shares(raw: $0) }
                }
            case .account(let id):
                amount = unavailable.contains(vehicle) ? 0 : accountEffect[id] ?? 0
            }
            let resulting = p.value + (classifiedEffect[vehicle] ?? 0)
            return VehicleRow(
                vehicle: vehicle, name: p.name, classes: p.classes.joined(separator: ", "), price: p.price, sharesHeld: p.shares,
                value: p.value, share: share(p.value), amount: amount, orderShares: orderShares, resultingValue: resulting,
                resultingShare: shareAfter(resulting), isExcluded: inputs.excludedVehicles.contains(vehicle))
        }

        // MARK: Warnings in plain language

        func name(_ id: UUID?) -> String { id.flatMap { stored[plan.resolve($0)]?.name }.map { "“\($0)”" } ?? "the top level" }
        func vehicleName(_ vehicle: AllocationVehicle) -> String { "“\(positions[vehicle]?.name ?? "A position")”" }
        /// Why some siblings of a group take no part: the user's exclusions, or only classifications
        /// that cannot trade (those have their own message).
        func exclusions(in parent: UUID?) -> (user: Bool, other: Bool) {
            let reasons = taxonomy.siblings(ofParent: parent.map(plan.resolve)).compactMap { plan.frozen[$0.id] }
            return (reasons.contains { $0 == .excluded || $0 == .implied }, reasons.contains { $0 == .unavailable || $0 == .empty })
        }
        var texts: [(RebalancingWarning.Level, String)] = []
        if plan.isEverythingFrozen {
            texts.append((.warning, inputs.hasExclusions
                ? "Everything is excluded, so there is nothing to trade. Check a classification to include it again."
                : "Nothing can be traded: no classification with a target has a position that can be bought or sold here."))
        }
        let empty = taxonomy.flattened.filter { plan.frozen[$0.classification.id] == .empty }.map { "“\($0.classification.name)”" }
        if !empty.isEmpty, !plan.isEverythingFrozen {
            texts.append((.warning, "\(empty.joined(separator: ", ")) \(empty.count == 1 ? "has a target but nothing is" : "have targets but nothing is") assigned, so \(empty.count == 1 ? "it is" : "they are") left out and the other targets fill the rest. Assign a security or account in the Edit tab."))
        }
        let outOfScope = taxonomy.flattened.filter { plan.frozen[$0.classification.id] == .unavailable }.map { "“\($0.classification.name)”" }
        if !outOfScope.isEmpty {
            texts.append((.info, isNarrowed
                ? "\(outOfScope.joined(separator: ", ")) only \(outOfScope.count == 1 ? "holds" : "hold") cash accounts or securities that are not part of this scope; \(outOfScope.count == 1 ? "it is" : "they are") left out and the other targets fill the rest."
                : "\(outOfScope.joined(separator: ", ")) only \(outOfScope.count == 1 ? "holds" : "hold") retired or benchmark securities that are not bought; \(outOfScope.count == 1 ? "it is" : "they are") left out and the other targets fill the rest."))
        }
        if inputs.cash < 0, movedCash > inputs.cash {
            texts.append((.warning, movedCash == 0
                ? "Nothing can be raised with these settings, so no withdrawal is possible."
                : "Only \(Fmt.money(minor: -movedCash, currency: currency)) of the requested \(Fmt.money(minor: -inputs.cash, currency: currency)) can be raised; the withdrawal is limited to that."))
        }
        for warning in proposal.warnings {
            switch warning {
            case .noTargets(let parent):
                guard !plan.isEverythingFrozen else { continue }
                texts.append((parent == nil ? .warning : .info, parent == nil
                    ? "No target weights are set, so money is spread in proportion to the current values. Set targets in the Edit tab."
                    : "\(name(parent)) has no targets for its sub-classifications; its amount is spread in proportion to their current values."))
            case .targetsNormalized(let parent, let sum):
                let excluded = exclusions(in: parent)
                if excluded.user {
                    texts.append((.info, "Excluded classifications in \(name(parent)) keep their current value; the others share the rest according to their targets."))
                } else if excluded.other {
                    continue
                } else if sum == 10_000 {
                    texts.append((.info, "Some classifications in \(name(parent)) have no target and are left untouched."))
                } else {
                    texts.append((.warning, "The targets in \(name(parent)) add up to \(Fmt.percent(basisPoints: sum)) and were scaled to 100%. Fix them in the Edit tab."))
                }
            case .noVehicles(let classification):
                texts.append((.warning, "\(name(classification)) should receive money but has no security or account that can be bought."))
            case .sharedVehicle(let vehicle):
                texts.append((.info, "\(vehicleName(vehicle)) is split across classifications or only partly assigned, so its order also moves other classes."))
            case .missingPrice(let securityID):
                texts.append((.warning, "\(vehicleName(.security(securityID))) has no price; its order has no share count."))
            case .insufficientHoldings(let classification):
                texts.append((.warning, "There is not enough in \(name(classification)) to sell the requested amount."))
            }
        }
        var seen = Set<String>()
        warnings = texts.filter { seen.insert($0.1).inserted }.enumerated().map { RebalancingWarning(id: "w\($0)", level: $1.0, text: $1.1) }
    }
}

extension RebalancingModel {
    /// The proposal as tab-separated text.
    func tsv(_ mode: AllocationSession.ProposalMode) -> String {
        func money(_ minor: Int64?) -> String { minor.map { TSV.number(Money(minor: $0, currency: currency).decimalValue) } ?? "" }
        func percent(_ value: Double?) -> String { value.map { TSV.number(Decimal($0 * 100).rounded(4)) } ?? "" }
        switch mode {
        case .classes:
            return TSV.string(
                header: ["Name", "Level", "Current", "Current %", "Target %", "Buy / Sell", "After", "After %", "Currency"],
                rows: classRows.flatMap(\.flattened).map {
                    [$0.name, String($0.depth), money($0.value), percent($0.share), percent($0.targetShare), money($0.amount),
                     money($0.resultingValue), percent($0.resultingShare), currency]
                })
        case .orders:
            return TSV.string(
                header: ["Name", "Classification", "Current", "Current %", "Buy / Sell", "Shares", "After", "After %", "Currency"],
                rows: vehicleRows.map {
                    [$0.name, $0.classes, money($0.value), percent($0.share), money($0.amount),
                     $0.orderShares.map { TSV.number($0.decimalValue) } ?? "", money($0.resultingValue), percent($0.resultingShare), currency]
                })
        }
    }
}
