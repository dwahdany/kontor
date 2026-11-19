import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Allocation feature with the app shell. The executable lists `AllocationFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Allocation` needs to change.
public enum AllocationFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.allocation) { AllocationScreen() }
            .commands { store in commands(store) }
            .inspector { AllocationInspector() }
            .sheet { request in
                if case .custom(id: SplitSheet.requestID, let payload) = request {
                    SplitSheet(payload: payload)
                } else if case .custom(id: RebalancingReviewSheet.requestID, let payload) = request {
                    RebalancingReviewSheet(payload: payload)
                }
            }
    }

    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        let session = AllocationSession.session(for: store)
        func open(_ tab: AllocationSession.Tab, taxonomy: UUID? = nil) {
            if let taxonomy { session.taxonomyID = taxonomy }
            session.tab = tab
            // The screen is (re)created by the navigation below; its restored tab must not win.
            session.hasExplicitTab = true
            if let id = taxonomy ?? session.taxonomy(in: store.file)?.id {
                store.navigate(to: .taxonomy(id))
            } else {
                store.navigate(to: .allocation)
            }
        }
        var commands: [PaletteCommand] = [
            PaletteCommand(
                id: "allocation.rebalance", title: "Rebalance Portfolio…", subtitle: "Propose trades that bring the allocation back to its targets",
                symbol: "scalemass", keywords: ["rebalancing", "target", "invest", "buy", "sell"]
            ) { open(.rebalancing) },
            PaletteCommand(
                id: "allocation.edit", title: "Edit Classifications and Targets", subtitle: session.taxonomy(in: store.file)?.name,
                symbol: "slider.horizontal.3", keywords: ["taxonomy", "assign", "target weight", "classification"]
            ) { open(.edit) },
        ]
        for taxonomy in store.file.taxonomies {
            commands.append(PaletteCommand(
                id: "allocation.show.\(taxonomy.id.uuidString)", title: "Allocation by \(taxonomy.name)", symbol: "chart.pie",
                category: .navigation, keywords: ["taxonomy", "allocation"]
            ) { open(.allocation, taxonomy: taxonomy.id) })
        }
        for template in TaxonomyTemplate.allCases {
            commands.append(PaletteCommand(
                id: "allocation.new.\(template.rawValue)", title: "New Taxonomy: \(template.title)", subtitle: template.summary,
                symbol: template.symbol, keywords: ["taxonomy", "template", "create"]
            ) {
                let taxonomy = template.make(in: store.file)
                store.upsertTaxonomy(taxonomy, actionName: "New Taxonomy")
                open(template == .currency ? .allocation : .edit, taxonomy: taxonomy.id)
            })
        }
        if let taxonomy = session.taxonomy(in: store.file) {
            commands.append(PaletteCommand(
                id: "allocation.copy", title: "Copy Allocation as TSV", subtitle: taxonomy.name, symbol: "doc.on.doc",
                keywords: ["export", "clipboard", "spreadsheet"]
            ) {
                Task { @MainActor in
                    let key = store.allocationKey(for: taxonomy)
                    guard let model = try? await store.analyze("allocation.model", variant: key, { analysis in
                        AllocationModel(analysis, taxonomy: taxonomy, scopeRoot: key.scopeRoot)
                    }) else { return }
                    Pasteboard.copy(model.tsv())
                    store.toast("Copied the allocation of “\(taxonomy.name)”", style: .success)
                }
            })
        }
        return commands
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
