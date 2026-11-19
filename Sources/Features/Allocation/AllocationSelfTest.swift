import Foundation
import KontorModel
import KontorEngine
import KontorUI

/// Hooks for the app's headless self-test (`Kontor --selftest`): the rebalancing proposal and the
/// review sheet's "Add Transactions", without a view.
public enum AllocationSelfTest {
    public struct Outcome: Sendable {
        public var taxonomyName: String
        public var orders: Int
        public var drafts: Int
        public var created: Int
        public var driftBefore: Double?
        public var driftAfter: Double?
        public var residualCash: Int64
    }

    /// Gives every top-level classification of `taxonomy` an equal target and assigns the given
    /// securities round-robin (what the Edit tab's target fields and drag-and-drop do), in one
    /// undo step.
    @MainActor
    public static func setEqualTargets(taxonomyID: UUID, assigning securities: [UUID], in store: PortfolioStore) throws {
        guard let index = store.file.taxonomies.firstIndex(where: { $0.id == taxonomyID }), !store.file.taxonomies[index].root.isEmpty else {
            throw SelfTestFailure("the taxonomy has no classifications")
        }
        store.mutate("Edit Targets") { file in
            let count = file.taxonomies[index].root.count
            let share = 10_000 / count
            for i in 0..<count {
                file.taxonomies[index].root[i].targetWeight = i == count - 1 ? 10_000 - share * (count - 1) : share
            }
            for (n, id) in securities.enumerated() {
                file.taxonomies[index].root[n % count].assignments.append(Classification.Assignment(securityID: id))
            }
        }
    }

    /// Rebalancing tab → invest `amount` → Create Transactions… → Add. Uses the same model and the
    /// same cache key as the tab and the review sheet.
    @MainActor
    public static func rebalance(taxonomyID: UUID, investing amount: Int64, in store: PortfolioStore) async throws -> Outcome {
        guard let taxonomy = store.file.taxonomies.first(where: { $0.id == taxonomyID }) else {
            throw SelfTestFailure("taxonomy \(taxonomyID) does not exist")
        }
        var inputs = RebalancingInputs()
        inputs.amount = amount
        let key = RebalancingKey(taxonomy: taxonomy.id, inputs: inputs.sanitized(for: taxonomy), today: store.today)
        let model = try await store.analyze("allocation.rebalancing", interval: store.interval(for: .ytd), variant: key) { analysis in
            RebalancingModel(analysis, taxonomy: taxonomy, inputs: key.inputs, today: key.today)
        }
        let transactions = model.drafts.compactMap(\.transaction)
        if !transactions.isEmpty { store.addTransactions(transactions, actionName: "Apply Rebalancing") }
        return Outcome(
            taxonomyName: taxonomy.name, orders: model.orderCount, drafts: model.drafts.count, created: transactions.count,
            driftBefore: model.driftBefore, driftAfter: model.driftAfter, residualCash: model.residualCash)
    }
}
