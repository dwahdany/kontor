import SwiftUI
import KontorUI

/// The things one can do to plans — shared by the screen, the detail pane, menus, the inspector and
/// the command palette. Every action is one undoable step.
@MainActor
enum PlanActions {
    /// Id of the feature-private "Generate due transactions" sheet (`payload["plan"]` = one plan).
    static let generateSheetID = "plans.generate"

    static func generate(_ planID: UUID? = nil, in store: PortfolioStore) {
        store.present(.custom(id: generateSheetID, payload: planID.map { ["plan": $0.uuidString] } ?? [:]))
    }

    /// Deletes plans. Their transactions stay — the toast says so, and Undo brings the plans back.
    static func delete(_ ids: Set<UUID>, in store: PortfolioStore) {
        let plans = ids.compactMap { store.plan($0) }
        guard !plans.isEmpty else { return }
        store.deletePlans(ids)
        store.toast(
            plans.count == 1 ? "Deleted “\(plans[0].name)”" : "Deleted \(Fmt.integer(plans.count)) plans",
            message: "Transactions already created by \(plans.count == 1 ? "the plan" : "these plans") were kept. Undo with ⌘Z.",
            style: .info)
    }

    static func pause(_ id: UUID, in store: PortfolioStore) {
        let today = store.today
        store.mutate("Pause Plan") { file in
            guard let index = file.plans.firstIndex(where: { $0.id == id }) else { return }
            PlanGeneration.pause(&file.plans[index], today: today)
        }
    }

    static func resume(_ id: UUID, in store: PortfolioStore) {
        let today = store.today
        store.mutate("Resume Plan") { file in
            guard let index = file.plans.firstIndex(where: { $0.id == id }) else { return }
            PlanGeneration.resume(&file.plans[index], today: today)
        }
    }

    static func skip(_ day: Day, of id: UUID, in store: PortfolioStore) {
        store.mutate("Skip Execution") { file in
            guard let index = file.plans.firstIndex(where: { $0.id == id }) else { return }
            PlanGeneration.skip(day, in: &file.plans[index])
        }
    }

    static func restore(_ day: Day, of id: UUID, in store: PortfolioStore) {
        store.mutate("Restore Execution") { file in
            guard let index = file.plans.firstIndex(where: { $0.id == id }) else { return }
            PlanGeneration.restore(day, in: &file.plans[index])
        }
    }

    static func duplicate(_ id: UUID, in store: PortfolioStore) {
        guard var copy = store.plan(id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        copy.start = max(copy.start, store.today.startOfMonth.addingMonths(1))
        copy.end = nil
        copy.skippedDates = nil
        store.mutate("Duplicate Plan") { $0.plans.append(copy) }
        store.navigate(to: .plan(copy.id))
    }

    /// Whether the plan's end date has passed (it is paused or finished).
    static func isEnded(_ plan: InvestmentPlan, today: Day) -> Bool {
        plan.nextDueDate(after: today) == nil
    }

    static func tsv(_ rows: [PlanRow]) -> String {
        TSV.string(
            header: ["Name", "Type", "Security / Account", "Amount", "Currency", "Interval (months)", "Start", "End", "Next Due",
                     "Executions", "Total", "Status"],
            rows: rows.map { row in
                [row.name, row.kindTitle, row.target, TSV.number(row.amount.decimalValue), row.amount.currency,
                 String(row.intervalMonths), row.start.iso, row.end?.iso ?? "", row.nextDue?.iso ?? "", String(row.executions),
                 TSV.number(Money(minor: row.total, currency: row.amount.currency).decimalValue), row.state.title]
            })
    }
}
