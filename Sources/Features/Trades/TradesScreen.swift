import SwiftUI
import UniformTypeIdentifiers
import KontorModel
import KontorUI

/// The Trades screen: round trips derived from the engine's trade report (`analysis.trades`).
///
/// Three tabs — closed trades (realized), open trades (unrealized) and a per-calendar-year tax
/// summary. Closed trades follow the window's scope and reporting period (by closing date); open
/// trades are valued at the end of the period; the tax-year summary always covers all years.
///
/// Launch state (`--state key=value`, read once on appear):
///
/// | key | values |
/// |---|---|
/// | `tab` | `closed` (default) · `open` · `years` |
/// | `chart` | `period` · `distribution` · `cumulative` · `holding` — the chart shown first; `off` hides the charts |
/// | `hover` | `on` — pins the charts' tooltips |
/// | `filter` | quick-filter text (security, ticker, ISIN, depot) |
/// | `outcome` | `all` · `winners` · `losers` |
/// | `holding` | `all` · `long` · `short` (relative to `threshold`) |
/// | `threshold` | long-term threshold in days (default 365) |
/// | `year` | closing year (closed tab) or opening year (open tab), e.g. `2024` |
/// | `security` | security UUID — shows only trades in that security (the "Only …" chip) |
/// | `sort` | `security` `depot` `opened` `closed` `held` `shares` `entry` `exit` `fees` `taxes` `gain` `return` `annualized`, optional `:asc` / `:desc` |
/// | `selection` | `first` or a 1-based row number — selects that row (use with `--inspector` to see its lots) |
///
/// Entity focus comes from `--route`: `transaction:<uuid>` selects the trade closed by that
/// transaction, `security:<uuid>` the open trades of that security.
public struct TradesScreen: View {
    @Environment(PortfolioStore.self) private var store

    // View state lives in @State (works in every host, including the screenshot mode) and is
    // mirrored into scene storage so that it survives relaunch.
    @SceneStorage("trades.tab") private var storedTab = TradesTab.closed
    @SceneStorage("trades.filter") private var storedFilter = ""
    @SceneStorage("trades.showsCharts") private var storedShowsCharts = true
    @SceneStorage("trades.leadChart") private var storedLeadChart = TradeChartKind.period
    @State private var tab = TradesTab.closed
    @State private var filterText = ""
    @State private var showsCharts = true
    @State private var leadChart = TradeChartKind.period
    @AppStorage(LongTermThreshold.storageKey) private var storedThreshold = LongTermThreshold.defaultDays

    @State private var outcome = OutcomeFilter.all
    @State private var holding = HoldingFilter.all
    @State private var year: Int?
    @State private var securityID: UUID?
    @State private var depotID: UUID?
    @State private var thresholdOverride: Int?
    @State private var closedSort = [KeyPathComparator(\TradeRow.end, order: .reverse)]
    @State private var openSort = [KeyPathComparator(\TradeRow.exitValue, order: .reverse)]
    @State private var closedSelection = Set<TradeRow.ID>()
    @State private var openSelection = Set<TradeRow.ID>()
    @State private var closed = Loadable<TradeListModel>()
    @State private var open = Loadable<TradeListModel>()
    @State private var pinsHover = false
    @State private var didAppear = false
    @State private var pendingSelection: Int?
    @State private var contentWidth: CGFloat = 1000
    @State private var exportDocument: CSVDocument?
    @State private var isExporting = false

    private var commands: TradesCommandCenter { .shared }

    public init() {}

    private var thresholdDays: Int { thresholdOverride ?? max(1, storedThreshold) }

    private func query(_ kind: TradeKind) -> TradeQuery {
        TradeQuery(
            kind: kind, text: filterText, outcome: outcome, holding: holding, thresholdDays: thresholdDays, year: year,
            securityID: securityID, depotID: depotID, sortOrder: kind == .closed ? closedSort : openSort)
    }

    private var isFiltering: Bool { query(.closed).isFiltering }

