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
/// | `chart` | `period` · `distribution` · `cumulative` · `holding` — the chart shown first (also shows the charts in a short window, where they start collapsed); `off` hides the charts |
/// | `hover` | `on` — pins the charts' tooltips |
/// | `filter` | quick-filter text (security, ticker, ISIN, depot) |
/// | `outcome` | `all` · `winners` · `losers` |
/// | `holding` | `all` · `long` · `short` (relative to `threshold`; applied per lot) |
/// | `threshold` | long-term threshold in days (default 365) |
/// | `year` | closing year (closed tab) or purchase year of the lots (open tab), e.g. `2024` — applies to the tab named by `tab` |
/// | `security` | security UUID — shows only trades in that security (the "Only …" chip) |
/// | `sort` | `security` `depot` `opened` `closed` `held` `shares` `entry` `exit` `fees` `taxes` `gain` `return` `annualized`, optional `:asc` / `:desc` |
/// | `selection` | `first` or a 1-based row number — selects that row (use with `--inspector` to see its lots) |
///
/// Entity focus comes from `--route`: `transaction:<uuid>` selects the trade closed by that
/// transaction, `security:<uuid>` the open trades of that security.
///
/// Tab, filters, sort orders and the chart choice are restored per window (`trades.state`). The
/// year filter is kept per tab: it means "closed in" on one and "bought in" on the other.
public struct TradesScreen: View {
    @Environment(PortfolioStore.self) private var store

    // View state lives in @State (works in every host, including the screenshot mode) and is
    // mirrored as one value into scene storage, so that all of it — not half — survives leaving
    // the screen and relaunching.
    @SceneStorage("trades.state") private var storedState = ""
    @State private var tab = TradesTab.closed
    @State private var filterText = ""
    @State private var showsCharts = true
    /// The user (or `--state chart=…`) asked for the charts although the window is short.
    @State private var chartsForced = false
    @State private var leadChart = TradeChartKind.period
    @AppStorage(LongTermThreshold.storageKey) private var storedThreshold = LongTermThreshold.defaultDays

    @State private var outcome = OutcomeFilter.all
    @State private var holding = HoldingFilter.all
    /// The year filter means "closed in" on the Closed tab and "bought in" on the Open tab, so each tab has its own.
    @State private var closedYear: Int?
    @State private var openYear: Int?
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
    @State private var contentSize = CGSize(width: 1000, height: 800)
    /// The focus this screen last published, so that only its own focus is ever retracted.
    @State private var publishedFocus: Route.Focus?
    @State private var exportDocument: CSVDocument?
    @State private var exportFilename = ""
    @State private var isExporting = false

    private var commands: TradesCommandCenter { .shared }

    public init() {}

    private var thresholdDays: Int { thresholdOverride ?? max(1, storedThreshold) }

    private func query(_ kind: TradeKind) -> TradeQuery {
        TradeQuery(
            kind: kind, text: filterText, outcome: outcome, holding: holding, thresholdDays: thresholdDays,
            year: kind == .closed ? closedYear : openYear, securityID: securityID, depotID: depotID,
            sortOrder: kind == .closed ? closedSort : openSort)
    }

    /// Everything that is restored per window.
    private var viewState: TradesViewState {
        TradesViewState(
            tab: tab, filterText: filterText, showsCharts: showsCharts, leadChart: leadChart, outcome: outcome, holding: holding,
            closedYear: closedYear, openYear: openYear, securityID: securityID, depotID: depotID,
            closedSort: closedSort.first.flatMap(TradesTable.sortKey), openSort: openSort.first.flatMap(TradesTable.sortKey))
    }

    private var contentWidth: CGFloat { contentSize.width }

    /// Charts take about a third of a short window; there they stay collapsed unless asked for.
    private var chartsVisible: Bool {
        showsCharts && (chartsForced || contentSize.height >= TradesLayout.minimumHeightForCharts)
    }

