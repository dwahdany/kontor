import SwiftUI
import KontorUI
import KontorMarketData

/// The Securities screen: master data and market data.
///
/// Left: a searchable, filterable list of all securities (filter chips, watchlists, sort).
/// Right: the detail of the selected security — header, price chart, key figures and the tabs
/// Transactions, Prices, Events, Data Source and Notes. It is the target of `Route.security(id)`.
///
/// Launch state (`--state key=value`, read once on appear):
///
/// | key | values |
/// |---|---|
/// | `security` | `first` or a security UUID — select it (same as `--route security:<uuid>`) |
/// | `selection` | `multi` — select the first three rows (bulk actions pane) · `none` — select nothing |
/// | `filter` | `all` `held` `notheld` `retired` `missing` `watchlist:<uuid, name or 1-based index>` |
/// | `sort` | `name` `price` `day` `period` `value` `updated`; `order=asc` or `desc` |
/// | `search` | text for the quick filter |
/// | `tab` | `overview` `transactions` `prices` `events` `source` `notes` |
/// | `chart` | `1M` `3M` `6M` `YTD` `1Y` `3Y` `5Y` `MAX` (the chart's own period) |
/// | `ma` | `50`, `200` or `50,200` — moving averages |
/// | `cost` | `on` — purchase-price line |
/// | `compare` | `benchmark` (the first benchmark of the file) or a security UUID |
/// | `hover` | `YYYY-MM-DD` — pins the chart's crosshair |
/// | `prices` | `deleterange` — opens the delete-range bar of the Prices tab |
/// | `events` | `note` — opens the add-note bar of the Events tab |
/// | `watchlist` | `new` — opens the new-watchlist bar · `rename` — renames the filtered watchlist |
///
/// Sheets: `--sheet new-security` (add `--state editor=manual` or `editor=search`, `query=<text>`),
/// `--sheet edit-security:first`, `--sheet "custom:securities.split?security=<uuid>&ratio=2:1&day=YYYY-MM-DD&adjust=quotes|shares|both|none"`.
public struct SecuritiesScreen: View {
    @Environment(PortfolioStore.self) private var store

    @State private var list = Loadable<SecurityListModel>()
    @State private var selection = Set<UUID>()
    @State private var query = SecurityListQuery(today: Day(rawValue: 0))
    @State private var view = SecurityViewState()
    @State private var didSeed = false
    @State private var didAutoSelect = false
    @State private var watchlistEdit: WatchlistNameEdit?
    @State private var scrollTarget: UUID?
    /// Bumped with every scroll request; the scroll task is keyed on it (and never changes its own
    /// key, which SwiftUI reports as "tried to update multiple times per frame").
    @State private var scrollSerial = 0
    @State private var handledScrollSerial = 0
    /// A deep-linked security that still has to be revealed once the rows are known.
    @State private var pendingReveal: UUID?
    /// Width of the list chosen by dragging the divider; 0 = automatic.
    @SceneStorage("securities.listWidth") private var listWidthOverride = 0.0

    public init() {}

    /// About a third of the screen, wide enough for the row layout, leaving room for the detail.
    private func listWidth(in total: CGFloat) -> CGFloat {
        let upper = max(330, min(620, total - 430))
        let preferred = listWidthOverride > 0 ? CGFloat(listWidthOverride) : total * 0.36
        return min(max(preferred, 330), listWidthOverride > 0 ? upper : min(upper, 460))
    }

    private struct ListVariant: Hashable, Sendable {
        var query: SecurityListQuery
        var watchlists: [Watchlist]
        var providerNames: [String: String]
    }