    public var body: some View {
        let closedQuery = query(.closed), openQuery = query(.open)
        Group {
            if store.file.transactions.isEmpty {
                onboarding
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    tabBar
                    switch tab {
                    case .closed: list(closed, kind: .closed)
                    case .open: list(open, kind: .open)
                    case .years:
                        TaxYearsView(pinsHover: pinsHover) { year in
                            store.period = .year(year)
                            clearFilters()
                            tab = .closed
                        } export: { model in
                            export(model)
                        }
                    }
                }
                .padding(.top, DS.Spacing.m)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .loadingOverlay(tab == .closed ? closed.isInitialLoad : tab == .open ? open.isInitialLoad : false)
        .analysisTask($closed, id: "trades.list", variant: closedQuery) { analysis in TradeListModel(analysis, query: closedQuery) }
        .analysisTask($open, id: "trades.list", variant: openQuery) { analysis in TradeListModel(analysis, query: openQuery) }
        .toolbar {
            ToolbarItem { ScopePicker(accounts: false, classifications: true) }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: exportName) { result in
            if case .success(let url) = result {
                store.toast("Exported \(url.lastPathComponent)", style: .success)
            } else if case .failure(let error) = result {
                store.show(Toast("Export failed", message: error.localizedDescription, style: .error, duration: 6))
            }
            exportDocument = nil
        }
        .background { tabShortcuts }
        .onAppear(perform: readLaunchState)
        .onChange(of: commands.request, initial: true) { _, request in handle(request) }
        .onChange(of: store.route.focus, initial: true) { _, _ in revealFocus() }
        .onChange(of: closed.value?.rows.count) { _, _ in rowsChanged() }
        .onChange(of: open.value?.rows.count) { _, _ in rowsChanged() }
        .onChange(of: closedSelection) { _, _ in if tab == .closed { publishFocus() } }
        .onChange(of: openSelection) { _, _ in if tab == .open { publishFocus() } }
        .onChange(of: tab) { _, new in
            storedTab = new
            publishFocus()
        }
        .onChange(of: filterText) { _, new in storedFilter = new }
        .onChange(of: showsCharts) { _, new in storedShowsCharts = new }
        .onChange(of: leadChart) { _, new in storedLeadChart = new }
    }

    // MARK: Tabs and filters

    /// Tabs, period caption, quick filter and filters. Drops the caption first and collapses the
    /// filters into one menu second when the window gets narrow.
    private var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            tabBarRow(showsCaption: true, expandsFilters: true)
            tabBarRow(showsCaption: false, expandsFilters: true)
            tabBarRow(showsCaption: true, expandsFilters: false)
            tabBarRow(showsCaption: false, expandsFilters: false)
        }
        .padding(.horizontal, DS.Spacing.xl)
    }

    private func tabBarRow(showsCaption: Bool, expandsFilters: Bool) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Picker("View", selection: $tab) {
                Text(tabTitle("Closed", count: closed.value?.totalCount)).tag(TradesTab.closed)
                Text(tabTitle("Open", count: open.value?.totalCount)).tag(TradesTab.open)
                Text("Tax Years").tag(TradesTab.years)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Trades view")
            .help("Closed trades (⌃1), open trades (⌃2), tax years (⌃3)")

            if tab != .years {
                if showsCaption {
                    Text(periodCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(tab == .closed ? "Trades closed in the reporting period" : "Positions held at the end of the reporting period")
                }
                Spacer(minLength: DS.Spacing.s)
                QuickFilterField(text: $filterText, prompt: "Filter trades")
                    .frame(width: 180)
                TradeFilterMenu(
                    kind: tab == .open ? .open : .closed, isExpanded: expandsFilters, outcome: $outcome, holding: $holding, year: $year,
                    depotID: $depotID,
                    thresholdDays: Binding(get: { thresholdDays }, set: { storedThreshold = $0; thresholdOverride = nil }),
                    years: activeModel?.years ?? [], depots: activeModel?.depots ?? [])
                Toggle(isOn: $showsCharts.animation(DS.Motion.quick)) {
                    Label("Charts", systemImage: "chart.bar.xaxis")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(showsCharts ? "Hide the charts" : "Show the charts")
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    /// ⌃1 / ⌃2 / ⌃3 switch between the tabs.
    private var tabShortcuts: some View {
        Group {
            Button("Closed Trades") { tab = .closed }.keyboardShortcut("1", modifiers: .control)
            Button("Open Trades") { tab = .open }.keyboardShortcut("2", modifiers: .control)
            Button("Tax Years") { tab = .years }.keyboardShortcut("3", modifiers: .control)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func tabTitle(_ title: String, count: Int?) -> String {
        guard let count else { return title }
        return "\(title)  \(Fmt.integer(count))"
    }

    private var periodCaption: String {
        let interval = store.periodInterval
        let scope = store.isWholePortfolioScope ? "" : " · \(store.scopeTitle)"
        switch tab {
        case .closed: return "\(Fmt.interval(interval))\(scope)"
        case .open: return "as of \(Fmt.day(interval.end, style: .medium))\(scope)"
        case .years: return ""
        }
    }

    private var activeModel: TradeListModel? {
        tab == .open ? open.value : closed.value
    }

    private func clearFilters() {
        filterText = ""
        outcome = .all
        holding = .all
        year = nil
        securityID = nil
        depotID = nil
    }

    // MARK: Lists

    @ViewBuilder private func list(_ loadable: Loadable<TradeListModel>, kind: TradeKind) -> some View {
        if let model = loadable.value {
            if model.totalCount == 0 {
                emptyPeriod(kind)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    VStack(alignment: .leading, spacing: DS.Spacing.m) {
                        TradeTiles(model: model, thresholdDays: thresholdDays, width: contentWidth - 2 * DS.Spacing.xl)
                        if let securityID, let name = store.security(securityID)?.name {
                            securityChip(name)
                        }
                        if showsCharts, !model.rows.isEmpty {
                            TradeChartStrip(
                                model: model, lead: $leadChart, width: contentWidth - 2 * DS.Spacing.xl,
                                isRefreshing: loadable.isRefreshing, pinsHover: pinsHover)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.xl)
                    TradesTable(
                        model: model, selection: kind == .closed ? $closedSelection : $openSelection,
                        sortOrder: kind == .closed ? $closedSort : $openSort, isFiltering: isFiltering,
                        clearFilters: clearFilters, filterSecurity: { securityID = $0 })
                        .opacity(loadable.isRefreshing ? 0.7 : 1)
                }
            }
        } else {
            Color.clear
        }
    }

    private func securityChip(_ name: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text("Only").foregroundStyle(.secondary)
            Text(name).fontWeight(.medium).lineLimit(1)
            Button {
                securityID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Show trades in all securities")
        }
        .font(.callout)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    // MARK: Empty states

    private var onboarding: some View {
        EmptyState(
            "No Trades Yet", symbol: "arrow.left.arrow.right",
            message: "A trade is a round trip: shares you bought and later sold. Record a purchase or import your history — open positions and every sale will be analysed here."
        ) {
            Button("New Purchase…") { store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today))) }
                .buttonStyle(.borderedProminent)
            Button("Import…") { store.present(.importFile(nil)) }
        }
    }

    @ViewBuilder private func emptyPeriod(_ kind: TradeKind) -> some View {
        let scope = store.isWholePortfolioScope ? "" : " in \(store.scopeTitle)"
        switch kind {
        case .closed:
            EmptyState(
                "No Closed Trades in This Period", symbol: "checkmark.circle",
                message: "Nothing was sold\(scope) between \(Fmt.day(min(store.periodInterval.firstDay, store.periodInterval.end), style: .medium)) and \(Fmt.day(store.periodInterval.end, style: .medium)). A trade closes when you sell or deliver out shares."
            ) {
                if store.period != .allTime {
                    Button("Show All Time") { store.period = .allTime }
                }
                if (open.value?.totalCount ?? 0) > 0 {
                    Button("View Open Trades") { tab = .open }
                }
                if !store.isWholePortfolioScope {
                    Button("Whole Portfolio") { store.scopeSelection = .portfolio }
                }
            }
        case .open:
            EmptyState(
                "No Open Trades", symbol: "tray",
                message: "No securities were held\(scope) on \(Fmt.day(store.periodInterval.end, style: .medium)). Open trades are the positions you still hold, valued at market."
            ) {
                Button("New Purchase…") { store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today))) }
                if (closed.value?.totalCount ?? 0) > 0 {
                    Button("View Closed Trades") { tab = .closed }
                }
                if !store.isWholePortfolioScope {
                    Button("Whole Portfolio") { store.scopeSelection = .portfolio }
                }
            }
        }
    }

    // MARK: Focus (routing contract)

    /// Selects the trade a deep link asks for: the trade closed by a transaction, or the open trades of a security.
    private func revealFocus() {
        switch store.route.focus {
        case .transaction(let id):
            guard let rows = closed.value?.rows else { return }
            let ids = Set(rows.filter { $0.closingTransactionID == id }.map(\.id))
            guard !ids.isEmpty else { return }
            if tab != .closed { tab = .closed }
            if closedSelection != ids { closedSelection = ids }
        case .security(let id):
            // Prefer the tab the user is on; fall back to the other one if only that has trades in the security.
            let openIDs = Set((open.value?.rows ?? []).filter { $0.securityID == id }.map(\.id))
            let closedIDs = Set((closed.value?.rows ?? []).filter { $0.securityID == id }.map(\.id))
            if tab == .closed, !closedIDs.isEmpty {
                if Set(closedSelection.map(\.securityID)) != [id] { closedSelection = closedIDs }
            } else if !openIDs.isEmpty {
                if tab == .closed, open.value != nil, closed.value != nil { tab = .open }
                if tab == .open, Set(openSelection.map(\.securityID)) != [id] { openSelection = openIDs }
            }
        default:
            break
        }
    }

    /// Tells the store what is selected so the inspector follows.
    private func publishFocus() {
        switch tab {
        case .closed:
            let transactions = Set(closedSelection.compactMap(\.closingTransactionID))
            if transactions.count == 1, let id = transactions.first {
                store.setFocus(.transaction(id))
            } else if !closedSelection.isEmpty || isTradeFocus {
                store.setFocus(nil)
            }
        case .open:
            let securities = Set(openSelection.map(\.securityID))
            if securities.count == 1, let id = securities.first {
                store.setFocus(.security(id))
            } else if !openSelection.isEmpty || isTradeFocus {
                store.setFocus(nil)
            }
        case .years:
            break
        }
    }

    /// True if the current focus is one this screen published (so clearing the selection may clear it).
    private var isTradeFocus: Bool {
        switch store.route.focus {
        case .transaction(let id): closed.value?.rows.contains { $0.closingTransactionID == id } ?? false
        case .security(let id): open.value?.rows.contains { $0.securityID == id } ?? false
        default: false
        }
    }

    private func rowsChanged() {
        if let index = pendingSelection, let rows = activeModel?.rows, !rows.isEmpty {
            pendingSelection = nil
            let row = rows[min(max(index, 1), rows.count) - 1]
            if tab == .open { openSelection = [row.id] } else { closedSelection = [row.id] }
        }
        // Drop selected rows that no longer exist (filter, period, undo).
        if let rows = closed.value?.rows, !closedSelection.isEmpty {
            let valid = closedSelection.intersection(rows.map(\.id))
            if valid != closedSelection { closedSelection = valid }
        }
        if let rows = open.value?.rows, !openSelection.isEmpty {
            let valid = openSelection.intersection(rows.map(\.id))
            if valid != openSelection { openSelection = valid }
        }
        revealFocus()
    }

    // MARK: Launch state, commands, export

    private func readLaunchState() {
        guard !didAppear else { return }
        didAppear = true
        filterText = storedFilter
        showsCharts = storedShowsCharts
        leadChart = storedLeadChart
        tab = store.launchValue("tab", as: TradesTab.self) ?? storedTab
        if let chart = store.launchValue("chart") {
            if chart == "off" {
                showsCharts = false
            } else if let kind = TradeChartKind(rawValue: chart) {
                showsCharts = true
                leadChart = kind
            }
        }
        pinsHover = store.launchValue("hover") == "on"
        if let text = store.launchValue("filter") { filterText = text }
        outcome = store.launchValue("outcome", as: OutcomeFilter.self) ?? outcome
        holding = store.launchValue("holding", as: HoldingFilter.self) ?? holding
        if let days = store.launchValue("threshold").flatMap(Int.init), days > 0 { thresholdOverride = days }
        if let value = store.launchValue("year").flatMap(Int.init) { year = value }
        if let id = store.launchValue("security").flatMap(UUID.init(uuidString:)) { securityID = id }
        if let sort = store.launchValue("sort"), let comparator = TradesTable.comparator(sort) {
            closedSort = [comparator]
            openSort = [comparator]
        }
        if let selection = store.launchValue("selection") {
            pendingSelection = selection == "first" ? 1 : Int(selection)
            rowsChanged()
        }
    }

    private func handle(_ request: TradesCommandCenter.Request?) {
        guard let request, request.store == ObjectIdentifier(store) else { return }
        commands.request = nil
        switch request.action {
        case .show(let target):
            tab = target
        case .exportYears:
            tab = .years
            Task {
                let model = try? await store.analyze("trades.years", interval: store.interval(for: .allTime)) { TaxYearsModel($0) }
                if let model, !model.isEmpty { export(model) }
            }
        }
    }

    private func export(_ model: TaxYearsModel) {
        exportDocument = CSVDocument(text: model.csv())
        isExporting = true
    }

    private var exportName: String {
        let name = store.file.name.isEmpty ? "Portfolio" : store.file.name
        return "\(name) – Tax Years.csv"
    }
}

/// The screen's tabs (`--state tab=…`).
enum TradesTab: String, Sendable, Hashable {
    case closed, open, years
}

/// Lets palette commands (which only see the store) drive the screen's view state.
@MainActor @Observable final class TradesCommandCenter {
    static let shared = TradesCommandCenter()

    enum Action: Equatable {
        case show(TradesTab)
        case exportYears
    }

    struct Request: Equatable {
        var store: ObjectIdentifier
        var action: Action
        var serial: Int
    }

    var request: Request?
    private var serial = 0

    func send(_ action: Action, to store: PortfolioStore) {
        serial += 1
        request = Request(store: ObjectIdentifier(store), action: action, serial: serial)
        store.navigate(to: .trades)
    }
}

/// A CSV file for `fileExporter`.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
