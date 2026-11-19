import SwiftUI
import KontorInterchange
import KontorModel
import KontorUI

/// Registration of the Import feature with the app shell. The executable lists `ImportFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, sheets) is
/// declared here, so no file outside `Sources/Features/Import` needs to change.
///
/// Sheets owned by this feature:
/// * `.importFile(URL?)` — `ImportSheet`: Portfolio Performance summary, CSV wizard, guidance.
/// * `.export(ExportRequest)` — `ExportSheet`.
/// * `.custom(id: "import.export", payload: ["format": …])` — the export sheet opened on a format
///   `ExportRequest` cannot name (`holdings`, `pp`, `json`, also `transactions`, `quotes`, `securities`).
public enum ImportFeature {
    /// Id of the feature-private export request (see above).
    public static let exportSheetID = "import.export"

    @MainActor public static var module: FeatureModule {
        FeatureModule(.`import`) { ImportScreen() }
            .commands { store in commands(store) }
            .sheet { request in
                if case .importFile(let url) = request {
                    ImportSheet(url: url)
                } else if case .export(let export) = request {
                    ExportSheet(request: export)
                } else if case .custom(id: exportSheetID, let payload) = request {
                    ExportSheet(request: ExportRequest(), initialFormat: payload["format"].flatMap(ExportFormat.init(rawValue:)))
                }
            }
    }

    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        func export(_ format: ExportFormat, _ title: String, keywords: [String]) -> PaletteCommand {
            PaletteCommand(id: "import.export-\(format.rawValue)", title: title, symbol: format.symbol, keywords: ["export", "save"] + keywords) {
                store.present(.custom(id: exportSheetID, payload: ["format": format.rawValue]))
            }
        }
        func choose(_ id: String, _ title: String, symbol: String, target: CSVImportTarget?, keywords: [String]) -> PaletteCommand {
            PaletteCommand(id: id, title: title, symbol: symbol, keywords: ["import"] + keywords) {
                chooseFile(store, target: target)
            }
        }
        var commands = [
            choose("import.portfolio-performance", "Import Portfolio Performance File…", symbol: "shippingbox", target: nil, keywords: ["pp", "xml", "migrate"]),
            choose("import.csv-transactions", "Import Transactions from CSV…", symbol: "tablecells", target: .transactions, keywords: ["broker", "bank", "csv"]),
            choose("import.csv-quotes", "Import Quotes from CSV…", symbol: "chart.line.uptrend.xyaxis", target: .quotes, keywords: ["prices", "history", "csv"]),
            choose("import.csv-securities", "Import Securities from CSV…", symbol: "building.columns", target: .securities, keywords: ["list", "csv"]),
        ]
        if !store.file.isBlank {
            commands += [
                export(.transactions, "Export Transactions as CSV…", keywords: ["ledger", "spreadsheet", "excel"]),
                export(.holdings, "Export Holdings as CSV…", keywords: ["positions", "statement", "spreadsheet", "excel"]),
                export(.quotes, "Export Quotes as CSV…", keywords: ["prices", "history"]),
                export(.securities, "Export Securities as CSV…", keywords: ["master data"]),
                export(.portfolioPerformance, "Export for Portfolio Performance (XML)…", keywords: ["pp", "xml"]),
                export(.json, "Export as Kontor JSON…", keywords: ["copy", "backup"]),
            ]
        }
        return commands
    }

    /// Asks for a file (open panel) and hands it to the import sheet. `target` pre-selects what a CSV contains.
    @MainActor static func chooseFile(_ store: PortfolioStore, target: CSVImportTarget?) {
        guard let url = ImportPanels.chooseFile(message: message(for: target)) else { return }
        ImportHints.preferredTarget = target
        store.present(.importFile(url))
    }

    nonisolated private static func message(for target: CSVImportTarget?) -> String {
        switch target {
        case nil: "Choose a Portfolio Performance file or a CSV file"
        case .transactions: "Choose a CSV file with transactions"
        case .quotes: "Choose a CSV file with the quotes of one security"
        case .securities: "Choose a CSV file with a list of securities"
        }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
