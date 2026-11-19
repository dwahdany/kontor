import SwiftUI
import KontorUI

// The Rebalancing tab's model: the engine's `RebalancingProposal` shaped into table rows, readable
// warnings and draft transactions. Built off the main actor (`store.analyze` / `analysisTask`).

/// One line of the "By Classification" table: a classification or a vehicle's part inside it.
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
    var targetShare: Double?
    /// What the proposal adds (+) or removes (−).
    var amount: Int64
    var resultingValue: Int64?
    var resultingShare: Double?
    var isExcluded: Bool
    /// Classifications only: whether "exclude" is meaningful (it has a target).
    var canExclude: Bool
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
    /// The whole position (all assignments + unassigned part).
    var value: Int64
    var share: Double?
    var amount: Int64
    var orderShares: Shares?
    var resultingValue: Int64
    var resultingShare: Double?
    var isExcluded: Bool
}

/// A transaction the proposal would create, ready to be reviewed.
struct DraftTransaction: Identifiable, Sendable, Hashable {
    var id: UUID
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
    var cash: Int64
    /// Purchases / sales of securities (positive magnitudes).
    var securityBuys: Int64
    var securitySells: Int64
    /// Net change the proposal asks of cash accounts that are part of the taxonomy (+ keep more).
    var accountChange: Int64
    var hasAccountOrders: Bool
    /// `cash − Σ orders`: > 0 is money left over, < 0 is money the orders need on top (whole-share
    /// rounding of sales, or holdings too small to sell).
    var residualCash: Int64
    var valueBefore: Int64
    var valueAfter: Int64
    var hasTargets: Bool
    var hasVehicles: Bool
    /// Largest |actual − target| over all targeted classifications, before and after.
    var driftBefore: Double?
    var driftAfter: Double?

    var classRows: [ProposalRow]
    var vehicleRows: [VehicleRow]
    var warnings: [RebalancingWarning]
    var drafts: [DraftTransaction]
    /// Orders on cash accounts — they need no booking ("keep €500 more in Savings").
    var cashNotes: [String]
    /// Optional booking of the money itself: a deposit of the cash to invest (or a withdrawal) on
    /// the account most drafts settle against. Offered, never added by default.
    var cashDraft: DraftTransaction?

    var orderCount: Int { vehicleRows.count { $0.amount != 0 } }
    var bookableDrafts: [DraftTransaction] { drafts.filter { $0.transaction != nil } }

    /// The taxonomy the engine sees: excluded classifications lose their target (the engine leaves
    /// untargeted siblings untouched), excluded vehicles lose their assignments (they become
    /// unassigned, which the engine never trades).
    static func effectiveTaxonomy(_ taxonomy: Taxonomy, inputs: RebalancingInputs) -> Taxonomy {
        var copy = taxonomy
        for id in inputs.excludedClassifications { copy.update(id) { $0.targetWeight = nil } }
        for vehicle in inputs.excludedVehicles { copy.removeAssignments(of: vehicle) }
        return copy
    }

