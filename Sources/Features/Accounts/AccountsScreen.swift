import SwiftUI
import KontorUI

/// The Accounts screen: an overview of cash accounts and depots, and a detail page for each.
///
/// Which page is shown follows the route: `store.route.focus == .account(id)` / `.depot(id)` opens
/// that entity's detail page, no focus shows the overview. Opening an entity is a
/// `store.navigate(to:)`, so the window's back / forward buttons step between overview and detail.
///
/// Launch state (`--state key=value`, read once on appear):
///
/// | key | values | effect |
/// |---|---|---|
/// | `account` | `first`, or an account name (case-insensitive) | opens that account's detail page |
/// | `depot` | `first`, or a depot name | opens that depot's detail page |
/// | `tab` | `positions` (default), `transactions` | table shown on a depot's detail page |
/// | `retired` | `shown` | expands the retired accounts and depots on the overview |
/// | `hover` | `last`, `mid`, or `YYYY-MM-DD` | pins the chart tooltips (overview and detail) to that day |
/// | `filter` | text | quick filter of the statement / transactions / positions table on a detail page |
/// | `range` | `period` (default), `all` | whether the statement / depot transactions list the reporting period or everything |
/// | `highlight` | `first`, `last`, or an account / depot name | keyboard highlight on the overview (scrolled into view) |
///
/// Entity focus also works through `--route account:<uuid>` / `--route depot:<uuid>`; the period
/// comes from `--period`.
public struct AccountsScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var appliedLaunchState = false

    public init() {}

    public var body: some View {
        Group {
            if let id = store.route.accountID, store.account(id) != nil {
                AccountDetailView(accountID: id).id(id)
            } else if let id = store.route.depotID, store.depot(id) != nil {
                DepotDetailView(depotID: id).id(id)
            } else {
                AccountsOverviewView()
            }
        }
        .onAppear {
            guard !appliedLaunchState else { return }
            appliedLaunchState = true
            if let focus = Self.launchFocus(store.launchState, in: store.file) { store.setFocus(focus) }
        }
    }

    /// `account=first|<name>` / `depot=first|<name>` → the entity to open.
    static func launchFocus(_ state: [String: String], in file: PortfolioFile) -> Route.Focus? {
        func match<E>(_ value: String, _ items: [E], name: KeyPath<E, String>) -> E? {
            if value.lowercased() == "first" { return items.first }
            return items.first { $0[keyPath: name].compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if let value = state["account"], let account = match(value, file.accounts, name: \.name) { return .account(account.id) }
        if let value = state["depot"], let depot = match(value, file.depots, name: \.name) { return .depot(depot.id) }
        return nil
    }

    /// `hover=last|mid|YYYY-MM-DD` → the day chart tooltips are pinned to.
    static func launchHover(_ state: [String: String], interval: DayInterval) -> Day? {
        guard let value = state["hover"]?.lowercased() else { return nil }
        switch value {
        case "last": return interval.end
        case "mid": return interval.start.advanced(by: interval.dayCount / 2)
        default: return Day(iso: value)
        }
    }
}

// MARK: - Overview

struct AccountsOverviewView: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.gainStyle) private var gainStyle
    @State private var model = Loadable<AccountsOverview>()
    @State private var highlight: AccountsEntity?
    @State private var hovered: AccountsEntity?
    @State private var pinnedDay: Day?
    @SceneStorage("accounts.showsRetiredAccounts") private var showsRetiredAccounts = false
    @SceneStorage("accounts.showsRetiredDepots") private var showsRetiredDepots = false
    /// `--state retired=shown`: expanded regardless of what the window remembers.
    @State private var forcesRetired = false
    @FocusState private var listFocused: Bool
    /// `--state highlight=…`: the highlight is drawn although the screenshot window never has focus.
    @State private var pinsHighlight = false
    /// Width of the scroll area; narrow windows drop the least important columns.
    @State private var width: CGFloat = 1_000

    private var showsActivity: Bool { width >= 860 }
    private var showsSparkline: Bool { width >= 680 }

    private enum Column {
        static let sparkline: CGFloat = 104
        static let activity: CGFloat = 112
        static let money: CGFloat = 132
        static let positions: CGFloat = 76
        static let performance: CGFloat = 150
        static let chevron: CGFloat = 12
    }

    var body: some View {
        let today = store.today
        Group {
            if store.file.accounts.isEmpty && store.file.depots.isEmpty {
                emptyState
            } else if let overview = model.value {
                content(overview)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "accounts.overview", scope: .portfolio, variant: today) { analysis in
            AccountsOverview(analysis, today: today)
        }
        .onAppear {
            forcesRetired = store.launchValue("retired") == "shown"
            pinnedDay = AccountsScreen.launchHover(store.launchState, interval: store.periodInterval)
            if let value = store.launchValue("highlight") {
                highlight = Self.launchHighlight(value, in: store.file)
                pinsHighlight = highlight != nil
            }
        }
    }

    /// `highlight=first|last|<name>` → the row to highlight.
    static func launchHighlight(_ value: String, in file: PortfolioFile) -> AccountsEntity? {
        let all = file.accounts.map { (AccountsEntity.account($0.id), $0.name) } + file.depots.map { (AccountsEntity.depot($0.id), $0.name) }
        switch value.lowercased() {
        case "first": return all.first?.0
        case "last": return all.last?.0
        default: return all.first { $0.1.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.0
        }
    }

    private var emptyState: some View {
        EmptyState(
            "No Accounts Yet", symbol: "creditcard",
            message: "A cash account holds your money, a depot holds your securities. Add one of each to start recording transactions — or import your history from a file."
        ) {
            Button("New Cash Account…") { store.present(.newAccount) }
                .keyboardShortcut(.defaultAction)
            Button("New Depot…") { store.present(.newDepot) }
            Button("Import…") { store.present(.importFile) }
        }
    }

    private func content(_ overview: AccountsOverview) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    summary(overview)
                    accountsSection(overview)
                    depotsSection(overview)
                }
                .screenPadding()
                .opacity(model.isRefreshing ? 0.6 : 1)
            }
            // The keyboard highlight is always on screen: arrow keys scroll just far enough.
            .onChange(of: highlight, initial: true) { _, entity in
                if let entity { scroller.scrollTo(entity) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .delete, .deleteForward]) { press in
            handleKey(press, overview)
        }
        .onCopyCommand { [NSItemProvider(object: overview.tsv as NSString)] }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { listFocused = true }
    }

    // MARK: Summary

    private func summary(_ overview: AccountsOverview) -> some View {
        let total = overview.netWorth.minor
        func share(_ part: Money) -> String {
            total > 0 ? "\(Fmt.percent(Double(part.minor) / Double(total), decimals: 1)) of net worth" : ""
        }
        return HStack(alignment: .top, spacing: DS.Spacing.l) {
            VStack(spacing: DS.Spacing.m) {
                // A total that leaves out what cannot be valued says so instead of looking complete.
                FigureTile("Net Worth", value: Fmt.money(overview.netWorth), footnote: "as of \(Fmt.day(overview.today, style: .medium))",
                           warning: overview.gaps.note)
                FigureTile("Cash", value: Fmt.money(overview.cashTotal), footnote: share(overview.cashTotal), warning: overview.gaps.cashNote)
                FigureTile("Securities", value: Fmt.money(overview.depotTotal), footnote: share(overview.depotTotal),
                           warning: overview.gaps.securitiesNote)
            }
            .frame(width: 250)
            Card("Net Worth by Account", symbol: "chart.bar.xaxis") {
                StackedAreaChart(
                    data: overview.chart, title: "Net worth by account", isLoading: model.isRefreshing, pinnedHover: pinnedDay,
                    emptyMessage: "Nothing was held in this period")
                    .frame(maxHeight: .infinity)
            } accessory: {
                Text(Fmt.interval(overview.interval)).font(.callout).foregroundStyle(.secondary).numeric()
            }
            .frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Cash accounts

    private func accountsSection(_ overview: AccountsOverview) -> some View {
        let showsValue = overview.hasForeignCurrency
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader("Cash Accounts", subtitle: Fmt.integer(overview.accounts.count)) {
                HelpButton(.cashAccount)
                Button("New Account", systemImage: "plus") { store.present(.newAccount) }
                    .help("Add a cash account (⌃⌘N)")
            }
            if overview.accounts.isEmpty {
                sectionPlaceholder("No cash accounts. Purchases and dividends need an account to settle on.", action: "New Cash Account…") {
                    store.present(.newAccount)
                }
            } else {
                VStack(spacing: 0) {
                    columnHeader {
                        Text("Account").frame(maxWidth: .infinity, alignment: .leading)
                        if showsSparkline { Text("Last 12 Months").frame(width: Column.sparkline, alignment: .leading) }
                        if showsActivity { Text("Last Activity").frame(width: Column.activity, alignment: .leading) }
                        Text("Balance").frame(width: Column.money, alignment: .trailing)
                        if showsValue {
                            Text("Value in \(overview.currency)").frame(width: Column.money, alignment: .trailing)
                        }
                    }
                    ForEach(overview.activeAccounts) { row in
                        Divider().padding(.leading, DS.Spacing.l)
                        accountRow(row, overview, showsValue: showsValue)
                    }
                    if !overview.retiredAccounts.isEmpty {
                        Divider().padding(.leading, DS.Spacing.l)
                        retiredToggle(count: overview.retiredAccounts.count, isExpanded: retiredBinding($showsRetiredAccounts))
                        if showsRetiredAccounts || forcesRetired {
                            ForEach(overview.retiredAccounts) { row in
                                Divider().padding(.leading, DS.Spacing.l)
                                accountRow(row, overview, showsValue: showsValue)
                            }
                        }
                    }
                    Divider()
                    totalRow("Total cash", value: overview.cashTotal, warning: overview.gaps.cashNote.map {
                        "\($0.prefix(1).uppercased() + $0.dropFirst()). Exchange rates are downloaded together with the quotes (Update Quotes, ⌘R)."
                    })
                }
                .cardBackground()
            }
        }
    }

    private func accountRow(_ row: AccountsOverview.AccountRow, _ overview: AccountsOverview, showsValue: Bool) -> some View {
        rowChrome(.account(row.id), isRetired: row.isRetired) {
            nameCell(symbol: "creditcard", name: row.name, tag: row.balance.currency, isRetired: row.isRetired, detail: row.note)
            if showsSparkline {
                Sparkline(row.sparkline, tint: .secondary)
                    .frame(width: Column.sparkline - 20, height: 22)
                    .frame(width: Column.sparkline, alignment: .leading)
                    .accessibilityHidden(true)
            }
            if showsActivity {
                Text(row.lastActivity.map { Fmt.relativeDay($0, today: overview.today) } ?? "No transactions")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Column.activity, alignment: .leading)
            }
            Text(Fmt.money(row.balance))
                .frame(width: Column.money, alignment: .trailing)
            if showsValue {
                Group {
                    if !row.isValued {
                        Label("No rate", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DS.Colors.warning)
                            .help("No exchange rate from \(row.balance.currency) to \(overview.currency). The balance counts as zero until a rate is available.")
                    } else {
                        Text(Fmt.money(row.value)).foregroundStyle(row.balance.currency == overview.currency ? .secondary : .primary)
                    }
                }
                .frame(width: Column.money, alignment: .trailing)
            }
        }
        .accessibilityLabel("\(row.name), balance \(Fmt.money(row.balance))\(row.isRetired ? ", retired" : "")")
    }

    // MARK: Depots

    private func depotsSection(_ overview: AccountsOverview) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader("Depots", subtitle: Fmt.integer(overview.depots.count)) {
                HelpButton(.depot)
                Button("New Depot", systemImage: "plus") { store.present(.newDepot) }
                    .help("Add a depot — the securities account where shares and funds are held")
            }
            if overview.depots.isEmpty {
                sectionPlaceholder("No depots. A depot holds your securities; add one to record purchases.", action: "New Depot…") {
                    store.present(.newDepot)
                }
            } else {
                VStack(spacing: 0) {
                    columnHeader {
                        Text("Depot").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Positions").frame(width: Column.positions, alignment: .trailing)
                        HStack(spacing: DS.Spacing.xs) {
                            Text("Performance · \(store.period.shortTitle)")
                            HelpButton(.ttwror)
                        }
                        .frame(width: Column.performance, alignment: .trailing)
                        Text("Market Value").frame(width: Column.money, alignment: .trailing)
                    }
                    ForEach(overview.activeDepots) { row in
                        Divider().padding(.leading, DS.Spacing.l)
                        depotRow(row)
                    }
                    if !overview.retiredDepots.isEmpty {
                        Divider().padding(.leading, DS.Spacing.l)
                        retiredToggle(count: overview.retiredDepots.count, isExpanded: retiredBinding($showsRetiredDepots))
                        if showsRetiredDepots || forcesRetired {
                            ForEach(overview.retiredDepots) { row in
                                Divider().padding(.leading, DS.Spacing.l)
                                depotRow(row)
                            }
                        }
                    }
                    Divider()
                    totalRow("Total securities", value: overview.depotTotal, warning: overview.gaps.securitiesNote.map {
                        "\($0.prefix(1).uppercased() + $0.dropFirst()). Open the depot to see which positions are affected."
                    })
                }
                .cardBackground()
            }
        }
    }

    private func depotRow(_ row: AccountsOverview.DepotRow) -> some View {
        rowChrome(.depot(row.id), isRetired: row.isRetired) {
            nameCell(symbol: "briefcase", name: row.name, tag: nil, isRetired: row.isRetired,
                     detail: row.referenceAccountName.map { "Settles on \($0)" } ?? "No reference account")
            Text(Fmt.integer(row.positionCount))
                .foregroundStyle(row.positionCount == 0 ? .secondary : .primary)
                .frame(width: Column.positions, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                if let ttwror = row.ttwror {
                    GainText(percent: ttwror)
                    Text(Fmt.money(row.gain, signed: true)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(Fmt.missing).foregroundStyle(.secondary)
                }
            }
            .frame(width: Column.performance, alignment: .trailing)
            HStack(spacing: DS.Spacing.xs) {
                if row.unvaluedPositions > 0 {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DS.Colors.warning)
                        .help("\(Fmt.integer(row.unvaluedPositions)) position\(row.unvaluedPositions == 1 ? "" : "s") without a price or exchange rate count\(row.unvaluedPositions == 1 ? "s" : "") as zero.")
                        .accessibilityLabel("Incomplete")
                }
                Text(Fmt.money(row.value))
            }
            .frame(width: Column.money, alignment: .trailing)
        }
        .accessibilityLabel("\(row.name), market value \(Fmt.money(row.value))\(row.isRetired ? ", retired" : "")")
    }

    // MARK: Row building blocks

    private func columnHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DS.Spacing.l) {
            content()
            Color.clear.frame(width: Column.chevron, height: 1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.top, DS.Spacing.m)
        .padding(.bottom, DS.Spacing.s)
    }

    private func nameCell(symbol: String, name: String, tag: String?, isRetired: Bool, detail: String) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Spacing.s) {
                    Text(name).fontWeight(.medium).lineLimit(1)
                    if let tag { Badge(tag) }
                    if isRetired { Badge("Retired") }
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowChrome<Content: View>(_ entity: AccountsEntity, isRetired: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        let isHighlighted = highlight == entity && (listFocused || pinsHighlight)
        return Button {
            open(entity)
        } label: {
            HStack(spacing: DS.Spacing.l) {
                content()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Column.chevron)
                    .accessibilityHidden(true)
            }
            .numeric()
            .opacity(isRetired ? 0.7 : 1)
            .padding(.horizontal, DS.Spacing.l)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHighlighted {
                Color.accentColor.opacity(0.16)
            } else if hovered == entity {
                Color.primary.opacity(0.045)
            }
        }
        .onHover { inside in
            if inside { hovered = entity } else if hovered == entity { hovered = nil }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { open(entity) }
            Divider()
            AccountsActions.recordMenu(entity, store: store)
            Divider()
            AccountsActions.manageMenu(entity, store: store, includesReorder: true)
        }
        .accessibilityHint("Opens the details")
        .id(entity)
    }

    private func retiredToggle(count: Int, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .frame(width: 22)
                Text("Retired").fontWeight(.medium)
                Text(Fmt.integer(count)).numeric()
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Spacing.l)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) retired, \(isExpanded.wrappedValue ? "shown" : "hidden")")
    }

    private func totalRow(_ title: String, value: Money, warning: String?) -> some View {
        HStack(spacing: DS.Spacing.l) {
            Text(title).foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(DS.Colors.warning)
                    .lineLimit(2)
                    .help(warning)
            }
            Spacer()
            Text(Fmt.money(value)).fontWeight(.semibold).numeric()
            Color.clear.frame(width: Column.chevron, height: 1)
        }
        .padding(.horizontal, DS.Spacing.l)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    private func sectionPlaceholder(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Text(message).foregroundStyle(.secondary)
            Spacer()
            Button(action, action: perform)
        }
        .padding(DS.Spacing.l)
        .cardBackground()
    }

    // MARK: Behaviour

    private func retiredBinding(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding {
            stored.wrappedValue || forcesRetired
        } set: { expanded in
            if forcesRetired {
                // Leaving the forced state: both sections keep what was visible, then this one changes.
                forcesRetired = false
                showsRetiredAccounts = true
                showsRetiredDepots = true
            }
            stored.wrappedValue = expanded
            // A highlight inside a group that just collapsed would be invisible: drop it.
            if !expanded, let highlight, AccountsActions.isRetired(highlight, in: store) { self.highlight = nil }
        }
    }

    private func open(_ entity: AccountsEntity) {
        store.navigate(to: Route(.accounts, focus: entity.focus))
    }

    /// Rows in the order they are listed, for arrow-key navigation.
    private func visibleEntities(_ overview: AccountsOverview) -> [AccountsEntity] {
        var result = overview.activeAccounts.map { AccountsEntity.account($0.id) }
        if showsRetiredAccounts || forcesRetired { result += overview.retiredAccounts.map { .account($0.id) } }
        result += overview.activeDepots.map { .depot($0.id) }
        if showsRetiredDepots || forcesRetired { result += overview.retiredDepots.map { .depot($0.id) } }
        return result
    }

    private func handleKey(_ press: KeyPress, _ overview: AccountsOverview) -> KeyPress.Result {
        let entities = visibleEntities(overview)
        guard !entities.isEmpty else { return .ignored }
        // Everything acts on the highlighted row only while it is listed: a row hidden in a
        // collapsed "Retired" group (or deleted meanwhile) is neither opened, moved nor deleted.
        let current = OverviewNavigation.resolved(highlight, visible: entities)
        if current == nil, highlight != nil { highlight = nil }
        switch press.key {
        case .upArrow, .downArrow:
            let offset = press.key == .upArrow ? -1 : 1
            if press.modifiers.contains([.command, .option]) {
                guard let current else { return .ignored }
                AccountsActions.move(current, by: offset, in: store)
            } else {
                highlight = OverviewNavigation.moved(current, by: offset, visible: entities)
            }
            return .handled
        case .return:
            guard let current else { return .ignored }
            open(current)
            return .handled
        case .delete, .deleteForward:
            guard let current else { return .ignored }
            AccountsActions.delete(current, in: store)
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Small shared views

/// A quiet capsule label ("EUR", "Retired").
struct Badge: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .fixedSize()
    }
}

/// A key figure in the style of `StatTile`, with room for a help topic and a gain-colored value.
struct FigureTile: View {
    @Environment(\.gainStyle) private var gainStyle
    private let label: String
    private let value: String
    private let footnote: String
    private let topic: HelpTopic?
    private let trend: Trend?
    /// Replaces the footnote: the figure is incomplete or not what it seems, and why.
    private let warning: String?

    init(_ label: String, value: String, footnote: String = "", topic: HelpTopic? = nil, trend: Trend? = nil, warning: String? = nil) {
        self.label = label
        self.value = value
        self.footnote = footnote
        self.topic = topic
        self.trend = trend
        self.warning = warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(label).font(.kontorCaption).foregroundStyle(.secondary).lineLimit(1)
                if let topic { HelpButton(topic).font(.caption) }
            }
            Text(value)
                .font(.kontorHero)
                .foregroundStyle(trend.map { $0.color(gainStyle) } ?? Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let warning {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Warning")
                    Text(warning).numeric().lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.callout)
                .foregroundStyle(DS.Colors.warning)
                .help(footnote.isEmpty ? warning : "\(warning) — \(footnote)")
            } else {
                Text(footnote.isEmpty ? " " : footnote)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .numeric()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}
