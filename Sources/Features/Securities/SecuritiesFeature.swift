import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Securities feature with the app shell. The executable lists `SecuritiesFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, sheets) is
/// declared here, so no file outside `Sources/Features/Securities` needs to change.
///
/// Sheets provided: `.newSecurity(prefill)`, `.editSecurity(id)` and the feature-private
/// `.custom(id: "securities.split", payload: ["security": uuid, "ratio": "2:1", "day": "YYYY-MM-DD"])`.
public enum SecuritiesFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.securities) { SecuritiesScreen() }
            .commands { store in commands(store) }
            .sheet { request in
                if case .newSecurity(let prefill) = request {
                    SecurityEditor(mode: .new(prefill))
                } else if case .editSecurity(let id) = request {
                    SecurityEditor(mode: .edit(id))
                } else if case .custom(id: SplitSheet.requestID, let payload) = request {
                    SplitSheet(payload: payload)
                }
            }
    }

    @MainActor static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        var commands = [
            PaletteCommand(id: "securities.new", title: "Add Security…", subtitle: "Search online or enter by hand",
                           symbol: "plus.circle", keywords: ["new", "stock", "etf", "fund", "crypto", "isin", "ticker"]) {
                store.present(.newSecurity)
            },
            PaletteCommand(id: "securities.copy", title: "Copy Securities as TSV", symbol: "doc.on.doc",
                           keywords: ["export", "clipboard", "master data"]) {
                Pasteboard.copy(store.securitiesTSV(Set(store.file.securities.map(\.id))))
                store.toast("Copied \(Fmt.integer(store.file.securities.count)) securities", style: .success)
            },
        ]
        guard let id = store.route.securityID, let security = store.security(id) else { return commands }
        let name = security.name
        commands += [
            PaletteCommand(id: "securities.edit", title: "Edit “\(name)”…", symbol: "pencil", keywords: ["security", "master data"]) {
                store.present(.editSecurity(id))
            },
            PaletteCommand(id: "securities.buy", title: "Buy “\(name)”…", symbol: Transaction.Kind.buy.symbol, keywords: ["purchase", "transaction"]) {
                store.presentNewTransaction(.buy, securityID: id)
            },
            PaletteCommand(id: "securities.split", title: "Record Stock Split for “\(name)”…", symbol: "arrow.triangle.branch",
                           keywords: ["split", "event", "adjust"]) {
                store.present(.custom(id: SplitSheet.requestID, payload: ["security": id.uuidString]))
            },
            PaletteCommand(id: "securities.benchmark",
                           title: store.isBenchmark(id) ? "Stop Using “\(name)” as Benchmark" : "Use “\(name)” as Benchmark",
                           symbol: "flag", keywords: ["benchmark", "compare"]) {
                store.toggleBenchmark(id)
            },
            PaletteCommand(id: "securities.retire", title: security.isRetired ? "Reactivate “\(name)”" : "Retire “\(name)”",
                           symbol: "archivebox", keywords: ["retire", "hide", "archive"]) {
                store.setRetired([id], !security.isRetired)
            },
            PaletteCommand(id: "securities.duplicate", title: "Duplicate “\(name)”", symbol: "plus.square.on.square", keywords: ["copy"]) {
                if let new = store.duplicateSecurity(id) { store.navigate(to: .security(new)) }
            },
        ]
        if MarketAccess.isOnline(store), MarketAccess.registry(store).isAutomatic(security.feed), !security.isRetired {
            commands.append(PaletteCommand(id: "securities.update", title: "Update Quotes of “\(name)”", symbol: "arrow.triangle.2.circlepath",
                                           keywords: ["quotes", "prices", "download", "refresh"]) {
                store.updateQuotes(only: [id])
            })
        }
        return commands
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