    init(_ analysis: Analysis, taxonomy: Taxonomy, inputs: RebalancingInputs, today: Day) {
        let ledger = analysis.ledger
        let snapshot = analysis.snapshot
        let original = analysis.allocation(for: taxonomy)
        let effective = Self.effectiveTaxonomy(taxonomy, inputs: inputs)
        let allocation = inputs.hasExclusions ? analysis.allocation(for: effective) : original
        let proposal = allocation.rebalancing(inputs.options)

        taxonomyID = taxonomy.id
        taxonomyName = taxonomy.name
        currency = proposal.currency
        day = today
        cash = inputs.cash
        let securityOrders = proposal.orders.filter { $0.vehicle.isSecurity }
        let accountOrders = proposal.orders.filter { !$0.vehicle.isSecurity }
        securityBuys = securityOrders.reduce(0) { $0 + max($1.amount, 0) }
        securitySells = securityOrders.reduce(0) { $0 + max(-$1.amount, 0) }
        accountChange = accountOrders.reduce(0) { $0 + $1.amount }
        hasAccountOrders = !accountOrders.isEmpty
        residualCash = proposal.residualCash
        valueBefore = proposal.valueBefore
        valueAfter = proposal.valueAfter
        let flat = proposal.flattened
        hasTargets = flat.contains { $0.targetShare != nil }
        hasVehicles = flat.contains { !$0.items.isEmpty }

        let before = proposal.valueBefore
        func share(_ value: Int64) -> Double? { before > 0 ? Double(value) / Double(before) : nil }
        let drifts = flat.compactMap { node -> (Double, Double)? in
            guard let target = node.targetShare, let now = share(node.value), let after = node.resultingShare else { return nil }
            return (abs(now - target), abs(after - target))
        }
        driftBefore = drifts.map(\.0).max()
        driftAfter = drifts.map(\.1).max()

        // By classification
        let colors = Dictionary(original.flattened.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        let stored = Dictionary(taxonomy.flattened.map { ($0.classification.id, $0.classification) }, uniquingKeysWith: { a, _ in a })
        func row(_ node: RebalancingProposal.Node, index: Int, parentExcluded: Bool) -> ProposalRow {
            let excluded = parentExcluded || inputs.excludedClassifications.contains(node.id)
            let items = node.items.map { item in
                ProposalRow(
                    id: "\(node.id.uuidString)/\(item.vehicle.token)", classificationID: nil, vehicle: item.vehicle,
                    name: item.name, depth: node.depth + 1, color: nil, value: item.value, share: share(item.value),
                    targetShare: nil, amount: item.amount, resultingValue: nil, resultingShare: nil, isExcluded: excluded,
                    canExclude: false, children: [])
            }
            return ProposalRow(
                id: node.id.uuidString, classificationID: node.id, vehicle: nil, name: node.name, depth: node.depth,
                color: ChartColors.classification(colors[node.id] ?? "", fallbackIndex: index), value: node.value,
                share: share(node.value), targetShare: node.targetShare, amount: node.amount,
                resultingValue: node.resultingValue, resultingShare: node.resultingShare, isExcluded: excluded,
                canExclude: !parentExcluded && stored[node.id]?.targetWeight != nil,
                children: node.children.enumerated().map { row($1, index: $0, parentExcluded: excluded) } + items)
        }
        classRows = proposal.nodes.enumerated().map { row($1, index: $0, parentExcluded: false) }

        // By security: every vehicle of the taxonomy with its whole position and net order.
        struct Position {
            var name: String
            var value: Int64 = 0
            var price: Double?
            var shares: Shares?
            var classes: [String] = []
        }
        var order: [AllocationVehicle] = []
        var positions: [AllocationVehicle: Position] = [:]
        for node in original.flattened {
            for item in node.items {
                if positions[item.vehicle] == nil {
                    positions[item.vehicle] = Position(name: item.name, price: item.pricePerShare, shares: item.shares)
                    order.append(item.vehicle)
                }
                positions[item.vehicle]!.value += item.value
                if !positions[item.vehicle]!.classes.contains(node.name) { positions[item.vehicle]!.classes.append(node.name) }
            }
        }
        for item in original.unassigned where positions[item.vehicle] != nil {
            positions[item.vehicle]!.value += item.value
        }
        let orders = Dictionary(proposal.orders.map { ($0.vehicle, $0) }, uniquingKeysWith: { a, _ in a })
        let totalBefore = original.totalValue
        let totalAfter = totalBefore + proposal.orders.reduce(Int64(0)) { $0 + $1.amount }
        vehicleRows = order.compactMap { vehicle in
            guard let p = positions[vehicle] else { return nil }
            let o = orders[vehicle]
            let after = p.value + (o?.amount ?? 0)
            return VehicleRow(
                vehicle: vehicle, name: p.name, classes: p.classes.joined(separator: ", "), price: p.price,
                sharesHeld: p.shares, value: p.value, share: totalBefore > 0 ? Double(p.value) / Double(totalBefore) : nil,
                amount: o?.amount ?? 0, orderShares: o?.shares, resultingValue: after,
                resultingShare: totalAfter > 0 ? Double(after) / Double(totalAfter) : nil,
                isExcluded: inputs.excludedVehicles.contains(vehicle))
        }

        // Warnings in plain language.
        func name(_ id: UUID?) -> String { id.flatMap { stored[$0]?.name }.map { "“\($0)”" } ?? "the top level" }
        func vehicleName(_ vehicle: AllocationVehicle) -> String { "“\(positions[vehicle]?.name ?? "A position")”" }
        func groupHasExclusion(_ parent: UUID?) -> Bool {
            taxonomy.siblings(ofParent: parent).contains { inputs.excludedClassifications.contains($0.id) }
        }
        warnings = proposal.warnings.enumerated().map { index, warning in
            let id = "w\(index)"
            switch warning {
            case .noTargets(let parent):
                return RebalancingWarning(id: id, level: parent == nil ? .warning : .info, text: parent == nil
                    ? "No target weights are set, so money is spread in proportion to the current values. Set targets in the Edit tab."
                    : "\(name(parent)) has no targets for its sub-classifications; its amount is spread in proportion to their current values.")
            case .targetsNormalized(let parent, let sum):
                if groupHasExclusion(parent) {
                    return RebalancingWarning(id: id, level: .info, text: "Excluded classifications in \(name(parent)) keep their current value; the targets of the others were scaled to fill the rest.")
                }
                if sum == 10_000 {
                    return RebalancingWarning(id: id, level: .info, text: "Some classifications in \(name(parent)) have no target and are left untouched.")
                }
                return RebalancingWarning(id: id, level: .warning, text: "The targets in \(name(parent)) add up to \(Fmt.percent(basisPoints: sum)) and were scaled to 100%. Fix them in the Edit tab.")
            case .noVehicles(let classification):
                return RebalancingWarning(id: id, level: .warning, text: "\(name(classification)) should receive money but has no security or account assigned.")
            case .sharedVehicle(let vehicle):
                return RebalancingWarning(id: id, level: .info, text: "\(vehicleName(vehicle)) is split across classifications or only partly assigned, so its order also moves other classes.")
            case .missingPrice(let securityID):
                return RebalancingWarning(id: id, level: .warning, text: "\(vehicleName(.security(securityID))) has no price; its order has no share count.")
            case .insufficientHoldings(let classification):
                return RebalancingWarning(id: id, level: .warning, text: "There is not enough in \(name(classification)) to sell the requested amount; the rest stays as leftover cash.")
            }
        }

        // Draft transactions.
        var drafts: [DraftTransaction] = []
        var notes: [String] = []
        let fallbackDepot = ledger.depots.first { !$0.isRetired } ?? ledger.depots.first
        let note = "Rebalancing — \(taxonomy.name)"
        for o in proposal.orders {
            guard case .security(let securityID) = o.vehicle else {
                let money = Fmt.money(minor: abs(o.amount), currency: proposal.currency)
                notes.append(o.amount > 0 ? "Keep \(money) more in \(o.name)." : "Take \(money) out of \(o.name).")
                continue
            }
            let kind: Transaction.Kind = o.isBuy ? .buy : .sell
            func failed(_ problem: String) -> DraftTransaction {
                DraftTransaction(
                    id: UUID(), kind: kind, securityName: o.name, depotName: "", accountName: "", shares: o.shares.map { Shares(raw: abs($0.raw)) },
                    amount: Money(minor: abs(o.amount), currency: proposal.currency), problem: problem, transaction: nil)
            }
            guard let orderShares = o.shares, orderShares.raw != 0 else {
                drafts.append(failed("No price — enter this order by hand."))
                continue
            }
            // Where to book: buys go to the depot that already holds the security, sales are
            // taken from the depots holding it, largest first.
            let holdings = (snapshot.position(securityID)?.holdings ?? []).sorted { $0.shares > $1.shares }
            var legs: [(depot: UUID, shares: Int64)] = []
            if o.isBuy {
                guard let depot = holdings.first?.depotID ?? fallbackDepot?.id else {
                    drafts.append(failed("No depot — add a depot first."))
                    continue
                }
                legs = [(depot, orderShares.raw)]
            } else {
                var left = -orderShares.raw
                for holding in holdings where left > 0 && holding.shares.raw > 0 {
                    let take = min(left, holding.shares.raw)
                    legs.append((holding.depotID, take))
                    left -= take
                }
                if legs.isEmpty {
                    drafts.append(failed("Not held in any depot."))
                    continue
                }
            }
            let totalShares = legs.reduce(Int64(0)) { $0 + $1.shares }
            var amountLeft = abs(o.amount)
            for (index, leg) in legs.enumerated() {
                // Split the order value over the legs in proportion to their shares (exact sum).
                let part = index == legs.count - 1 ? amountLeft : mulDiv(abs(o.amount), leg.shares, max(totalShares, 1))
                amountLeft -= part
                let depot = ledger.depot(leg.depot)
                let account = depot?.referenceAccountID.flatMap { ledger.account($0) }
                    ?? ledger.accounts.first { !$0.isRetired && $0.currency == proposal.currency }
                    ?? ledger.accounts.first { !$0.isRetired }
                guard let depot, let account else {
                    drafts.append(failed("No cash account to settle against."))
                    continue
                }
                guard let settled = ledger.converter.convert(minor: part, from: proposal.currency, to: account.currency, on: today) else {
                    drafts.append(failed("No exchange rate \(proposal.currency) → \(account.currency)."))
                    continue
                }
                var gross: Money?
                if let security = ledger.security(securityID), security.currency != account.currency,
                   let converted = ledger.converter.convert(minor: part, from: proposal.currency, to: security.currency, on: today) {
                    gross = Money(minor: converted, currency: security.currency)
                }
                let amount = Money(minor: settled, currency: account.currency)
                let transaction = Transaction(
                    kind: kind, date: today, accountID: account.id, depotID: depot.id, securityID: securityID,
                    shares: Shares(raw: leg.shares), amount: amount, securityGross: gross, note: note, source: "rebalancing")
                drafts.append(DraftTransaction(
                    id: transaction.id, kind: kind, securityName: o.name, depotName: depot.name, accountName: account.name,
                    shares: Shares(raw: leg.shares), amount: amount, problem: nil, transaction: transaction))
            }
        }
        self.drafts = drafts
        cashNotes = notes

        // The fresh money (or the withdrawal) itself, on the account the drafts use most.
        cashDraft = nil
        if inputs.cash != 0 {
            let used = drafts.compactMap { $0.transaction?.accountID }
            let favourite = Dictionary(grouping: used, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            let account = favourite.flatMap { ledger.account($0) }
                ?? ledger.accounts.first { !$0.isRetired && $0.currency == proposal.currency }
                ?? ledger.accounts.first { !$0.isRetired }
            if let account, let amount = ledger.converter.convert(minor: abs(inputs.cash), from: proposal.currency, to: account.currency, on: today) {
                let kind: Transaction.Kind = inputs.cash > 0 ? .deposit : .withdrawal
                let money = Money(minor: amount, currency: account.currency)
                let transaction = Transaction(kind: kind, date: today, accountID: account.id, amount: money, note: note, source: "rebalancing")
                cashDraft = DraftTransaction(
                    id: transaction.id, kind: kind, securityName: "", depotName: "", accountName: account.name, shares: nil,
                    amount: money, problem: nil, transaction: transaction)
            }
        }
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