    public var body: some View {
        let closedQuery = query(.closed), openQuery = query(.open)
        Group {
            if store.file.transactions.isEmpty {
                onboarding
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    tabBar
                    switch tab {
                    case .closed: list(closed, kind: .closed, query: closedQuery)
                    case .open: list(open, kind: .open, query: openQuery)
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
                .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .loadingOverlay(tab == .closed ? closed.isInitialLoad : tab == .open ? open.isInitialLoad : false)
        .analysisTask($closed, id: "trades.list", variant: closedQuery) { analysis in TradeListModel(analysis, query: closedQuery) }
        .analysisTask($open, id: "trades.list", variant: openQuery) { analysis in TradeListModel(analysis, query: openQuery) }
        .toolbar {
            ToolbarItem { ScopePicker(store: store, accounts: false, classifications: true) }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: exportFilename) { result in
            if case .success(let url) = result {
                store.toast("Exported \(url.lastPathComponent)", style: .success)
            } else if case .failure(let error) = result {
                store.show(Toast("Export failed", message: error.localizedDescription, style: .error, duration: 6))
            }
            exportDocument = nil
        }
        .background { tabShortcuts }
        .onAppear(perform: readLaunchState)
        .onDisappear { TradesSelectionCenter.shared.set(nil, for: store) }
        .onChange(of: commands.request, initial: true) { _, request in handle(request) }
        .onChange(of: store.route.focus, initial: true) { _, _ in revealFocus() }
        // The token follows the rows' identities, not just their number: a filter that swaps one
        // trade for another must drop the old selection too.
        .onChange(of: closed.value?.rowsToken) { _, _ in rowsChanged() }
        .onChange(of: open.value?.rowsToken) { _, _ in rowsChanged() }
        .onChange(of: closedSelection) { _, _ in if tab == .closed { publishFocus() } }
        .onChange(of: openSelection) { _, _ in if tab == .open { publishFocus() } }
        .onChange(of: tab) { _, _ in publishFocus() }
        .onChange(of: viewState) { _, new in
            if didAppear { storedState = new.storage }
        }
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
                    kind: tab == .open ? .open : .closed, isExpanded: expandsFilters, outcome: $outcome, holding: $holding,
                    year: tab == .open ? $openYear : $closedYear, depotID: $depotID,
                    thresholdDays: Binding(get: { thresholdDays }, set: { storedThreshold = $0; thresholdOverride = nil }),
                    years: activeModel?.years ?? [], depots: activeModel?.depots ?? [])
                Toggle(isOn: Binding(get: { chartsVisible }, set: { shows in
                    withAnimation(DS.Motion.quick) {
                        showsCharts = shows
                        chartsForced = shows
                    }
                })) {
                    Label("Charts", systemImage: "chart.bar.xaxis")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(chartsVisible ? "Hide the charts" : "Show the charts")
                Button {
                    exportTrades(tab == .open ? .open : .closed)
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(activeModel?.rows.isEmpty ?? true)
                .help("Export the listed trades as CSV, one line per lot")
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
        closedYear = nil
        openYear = nil
        securityID = nil
        depotID = nil
    }

    // MARK: Lists

    @ViewBuilder private func list(_ loadable: Loadable<TradeListModel>, kind: TradeKind, query: TradeQuery) -> some View {
        if let model = loadable.value {
            if model.totalCount == 0 {
                emptyPeriod(kind)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    VStack(alignment: .leading, spacing: DS.Spacing.m) {
                        TradeTiles(model: model, thresholdDays: thresholdDays, width: contentWidth - 2 * DS.Spacing.xl)
                        if !model.notices.isEmpty || model.hasWeightedRows {
                            TradeNoticeBar(notices: model.notices, weightedScope: model.hasWeightedRows ? store.scopeTitle : nil) { id in
                                store.navigate(to: .security(id))
                            }
                        }
                        if let securityID, let name = store.security(securityID)?.name {
                            securityChip(name)
                        }
                        if chartsVisible, !model.rows.isEmpty {
                            TradeChartStrip(
                                model: model, lead: $leadChart, width: contentWidth - 2 * DS.Spacing.xl,
                                isRefreshing: loadable.isRefreshing, pinsHover: pinsHover)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.xl)
                    TradesTable(
                        model: model, selection: kind == .closed ? $closedSelection : $openSelection,
                        sortOrder: kind == .closed ? $closedSort : $openSort, width: contentWidth, isFiltering: query.isFiltering,
                        clearFilters: clearFilters, filterSecurity: { securityID = $0 }, exportCSV: { exportTrades(kind) })
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

    /// Tells the store — and, for the depot the route cannot express, the inspector — what is selected.
    private func publishFocus() {
        let shared = TradesSelectionCenter.shared
        switch tab {
        case .closed:
            shared.set(nil, for: store)
            let transactions = Set(closedSelection.compactMap(\.closingTransactionID))
            if transactions.count == 1, let id = transactions.first {
                publish(.transaction(id))
            } else if case .security(let id) = store.route.focus, !closedSelection.isEmpty, Set(closedSelection.map(\.securityID)) == [id] {
                // Several closed trades of the security a deep link named: that selection is the
                // link's own doing, so the focus (and with it the inspector) stays on the security.
                publishedFocus = .security(id)
            } else {
                retractFocus(always: !closedSelection.isEmpty)
            }
        case .open:
            // An open row is one security in one depot; the route focus only names the security.
            shared.set(openSelection.count == 1 ? openSelection.first : nil, for: store)
            let securities = Set(openSelection.map(\.securityID))
            if securities.count == 1, let id = securities.first {
                publish(.security(id))
            } else {
                retractFocus(always: !openSelection.isEmpty)
            }
        case .years:
            // No trade list is visible, so no trade may stay in the inspector.
            shared.set(nil, for: store)
            retractFocus(always: false)
        }
    }

    private func publish(_ focus: Route.Focus) {
        publishedFocus = focus
        if store.route.focus != focus { store.setFocus(focus) }
    }

    /// Clears the focus if this screen published it (or `always`, when another selection replaced it).
    private func retractFocus(always: Bool) {
        let current = store.route.focus
        let isTrade: Bool = switch current {
        case .transaction, .security: true
        default: false
        }
        if current != nil, (always && isTrade) || current == publishedFocus { store.setFocus(nil) }
        publishedFocus = nil
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
        let restored = TradesViewState(storage: storedState)
        tab = restored.tab
        filterText = restored.filterText
        showsCharts = restored.showsCharts
        leadChart = restored.leadChart
        outcome = restored.outcome
        holding = restored.holding
        closedYear = restored.closedYear
        openYear = restored.openYear
        securityID = restored.securityID.flatMap { store.security($0)?.id }
        depotID = restored.depotID.flatMap { store.depot($0)?.id }
        if let comparator = restored.closedSort.flatMap(TradesTable.comparator) { closedSort = [comparator] }
        if let comparator = restored.openSort.flatMap(TradesTable.comparator) { openSort = [comparator] }

        tab = store.launchValue("tab", as: TradesTab.self) ?? tab
        if let chart = store.launchValue("chart") {
            if chart == "off" {
                showsCharts = false
            } else if let kind = TradeChartKind(rawValue: chart) {
                showsCharts = true
                chartsForced = true
                leadChart = kind
            }
        }
        pinsHover = store.launchValue("hover") == "on"
        if let text = store.launchValue("filter") { filterText = text }
        outcome = store.launchValue("outcome", as: OutcomeFilter.self) ?? outcome
        holding = store.launchValue("holding", as: HoldingFilter.self) ?? holding
        if let days = store.launchValue("threshold").flatMap(Int.init), days > 0 { thresholdOverride = days }
        if let value = store.launchValue("year").flatMap(Int.init) {
            if tab == .open { openYear = value } else { closedYear = value }
        }
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
        case .exportTrades:
            if tab == .years { tab = .closed }
            exportTrades(tab == .open ? .open : .closed)
        }
    }

    private var portfolioName: String { store.file.name.isEmpty ? "Portfolio" : store.file.name }

    private func export(_ model: TaxYearsModel) {
        exportDocument = CSVDocument(text: model.csv())
        exportFilename = "\(portfolioName) – Tax Years.csv"
        isExporting = true
    }

    /// Saves the listed trades (current filters and order) as CSV with one line per lot.
    private func exportTrades(_ kind: TradeKind) {
        let query = query(kind)
        Task {
            let text = try? await store.analyze("trades.csv", variant: query) { analysis in
                TradeExport.csv(TradeListModel(analysis, query: query, collectsLots: true), ledger: analysis.ledger, thresholdDays: query.thresholdDays)
            }
            guard let text else { return }
            exportDocument = CSVDocument(text: text)
            exportFilename = "\(portfolioName) – \(kind == .closed ? "Closed" : "Open") Trades.csv"
            isExporting = true
        }
    }
}

/// Layout thresholds of the screen.
enum TradesLayout {
    /// Below this content height the charts start collapsed: with them, a short window shows only a handful of rows.
    static let minimumHeightForCharts: CGFloat = 700
}

/// The view state that is restored per window, stored as one JSON string so that it is restored
/// completely or not at all.
struct TradesViewState: Codable, Equatable {
    var tab = TradesTab.closed
    var filterText = ""
    var showsCharts = true
    var leadChart = TradeChartKind.period
    var outcome = OutcomeFilter.all
    var holding = HoldingFilter.all
    var closedYear: Int?
    var openYear: Int?
    var securityID: UUID?
    var depotID: UUID?
    /// Sort orders in their launch-state form (`gain:desc`).
    var closedSort: String?
    var openSort: String?

    /// Decodes `storage`; anything unreadable yields the defaults.
    init(storage: String) {
        self = (try? JSONDecoder().decode(TradesViewState.self, from: Data(storage.utf8))) ?? TradesViewState()
    }

    init(
        tab: TradesTab = .closed, filterText: String = "", showsCharts: Bool = true, leadChart: TradeChartKind = .period,
        outcome: OutcomeFilter = .all, holding: HoldingFilter = .all, closedYear: Int? = nil, openYear: Int? = nil,
        securityID: UUID? = nil, depotID: UUID? = nil, closedSort: String? = nil, openSort: String? = nil
    ) {
        self.tab = tab
        self.filterText = filterText
        self.showsCharts = showsCharts
        self.leadChart = leadChart
        self.outcome = outcome
        self.holding = holding
        self.closedYear = closedYear
        self.openYear = openYear
        self.securityID = securityID
        self.depotID = depotID
        self.closedSort = closedSort
        self.openSort = openSort
    }

    var storage: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The single selected row of a window's Trades screen, for the inspector. The store's route focus
/// can name a security but not the depot it is held in; an open trade is identified by both.
@MainActor @Observable final class TradesSelectionCenter {
    static let shared = TradesSelectionCenter()

    private struct Entry {
        weak var store: PortfolioStore?
        var row: TradeRow.ID
    }

    private var rows: [ObjectIdentifier: Entry] = [:]

    /// The selection of `store` — never that of a closed document whose store happened to live at
    /// the same address.
    func row(for store: PortfolioStore) -> TradeRow.ID? {
        guard let entry = rows[ObjectIdentifier(store)], entry.store === store else { return nil }
        return entry.row
    }

    func set(_ row: TradeRow.ID?, for store: PortfolioStore) {
        let key = ObjectIdentifier(store)
        guard self.row(for: store) != row else { return }
        // Entries of documents that were closed meanwhile go with every change.
        for (id, entry) in rows where entry.store == nil { rows[id] = nil }
        rows[key] = row.map { Entry(store: store, row: $0) }
    }
}

/// The screen's tabs (`--state tab=…`).
enum TradesTab: String, Sendable, Hashable, Codable {
    case closed, open, years
}

/// Lets palette commands (which only see the store) drive the screen's view state.
@MainActor @Observable final class TradesCommandCenter {
    static let shared = TradesCommandCenter()

    enum Action: Equatable {
        case show(TradesTab)
        case exportYears
        /// Export the listed trades of the current tab as CSV.
        case exportTrades
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
