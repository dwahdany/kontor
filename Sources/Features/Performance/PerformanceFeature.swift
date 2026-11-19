import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Performance feature with the app shell. The executable lists `PerformanceFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector)
/// is declared here, so no file outside `Sources/Features/Performance` needs to change.
public enum PerformanceFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.performance) { PerformanceScreen() }
            .commands { store in commands(store) }
            .inspector { PerformanceInspector() }
    }

    @MainActor static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        let center = PerformanceCommandCenter.shared
        var commands = PerformanceTab.allCases.enumerated().map { index, tab in
            PaletteCommand(id: "performance.tab.\(tab.rawValue)", title: "Performance: \(tab.title)",
                           subtitle: subtitle(tab), symbol: tab.symbol, category: .navigation,
                           keywords: keywords(tab), shortcut: "⌃\(index + 1)") {
                center.show(tab: tab, in: store)
            }
        }
        commands += [
            PaletteCommand(id: "performance.chart.returns", title: "Performance: Compare Return with Benchmarks",
                           symbol: "chart.line.uptrend.xyaxis", category: .navigation, keywords: ["benchmark", "index", "chart", "ttwror"]) {
                center.show(chart: .returns, in: store)
            },
            PaletteCommand(id: "performance.chart.value", title: "Performance: Value and Invested Capital",
                           symbol: "chart.xyaxis.line", category: .navigation, keywords: ["chart", "invested", "deposits", "net worth"]) {
                center.show(chart: .value, in: store)
            },
            PaletteCommand(id: "performance.chart.drawdown", title: "Performance: Drawdown Chart",
                           symbol: "arrow.down.right", category: .navigation, keywords: ["underwater", "loss", "risk", "chart"]) {
                center.show(chart: .drawdown, in: store)
            },
            PaletteCommand(id: "performance.copy-summary", title: "Copy Performance Summary",
                           subtitle: "\(store.scopeTitle) · \(Fmt.interval(store.periodInterval))", symbol: "doc.on.doc",
                           keywords: ["ttwror", "irr", "export", "clipboard", "tsv"]) {
                copySummary(store)
            },
            PaletteCommand(id: "performance.copy-securities", title: "Copy Performance by Security as TSV",
                           subtitle: "\(store.scopeTitle) · \(Fmt.interval(store.periodInterval))", symbol: "tablecells",
                           keywords: ["export", "clipboard", "spreadsheet"]) {
                copySecurities(store)
            },
        ]
        return commands
    }

    private static func subtitle(_ tab: PerformanceTab) -> String {
        switch tab {
        case .calculation: "How the initial value became the final value"
        case .returns: "Monthly and yearly returns, rolling returns"
        case .risk: "Drawdowns, volatility, distribution of returns"
        case .securities: "What each security contributed"
        }
    }

    private static func keywords(_ tab: PerformanceTab) -> [String] {
        switch tab {
        case .calculation: ["breakdown", "waterfall", "statement", "fees", "taxes", "gains"]
        case .returns: ["heatmap", "months", "years", "rolling", "best", "worst"]
        case .risk: ["drawdown", "volatility", "sharpe", "histogram"]
        case .securities: ["contribution", "holdings", "table"]
        }
    }

    @MainActor private static func copySummary(_ store: PortfolioStore) {
        let scopeTitle = store.scopeTitle
        Task {
            guard let summary = try? await store.analyze("performance.summary", variant: scopeTitle, { PerformanceSummary($0, scopeTitle: scopeTitle) })
            else { return }
            Pasteboard.copy(summary.text)
            store.toast("Copied the performance summary", style: .success)
        }
    }

    @MainActor private static func copySecurities(_ store: PortfolioStore) {
        let query = SecuritiesQuery(filter: "", sortOrder: [KeyPathComparator(\SecurityRow.absolutePerformance, order: .reverse)])
        Task {
            guard let model = try? await store.analyze("performance.securities", variant: query, { SecuritiesModel($0, query: query) })
            else { return }
            Pasteboard.copy(SecuritiesModel.tsv(model.rows, currency: model.currency, irrIsAnnualized: model.irrIsAnnualized))
            store.toast("Copied \(Fmt.integer(model.rows.count)) \(model.rows.count == 1 ? "security" : "securities")", style: .success)
        }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
