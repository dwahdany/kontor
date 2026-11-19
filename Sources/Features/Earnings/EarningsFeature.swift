import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Earnings feature with the app shell. The executable lists `EarningsFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Earnings` needs to change.
public enum EarningsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.earnings) { EarningsScreen() }
            .commands { store in
                [
                    // "New Dividend" / "New Interest" come from the transaction editor's feature — no duplicates here.
                    PaletteCommand(id: "earnings.export-months", title: "Export Dividends by Month as CSV",
                                   subtitle: "Year × month table, all years", symbol: "square.and.arrow.up",
                                   keywords: ["earnings", "income", "matrix", "save"]) {
                        exportMatrix(store, copy: false)
                    },
                    PaletteCommand(id: "earnings.copy-months", title: "Copy Dividends by Month",
                                   subtitle: "Year × month table for pasting into a spreadsheet", symbol: "doc.on.doc",
                                   keywords: ["earnings", "income", "matrix", "clipboard", "tsv"]) {
                        exportMatrix(store, copy: true)
                    },
                ]
            }
            .inspector { EarningsInspector() }
    }

    /// The dividends matrix of the window's scope over all years — the same cached model the screen shows.
    @MainActor private static func exportMatrix(_ store: PortfolioStore, copy: Bool) {
        let interval = store.interval(for: .allTime)
        let query = EarningsModel.Query(kind: .dividends, today: store.today, allYears: interval)
        Task {
            guard let model = try? await store.analyze("earnings.model", interval: interval, variant: query, { analysis in
                EarningsModel(analysis, query: query)
            }) else { return }
            if copy {
                let table = EarningsExport.matrix(model)
                Pasteboard.copy(TSV.string(header: table.header, rows: table.rows))
                store.toast("Copied \(Fmt.integer(table.rows.count)) rows", style: .success)
            } else {
                EarningsExport.save(EarningsExport.matrix(model, numbers: .plain), store: store)
            }
        }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
