import SwiftUI
import KontorModel
import KontorUI

/// The Holdings screen: the statement of assets on a chosen day — every position and cash balance
/// with price, value, weight, cost, gains and the period's return figures — as a sortable,
/// groupable table with an optional treemap or concentration chart above it.
///
/// Follows the window's scope (`ScopePicker`) and reporting period (`PeriodPicker`). The statement
/// day decides what is held; the period decides which stretch the return figures cover — rolling
/// periods end on the statement day, fixed ones keep their dates (see `HoldingsStatementPeriod`).
///
/// Launch state (`--state key=value`, screenshot mode):
///
/// | key | values |
/// |---|---|
/// | `day` | statement day, `YYYY-MM-DD` (default: today) |
/// | `group` | `none` · `depot` · `currency` · `taxonomy` (the first one) · `taxonomy:<uuid>` · a taxonomy name (`regions`) |
/// | `view` | `table` · `treemap` · `concentration` |
/// | `closed` | `on` — include positions closed during the period |
/// | `cash` | `off` — hide cash accounts |
/// | `filter` | quick-filter text |
/// | `sort` | `name` `shares` `price` `day` `value` `weight` `cost` `gain` `gainpct` `ttwror` `irr` `dividends` `trend`, optional `:asc` / `:desc` |
/// | `select` | `first`, or part of a row name — selects that row (the inspector follows; use with `--inspector`) |
/// | `hover` | part of a row name — pins the chart tooltip of `view=treemap` / highlights the segment of `view=concentration` |
/// | `collapse` | `all` — collapse every group |
///
/// `--route security:<uuid>` / `account:<uuid>` selects the matching row, expands its group and
/// scrolls to it.
///
/// Shortcuts for the selected row: ⌃⌘B buy · ⇧⌃⌘S sell (⌃⌘S is the system's sidebar toggle) ·
/// ⌃⌘D record dividend · ⌃⌘T show transactions · ⌘T statement for today.
public struct HoldingsScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var base = Loadable<HoldingsBase>()
    @State private var pinnedHover: String?
    @State private var launchSelection: String?
    @State private var launchHover: String?
    @State private var collapsesAllAtLaunch = false
    @SceneStorage("holdings.columns") private var columns: TableColumnCustomization<HoldingRow>
    @SceneStorage("holdings.grouping") private var storedGrouping = "none"
    @SceneStorage("holdings.visual") private var storedVisual = HoldingsVisual.table.rawValue
    @SceneStorage("holdings.closed") private var storedClosed = false
    @SceneStorage("holdings.cash") private var storedCash = true

    public init() {}

    public var body: some View {
        let state = HoldingsViewState.of(store)
        let query = state.query(in: store)
        VStack(spacing: 0) {
            if store.file.transactions.isEmpty {
                onboarding
            } else {
                HoldingsControlBar(state: state)
                content(state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(base.isInitialLoad && state.display.lines.isEmpty && !store.file.transactions.isEmpty)
        .analysisTask($base, id: "holdings.base", interval: state.interval(in: store), variant: query) { analysis in
            HoldingsBase(analysis, query: query)
        }
        .toolbar { ToolbarItem { ScopePicker(store: store) } }
        .background { HoldingsShortcuts(state: state) }
        .onAppear { seed(state) }
        .onChange(of: base.value?.stamp, initial: true) { rebuild(state) }
        .onChange(of: state.options) { rebuild(state) }
        .onChange(of: state.selection) { _, selection in selectionChanged(selection, state) }
        .onChange(of: store.route.focus, initial: true) { revealRouteFocus(state) }
        .onChange(of: state.grouping) { _, grouping in storedGrouping = grouping.key }
        .onChange(of: state.visual) { _, visual in storedVisual = visual.rawValue }
        .onChange(of: state.options.includesClosed) { _, value in storedClosed = value }
        .onChange(of: state.options.showsCash) { _, value in storedCash = value }
    }

    // MARK: Content

    @ViewBuilder private func content(_ state: HoldingsViewState) -> some View {
        let display = state.display
        let currency = base.value?.currency ?? store.baseCurrency
        let period = state.statementPeriod(in: store)
        if let model = base.value, !model.isEmpty {
            HoldingsSummary(model: model, periodTitle: period.shortTitle(of: store.period), isRefreshing: base.isRefreshing)
                .padding(.horizontal, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.m)
        }
        if base.value != nil, display.entityCount > 0 {
            switch state.visual {
            case .table:
                EmptyView()
            case .treemap:
                HoldingsTreemapCard(
                    display: display, currency: currency, periodTitle: period.title(of: store.period).lowercased(), isLoading: base.isRefreshing,
                    pinnedID: pinnedHover, state: state)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.bottom, DS.Spacing.m)
            case .concentration:
                HoldingsConcentrationCard(concentration: display.concentration, currency: currency, pinnedID: pinnedHover, state: state)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.bottom, DS.Spacing.m)
            }
        }
        if let model = base.value, display.entityCount == 0 {
            Divider()
            emptyState(model, state)
        } else if display.lines.isEmpty {
            // Nothing computed yet: the table is created once its rows exist (see `tableIdentity`).
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Divider()
            HoldingsTable(display: display, reportingCurrency: currency, state: state, columns: $columns)
                .id(tableIdentity(state))
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(state) }
        }
    }

    /// The table is rebuilt (rather than diffed) when its structure changes — grouping, or which
    /// kinds of lines it contains. Inserting hundreds of rows into a live `Table` makes AppKit's
    /// automatic row heights re-enter the table update.
    private func tableIdentity(_ state: HoldingsViewState) -> String {
state.display.structureKey
    }

    private func footer(_ state: HoldingsViewState) -> some View {
        let display = state.display
        return TableFooter(
            count: display.entityCount, noun: "holding", selected: state.selectedRows.count,
            filteredFrom: display.unfilteredCount
        ) {
            if let model = base.value {
                // The total line is the last row of the table and scrolls away with it; its
                // figures that appear nowhere else stay visible here, room permitting.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Spacing.m) {
                        footerTotals(display.total, currency: model.currency)
                        footerStatus(model, state)
                    }
                    footerStatus(model, state)
                }
            }
            if base.isRefreshing { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder private func footerTotals(_ total: HoldingRow?, currency: CurrencyCode) -> some View {
        if let total {
            if let change = total.dayChange, let amount = total.dayChangeAmount {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Day")
                    GainText(percent: change)
                    GainText(money: Money(minor: amount, currency: currency))
                }
                .help("Change in value of the lines shown since the previous quotes, exchange-rate moves included.")
                .accessibilityElement(children: .combine)
            }
            if let dividends = total.dividends, dividends != 0 {
                Text("Dividends \(Fmt.money(minor: dividends, currency: currency))")
                    .help("Dividends of the lines shown in the period (gross).")
            }
        }
    }

    @ViewBuilder private func footerStatus(_ model: HoldingsBase, _ state: HoldingsViewState) -> some View {
        let period = state.statementPeriod(in: store)
        if !model.unvalued.isEmpty {
            Button {
                store.present(.consistencyReport)
            } label: {
                Label("\(Fmt.integer(model.unvalued.count)) without a value", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.warning)
            .help("Cannot be valued (price or exchange rate missing) and count as zero: \(model.unvalued.joined(separator: ", ")). Click to check consistency and see what is missing.")
        }
        if model.staleCount > 0 {
            Label("\(Fmt.integer(model.staleCount)) stale \(model.staleCount == 1 ? "price" : "prices")", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(DS.Colors.warning)
                .help("The latest quote of these positions is more than \(HoldingsBase.staleAfterDays) days older than the statement day.")
        }
        if model.hasPeriodFigures {
            let text = period.coverage == .ended && model.interval.end != model.day
                ? "Period: \(Fmt.interval(model.interval)), ended before the statement day"
                : "Period: \(Fmt.interval(model.interval))"
            Text(text)
                .lineLimit(1)
                .help(period.note(of: store.period) ?? "TTWROR, IRR and dividends refer to this period. Change it with the period picker in the toolbar.")
        } else {
            Label("No period figures", systemImage: "calendar.badge.exclamationmark")
                .lineLimit(1)
                .help(period.note(of: store.period) ?? "The period has no figures for this statement day.")
        }
    }

    // MARK: Empty states

    private var onboarding: some View {
        EmptyState(
            "No Holdings Yet", symbol: "briefcase",
            message: "Holdings are what you own on a given day: the securities in your depots and the cash in your accounts. Record a first purchase or deposit, or import your history, and they appear here with their value, cost and return."
        ) {
            Button("Record a Purchase…") { store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today))) }
                .buttonStyle(.borderedProminent)
            Button("Deposit Cash…") { store.present(.newTransaction(TransactionPrefill(kind: .deposit, date: store.today))) }
            Button("Import…") {
                if let choose = store.services.chooseImportFile { choose(store) } else { store.present(.importFile) }
            }
        }
    }

    @ViewBuilder private func emptyState(_ model: HoldingsBase, _ state: HoldingsViewState) -> some View {
        let day = Fmt.day(model.day, style: .medium)
        if !state.options.filter.isEmpty, state.display.unfilteredCount > 0 {
            EmptyState("No Matches", symbol: "line.3.horizontal.decrease.circle", message: "No holding matches “\(state.options.filter)”.") {
                Button("Clear Filter") { state.options.filter = "" }
            }
        } else if !state.options.showsCash, model.cashCount > 0, model.positionCount == 0 {
            EmptyState("Only Cash on \(day)", symbol: "banknote", message: "\(store.isWholePortfolioScope ? "The portfolio" : store.scopeTitle) holds no securities on that day, and cash accounts are hidden.") {
                Button("Show Cash Accounts") { state.options.showsCash = true }
            }
        } else {
            EmptyState(
                "Nothing Held on \(day)", symbol: "tray",
                message: store.isWholePortfolioScope
                    ? "The portfolio holds no securities and no cash on that day."
                    : "\(store.scopeTitle) holds nothing on that day."
            ) {
                if model.day != store.today {
                    Button("Jump to Today") { state.day = nil }
                }
                if !store.isWholePortfolioScope {
                    Button("Show Whole Portfolio") { store.scopeSelection = .portfolio }
                }
                if !model.closed.isEmpty, !state.options.includesClosed {
                    Button("Show Positions Closed in the Period") { state.options.includesClosed = true }
                }
            }
        }
    }

    // MARK: State plumbing

    /// Applies stored settings and the screenshot mode's launch state — once per window.
    private func seed(_ state: HoldingsViewState) {
        guard !state.isSeeded else { return }
        state.grouping = HoldingsGrouping(key: storedGrouping, taxonomies: store.file.taxonomies) ?? .none
        state.visual = HoldingsVisual(rawValue: storedVisual) ?? .table
        state.options.includesClosed = storedClosed
        state.options.showsCash = storedCash

        if let text = store.launchValue("group"), let grouping = HoldingsGrouping(key: text, taxonomies: store.file.taxonomies) {
            state.grouping = grouping
        }
        if let visual = store.launchValue("view", as: HoldingsVisual.self) { state.visual = visual }
        if let day = store.launchValue("day").flatMap({ Day(iso: $0) }) { state.setDay(day, in: store) }
        if let closed = store.launchValue("closed") { state.options.includesClosed = ["on", "true", "1", "yes"].contains(closed.lowercased()) }
        if let cash = store.launchValue("cash") { state.options.showsCash = !["off", "false", "0", "no"].contains(cash.lowercased()) }
        if let filter = store.launchValue("filter") { state.options.filter = filter }
        if let sort = store.launchValue("sort"), let order = Self.sortOrder(sort) { state.options.sortOrder = order }
        launchSelection = store.launchValue("select")
        launchHover = store.launchValue("hover")
        collapsesAllAtLaunch = store.launchValue("collapse")?.lowercased() == "all"
        // Last: changes a palette command asked for before this window showed the screen.
        state.finishSeeding()
    }

    private static func sortOrder(_ text: String) -> [KeyPathComparator<HoldingRow>]? {
        let parts = text.lowercased().split(separator: ":")
        guard let column = parts.first else { return nil }
        let explicit: SortOrder? = parts.count > 1 ? (parts[1] == "asc" ? .forward : parts[1] == "desc" ? .reverse : nil) : nil
        func make<Value: Comparable>(_ keyPath: KeyPath<HoldingRow, Value> & Sendable, _ fallback: SortOrder = .reverse) -> [KeyPathComparator<HoldingRow>] {
            [KeyPathComparator(keyPath, order: explicit ?? fallback)]
        }
        switch column {
        case "name": return make(\.name, .forward)
        case "shares": return make(\.sharesSort)
        case "price": return make(\.priceSort)
        case "day": return make(\.dayChangeSort)
        case "value": return make(\.value)
        case "weight": return make(\.weightSort)
        case "cost": return make(\.costSort)
        case "gain": return make(\.gainSort)
        case "gainpct": return make(\.gainFractionSort)
        case "ttwror": return make(\.ttwrorSort)
        case "irr": return make(\.irrSort)
        case "dividends": return make(\.dividendsSort)
        case "trend": return make(\.trendSort)
        default: return nil
        }
    }

    /// Stage 2: filter, sort and total the engine-derived rows (a few hundred at most).
    private func rebuild(_ state: HoldingsViewState) {
        guard let model = base.value else { return }
        let display = HoldingsDisplay(model, options: state.options)
        state.display = display
        state.displayedDay = model.day
        state.displayedCurrency = model.currency
        let valid = state.selection.filter { display.rowsByID[$0] != nil }
        if valid != state.selection { state.selection = valid }

        if collapsesAllAtLaunch {
            collapsesAllAtLaunch = false
            state.collapsed = Set(display.groups.map(\.id))
        }
        if let text = launchSelection, let row = Self.match(text, in: display) {
            launchSelection = nil
            state.reveal(row.id)
        }
        if let text = launchHover, let row = Self.match(text, in: display) {
            launchHover = nil
            pinnedHover = row.id
        }
        revealRouteFocus(state)
    }

    private static func match(_ text: String, in display: HoldingsDisplay) -> HoldingRow? {
        let entities = display.lines.filter(\.isEntity)
        if text.lowercased() == "first" { return entities.first }
        return entities.first { $0.name.localizedCaseInsensitiveContains(text) }
    }

    /// Routing contract: a focused security or account is selected and scrolled to if the table
    /// shows it (its group is expanded).
    private func revealRouteFocus(_ state: HoldingsViewState) {
        let display = state.display
        let target: HoldingRow?
        if let id = store.route.securityID {
            guard !state.selection.contains(where: { display.rowsByID[$0]?.securityID == id }) else { return }
            target = display.lines.first { $0.isEntity && $0.securityID == id }
        } else if let id = store.route.accountID {
            guard !state.selection.contains(where: { display.rowsByID[$0]?.accountID == id }) else { return }
            target = display.lines.first { $0.isEntity && $0.accountID == id }
        } else {
            return
        }
        guard let target else { return }
        state.reveal(target.id)
    }

    /// Selection → focus, so the inspector follows.
    private func selectionChanged(_ selection: Set<String>, _ state: HoldingsViewState) {
        let rows = selection.compactMap { state.display.rowsByID[$0] }.filter(\.isEntity)
        guard selection.count == 1, let row = rows.first else {
            if store.route.focus != nil { store.setFocus(nil) }
            return
        }
        if let id = row.securityID {
            if store.route.securityID != id { store.setFocus(.security(id)) }
        } else if let id = row.accountID {
            if store.route.accountID != id { store.setFocus(.account(id)) }
        }
    }
}

