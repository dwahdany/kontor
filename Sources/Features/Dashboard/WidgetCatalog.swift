import SwiftUI
import KontorUI

/// The widget catalogue. Raw values are the **stable ids** stored in `Dashboard.Widget.kind` — never
/// rename them. Kinds that this build does not know render a graceful "unsupported widget" tile and
/// are preserved in the file untouched.
enum WidgetKind: String, CaseIterable, Sendable, Identifiable {
    case netWorth = "total-value"
    case ttwror = "ttwror"
    case annualizedReturn = "ttwror-annualized"
    case irr = "irr"
    case absoluteGain = "absolute-gain"
    case performanceChart = "performance-chart"
    case valueChart = "value-chart"
    case allocation = "allocation"
    case topMovers = "top-movers"
    case holdings = "holdings"
    case earnings = "earnings"
    case maxDrawdown = "max-drawdown"
    case volatility = "volatility"
    case sharpeRatio = "sharpe-ratio"
    case monthlyReturns = "monthly-returns"
    case cash = "cash"
    case upcomingPlans = "upcoming-plans"
    case recentTransactions = "recent-transactions"
    case watchlist = "watchlist"
    case consistency = "consistency"
    case gettingStarted = "getting-started"

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case performance = "Performance"
        case risk = "Risk"
        case positions = "Positions"
        case income = "Income"
        case activity = "Activity"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .performance: "chart.line.uptrend.xyaxis"
            case .risk: "waveform.path.ecg"
            case .positions: "briefcase"
            case .income: "banknote"
            case .activity: "clock"
            }
        }
    }

    /// The visual family: decides the nominal height and the header style.
    enum Shape { case tile, chart, list }

    var title: String {
        switch self {
        case .netWorth: "Net Worth"
        case .ttwror: "Time-Weighted Return"
        case .annualizedReturn: "Annualized Return"
        case .irr: "Internal Rate of Return"
        case .absoluteGain: "Absolute Gain"
        case .performanceChart: "Performance"
        case .valueChart: "Value vs. Invested Capital"
        case .allocation: "Allocation"
        case .topMovers: "Top Movers"
        case .holdings: "Largest Holdings"
        case .earnings: "Dividends & Interest"
        case .maxDrawdown: "Max Drawdown"
        case .volatility: "Volatility"
        case .sharpeRatio: "Sharpe Ratio"
        case .monthlyReturns: "Monthly Returns"
        case .cash: "Cash Balances"
        case .upcomingPlans: "Upcoming Plans"
        case .recentTransactions: "Recent Transactions"
        case .watchlist: "Watchlist"
        case .consistency: "Consistency Check"
        case .gettingStarted: "Getting Started"
        }
    }

    var summary: String {
        switch self {
        case .netWorth: "Total value with the latest day's change and a sparkline of the period."
        case .ttwror: "Return of the period, independent of deposits and withdrawals."
        case .annualizedReturn: "The time-weighted return expressed per year."
        case .irr: "Money-weighted return: what your own cash flows earned per year."
        case .absoluteGain: "What the period earned in money, after deposits and withdrawals."
        case .performanceChart: "Cumulative return over time, compared with your benchmarks."
        case .valueChart: "Portfolio value against the capital you put in."
        case .allocation: "How the portfolio is split along one of your taxonomies."
        case .topMovers: "Best and worst positions of the period — or of the day."
        case .holdings: "Your biggest positions by weight."
        case .earnings: "Dividends and interest of the last twelve months, or per year."
        case .maxDrawdown: "The deepest fall from a peak within the period."
        case .volatility: "How much the daily returns fluctuate, per year."
        case .sharpeRatio: "Return earned per unit of risk taken."
        case .monthlyReturns: "A year-by-month heatmap of returns for the last calendar years."
        case .cash: "Balances of your cash accounts."
        case .upcomingPlans: "Next executions of your savings plans and standing orders."
        case .recentTransactions: "The latest transactions in the ledger."
        case .watchlist: "Securities you follow, with price trend."
        case .consistency: "Problems the consistency check found in your data."
        case .gettingStarted: "A short checklist for setting up a new portfolio."
        }
    }

    var symbol: String {
        switch self {
        case .netWorth: "sum"
        case .ttwror: "chart.line.uptrend.xyaxis"
        case .annualizedReturn: "calendar.badge.clock"
        case .irr: "arrow.triangle.2.circlepath"
        case .absoluteGain: "plusminus"
        case .performanceChart: "chart.xyaxis.line"
        case .valueChart: "chart.line.flattrend.xyaxis"
        case .allocation: "chart.pie"
        case .topMovers: "arrow.up.arrow.down"
        case .holdings: "list.number"
        case .earnings: "banknote"
        case .maxDrawdown: "arrow.down.right"
        case .volatility: "waveform.path.ecg"
        case .sharpeRatio: "scalemass"
        case .monthlyReturns: "tablecells"
        case .cash: "creditcard"
        case .upcomingPlans: "calendar"
        case .recentTransactions: "clock"
        case .watchlist: "eye"
        case .consistency: "checkmark.shield"
        case .gettingStarted: "checklist"
        }
    }

    var category: Category {
        switch self {
        case .netWorth, .gettingStarted, .consistency: .overview
        case .ttwror, .annualizedReturn, .irr, .absoluteGain, .performanceChart, .valueChart, .monthlyReturns: .performance
        case .maxDrawdown, .volatility, .sharpeRatio: .risk
        case .allocation, .topMovers, .holdings, .watchlist: .positions
        case .earnings, .cash: .income
        case .upcomingPlans, .recentTransactions: .activity
        }
    }

    var shape: Shape {
        switch self {
        case .netWorth, .ttwror, .annualizedReturn, .irr, .absoluteGain, .maxDrawdown, .volatility, .sharpeRatio, .consistency: .tile
        case .performanceChart, .valueChart, .allocation, .earnings, .monthlyReturns: .chart
        case .topMovers, .holdings, .cash, .upcomingPlans, .recentTransactions, .watchlist, .gettingStarted: .list
        }
    }

    var defaultSpan: Int {
        switch self {
        case .performanceChart: 4
        case .valueChart, .allocation, .earnings, .monthlyReturns, .topMovers, .holdings, .recentTransactions, .watchlist, .gettingStarted: 2
        default: 1
        }
    }

    /// The finance term the tile shows — a ⓘ next to the title explains it.
    var helpTopic: HelpTopic? {
        switch self {
        case .ttwror: .ttwror
        case .annualizedReturn: .annualizedReturn
        case .irr: .irr
        case .absoluteGain: .absolutePerformance
        case .performanceChart: .benchmark
        case .valueChart: .investedCapital
        case .allocation: .allocation
        case .maxDrawdown: .maxDrawdown
        case .volatility: .volatility
        case .sharpeRatio: .sharpeRatio
        case .earnings: .grossVersusNet
        case .upcomingPlans: .savingsPlan
        case .consistency: .consistencyCheck
        default: nil
        }
    }

    /// Whether the numbers depend on the reporting period (and so can override it).
    ///
    /// Monthly returns are not in this list on purpose: the grid is made of whole calendar years
    /// since the first transaction and `count` says how many of them to show — a reporting period
    /// could only cut years in half (a "Year" total over six months) or pad the grid with months
    /// from before the portfolio existed.
    var usesPeriod: Bool {
        switch self {
        case .netWorth, .ttwror, .annualizedReturn, .irr, .absoluteGain, .performanceChart, .valueChart, .topMovers,
             .maxDrawdown, .volatility, .sharpeRatio, .watchlist: true
        default: false
        }
    }

    /// Statements of one day (what is held, where, how it is split). They have no period of their
    /// own but are valued on the **last day of the window's period**, so they always add up to the
    /// net worth shown next to them — today for every period that runs until today.
    var isSnapshot: Bool {
        switch self {
        case .allocation, .holdings, .cash: true
        default: false
        }
    }

    /// Lists of the whole document that deliberately ignore the window's scope; they say so with
    /// a chip while the window is narrowed to a part of the portfolio.
    var alwaysShowsWholePortfolio: Bool {
        switch self {
        case .upcomingPlans, .recentTransactions, .consistency: true
        default: false
        }
    }

    /// Whether the numbers depend on the scope (and so can override it).
    var usesScope: Bool {
        switch self {
        case .upcomingPlans, .recentTransactions, .watchlist, .consistency, .gettingStarted: false
        default: true
        }
    }

    /// Whether `count` (number of rows) is configurable.
    var usesCount: Bool {
        switch self {
        case .topMovers, .holdings, .recentTransactions, .upcomingPlans, .monthlyReturns: true
        default: false
        }
    }

    var defaultCount: Int {
        switch self {
        case .topMovers: 3
        case .holdings: 6
        case .recentTransactions: 6
        case .upcomingPlans: 5
        case .monthlyReturns: 6
        default: 0
        }
    }

    var countRange: ClosedRange<Int> {
        switch self {
        case .topMovers: 1...8
        case .monthlyReturns: 1...15
        default: 3...15
        }
    }

    var countLabel: String {
        switch self {
        case .topMovers: "Positions per side"
        case .monthlyReturns: "Years"
        default: "Rows"
        }
    }

    /// The screen a click on the tile's title opens.
    var destination: AppScreen? {
        switch self {
        case .netWorth, .holdings, .topMovers: .holdings
        case .ttwror, .annualizedReturn, .irr, .absoluteGain, .performanceChart, .valueChart, .maxDrawdown, .volatility,
             .sharpeRatio, .monthlyReturns: .performance
        case .allocation: .allocation
        case .earnings: .earnings
        case .cash: .accounts
        case .upcomingPlans: .plans
        case .recentTransactions: .transactions
        case .watchlist: .securities
        case .consistency, .gettingStarted: nil
        }
    }

    /// Height used for gallery previews and placeholders.
    var nominalHeight: CGFloat {
        switch shape {
        case .tile: 112
        case .chart: 300
        case .list: 250
        }
    }
}

