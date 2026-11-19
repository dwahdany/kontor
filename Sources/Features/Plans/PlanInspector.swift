import SwiftUI
import KontorUI

/// Inspector content while the Plans screen is active: the settings of the focused plan — the part
/// the detail pane summarises in one line — with links to what it books on.
struct PlanInspector: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        if let plan = store.plan(store.route.planID) {
            Form {
                Section("Plan") {
                    KeyValueRow("Name", plan.name)
                    KeyValueRow("Type", plan.kind.title)
                    KeyValueRow("Amount", Fmt.money(plan.amount))
                    if plan.kind == .purchase {
                        KeyValueRow("Of Which Fees", Fmt.money(minor: plan.fees, currency: plan.amount.currency))
                    }
                    KeyValueRow("Repeats", PlanText.interval(plan.intervalMonths))
                }
                Section("Schedule") {
                    KeyValueRow("First Execution", Fmt.day(plan.start, style: .medium))
                    KeyValueRow("Ends", plan.end.map { Fmt.day($0, style: .medium) } ?? "No end")
                    // As in the list: a plan that cannot be executed has no next date.
                    KeyValueRow("Next Execution", canRun(plan)
                        ? plan.nextDueDate(after: store.today).map { Fmt.day($0, style: .medium) } ?? Fmt.missing
                        : Fmt.missing)
                    KeyValueRow("Skipped Dates", Fmt.integer(plan.skippedDates?.count ?? 0))
                }
                Section("Books On") {
                    if plan.kind == .purchase {
                        link("Security", store.security(plan.securityID)?.name) {
                            if let id = plan.securityID { store.navigate(to: .security(id)) }
                        }
                        link("Depot", store.depot(plan.depotID)?.name) {
                            if let id = plan.depotID { store.navigate(to: .depot(id)) }
                        }
                    }
                    link(plan.kind == .purchase ? "Paid From" : "Account", store.account(plan.accountID)?.name) {
                        if let id = plan.accountID { store.navigate(to: .account(id)) }
                    }
                }
                if !plan.note.isEmpty {
                    Section("Note") { Text(plan.note).textSelection(.enabled) }
                }
                Section {
                    Button("Edit Plan…") { store.present(.editPlan(plan.id)) }
                } footer: {
                    Text("Executions are marked in the ledger with the source “\(plan.sourceTag.prefix(13))…”, which is how Kontor recognizes them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            EmptyState("No Plan Selected", symbol: "calendar.badge.clock", message: "Select a plan to see its settings.")
        }
    }

    /// The editor's validation mirrors the engine's plan problems and needs no pass over the ledger.
    private func canRun(_ plan: InvestmentPlan) -> Bool {
        PlanDraft(plan).validate(
            security: store.security(plan.securityID), depot: store.depot(plan.depotID), account: store.account(plan.accountID),
            currency: plan.amount.currency) == nil
    }

    private func link(_ key: String, _ name: String?, action: @escaping () -> Void) -> some View {
        KeyValueRow(key) {
            if let name {
                Button(name, action: action)
                    .buttonStyle(.link)
                    .lineLimit(1)
            } else {
                Text(Fmt.missing)
            }
        }
    }
}
