import Foundation
import KontorModel
import KontorEngine
import KontorUI

/// Hooks for the app's headless self-test (`Kontor --selftest`): the plan editor's draft and the
/// Generate sheet's proposal and apply step, without a view.
public enum PlansSelfTest {
    /// "New Savings Plan" → security, amount, start → Add.
    @MainActor @discardableResult
    public static func addSavingsPlan(securityID: UUID, amount: Int64, start: Day, in store: PortfolioStore) throws -> UUID {
        var draft = PlanDraft(prefill: PlanPrefill(kind: .purchase, securityID: securityID, start: start), file: store.file, today: store.today)
        draft.amountMinor = amount
        if let problem = draft.validate(
            security: store.security(draft.securityID), depot: store.depot(draft.depotID), account: store.account(draft.accountID)) {
            throw SelfTestFailure("the plan editor refuses the plan: \(problem)")
        }
        let currency = store.account(draft.accountID)?.currency ?? store.security(securityID)?.currency ?? store.baseCurrency
        var plan = draft.plan(currency: currency)
        if plan.name.isEmpty { plan.name = draft.suggestedName(security: store.security(securityID)?.name) }
        store.addPlan(plan)
        guard store.plan(plan.id) != nil else { throw SelfTestFailure("the plan was not added") }
        return plan.id
    }

    /// Generate… → accept every default → Add. Returns what the sheet proposed and what was booked.
    @MainActor
    public static func generateDue(in store: PortfolioStore) async throws -> (proposed: Int, created: Int, skipped: Int) {
        let plans = store.file.plans
        let today = store.today
        let key = GenerationProposal.Key(planID: nil, today: today)
        let proposal = try await store.compute(key) { ledger in GenerationProposal(ledger, plans: plans, today: today) }
        var outcome = GenerationOutcome()
        store.mutate("Generate Plan Transactions") { file in
            outcome = PlanGeneration.apply(proposal.items, choices: [:], shares: [:], to: &file)
        }
        // Once booked, nothing may be due any more for what was created.
        let after = try await store.compute(GenerationProposal.Key(planID: nil, today: today)) { ledger in
            GenerationProposal(ledger, plans: plans, today: today)
        }
        let stillDue = after.items.count { $0.defaultChoice == .create && $0.canCreate }
        if outcome.created > 0, stillDue >= proposal.items.count {
            throw SelfTestFailure("\(outcome.created) plan transactions were generated but \(stillDue) executions are still due")
        }
        return (proposal.items.count, outcome.created, outcome.skipped)
    }
}