// MARK: - Widget configuration

/// Keys of `Dashboard.Widget.config`. Values are plain strings so files stay readable:
///
/// | key | value |
/// |---|---|
/// | `period` | `ReportingPeriod.code` (`YTD`, `1M`, `ALL`/`max`, `2024`, `2024-01-01..2024-06-30`; case-insensitive) or the JSON encoding of a `ReportingPeriod`. Absent = follow the window. |
/// | `scope` | `ScopeSelection.stringValue` (`portfolio`, `depot:<uuid>`, `account:<uuid>`, `classification:<t>/<c>`) or the JSON encoding of a `ScopeSelection`. Absent = follow the window. |
/// | `taxonomy` | taxonomy UUID (allocation). Absent = the first taxonomy. |
/// | `benchmark` | security UUID, or `none` (performance chart). Absent = the portfolio's benchmarks. |
/// | `count` | number of rows / years |
/// | `grouping` | `month` (trailing twelve months, default) or `year` (earnings) |
/// | `mode` | `period` (default) or `day` (top movers) |
/// | `watchlist` | watchlist UUID. Absent = the first watchlist. |
enum WidgetConfigKey {
    static let period = "period"
    static let scope = "scope"
    static let taxonomy = "taxonomy"
    static let benchmark = "benchmark"
    static let count = "count"
    static let grouping = "grouping"
    static let mode = "mode"
    static let watchlist = "watchlist"
}

