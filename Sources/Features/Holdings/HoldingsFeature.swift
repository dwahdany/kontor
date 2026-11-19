import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Holdings feature with the app shell. The executable lists `HoldingsFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Holdings` needs to change.
public enum HoldingsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.holdings) { HoldingsScreen() }
            .commands { store in commands(store) }
            .inspector { HoldingsInspector() }
    }

    /// Palette commands: views of the statement (they open the screen), copy and export.
    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        let state = HoldingsViewState.of(store)
        func show(_ change: @escaping @MainActor (HoldingsViewState) -> Void) -> @MainActor () -> Void {
            {
                state.isSeeded = true
                change(state)
                if store.route.screen != .holdings { store.navigate(to: .holdings) }
            }
        }
        var commands = [
            PaletteCommand(id: "holdings.group.none", title: "Holdings: No Grouping", symbol: "list.bullet", keywords: ["flat", "ungroup"],
                           action: show { $0.grouping = .none }),
            PaletteCommand(id: "holdings.group.depot", title: "Holdings: Group by Depot & Account", symbol: "briefcase", keywords: ["broker", "subtotal"],
                           action: show { $0.grouping = .depot }),
            PaletteCommand(id: "holdings.group.currency", title: "Holdings: Group by Currency", symbol: "dollarsign.circle", keywords: ["fx", "subtotal"],
                           action: show { $0.grouping = .currency }),
        ]
        for taxonomy in store.file.taxonomies {
            commands.append(PaletteCommand(
                id: "holdings.group.taxonomy.\(taxonomy.id.uuidString)", title: "Holdings: Group by \(taxonomy.name)", symbol: "square.stack.3d.up",
                keywords: ["taxonomy", "classification", "subtotal"], action: show { $0.grouping = .taxonomy(taxonomy.id) }))
        }
        commands += [
            PaletteCommand(id: "holdings.view.treemap", title: "Holdings: Show Treemap", subtitle: "Weight and period return",
                           symbol: HoldingsVisual.treemap.symbol, keywords: ["heatmap", "chart"], action: show { $0.visual = .treemap }),
            PaletteCommand(id: "holdings.view.concentration", title: "Holdings: Show Concentration", subtitle: "Share of the largest positions",
                           symbol: HoldingsVisual.concentration.symbol, keywords: ["top holdings", "chart", "risk"], action: show { $0.visual = .concentration }),
            PaletteCommand(id: "holdings.view.table", title: "Holdings: Table Only", symbol: HoldingsVisual.table.symbol, keywords: ["hide chart"],
                           action: show { $0.visual = .table }),
        ]
        for jump in HoldingsDayJump.allCases {
            let day = jump.day(today: store.today)
            commands.append(PaletteCommand(
                id: "holdings.day.\(jump.rawValue)", title: "Holdings as of \(jump.title)", subtitle: Fmt.day(day, style: .medium), symbol: "calendar",
                keywords: ["statement", "date", "assets"], action: show { $0.setDay(day, in: store) }))
        }
        commands.append(PaletteCommand(
            id: "holdings.closed", title: state.options.includesClosed ? "Holdings: Hide Closed Positions" : "Holdings: Include Positions Closed in the Period",
            symbol: "checkmark.circle", keywords: ["sold"], action: show { $0.options.includesClosed.toggle() }))
        if store.route.screen == .holdings, !state.display.lines.isEmpty {
            commands += [
                PaletteCommand(id: "holdings.copy", title: "Copy Holdings Table", subtitle: "Tab-separated, as shown", symbol: "doc.on.doc",
                               keywords: ["tsv", "clipboard", "spreadsheet"]) { HoldingsActions.copy([], in: store) },
                PaletteCommand(id: "holdings.export", title: "Export Holdings as CSV…", subtitle: "The table as shown", symbol: "square.and.arrow.up",
                               keywords: ["save", "file", "spreadsheet"]) { HoldingsActions.exportCSV(in: store) },
            ]
        }
        return commands
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
