import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Plans feature with the app shell. The executable lists `PlansFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Plans` needs to change.
///
/// Sheets owned by this feature: `.newPlan(PlanPrefill)`, `.editPlan(id)` and the feature-private
/// `.custom(id: "plans.generate", payload: ["plan": "<uuid>"])` (no payload = all plans).
public enum PlansFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.plans) { PlansScreen() }
            .commands { store in commands(store) }
            .inspector { PlanInspector() }
            .sheet { request in
                if case .newPlan(let prefill) = request {
                    PlanEditor(mode: .new(prefill))
                } else if case .editPlan(let id) = request {
                    PlanEditor(mode: .edit(id))
                } else if case .custom(id: PlanActions.generateSheetID, let payload) = request {
                    GenerateSheet(planID: payload["plan"].flatMap(UUID.init(uuidString:)))
                }
            }
    }

    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        var commands = [
            PaletteCommand(
                id: "plans.generate", title: "Generate Due Plan Transactions…",
                subtitle: "Review and add the plan executions that are due", symbol: "calendar.badge.plus",
                keywords: ["savings plan", "execute", "due", "recurring", "book"]
            ) { PlanActions.generate(in: store) },
            PaletteCommand(
                id: "plans.new-purchase", title: "New Savings Plan…", subtitle: "Buy a security at a regular interval",
                symbol: "cart", keywords: ["purchase plan", "recurring", "monthly", "etf"]
            ) { store.present(.newPlan(PlanPrefill(kind: .purchase))) },
            PaletteCommand(
                id: "plans.new-deposit", title: "New Deposit Plan…", subtitle: "Book a regular deposit",
                symbol: "arrow.down.to.line", keywords: ["recurring", "monthly", "standing order"]
            ) { store.present(.newPlan(PlanPrefill(kind: .deposit))) },
            PaletteCommand(
                id: "plans.new-withdrawal", title: "New Withdrawal Plan…", subtitle: "Book a regular withdrawal",
                symbol: "arrow.up.to.line", keywords: ["recurring", "payout", "monthly"]
            ) { store.present(.newPlan(PlanPrefill(kind: .withdrawal))) },
        ]
        commands += store.file.plans.map { plan in
            PaletteCommand(
                id: "plans.show.\(plan.id.uuidString)", title: plan.name,
                subtitle: "\(plan.kind.title) plan · \(Fmt.money(plan.amount)) \(PlanText.interval(plan.intervalMonths).lowercased())",
                symbol: "calendar.badge.clock", category: .navigation, keywords: ["plan"]
            ) { store.navigate(to: .plan(plan.id)) }
        }
        return commands
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