extension Dashboard.Widget {
    static let spanRange = 1...4

    var widgetKind: WidgetKind? { WidgetKind(rawValue: kind) }

    /// The user's title, or the catalogue name.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return widgetKind?.title ?? "Unsupported Widget"
    }

    /// The title on the tile. "Net Worth" is the name of the whole portfolio's value only: a depot,
    /// an account or a classification has a "Value".
    func displayTitle(isPartialScope: Bool) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, isPartialScope, widgetKind == .netWorth { return "Value" }
        return displayTitle
    }

    var clampedSpan: Int { min(max(span, Self.spanRange.lowerBound), Self.spanRange.upperBound) }

    /// References of this widget that no longer resolve in `file` (a deleted depot, taxonomy,
    /// benchmark security or watchlist), as sentences for the tile's warning.
    func danglingReferences(in file: PortfolioFile) -> [String] {
        guard let kind = widgetKind else { return [] }
        var notes: [String] = []
        if kind.usesScope, let scope = scopeOverride, scope.resolve(in: file) == nil {
            notes.append("The scope this widget was fixed to no longer exists. It follows the window's scope.")
        }
        if kind.usesPeriod, let text = config[WidgetConfigKey.period], !text.isEmpty, periodOverride == nil {
            notes.append("The period “\(text)” this widget was fixed to is not understood. It follows the window's period.")
        }
        switch kind {
        case .allocation:
            if let id = uuid(WidgetConfigKey.taxonomy), !file.taxonomies.isEmpty, !file.taxonomies.contains(where: { $0.id == id }) {
                notes.append("The taxonomy chosen for this widget no longer exists. It shows “\(file.taxonomies[0].name)”.")
            }
        case .performanceChart:
            if let id = uuid(WidgetConfigKey.benchmark), !file.securities.contains(where: { $0.id == id }) {
                notes.append("The security this widget was compared with no longer exists.")
            }
        case .watchlist:
            if let id = uuid(WidgetConfigKey.watchlist), !file.watchlists.isEmpty, !file.watchlists.contains(where: { $0.id == id }) {
                notes.append("The watchlist chosen for this widget no longer exists. It shows “\(file.watchlists[0].name)”.")
            }
        default:
            break
        }
        return notes
    }

    /// The widget without references that no longer resolve in `file` — what the tile effectively
    /// shows. The settings sheet edits this, so its pickers show real choices and "Done" cleans
    /// the file. Settings the kind does not use (a period on a period-less widget) are dropped too.
    func normalized(in file: PortfolioFile) -> Dashboard.Widget {
        guard let kind = widgetKind else { return self }
        var copy = self
        if !kind.usesScope || scopeOverride?.resolve(in: file) == nil { copy.config[WidgetConfigKey.scope] = nil }
        if !kind.usesPeriod || periodOverride == nil { copy.config[WidgetConfigKey.period] = nil }
        func drop(_ key: String, unless exists: (UUID) -> Bool) {
            guard let text = config[key], text.lowercased() != "none" else { return }
            if let id = UUID(uuidString: text), exists(id) { return }
            copy.config[key] = nil
        }
        switch kind {
        case .allocation:
            drop(WidgetConfigKey.taxonomy) { id in file.taxonomies.contains { $0.id == id } }
        case .performanceChart:
            drop(WidgetConfigKey.benchmark) { id in file.securities.contains { $0.id == id } }
        case .watchlist:
            drop(WidgetConfigKey.watchlist) { id in file.watchlists.contains { $0.id == id } }
        default:
            break
        }
        return copy
    }

    init(_ kind: WidgetKind, title: String = "", span: Int? = nil, config: [String: String] = [:]) {
        self.init(kind: kind.rawValue, title: title, span: span ?? kind.defaultSpan, config: config)
    }

    var periodOverride: ReportingPeriod? {
        get {
            guard let text = config[WidgetConfigKey.period], !text.isEmpty else { return nil }
            if let period = ReportingPeriod(code: text) { return period }
            return try? JSONDecoder().decode(ReportingPeriod.self, from: Data(text.utf8))
        }
        set { config[WidgetConfigKey.period] = newValue?.code }
    }

    var scopeOverride: ScopeSelection? {
        get {
            guard let text = config[WidgetConfigKey.scope], !text.isEmpty else { return nil }
            if let scope = ScopeSelection(string: text) { return scope }
            return try? JSONDecoder().decode(ScopeSelection.self, from: Data(text.utf8))
        }
        set { config[WidgetConfigKey.scope] = newValue?.stringValue }
    }

    var count: Int {
        get {
            guard let kind = widgetKind else { return 0 }
            let stored = config[WidgetConfigKey.count].flatMap { Int($0) } ?? kind.defaultCount
            return min(max(stored, kind.countRange.lowerBound), kind.countRange.upperBound)
        }
        set { config[WidgetConfigKey.count] = widgetKind?.defaultCount == newValue ? nil : String(newValue) }
    }

    func uuid(_ key: String) -> UUID? { config[key].flatMap { UUID(uuidString: $0) } }

    var groupsEarningsByYear: Bool { config[WidgetConfigKey.grouping]?.lowercased() == "year" }
    var showsMoversOfTheDay: Bool { config[WidgetConfigKey.mode]?.lowercased() == "day" }
    var hidesBenchmarks: Bool { config[WidgetConfigKey.benchmark]?.lowercased() == "none" }
}

