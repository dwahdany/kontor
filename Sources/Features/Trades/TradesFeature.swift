import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Trades feature with the app shell. The executable lists `TradesFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector)
/// is declared here, so no file outside `Sources/Features/Trades` needs to change.
public enum TradesFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.trades) { TradesScreen() }
            .commands { store in commands(store) }
            .inspector { TradesInspector() }
    }

    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        let center = TradesCommandCenter.shared
        return [
            PaletteCommand(id: "trades.show-closed", title: "Show Closed Trades", subtitle: "Realized gains and losses", symbol: "checkmark.circle",
                           category: .navigation, keywords: ["realized", "sold", "round trip", "winners", "losers"]) {
                center.send(.show(.closed), to: store)
            },
            PaletteCommand(id: "trades.show-open", title: "Show Open Trades", subtitle: "Positions still held, at market value", symbol: "tray",
                           category: .navigation, keywords: ["unrealized", "positions", "lots"]) {
                center.send(.show(.open), to: store)
            },
            PaletteCommand(id: "trades.show-years", title: "Show Tax Years", subtitle: "Realized gains, dividends and taxes per calendar year",
                           symbol: "calendar", category: .navigation, keywords: ["tax", "year", "annual", "summary", "capital gains"]) {
                center.send(.show(.years), to: store)
            },
            PaletteCommand(id: "trades.export-years", title: "Export Tax Year Summary as CSV…", symbol: "square.and.arrow.up",
                           keywords: ["tax", "csv", "save", "capital gains", "dividends"]) {
                center.send(.exportYears, to: store)
            },
            PaletteCommand(id: "trades.export-trades", title: "Export Trades as CSV…", subtitle: "The listed trades, one line per lot",
                           symbol: "square.and.arrow.up", keywords: ["tax", "csv", "save", "lots", "sales", "realized"]) {
                center.send(.exportTrades, to: store)
            },
            PaletteCommand(id: "trades.copy-years", title: "Copy Tax Year Summary", symbol: "doc.on.doc",
                           keywords: ["tax", "clipboard", "tsv", "capital gains"]) {
                Task {
                    guard let model = try? await store.analyze("trades.years", interval: store.interval(for: .allTime), { TaxYearsModel($0) }) else { return }
                    Pasteboard.copy(model.tsv())
                    store.toast("Copied \(Fmt.integer(model.years.count)) tax years", style: .success)
                }
            },
            PaletteCommand(id: "trades.copy-closed", title: "Copy Closed Trades as TSV", subtitle: "Current period and scope", symbol: "doc.on.doc",
                           keywords: ["clipboard", "export", "realized"]) {
                Task {
                    let query = TradeQuery(kind: .closed, sortOrder: [KeyPathComparator(\TradeRow.end, order: .reverse)])
                    guard let model = try? await store.analyze("trades.list", variant: query, { TradeListModel($0, query: query) }) else { return }
                    Pasteboard.copy(TradeExport.tsv(model.rows, kind: .closed, currency: model.currency))
                    store.toast("Copied \(Fmt.integer(model.rows.count)) closed trades", style: .success)
                }
            },
        ]
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