// MARK: - Control bar

/// Statement date, grouping, chart choice, quick filter and table options.
private struct HoldingsControlBar: View {
    @Environment(PortfolioStore.self) private var store
    @Bindable var state: HoldingsViewState

    var body: some View {
        // One row when there is room; otherwise the date moves to a row of its own.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.m) {
                dayControl
                Spacer(minLength: DS.Spacing.s)
                groupingPicker
                visualPicker
                QuickFilterField(text: $state.options.filter, prompt: "Filter holdings")
                optionsMenu
            }
            VStack(spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.m) {
                    dayControl
                    Spacer(minLength: DS.Spacing.s)
                    optionsMenu
                }
                HStack(spacing: DS.Spacing.m) {
                    groupingPicker
                    visualPicker
                    Spacer(minLength: 0)
                    QuickFilterField(text: $state.options.filter, prompt: "Filter holdings", focusShortcut: false)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
    }

    private var visualPicker: some View {
        Picker("Chart", selection: $state.visual) {
            ForEach(HoldingsVisual.allCases) { visual in
                Label(visual.title, systemImage: visual.symbol).tag(visual)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .fixedSize()
        .help("Show the table only, with a treemap, or with a concentration bar")
    }

    private var day: Binding<Day> {
        Binding(get: { state.day(in: store) }, set: { state.setDay($0, in: store) })
    }

    private var dayControl: some View {
        HStack(spacing: DS.Spacing.s) {
            Text("As of").foregroundStyle(.secondary)
            DayField("Statement date", day: day)
            Menu {
                ForEach(HoldingsDayJump.allCases) { jump in
                    let target = jump.day(today: store.today)
                    Button {
                        state.setDay(target, in: store)
                    } label: {
                        Text("\(jump.title) — \(Fmt.day(target, style: .medium))")
                    }
                }
            } label: {
                Label("Jump to date", systemImage: "calendar")
            }
            .menuStyle(.button)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Jump to today or the end of the last month, quarter or year")
            if state.day(in: store) != store.today {
                Button("Today") { state.day = nil }
                    .buttonStyle(.link)
                    .help("Back to today (⌘T)")
            } else {
                Text("Today").foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
    }

    /// Bound to the grouping in effect, so the picker never shows an empty selection while the
    /// table has fallen back to "No Grouping" (the grouped-by taxonomy was deleted).
    private var grouping: Binding<HoldingsGrouping> {
        Binding(get: { state.resolvedGrouping(in: store) }, set: { state.grouping = $0 })
    }

    private var groupingPicker: some View {
        Picker("Group by", selection: grouping) {
            Text("No Grouping").tag(HoldingsGrouping.none)
            Text("Depot & Account").tag(HoldingsGrouping.depot)
            Text("Currency").tag(HoldingsGrouping.currency)
            if !store.file.taxonomies.isEmpty {
                Section("Taxonomy") {
                    ForEach(store.file.taxonomies) { taxonomy in
                        Text(taxonomy.name.isEmpty ? "Untitled" : taxonomy.name).tag(HoldingsGrouping.taxonomy(taxonomy.id))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Group the table with subtotals")
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Cash Accounts", isOn: $state.options.showsCash)
            Toggle("Include Positions Closed in the Period", isOn: $state.options.includesClosed)
            if state.display.isGrouped {
                Divider()
                Button("Expand All Groups") { state.collapsed.removeAll() }
                Button("Collapse All Groups") { state.collapsed = Set(state.display.groups.map(\.id)) }
            }
            Divider()
            Button("Reset Sorting") { state.options.sortOrder = HoldingsDisplay.defaultSortOrder }
            Divider()
            Button("Copy Table", systemImage: "doc.on.doc") { HoldingsActions.copy([], in: store) }
            Button("Export as CSV…", systemImage: "square.and.arrow.up") { HoldingsActions.exportCSV(in: store) }
        } label: {
            Label("Table options", systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("Table options, copy and export")
    }
}

// MARK: - Summary strip

/// The key figures of the statement above the table.
private struct HoldingsSummary: View {
    let model: HoldingsBase
    let periodTitle: String
    let isRefreshing: Bool

    private enum Figure: CaseIterable { case total, securities, cash, cost, gain, ttwror, irr }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip([.total, .securities, .cash, .cost, .gain, .ttwror, .irr])
            strip([.total, .securities, .cash, .gain, .ttwror, .irr])
            strip([.total, .gain, .ttwror, .irr])
            strip([.total, .gain, .ttwror])
        }
        .opacity(isRefreshing ? 0.6 : 1)
    }

    private func strip(_ figures: [Figure]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(figures.enumerated()), id: \.offset) { index, figure in
                if index > 0 {
                    Divider().frame(height: 44).padding(.horizontal, DS.Spacing.l)
                }
                view(for: figure)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func fraction(_ part: Int64) -> String {
        model.totalValue > 0 ? "\(Fmt.percent(Double(part) / Double(model.totalValue), decimals: 1)) of total" : " "
    }

    @ViewBuilder private func view(for figure: Figure) -> some View {
        let currency = model.currency
        switch figure {
        case .total:
            tile("Total Value", footnote: "as of \(Fmt.day(model.day, style: .medium))") {
                Text(Fmt.money(minor: model.totalValue, currency: currency)).font(.kontorHero)
            }
        case .securities:
            tile("Securities", footnote: fraction(model.securitiesValue)) {
                Text(Fmt.money(minor: model.securitiesValue, currency: currency))
            }
        case .cash:
            tile("Cash", footnote: fraction(model.cashValue)) {
                Text(Fmt.money(minor: model.cashValue, currency: currency))
            }
        case .cost:
            tile("Cost Basis", topic: .costBasis, footnote: "of the securities") {
                Text(Fmt.money(minor: model.costBasis, currency: currency))
            }
        case .gain:
            let gain = model.securitiesValue - model.costBasis
            tile("Unrealized Gain", topic: .unrealizedGains,
                 footnote: model.costBasis > 0 ? "\(Fmt.percent(Double(gain) / Double(model.costBasis), signed: true)) on cost" : " ") {
                GainText(money: Money(minor: gain, currency: currency))
            }
        case .ttwror:
            tile("TTWROR · \(periodTitle)", topic: .ttwror,
                 footnote: model.absolutePerformance.map { Fmt.money(minor: $0, currency: currency, signed: true) } ?? "period begins later") {
                if let ttwror = model.ttwror { ReturnText(value: ttwror) } else { Text(Fmt.missing) }
            }
        case .irr:
            tile("IRR · \(periodTitle)", topic: .irr, footnote: model.hasPeriodFigures ? "per year" : "period begins later") {
                if let irr = model.irr { ReturnText(value: irr) } else { Text(Fmt.missing) }
            }
        }
    }

    private func tile<Value: View>(_ label: String, topic: HelpTopic? = nil, footnote: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(label).font(.kontorCaption).foregroundStyle(.secondary)
                if let topic { HelpButton(topic) }
            }
            value()
                .font(.kontorValue)
                .frame(height: 30, alignment: .bottomLeading)
            Text(footnote)
                .font(.caption)
                .numeric()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Keyboard shortcuts

/// The key equivalents of the row actions — declared once, used by the hidden shortcut buttons and
/// shown in the context menu.
///
/// Sell is ⇧⌃⌘S: ⌃⌘S is the system's Show/Hide Sidebar (View menu, `SidebarCommands`).
enum HoldingsShortcut {
    case buy, sell, dividend, transactions

    var key: KeyEquivalent {
        switch self {
        case .buy: "b"
        case .sell: "s"
        case .dividend: "d"
        case .transactions: "t"
        }
    }

    var modifiers: EventModifiers {
        self == .sell ? [.command, .control, .shift] : [.command, .control]
    }

    func applies(to row: HoldingRow) -> Bool {
        switch self {
        case .buy, .dividend: row.securityID != nil
        case .sell: row.kind == .position
        case .transactions: row.isEntity
        }
    }
}

/// Shortcuts for the selected row; hidden buttons so they work wherever the focus is on the screen.
/// A button is disabled — and its key passes on to the menus — unless exactly one row it applies
/// to is selected.
private struct HoldingsShortcuts: View {
    @Environment(PortfolioStore.self) private var store
    let state: HoldingsViewState

    var body: some View {
        let rows = state.selectedRows
        let row = rows.count == 1 ? rows.first : nil
        Group {
            shortcut("Buy", .buy, row) { HoldingsActions.buy($0, in: store) }
            shortcut("Sell", .sell, row) { HoldingsActions.sell($0, in: store) }
            shortcut("Record Dividend", .dividend, row) { HoldingsActions.recordDividend($0, in: store) }
            shortcut("Show Transactions", .transactions, row) { HoldingsActions.showTransactions($0, in: store) }
            Button("Statement for Today") { state.day = nil }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(state.day == nil)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func shortcut(_ title: String, _ shortcut: HoldingsShortcut, _ row: HoldingRow?, action: @escaping (HoldingRow) -> Void) -> some View {
        let target = row.flatMap { shortcut.applies(to: $0) ? $0 : nil }
        return Button(title) {
            if let target { action(target) }
        }
        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        .disabled(target == nil)
    }
}
