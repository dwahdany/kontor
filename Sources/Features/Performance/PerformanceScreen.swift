import SwiftUI
import KontorModel
import KontorUI

/// The Performance screen: how the window's scope did over the reporting period, and why.
///
/// Header tiles (TTWROR, IRR, gain, final value, drawdown, volatility, Sharpe), the main chart
/// (return vs. benchmarks · value vs. invested capital · drawdown; drag to measure a sub-range),
/// a period comparison, and four sections: Calculation, Returns, Risk, Securities.
///
/// Launch state (`--state key=value`, read once on appear):
///
/// | key | values | effect |
/// |---|---|---|
/// | `chart` | `returns` \| `value` \| `drawdown` | main chart mode |
/// | `tab` | `calculation` \| `returns` \| `risk` \| `securities` | section below the chart |
/// | `scroll` | `tabs` | scrolls the section into view (small windows) |
/// | `hover` | `0…1` or `YYYY-MM-DD` | pins the main chart's crosshair |
/// | `range` | `YYYY-MM-DD..YYYY-MM-DD` | pins a selected sub-range and shows its figures |
/// | `compare` | security UUIDs, comma-separated | ad-hoc comparisons in the return chart |
/// | `line` | a statement line, e.g. `dividends`, `fees`, `realizedGains` | Calculation: selected line and its entries |
/// | `month` | `YYYY-MM` | Returns: the picked heatmap month |
/// | `distribution` | `daily` \| `monthly` | Risk: histogram |
/// | `filter` | text | Securities: quick filter |
/// | `sort` | `name` \| `value` \| `ttwror` \| `irr` \| `gain` \| `share` | Securities: sort column (descending, name ascending) |
///
/// Entity focus comes from `--route performance/security:<uuid>` (opens Securities with that row
/// selected); scope and period from `--scope` / `--period`.
public struct PerformanceScreen: View {
    @Environment(PortfolioStore.self) private var store

    @State private var overview = Loadable<OverviewModel>()
    @State private var calculation = Loadable<CalculationModel>()
    @State private var returns = Loadable<ReturnsModel>()
    @State private var risk = Loadable<RiskModel>()
    @State private var securities = Loadable<SecuritiesModel>()

    // `@State` is the source of truth; scene storage only persists it per window. (Scene storage
    // alone does not work where there is no scene — the headless screenshot mode.)
    @State private var tab = PerformanceTab.calculation
    @State private var chartMode = PerformanceChartMode.returns
    @State private var compareList = ""
    @SceneStorage("performance.tab") private var storedTab = PerformanceTab.calculation
    @SceneStorage("performance.chart") private var storedChartMode = PerformanceChartMode.returns
    @SceneStorage("performance.compare") private var storedCompare = ""

    @State private var pinnedHover: Day?
    @State private var pinnedHoverFraction: Double?
    @State private var pinnedRange: DayInterval?
    @State private var selectedLine: StatementLine?
    @State private var contentWidth: CGFloat = 1_100
    @State private var didReadLaunchState = false
    @State private var scrollToTop = 0
    @State private var didScrollForLaunch = false

    private static let tabsAnchor = "performance.tabs"
    private static let topAnchor = "performance.top"

    public init() {}