    public var body: some View {
        Group {
            if store.file.securities.isEmpty {
                emptyState
            } else {
                GeometryReader { geometry in
                    let width = listWidth(in: geometry.size.width)
                    HStack(spacing: 0) {
                        listPane(compact: width < 400)
                            .frame(width: width)
                        SplitHandle(width: width) { listWidthOverride = Double($0) }
                        detailPane(compact: geometry.size.width - width < 560)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .modifier(ListTask(list: $list, variant: variant, automatic: MarketAccess.automaticProviders(store)))
        .onAppear(perform: seed)
        .onChange(of: store.route.securityID, initial: true) { _, id in reveal(id) }
        .onChange(of: selection) { _, ids in
            store.setFocus(ids.count == 1 ? .security(ids.first!) : nil)
        }
        .onChange(of: list.value?.rows.map(\.id)) { _, ids in rowsChanged(ids ?? []) }
        .onChange(of: store.revision) { _, _ in
            let valid = selection.filter { store.security($0) != nil }
            if valid.count != selection.count { selection = valid }
            // Undo or a deletion elsewhere may have removed the watchlist that is filtered on or
            // being renamed.
            query.filter = query.filter.validated(in: store.file.watchlists)
            if let id = watchlistEdit?.id, !store.file.watchlists.contains(where: { $0.id == id }) { watchlistEdit = nil }
        }
    }

    private var variant: ListVariant {
        var query = query
        query.today = store.today
        return ListVariant(query: query, watchlists: store.file.watchlists, providerNames: MarketAccess.providerNames(store))
    }

    /// Keeps the list model up to date; a separate modifier so the closure captures plain values.
    private struct ListTask: ViewModifier {
        @Binding var list: Loadable<SecurityListModel>
        let variant: ListVariant
        let automatic: Set<String>

        func body(content: Content) -> some View {
            let variant = variant
            let automatic = automatic
            content.analysisTask($list, id: "securities.list", scope: .portfolio, variant: variant) { analysis in
                SecurityListModel(analysis, query: variant.query, watchlists: variant.watchlists,
                                  providerNames: variant.providerNames, automaticProviders: automatic)
            }
        }
    }

    // MARK: Launch state, routing, selection

    private func seed() {
        guard !didSeed else { return }
        didSeed = true
        query.today = store.today
        if let value = store.launchValue("filter"), let filter = SecurityFilter(launchValue: value, file: store.file) {
            query.filter = filter
        }
        if let sort = store.launchValue("sort", as: SecuritySort.self) {
            query.sort = sort
            query.ascending = sort.defaultAscending
        }
        if let order = store.launchValue("order") { query.ascending = order != "desc" }
        if let text = store.launchValue("search") { query.text = text }
        view.seed(from: store)
        switch store.launchValue("security") {
        case "first"?:
            if let first = store.file.securities.first { select(first.id) }
        case let value?:
            if let id = UUID(uuidString: value), store.security(id) != nil { select(id) }
        case nil:
            break
        }
        if store.launchValue("selection") == "none" { didAutoSelect = true }
        switch store.launchValue("watchlist") {
        case "new"?: watchlistEdit = WatchlistNameEdit(id: nil, name: "")
        case "rename"?:
            if case .watchlist(let id) = query.filter, let list = store.file.watchlists.first(where: { $0.id == id }) {
                watchlistEdit = WatchlistNameEdit(id: id, name: list.name)
            }
        default: break
        }
    }

    private func select(_ id: UUID) {
        didAutoSelect = true
        selection = [id]
        requestScroll(to: id)
    }

    /// A deep link names a security: select it, and drop filters that would hide it.
    private func reveal(_ id: UUID?) {
        guard let id, store.security(id) != nil else { return }
        didAutoSelect = true
        guard selection != [id] else { return }
        if let rows = list.value?.rows {
            if !rows.contains(where: { $0.id == id }) { showAll() }
        } else {
            pendingReveal = id
        }
        selection = [id]
        requestScroll(to: id)
    }

    private func showAll() {
        query.filter = .all
        query.text = ""
    }

    private func rowsChanged(_ ids: [UUID]) {
        if let id = pendingReveal, list.value != nil {
            pendingReveal = nil
            if !ids.contains(id), query.filter != .all || !query.text.isEmpty { showAll() } else { requestScroll(to: id) }
        }
        guard !ids.isEmpty else { return }
        if !didAutoSelect {
            didAutoSelect = true
            if store.launchValue("selection") == "multi" {
                selection = Set(ids.prefix(3))
            } else if selection.isEmpty {
                // Master–detail: show something useful right away.
                selection = [ids[0]]
            }
        }
    }

    // MARK: Empty file

    private var emptyState: some View {
        EmptyState(
            "No Securities Yet", symbol: "building.columns",
            message: "Securities are the stocks, funds, bonds and crypto assets you own or watch. "
                + "Search for one online to add it with its price history, or enter it by hand."
        ) {
            Button("Add Security…") { store.present(.newSecurity) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button("Import…") { store.present(.importFile) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List pane

    private var rows: [SecurityRow] { list.value?.rows ?? [] }
    private var counts: SecurityListModel.Counts { list.value?.counts ?? .init() }

    private func listPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                QuickFilterField(text: $query.text, prompt: "Filter securities")
                Spacer(minLength: 0)
                sortMenu
                Button {
                    store.present(.newSecurity)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a security")
                .accessibilityLabel("Add Security")
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.top, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.s)

            FilterChips(filter: $query.filter, counts: counts, edit: $watchlistEdit, selection: selection)

            if let edit = watchlistEdit {
                WatchlistNameBar(edit: edit) { name in commitWatchlist(edit, name: name) } cancel: { watchlistEdit = nil }
            }

            ListColumnHeader(query: $query, periodTitle: store.period.shortTitle, compact: compact)
            Divider()

            if rows.isEmpty, list.value != nil {
                noMatches
            } else {
                securityList(compact: compact)
            }
            ListFooter(model: list.value, total: store.file.securities.count, selected: selection.count)
        }
        .loadingOverlay(list.isInitialLoad)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { query.sort }, set: { sort in
                if query.sort == sort { query.ascending.toggle() } else { query.sort = sort; query.ascending = sort.defaultAscending }
            })) {
                ForEach(SecuritySort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Order", selection: $query.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(query.sort.title), \(query.ascending ? "ascending" : "descending")")
        .accessibilityLabel("Sort")
    }

    private var noMatches: some View {
        EmptyState("No Matching Securities", symbol: "line.3.horizontal.decrease.circle", message: noMatchesMessage) {
            if !query.text.isEmpty || query.filter != .all {
                Button("Show All Securities") {
                    query.text = ""
                    query.filter = .all
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesMessage: String {
        if case .watchlist = query.filter, query.text.isEmpty {
            return "This watchlist is empty. Drag securities onto its chip, or use “Add to Watchlist” in a security's context menu."
        }
        switch query.filter {
        case .missingQuotes where query.text.isEmpty: return "Every security has current quotes."
        case .retired where query.text.isEmpty: return "No security is retired."
        default: return "Nothing matches the current filter."
        }
    }

    private func securityList(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(rows) { row in
                    SecurityRowView(row: row, compact: compact)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets(top: 5, leading: DS.Spacing.s, bottom: 5, trailing: DS.Spacing.s))
                        .draggable(dragPayload(for: row.id))
                        .id(row.id)
                }
            }
            .listStyle(.inset)
            // A new query replaces the list instead of animating row insertions: AppKit's automatic
            // row heights log a re-entrancy warning when many rows are inserted into a live table.
            .id(list.value?.query)
            .opacity(list.isRefreshing ? 0.7 : 1)
            .contextMenu(forSelectionType: UUID.self) { ids in
                SecurityContextMenu(store: store, ids: ids, filter: query.filter) { name in
                    watchlistEdit = WatchlistNameEdit(id: nil, name: name, adding: ids)
                } selectNew: { id in
                    select(id)
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { store.present(.editSecurity(id)) }
            }
            .onDeleteCommand { store.confirmDeleteSecurities(selection) }
            .onCopyCommand { [NSItemProvider(object: store.securitiesTSV(selection) as NSString)] }
            .accessibilityLabel("Securities")
            // Scroll once the rows that contain the target are on screen: when a scroll is requested
            // and again when a new list arrives. Two observers, one value each — a combined key that
            // changes twice in a frame (request + new query) makes SwiftUI drop one of the updates.
            .onChange(of: scrollSerial, initial: true) { _, _ in scrollToTarget(with: proxy) }
            .onChange(of: list.value?.query) { _, _ in scrollToTarget(with: proxy) }
        }
    }

    private func scrollToTarget(with proxy: ScrollViewProxy) {
        guard handledScrollSerial != scrollSerial, let target = scrollTarget, rows.contains(where: { $0.id == target }) else { return }
        let serial = scrollSerial
        Task { @MainActor in
            // One turn later: the list may only just have received these rows.
            await Task.yield()
            guard handledScrollSerial != serial else { return }
            proxy.scrollTo(target, anchor: .center)
            handledScrollSerial = serial
        }
    }

    private func requestScroll(to id: UUID) {
        scrollTarget = id
        scrollSerial += 1
    }

    /// Dragging a selected row drags the whole selection (one UUID per line).
    private func dragPayload(for id: UUID) -> String {
        let ids = selection.contains(id) ? rows.map(\.id).filter(selection.contains) : [id]
        return ids.map(\.uuidString).joined(separator: "\n")
    }

    private func commitWatchlist(_ edit: WatchlistNameEdit, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        watchlistEdit = nil
        guard !name.isEmpty else { return }
        if let id = edit.id {
            // A rename of a watchlist that is gone by now does nothing (it must not create a new one).
            guard var list = store.file.watchlists.first(where: { $0.id == id }), list.name != name else { return }
            list.name = name
            store.mutate("Rename Watchlist") { file in
                if let index = file.watchlists.firstIndex(where: { $0.id == id }) { file.watchlists[index] = list }
            }
        } else {
            let list = Watchlist(name: name, securityIDs: store.file.securities.map(\.id).filter(edit.adding.contains))
            store.mutate("New Watchlist") { $0.watchlists.append(list) }
            query.filter = .watchlist(list.id)
        }
    }

    // MARK: Detail pane

    @ViewBuilder private func detailPane(compact: Bool) -> some View {
        if selection.count == 1, let id = selection.first, store.security(id) != nil {
            SecurityDetailView(securityID: id, compact: compact, view: view)
        } else if selection.count > 1 {
            MultiSelectionView(ids: selection, filter: query.filter)
        } else {
            EmptyState("No Security Selected", symbol: "building.columns",
                       message: "Select a security in the list to see its chart, key figures, transactions and quotes.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The divider between list and detail; drag to resize the list, double-click for the automatic width.
private struct SplitHandle: View {
    let width: CGFloat
    let resize: (CGFloat) -> Void
    @State private var startWidth: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                resize(max(330, start + value.translation.width))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
                    .onTapGesture(count: 2) { resize(0) }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - View state shared by the detail pane

enum DetailTab: String, CaseIterable, Identifiable {
    case overview, transactions, prices, events, source, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .transactions: "Transactions"
        case .prices: "Prices"
        case .events: "Events"
        case .source: "Data Source"
        case .notes: "Notes"
        }
    }
}

/// Tab and chart settings survive a change of the selected security, so that flipping through
/// the list compares like with like.
@MainActor @Observable
final class SecurityViewState {
    var tab = DetailTab.overview
    var range = ChartRange.oneYear
    var showsPurchasePrice = false
    var showsAverage50 = false
    var showsAverage200 = false
    var compareID: UUID?
    var pinnedHover: Day?
    var showsDeleteRange = false
    var showsNoteEditor = false

    func seed(from store: PortfolioStore) {
        tab = store.launchValue("tab", as: DetailTab.self) ?? tab
        if let value = store.launchValue("chart"), let range = ChartRange(rawValue: value.uppercased()) { self.range = range }
        if let averages = store.launchValue("ma")?.split(separator: ",") {
            showsAverage50 = averages.contains("50")
            showsAverage200 = averages.contains("200")
        }
        showsPurchasePrice = store.launchValue("cost") == "on"
        if let value = store.launchValue("compare") {
            compareID = value == "benchmark" ? store.file.settings.benchmarkSecurityIDs.first : UUID(uuidString: value)
        }
        pinnedHover = store.launchValue("hover").flatMap { Day(iso: $0) }
        showsDeleteRange = store.launchValue("prices") == "deleterange"
        showsNoteEditor = store.launchValue("events") == "note"
    }
}

// MARK: - Rows

struct SecurityRowView: View {
    let row: SecurityRow
    /// Narrow list: no sparkline.
    var compact = false

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(row.displayName)
                        .lineLimit(1)
                        .foregroundStyle(row.isRetired || row.name.isEmpty ? .secondary : .primary)
                    if row.isBenchmark {
                        Image(systemName: "flag")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .help("Used as a benchmark")
                            .accessibilityLabel("Benchmark")
                    }
                }
                HStack(spacing: DS.Spacing.xs) {
                    Text(row.identifiers.isEmpty ? row.currency : row.identifiers)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusGlyph
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(tooltip)

            if !compact {
                Sparkline(row.spark, tint: row.isRetired ? .secondary : nil)
                    .frame(width: 52, height: 22)
                    .opacity(row.spark.isEmpty ? 0 : 1)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(row.latest.map { Fmt.price($0, currency: row.currency) } ?? Fmt.missing)
                    .numeric()
                    .lineLimit(1)
                Group {
                    if let change = row.dayChange, row.health == .current, !row.isRetired {
                        DeltaLabel(fraction: change)
                    } else if let day = row.latestDay {
                        Text(Fmt.day(day, style: .medium)).foregroundStyle(.secondary).numeric()
                    } else {
                        Text("No quotes").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            .frame(width: compact ? 82 : 88, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                if let problem = row.valuationProblem {
                    // Held, but without a quote or exchange rate: unknown, not zero.
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .foregroundStyle(DS.Colors.warning)
                        Text(Fmt.missing).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .help("\(problem) — this holding cannot be valued and is left out of the total.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Not valued: \(problem)")
                } else {
                    Text(row.value.map { Fmt.moneyRounded($0) } ?? Fmt.missing)
                        .numeric()
                        .lineLimit(1)
                        .foregroundStyle(row.value == nil ? .tertiary : .primary)
                }
                Group {
                    if let change = row.periodChange {
                        GainText(percent: change)
                    } else {
                        Text(Fmt.missing).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            .frame(width: compact ? 70 : 76, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Full name plus where the quotes come from and how fresh they are.
    private var tooltip: String {
        var lines = [row.displayName]
        let source = row.feedName.isEmpty ? "No data source" : (row.hasAutomaticFeed ? "Quotes from \(row.feedName)" : "Data source: \(row.feedName)")
        if let day = row.latestDay {
            lines.append("\(source) · latest quote \(Fmt.day(day, style: .medium))")
        } else {
            lines.append("\(source) · no quotes yet")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var statusGlyph: some View {
        if row.isRetired {
            StatusBadge(title: "Retired").fixedSize()
        } else {
            switch row.health {
            case .current:
                EmptyView()
            case .stale(let days):
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(DS.Colors.warning)
                    .help("The latest quote is \(Fmt.duration(days: days)) old.")
                    .accessibilityLabel("Quotes are \(Fmt.duration(days: days)) old")
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(DS.Colors.warning)
                    .help("This security has no quotes yet.")
                    .accessibilityLabel("No quotes")
            }
        }
    }
}

/// Column captions of the list; clicking one sorts by it.
private struct ListColumnHeader: View {
    @Binding var query: SecurityListQuery
    let periodTitle: String
    var compact = false

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            caption("Security", .name).frame(maxWidth: .infinity, alignment: .leading)
            if !compact { Text("1Y").frame(width: 52, alignment: .center).help("Price over the past year") }
            HStack(spacing: 3) {
                caption("Price", .price)
                Text("·")
                caption("Day", .day)
            }
            .frame(width: compact ? 82 : 88, alignment: .trailing)
            HStack(spacing: 3) {
                caption("Value", .value, help: "Market value of your holding today — click to sort")
                Text("·")
                caption(periodTitle, .period, help: "Price change over the reporting period (\(periodTitle)) — click to sort")
            }
            .frame(width: compact ? 70 : 76, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l + 2)
        .padding(.vertical, 5)
    }

    private func caption(_ title: String, _ sort: SecuritySort, help: String? = nil) -> some View {
        Button {
            if query.sort == sort { query.ascending.toggle() } else { query.sort = sort; query.ascending = sort.defaultAscending }
        } label: {
            HStack(spacing: 2) {
                Text(title).lineLimit(1)
                if query.sort == sort {
                    Image(systemName: query.ascending ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(query.sort == sort ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "Sort by \(sort.title.lowercased())")
        .accessibilityLabel("Sort by \(sort.title)")
    }
}

private struct ListFooter: View {
    let model: SecurityListModel?
    let total: Int
    let selected: Int

    var body: some View {
        let count = model?.rows.count ?? 0
        HStack(spacing: DS.Spacing.m) {
            Text(text(count))
            Spacer(minLength: DS.Spacing.s)
            if let model, model.totalValue != 0 || model.unvaluedCount > 0 {
                Text(heldText(model))
                    .help(model.unvaluedCount == 0
                          ? "Market value today of the listed holdings"
                          : "Market value today of the listed holdings. \(Fmt.integer(model.unvaluedCount)) of them cannot be valued (missing quote or exchange rate) and are left out.")
            }
        }
        .font(.callout)
        .numeric()
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func text(_ count: Int) -> String {
        var parts = ["\(Fmt.integer(count)) \(count == 1 ? "security" : "securities")"]
        if total != count { parts[0] += " of \(Fmt.integer(total))" }
        if selected > 1 { parts.append("\(Fmt.integer(selected)) selected") }
        return parts.joined(separator: " · ")
    }

    private func heldText(_ model: SecurityListModel) -> String {
        var parts = [String]()
        if model.totalValue != 0 { parts.append("Held \(Fmt.moneyRounded(Money(minor: model.totalValue, currency: model.currency)))") }
        if model.unvaluedCount > 0 { parts.append("\(Fmt.integer(model.unvaluedCount)) not valued") }
        return parts.joined(separator: " · ")
    }
}