// MARK: - Defaults

enum DashboardDefaults {
    /// Id of the dashboard shown for files that do not contain one yet. It is written to the file
    /// with the first edit.
    static let implicitID = UUID(uuidString: "D0A5B0A2-0000-4000-8000-00000000D001")!

    /// The default widget set ("Reset to Default").
    static func widgets(for file: PortfolioFile) -> [Dashboard.Widget] {
        var allocation = [String: String]()
        if let taxonomy = file.taxonomies.first { allocation[WidgetConfigKey.taxonomy] = taxonomy.id.uuidString }
        var widgets: [Dashboard.Widget] = [
            .init(.netWorth),
            .init(.ttwror),
            .init(.irr),
            .init(.absoluteGain),
            .init(.performanceChart),
            .init(.allocation, config: allocation),
            .init(.holdings),
            .init(.earnings),
            .init(.topMovers),
            .init(.recentTransactions),
        ]
        if !file.plans.isEmpty { widgets.append(.init(.upcomingPlans, span: 1)) }
        widgets.append(.init(.cash))
        if file.plans.isEmpty { widgets.append(.init(.consistency)) }
        return widgets
    }

    /// The dashboard of a file that has none. Widget ids are deterministic, so the implicit
    /// dashboard is the same value every time it is asked for (stable view identity, and edits
    /// can address its widgets).
    static func dashboard(for file: PortfolioFile) -> Dashboard {
        Dashboard(id: implicitID, name: "Overview", widgets: widgets(for: file).enumerated().map { index, widget in
            var widget = widget
            widget.id = stableID(0xD0, index)
            return widget
        })
    }

    private static func stableID(_ group: Int, _ index: Int) -> UUID {
        UUID(uuidString: "D0A5B0A2-0000-4000-8000-00000000" + String(group, radix: 16) + String(index + 16, radix: 16))!
    }

    /// One of everything — for the widget gallery review (`--state dashboard=catalog`); never saved.
    static func catalog(for file: PortfolioFile) -> Dashboard {
        Dashboard(id: UUID(uuidString: "D0A5B0A2-0000-4000-8000-00000000D002")!, name: "All Widgets",
                  widgets: WidgetKind.allCases.enumerated().map { index, kind in
                      Dashboard.Widget(id: stableID(0xE0, index), kind: kind.rawValue, span: kind.defaultSpan)
                  })
    }

    /// A name that is not taken yet: "Dashboard", "Dashboard 2", …
    static func uniqueName(_ base: String, in file: PortfolioFile) -> String {
        let taken = Set(file.dashboards.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