    public var body: some View {
        let compare = compareIDs
        Group {
            if store.file.transactions.isEmpty {
                onboarding
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .analysisTask($overview, id: "performance.overview", variant: compare) { analysis in
            OverviewModel(analysis, compare: compare)
        }
        .toolbar { ToolbarItem { ScopePicker() } }
        .onAppear(perform: readLaunchState)
        .onChange(of: tab) { _, value in storedTab = value }
        .onChange(of: chartMode) { _, value in storedChartMode = value }
        .onChange(of: compareList) { _, value in storedCompare = value }
        .onChange(of: PerformanceCommandCenter.shared.token, initial: true) { _, _ in applyPendingCommand() }
        .onChange(of: store.route.securityID, initial: true) { _, id in
            if id != nil, store.route.screen == .performance, didReadLaunchState { tab = .securities }
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    heading.id(Self.topAnchor)
                    if let model = overview.value, !model.hasActivity {
                        nothingToMeasure(model)
                    } else {
                        SummaryTiles(model: overview.value)
                            .opacity(overview.isRefreshing ? 0.6 : 1)
                        chartRow
                        tabSection.id(Self.tabsAnchor)
                    }
                }
                .screenPadding()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            .loadingOverlay(overview.isInitialLoad)
            .task(id: overview.value != nil) {
                // `--state scroll=tabs`: once there is content to scroll to.
                guard overview.value != nil, store.launchValue("scroll") == "tabs", !didScrollForLaunch else { return }
                didScrollForLaunch = true
                await store.whileBusy {
                    try? await Task.sleep(for: .milliseconds(250))
                    proxy.scrollTo(Self.tabsAnchor, anchor: .top)
                }
            }
            .onChange(of: scrollToTop) { _, _ in
                withAnimation(DS.Motion.quick) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
    }

    private var isWide: Bool { contentWidth >= 980 }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(store.scopeTitle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HelpButton(.scope)
            Text(Fmt.interval(store.periodInterval))
                .font(.callout)
                .numeric()
                .foregroundStyle(.secondary)
                .padding(.leading, DS.Spacing.xs)
            HelpButton(.reportingPeriod)
            Spacer(minLength: DS.Spacing.s)
            Text("\(Fmt.duration(days: store.periodInterval.dayCount)) · \(store.baseCurrency)")
                .font(.callout)
                .numeric()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var chartRow: some View {
        let chart = PerformanceChartCard(
            model: overview, mode: $chartMode, pinnedHover: pinnedHover ?? pinnedHoverFraction.flatMap { f in overview.value?.day(at: f) },
            pinnedRange: $pinnedRange, compare: compareIDs, addComparison: addComparison, removeComparison: removeComparison)
        if isWide {
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                chart
                PeriodComparisonCard(layout: .column)
                    .frame(width: 318)
            }
        } else {
            chart
            PeriodComparisonCard(layout: .row)
        }
    }

    private var tabSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.m) {
                Picker("Section", selection: $tab) {
                    ForEach(PerformanceTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Switch sections with ⌃1 – ⌃4")
                Spacer(minLength: 0)
            }
            .background { tabShortcuts }

            switch tab {
            case .calculation:
                CalculationTab(model: $calculation, selectedLine: $selectedLine, isWide: isWide)
            case .returns:
                ReturnsTab(model: $returns, isWide: isWide)
            case .risk:
                RiskTab(model: $risk, isWide: isWide) { interval in
                    chartMode = .drawdown
                    pinnedRange = interval
                    scrollToTop += 1
                }
            case .securities:
                SecuritiesTab(model: $securities, compare: compareIDs, addComparison: { id in
                    addComparison(id)
                    chartMode = .returns
                })
            }
        }
    }

    /// ⌃1 … ⌃4 switch sections; ⌃⌥1 … ⌃⌥3 switch the chart.
    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(PerformanceTab.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { tab = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            ForEach(Array(PerformanceChartMode.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { chartMode = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .option])
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    // MARK: Empty states

    private var onboarding: some View {
        VStack(spacing: DS.Spacing.l) {
            EmptyState("No Performance Yet", symbol: "chart.line.uptrend.xyaxis",
                       message: "Performance is measured from your transactions. Record a first deposit or purchase — or import your history — and this screen shows your return, what it is made of, and how bumpy the ride was.") {
                Button("New Transaction…") { store.present(.newTransaction(TransactionPrefill(kind: .deposit, date: store.today))) }
                    .keyboardShortcut(.defaultAction)
                Button("Import…") { store.present(.importFile) }
            }
            .frame(maxHeight: 300)
            Card {
                HelpTopicView(topic: .ttwrorVersusIRR)
            }
            .frame(maxWidth: 380)
        }
        .screenPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nothingToMeasure(_ model: OverviewModel) -> some View {
        Card {
            EmptyState("Nothing to Measure", symbol: "chart.line.flattrend.xyaxis",
                       message: "\(store.scopeTitle) held nothing in this period (\(Fmt.interval(model.interval))). Choose a longer period\(store.isWholePortfolioScope ? "" : " or another scope").") {
                Button("Show All Time") { store.period = .allTime }
                if !store.isWholePortfolioScope {
                    Button("Whole Portfolio") { store.scopeSelection = .portfolio }
                }
            }
            .frame(minHeight: 320)
        }
    }

    // MARK: Comparisons

    /// Ad-hoc comparison securities of this window (benchmarks from the settings are always shown).
    private var compareIDs: [UUID] {
        compareList.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            .filter { store.security($0) != nil }
    }

    private func addComparison(_ id: UUID) {
        var ids = compareIDs
        guard !ids.contains(id), !store.file.settings.benchmarkSecurityIDs.contains(id) else { return }
        let limit = OverviewModel.comparisonLimit - store.file.settings.benchmarkSecurityIDs.count
        guard ids.count < limit else {
            store.toast("The chart compares up to \(OverviewModel.comparisonLimit) securities", style: .info)
            return
        }
        ids.append(id)
        compareList = ids.map(\.uuidString).joined(separator: ",")
    }

    private func removeComparison(_ id: UUID) {
        compareList = compareIDs.filter { $0 != id }.map(\.uuidString).joined(separator: ",")
    }

    // MARK: Launch state and commands

    private func readLaunchState() {
        guard !didReadLaunchState else { return }
        didReadLaunchState = true
        tab = store.launchValue("tab", as: PerformanceTab.self) ?? storedTab
        chartMode = store.launchValue("chart", as: PerformanceChartMode.self) ?? storedChartMode
        compareList = storedCompare
        selectedLine = store.launchValue("line", as: StatementLine.self) ?? selectedLine
        if let hover = store.launchValue("hover") {
            if let day = Day(iso: hover) { pinnedHover = day } else if let fraction = Double(hover) { pinnedHoverFraction = fraction }
        }
        if let range = store.launchValue("range") {
            let parts = range.components(separatedBy: "..")
            if parts.count == 2, let from = Day(iso: parts[0]), let to = Day(iso: parts[1]), from < to {
                pinnedRange = DayInterval(start: from, end: to)
            }
        }
        if let compare = store.launchValue("compare") { compareList = compare }
        if store.route.securityID != nil, store.launchValue("tab") == nil { tab = .securities }
    }

    private func applyPendingCommand() {
        guard let request = PerformanceCommandCenter.shared.take(for: store) else { return }
        if let tab = request.tab { self.tab = tab }
        if let chart = request.chart { chartMode = chart }
    }
}

// MARK: - Header tiles

/// The seven key figures of the period. Placeholders keep the layout while the first result loads.
struct SummaryTiles: View {
    let model: OverviewModel?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.s) { tiles(minWidth: 132) }
            VStack(spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) { tiles(minWidth: 0).prefix4 }
                HStack(spacing: DS.Spacing.s) { tiles(minWidth: 0).suffix3 }
            }
        }
    }

    private func tiles(minWidth: CGFloat) -> TileSet {
        TileSet(model: model, minWidth: minWidth)
    }
}

/// The tiles as a group that can be laid out in one row or split 4 + 3.
struct TileSet: View {
    let model: OverviewModel?
    let minWidth: CGFloat
    var range: Range<Int> = 0..<7

    var prefix4: TileSet { TileSet(model: model, minWidth: minWidth, range: 0..<4) }
    var suffix3: TileSet { TileSet(model: model, minWidth: minWidth, range: 4..<7) }

    var body: some View {
        ForEach(Array(range), id: \.self) { index in
            tile(index).frame(minWidth: minWidth)
        }
    }

    @ViewBuilder private func tile(_ index: Int) -> some View {
        let m = model
        switch index {
        case 0:
            MetricTile("TTWROR", topic: .ttwror, value: m.map { Fmt.percent($0.ttwror, signed: true) } ?? Fmt.missing,
                       trend: m.map { Trend($0.ttwror) },
                       footnote: m.map { $0.showsAnnualized ? "\(Fmt.percent($0.ttwrorAnnualized, signed: true)) per year" : "over \(Fmt.duration(days: $0.interval.dayCount))" })
        case 1:
            MetricTile("IRR", topic: .irr, value: m.map { Fmt.percent($0.irr, signed: true) } ?? Fmt.missing,
                       trend: m.map { Trend(optional: $0.irr) }, footnote: "per year, money-weighted")
        case 2:
            MetricTile("Gain", topic: .absolutePerformance,
                       value: m.map { Fmt.money(minor: $0.absolutePerformance, currency: $0.currency, signed: true) } ?? Fmt.missing,
                       trend: m.map { Trend(minor: $0.absolutePerformance) }, footnote: "after fees and taxes")
        case 3:
            MetricTile("Final Value", value: m.map { Fmt.money(minor: $0.finalValue, currency: $0.currency) } ?? Fmt.missing,
                       footnote: m.map { "from \(Fmt.money(minor: $0.initialValue, currency: $0.currency))" })
        case 4:
            MetricTile("Max Drawdown", topic: .maxDrawdown,
                       value: m.map { $0.maxDrawdown.map { Fmt.percent(-$0.depth) } ?? Fmt.percent(0) } ?? Fmt.missing,
                       footnote: m.map { $0.maxDrawdown.map { "low on \(Fmt.day($0.trough, style: .medium))" } ?? "never below a peak" })
        case 5:
            MetricTile("Volatility", topic: .volatility, value: m.map { Fmt.percent($0.volatility) } ?? Fmt.missing, footnote: "per year")
        default:
            MetricTile("Sharpe Ratio", topic: .sharpeRatio, value: m.map { Fmt.ratio($0.sharpeRatio) } ?? Fmt.missing,
                       footnote: m.map { "risk-free rate \(Fmt.percent($0.riskFreeRate))" })
        }
    }
}
