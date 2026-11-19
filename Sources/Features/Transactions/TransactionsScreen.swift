import SwiftUI
import KontorUI

/// The ledger: every transaction of the portfolio in one fast, filterable, sortable table.
///
/// Launch state (`--state key=value`, read once when the screen appears):
///
/// | key | values |
/// |---|---|
/// | `filter` | comma-separated: `trades`, `income`, `cash`, `transfers`, `costs` (kind groups) and `issues` (only entries the consistency check complains about) |
/// | `account`, `depot`, `security` | name (or the beginning of it) of the entity to filter by; `account` also turns on the running balance |
/// | `dates` | `all` (default) · `period` (follow the window's reporting period) · `YYYY-MM-DD..YYYY-MM-DD` |
/// | `search` | text for the search field |
/// | `sort` | `date`, `type`, `security`, `shares`, `price`, `amount`, `fees`, `taxes`, `balance`, `account`, `depot`, `note`, optionally `:asc` / `:desc` |
/// | `selection` | number of rows to select from the top |
///
/// Entity focus comes from `--route transaction:<uuid>` (clears filters that hide it, selects and
/// scrolls to it). Sheets: `--sheet new-transaction[:kind]`, `--sheet edit-transaction:first|<uuid>`
/// (see `TransactionEditor` for its own keys) and `--sheet custom:transactions.change-date?count=3`.
public struct TransactionsScreen: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.gainStyle) private var gainStyle

    /// Column order, widths and visibility. The table works on the `@State` copy (which the screen
    /// also changes itself — the Balance and Issue columns appear with their filters); the copy is
    /// persisted per window.
    @SceneStorage("transactions.columns") private var storedColumns: TableColumnCustomization<LedgerRow>
    @State private var columns = TableColumnCustomization<LedgerRow>()
    @SceneStorage("transactions.search") private var storedSearch = ""
    @State private var search = ""
    @State private var filter = LedgerFilterState()
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\LedgerRow.order, order: .reverse)]
    @State private var content = Loadable<LedgerContent>()
    @State private var pendingReveal: UUID?
    /// The pending entry was just saved in the editor (not navigated to): never drop the filters for it.
    @State private var revealKeepsFilters = false
    @State private var scrollTarget: UUID?
    /// Identity of the table. Bumped when a new result adds many rows at once (a filter was
    /// cleared): the table is then replaced instead of receiving hundreds of row insertions, which
    /// makes AppKit log "reentrant operation in its NSTableView delegate".
    @State private var tableGeneration = 0
    /// Columns hidden while only transfers are listed.
    @State private var hiddenForTransfers = Set<String>()
    @State private var launchSelection = 0
    @State private var didReadLaunchState = false

    public init() {}

    private var rows: [LedgerRow] { content.value?.rows ?? [] }

    private var query: LedgerQuery {
        LedgerQuery(
            text: search, groups: filter.groups, accountID: filter.accountID, depotID: filter.depotID, securityID: filter.securityID,
            interval: filter.interval(period: store.periodInterval), issuesOnly: filter.issuesOnly, sortOrder: sortOrder)
    }

    private struct LoadKey: Hashable {
        var revision: Int
        var today: Day
        var query: LedgerQuery
    }

    public var body: some View {
        Group {
            if store.file.transactions.isEmpty {
                onboarding
            } else {
                ledger
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                QuickFilterField(text: $search, prompt: "Search transactions")
            }
            ToolbarItem {
                Menu {
                    actions(for: selection)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .help("Actions for the selected transactions")
                .disabled(selection.isEmpty)
            }
        }
        .onAppear(perform: readLaunchState)
        .task(id: LoadKey(revision: store.revision, today: store.today, query: query)) { await reload() }
        .onChange(of: selection) { _, ids in
            store.setFocus(ids.count == 1 ? .transaction(ids.first!) : nil)
        }
        .onChange(of: store.route.transactionID, initial: true) { _, id in
            guard let id, selection != [id] else { return }
            pendingReveal = id
            revealKeepsFilters = SavedTransactions.take(id, from: store)
            reveal()
        }
        // "Show Transactions" from other screens: Route(.transactions, focus: .security / .account /
        // .depot) lists exactly that entity's entries.
        .onChange(of: [store.route.securityID, store.route.accountID, store.route.depotID]) { _, _ in applyRouteFilter() }
        .onChange(of: filter.accountID) { _, account in
            // The running balance only means something for a single account.
            columns[visibility: "balance"] = account == nil ? .hidden : .visible
        }
        .onChange(of: filter.issuesOnly) { _, issuesOnly in
            columns[visibility: "issue"] = issuesOnly ? .visible : .hidden
        }
        .onChange(of: filter.showsOnlyTransfers) { _, transfers in showTransferColumns(transfers) }
        .onChange(of: columns) { _, columns in storedColumns = columns }
        .onChange(of: search) { _, search in storedSearch = search }
    }

    // MARK: Ledger

    private var ledger: some View {
        ScrollViewReader { proxy in
            // The table is created once the first rows exist: filling an on-screen NSTableView with
            // hundreds of rows in one update makes AppKit log a delegate re-entrancy warning.
            if content.value == nil {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                descriptionColumns
                moneyColumns
                partyColumns
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                actions(for: ids)
            } primaryAction: { ids in
                if let id = ids.first, ids.count == 1 { store.present(.editTransaction(id)) }
            }
            .onCopyCommand { [NSItemProvider(object: LedgerExport.tsv(selectedRows(selection)) as NSString)] }
            .onDeleteCommand { delete(selection) }
            .id(tableGeneration)
            .opacity(content.isRefreshing && content.revision != store.revision ? 0.6 : 1)
            .overlay {
                if content.value != nil, rows.isEmpty {
                    Group {
                        if filter.issuesOnly, content.value?.issueCount == 0 {
                            EmptyState("No Issues", symbol: "checkmark.seal",
                                       message: "Every entry passes the consistency check: nothing is missing, impossible or booked twice.") {
                                Button("Show All Transactions") { clearFilters() }
                            }
                        } else {
                            EmptyState("No Matching Transactions", symbol: "line.3.horizontal.decrease.circle",
                                       message: "Nothing in the ledger matches the search and filters.") {
                                Button("Clear Filters") { clearFilters() }
                            }
                        }
                    }
                    .background(.background)
                }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.5))
                scrollTarget = nil
            }
            }
        }
        .loadingOverlay(content.isInitialLoad)
        .safeAreaInset(edge: .top, spacing: 0) {
            LedgerFilterBar(filter: $filter, issueCount: content.value?.issueCount ?? 0, isFiltering: query.isFiltering, clear: clearFilters)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "transaction", selected: selection.count, filteredFrom: content.value?.totalCount ?? store.file.transactions.count) {
                if let content = content.value, !rows.isEmpty {
                    // Several rows selected: their sums — the way to add up a handful of bookings.
                    if selection.count > 1 {
                        LedgerSums(totals: content.totals(of: selection), isSelection: true)
                    } else {
                        LedgerSums(totals: content.totals, isSelection: false)
                    }
                }
            }
        }
    }

    // Column widths: the ideals of the twelve columns of an account's statement (the default eleven
    // plus Balance) add up to what the default 1440-pt window offers, so nothing scrolls out of
    // view; with fewer columns the table hands the spare width out. Money columns are wide enough
    // for a foreign-currency figure ("+4.516,34 US$"); names give way first and truncate in the middle.
    @TableColumnBuilder<LedgerRow, KeyPathComparator<LedgerRow>>
    private var descriptionColumns: some TableColumnContent<LedgerRow, KeyPathComparator<LedgerRow>> {
        TableColumn("Date", value: \.order) { DateCell(row: $0) }
            .width(min: 112, ideal: 112)
            .customizationID("date")
        TableColumn("Type", value: \.kindRank) { KindCell(row: $0) }
            .width(min: 110, ideal: 126)
            .customizationID("type")
        TableColumn("Issue", value: \.issue) { IssueCell(text: $0.issue) }
            .width(min: 120, ideal: 300)
            .defaultVisibility(.hidden)
            .customizationID("issue")
        TableColumn("Security", value: \.securityRank) { TextCell(text: $0.security, truncation: .middle) }
            .width(min: 90, ideal: 126)
            .customizationID("security")
        TableColumn("Shares", value: \.sharesKey) { SharesCell(row: $0) }
            .width(min: 54, ideal: 60)
            .alignment(.trailing)
            .customizationID("shares")
        TableColumn("Price", value: \.price) { PriceCell(row: $0, reporting: content.value?.totals.currency) }
            .width(min: 66, ideal: 74)
            .alignment(.trailing)
            .customizationID("price")
    }

    @TableColumnBuilder<LedgerRow, KeyPathComparator<LedgerRow>>
    private var moneyColumns: some TableColumnContent<LedgerRow, KeyPathComparator<LedgerRow>> {
        TableColumn("Amount", value: \.cash) { AmountCell(row: $0, showsCurrency: !isAccountView) }
            .width(min: 96, ideal: 104)
            .alignment(.trailing)
            .customizationID("amount")
        TableColumn("Balance", value: \.balanceKey) { BalanceCell(row: $0) }
            .width(min: 100, ideal: 110)
            .alignment(.trailing)
            .defaultVisibility(.hidden)
            .customizationID("balance")
        TableColumn("Fees", value: \.fees) { ChargeCell(minor: $0.fees, currency: isAccountView ? nil : $0.currency) }
            .width(min: 50, ideal: 58)
            .alignment(.trailing)
            .customizationID("fees")
        TableColumn("Taxes", value: \.taxes) { ChargeCell(minor: $0.taxes, currency: isAccountView ? nil : $0.currency) }
            .width(min: 58, ideal: 70)
            .alignment(.trailing)
            .customizationID("taxes")
    }

    @TableColumnBuilder<LedgerRow, KeyPathComparator<LedgerRow>>
    private var partyColumns: some TableColumnContent<LedgerRow, KeyPathComparator<LedgerRow>> {
        TableColumn("Account", value: \.accountRank) { row in
            let viewed = content.value?.balanceAccount
            PartyCell(name: row.account, target: row.kind == .cashTransfer ? row.counter : "", showsTarget: !showsTargetColumn,
                      isTargetView: viewed != nil && row.counterAccountID == viewed && row.accountID != viewed,
                      isSourceView: viewed != nil && row.accountID == viewed)
        }
            .width(min: 70, ideal: 122)
            .customizationID("account")
        TableColumn("Depot", value: \.depotRank) { row in
            let viewed = filter.depotID
            PartyCell(name: row.depot, target: row.kind == .securityTransfer ? row.counter : "", showsTarget: !showsTargetColumn,
                      isTargetView: viewed != nil && row.counterDepotID == viewed && row.depotID != viewed,
                      isSourceView: viewed != nil && row.depotID == viewed)
        }
            .width(min: 60, ideal: 86)
            .customizationID("depot")
        TableColumn("To", value: \.counterRank) { CounterCell(row: $0) }
            .width(min: 110, ideal: 190)
            .defaultVisibility(.hidden)
            .customizationID("counter")
        TableColumn("Note", value: \.note) { TextCell(text: $0.note, isSecondary: true) }
            .width(min: 44, ideal: 50)
            .customizationID("note")
        TableColumn("Source", value: \.source) { TextCell(text: $0.source, isSecondary: true) }
            .width(min: 60, ideal: 100)
            .defaultVisibility(.hidden)
            .customizationID("source")
    }

    /// A list of transfers is about where things went: the target gets its own column, in place of
    /// the Fees and Taxes columns (transfers have neither). Leaving the filter restores them.
    private func showTransferColumns(_ transfers: Bool) {
        columns[visibility: "counter"] = transfers ? .visible : .hidden
        if transfers {
            for id in ["fees", "taxes"] where columns[visibility: id] != .hidden {
                hiddenForTransfers.insert(id)
                columns[visibility: id] = .hidden
            }
        } else {
            for id in hiddenForTransfers { columns[visibility: id] = .automatic }
            hiddenForTransfers = []
        }
    }

    /// The list is one account's statement: every amount is in that account's currency, which the
    /// Balance column and the footer name — the other money columns then show bare numbers.
    private var isAccountView: Bool { content.value?.balanceAccount != nil }

    /// The "To" column is showing, so the Account / Depot cells need not repeat the target.
    private var showsTargetColumn: Bool { columns[visibility: "counter"] == .visible }

    private var onboarding: some View {
        EmptyState("No Transactions Yet", symbol: "list.bullet.rectangle",
                   message: "Everything Kontor shows is derived from this ledger. Record your first purchase or deposit, or bring your history in from a CSV file or Portfolio Performance.") {
            Button("New Transaction…") { store.present(.newTransaction) }
                .keyboardShortcut(.defaultAction)
            Button("Import…") { store.present(.importFile) }
        }
    }

    // MARK: Loading

    private func reload() async {
        let query = query
        let today = store.today
        let revision = store.revision
        content.isLoading = true
        await store.whileBusy {
            // All rows once per revision (shared, memoized); filter and sort per query, off the main actor.
            guard let base = try? await store.compute(LedgerBaseKey(today: today), { ledger in LedgerBase(ledger, today: today) }) else { return }
            let result = await LedgerContent.make(base: base, query: query)
            guard !Task.isCancelled else { return }
            if let shown = content.value?.rows.count, result.rows.count - shown > 50 { tableGeneration += 1 }
            content.value = result
            content.revision = revision
            content.isLoading = false
            if !selection.isEmpty {
                let visible = Set(result.rows.map(\.id))
                if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
            }
            if launchSelection > 0 {
                selection = Set(result.rows.prefix(launchSelection).map(\.id))
                launchSelection = 0
            }
            reveal()
        }
    }

    /// Selects and scrolls to the entry a deep link asked for, clearing filters that hide it. An
    /// entry the user just saved in the editor is selected only if the current filters show it:
    /// entering data must never throw away the search and the filters.
    private func reveal() {
        guard let id = pendingReveal, let content = content.value, content.totalCount == store.file.transactions.count else { return }
        guard store.transaction(id) != nil else {
            pendingReveal = nil
            return
        }
        if content.rows.contains(where: { $0.id == id }) {
            pendingReveal = nil
            revealKeepsFilters = false
            selection = [id]
            // A frame later: the table may only just have been created with these rows, or have
            // received them (cleared filters). Scrolling an NSTableView in the middle of that
            // update makes AppKit log a delegate re-entrancy warning.
            Task { @MainActor in
                await store.whileBusy {
                    try? await Task.sleep(for: .milliseconds(50))
                    scrollTarget = id
                    // And once more when the row heights are known (a far-away row lands short otherwise).
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollTarget = id
                }
            }
        } else if query.isFiltering {
            if revealKeepsFilters {
                pendingReveal = nil
                revealKeepsFilters = false
                store.toast("Saved — not in this list", message: "The current search and filters hide the entry. Clear them to see it.", style: .info)
            } else {
                clearFilters()
            }
        }
    }

    private func clearFilters() {
        search = ""
        filter = LedgerFilterState()
    }

    /// Narrows the ledger to the security, account or depot a route focuses on.
    private func applyRouteFilter() {
        let route = store.route
        guard route.securityID != nil || route.accountID != nil || route.depotID != nil else { return }
        search = ""
        filter = LedgerFilterState()
        filter.securityID = route.securityID
        filter.accountID = route.accountID
        filter.depotID = route.depotID
        columns[visibility: "balance"] = filter.accountID == nil ? .hidden : .visible
        columns[visibility: "issue"] = .hidden
        showTransferColumns(false)
    }

    private func readLaunchState() {
        guard !didReadLaunchState else { return }
        didReadLaunchState = true
        columns = storedColumns
        search = storedSearch
        defer { applyRouteFilter() }
        guard !store.launchState.isEmpty else { return }
        func match<E>(_ items: [E], _ key: String, name: (E) -> String) -> E? {
            guard let wanted = store.launchValue(key)?.lowercased(), !wanted.isEmpty else { return nil }
            return items.first { name($0).lowercased() == wanted } ?? items.first { name($0).lowercased().hasPrefix(wanted) }
                ?? items.first { name($0).lowercased().contains(wanted) }
        }
        for part in (store.launchValue("filter") ?? "").split(separator: ",") {
            if part == "issues" { filter.issuesOnly = true } else if let group = KindGroup(rawValue: String(part)) { filter.groups.insert(group) }
        }
        filter.accountID = match(store.file.accounts, "account", name: \.name)?.id
        filter.depotID = match(store.file.depots, "depot", name: \.name)?.id
        filter.securityID = match(store.file.securities, "security", name: \.name)?.id
        if let dates = store.launchValue("dates") {
            if dates == "period" {
                filter.dates = .period
            } else if let range = dates.range(of: ".."), let from = Day(iso: dates[..<range.lowerBound]), let to = Day(iso: dates[range.upperBound...]) {
                filter.dates = .custom
                filter.from = from
                filter.to = to
            }
        }
        if let text = store.launchValue("search") { search = text }
        if let sort = store.launchValue("sort") {
            let parts = sort.split(separator: ":")
            let ascending = parts.count > 1 ? parts[1] == "asc" : true
            if let name = parts.first, let comparator = Self.comparator(String(name), order: ascending ? .forward : .reverse) {
                sortOrder = [comparator]
            }
        }
        launchSelection = store.launchValue("selection").flatMap { Int($0) } ?? 0
        columns[visibility: "balance"] = filter.accountID == nil ? .hidden : .visible
        columns[visibility: "issue"] = filter.issuesOnly ? .visible : .hidden
        showTransferColumns(filter.showsOnlyTransfers)
    }

    private static func comparator(_ column: String, order: SortOrder) -> KeyPathComparator<LedgerRow>? {
        switch column {
        case "date": KeyPathComparator(\.order, order: order)
        case "type": KeyPathComparator(\.kindRank, order: order)
        case "security": KeyPathComparator(\.securityRank, order: order)
        case "shares": KeyPathComparator(\.sharesKey, order: order)
        case "price": KeyPathComparator(\.price, order: order)
        case "amount": KeyPathComparator(\.cash, order: order)
        case "fees": KeyPathComparator(\.fees, order: order)
        case "taxes": KeyPathComparator(\.taxes, order: order)
        case "balance": KeyPathComparator(\.balanceKey, order: order)
        case "account": KeyPathComparator(\.accountRank, order: order)
        case "depot": KeyPathComparator(\.depotRank, order: order)
        case "note": KeyPathComparator(\.note, order: order)
        default: nil
        }
    }

    // MARK: Actions

    private func selectedRows(_ ids: Set<UUID>) -> [LedgerRow] {
        rows.filter { ids.contains($0.id) }
    }

    @ViewBuilder private func actions(for ids: Set<UUID>) -> some View {
        let single = ids.count == 1 ? ids.first.flatMap { store.transaction($0) } : nil
        Button("Edit…") { if let id = ids.first { store.present(.editTransaction(id)) } }
            .disabled(ids.count != 1)
        Button(ids.count > 1 ? "Duplicate \(Fmt.integer(ids.count)) Transactions" : "Duplicate…") { duplicate(ids) }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(ids.isEmpty)
        Divider()
        Button("Change Date…") {
            store.present(.custom(id: ChangeDateSheet.requestID, payload: ["ids": ids.map(\.uuidString).joined(separator: ",")]))
        }
        .disabled(ids.isEmpty)
        Menu("Move to Account") {
            ForEach(store.file.accounts.filter { !$0.isRetired }) { account in
                Button("\(account.name) (\(account.currency))") { move(ids, toAccount: account) }
            }
        }
        .disabled(ids.isEmpty || store.file.accounts.isEmpty)
        Menu("Move to Depot") {
            ForEach(store.file.depots.filter { !$0.isRetired }) { depot in
                Button(depot.name) { move(ids, toDepot: depot) }
            }
        }
        .disabled(ids.isEmpty || store.file.depots.isEmpty)
        Divider()
        Button(ids.count > 1 ? "Copy \(Fmt.integer(ids.count)) Rows" : "Copy") {
            Pasteboard.copy(LedgerExport.tsv(selectedRows(ids)))
            store.toast("Copied \(Fmt.integer(ids.count)) \(ids.count == 1 ? "row" : "rows")", style: .success)
        }
        .disabled(ids.isEmpty)
        Button("Export…") { store.present(.export(ExportRequest(.transactions(only: ids)))) }
            .disabled(ids.isEmpty)
        if let single {
            Divider()
            if let security = single.securityID {
                Button("Show Security") { store.navigate(to: .security(security)) }
                Button("Only This Security") { filter.securityID = security }
            }
            if let account = single.accountID {
                Button("Show Account") { store.navigate(to: .account(account)) }
                Button("Only This Account") { filter.accountID = account }
            }
        }
        Divider()
        Button(ids.count > 1 ? "Delete \(Fmt.integer(ids.count)) Transactions" : "Delete", role: .destructive) { delete(ids) }
            .disabled(ids.isEmpty)
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.deleteTransactions(ids)
        selection.subtract(ids)
    }

    /// One entry: opens the editor with a copy dated today (nothing is added until it is saved).
    /// Several: adds copies right away — one undo step.
    private func duplicate(_ ids: Set<UUID>) {
        if ids.count == 1, let original = ids.first.flatMap({ store.transaction($0) }) {
            store.present(.newTransaction(TransactionPrefill(copying: original, date: store.today)))
            return
        }
        var copies = [Transaction]()
        for original in store.file.transactions where ids.contains(original.id) {
            var copy = original
            copy.id = UUID()
            copies.append(copy)
        }
        guard !copies.isEmpty else { return }
        store.addTransactions(copies, actionName: "Duplicate \(copies.count) Transactions")
        pendingReveal = nil
        selection = Set(copies.map(\.id))
        store.toast("Duplicated \(Fmt.integer(copies.count)) transactions", style: .success)
    }

    /// Books the selected entries on another account. Entries without a cash leg, and entries in
    /// another currency than the target account, are left alone (and counted in the toast).
    private func move(_ ids: Set<UUID>, toAccount account: Account) {
        var moved = 0, skipped = 0
        store.mutate(ids.count == 1 ? "Move Transaction to \(account.name)" : "Move \(ids.count) Transactions to \(account.name)") { file in
            for index in file.transactions.indices where ids.contains(file.transactions[index].id) {
                let t = file.transactions[index]
                guard t.kind.requiresAccount, t.amount.currency == account.currency, t.counterAccountID != account.id else {
                    skipped += 1
                    continue
                }
                if t.accountID != account.id {
                    file.transactions[index].accountID = account.id
                    moved += 1
                }
            }
        }
        report(moved: moved, skipped: skipped, target: account.name, reason: "no cash leg or another currency")
    }

    private func move(_ ids: Set<UUID>, toDepot depot: Depot) {
        var moved = 0, skipped = 0
        store.mutate(ids.count == 1 ? "Move Transaction to \(depot.name)" : "Move \(ids.count) Transactions to \(depot.name)") { file in
            for index in file.transactions.indices where ids.contains(file.transactions[index].id) {
                let t = file.transactions[index]
                // Trades and transfers move with their shares; dividends, fees and taxes on a
                // security follow, so the income stays with the position it was paid on.
                let belongsToDepot = t.kind.requiresDepot || (t.kind.attributesToDepot && t.securityID != nil)
                guard belongsToDepot, t.counterDepotID != depot.id else {
                    skipped += 1
                    continue
                }
                if t.depotID != depot.id {
                    file.transactions[index].depotID = depot.id
                    moved += 1
                }
            }
        }
        report(moved: moved, skipped: skipped, target: depot.name, reason: "they do not belong to a depot")
    }

    private func report(moved: Int, skipped: Int, target: String, reason: String) {
        let noun = { (count: Int) in "\(Fmt.integer(count)) \(count == 1 ? "transaction" : "transactions")" }
        if skipped > 0 {
            store.toast("Moved \(noun(moved)) to \(target)", message: "\(noun(skipped)) left unchanged: \(reason).", style: moved > 0 ? .info : .warning)
        } else if moved > 0 {
            store.toast("Moved \(noun(moved)) to \(target)", style: .success)
        }
    }
}

/// Cache key of the per-revision rows.
struct LedgerBaseKey: Hashable, Sendable {
    var id = "transactions.base"
    var today: Day
}

// MARK: - Footer sums

private struct LedgerSums: View {
    @Environment(\.gainStyle) private var gainStyle
    let totals: LedgerContent.Totals
    /// The sums cover the selected rows, not the whole list.
    let isSelection: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.l) {
                if isSelection {
                    Text("Selection").foregroundStyle(.secondary)
                }
                item("In", Fmt.money(minor: totals.inflows, currency: totals.currency, signed: totals.inflows != 0), color: totals.inflows > 0 ? gainStyle.gain : nil)
                item("Out", Fmt.money(minor: totals.outflows, currency: totals.currency), color: nil)
                item("Fees", Fmt.money(minor: totals.fees, currency: totals.currency), color: nil)
                item("Taxes", Fmt.money(minor: totals.taxes, currency: totals.currency), color: nil)
            }
            .accessibilityElement(children: .combine)
            .help("Sums of the \(isSelection ? "selected" : "listed") transactions, in \(totals.currency). Fees and taxes: those inside trades, dividends and interest plus Fee and Tax entries, less refunds. Transfers between your own accounts count only when the list is filtered to one account.")
            if totals.unconverted > 0 {
                // Amounts without an exchange rate are missing from the sums: say so instead of showing totals that look complete.
                Label("\(Fmt.integer(totals.unconverted)) not converted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
                    .lineLimit(1)
                    .fixedSize()
                    .help("\(Fmt.integer(totals.unconverted)) \(totals.unconverted == 1 ? "transaction is" : "transactions are") missing from these sums: no exchange rate to \(totals.currency) is on file for \(totals.unconverted == 1 ? "its" : "their") date. Add the rates (Securities ▸ exchange rates or Update Quotes), or filter to one account to see sums in its own currency.")
                    .accessibilityLabel("\(Fmt.integer(totals.unconverted)) transactions without exchange rate are missing from the sums")
            }
        }
    }

    private func item(_ title: String, _ value: String, color: Color?) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(title).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)).numeric()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Entries the editor saved a moment ago, per window's store. The ledger asks for them when the
/// route starts to focus a transaction: a deep link may clear filters that hide its target, the
/// user's own data entry may not.
@MainActor
enum SavedTransactions {
    private static var latest = [ObjectIdentifier: UUID]()

    static func note(_ id: UUID, in store: PortfolioStore) {
        latest[ObjectIdentifier(store)] = id
    }

    /// True (once) if `id` is the entry the editor saved last in `store`.
    static func take(_ id: UUID, from store: PortfolioStore) -> Bool {
        guard latest[ObjectIdentifier(store)] == id else { return false }
        latest[ObjectIdentifier(store)] = nil
        return true
    }
}

/// Money and share figures: one line, never cut off with an ellipsis — a narrow column tightens
/// and then shrinks the digits instead (a truncated number is a wrong number).
private extension View {
    func figure() -> some View {
        numeric().lineLimit(1).allowsTightening(true).minimumScaleFactor(0.7)
    }
}

// MARK: - Cells

private struct DateCell: View {
    let row: LedgerRow

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(Fmt.day(row.date))
            if row.minute >= 0 {
                Text(LedgerExport.time(Int(row.minute))).foregroundStyle(.tertiary).font(.callout)
            }
        }
        .numeric()
        .lineLimit(1)
    }
}

private struct KindCell: View {
    let row: LedgerRow

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            KindIcon(kind: row.kind).frame(width: 18)
            Text(row.kind.title).lineLimit(1).allowsTightening(true).help(row.kind.title)
            if !row.issue.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
                    .imageScale(.small)
                    .help(row.issue)
                    .accessibilityLabel("Issue: \(row.issue)")
            }
        }
    }
}

private struct TextCell: View {
    let text: String
    var isSecondary = false
    /// Names that share long beginnings ("iShares Core MSCI …") stay apart with `.middle`.
    var truncation = Text.TruncationMode.tail

    var body: some View {
        Text(text)
            .foregroundStyle(isSecondary ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(truncation)
            .help(text.count > 12 ? text : "")
    }
}

private struct IssueCell: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleOnly)
                .foregroundStyle(DS.Colors.warning)
                .lineLimit(1)
                .help(text)
        }
    }
}

/// "Giro → Savings" for transfers, the plain name otherwise. In a list filtered to one account or
/// depot the cell names the *other* side: "→ Savings" (went there) or "← Giro" (came from there).
private struct PartyCell: View {
    let name: String
    let target: String
    /// False while the "To" column shows the target.
    var showsTarget = true
    /// The list is filtered to the transfer's target.
    var isTargetView = false
    /// The list is filtered to the transfer's source.
    var isSourceView = false

    var body: some View {
        if target.isEmpty {
            Text(name).lineLimit(1).help(name.count > 12 ? name : "")
        } else if isTargetView {
            Text("\(Text("←  ").foregroundStyle(.tertiary))\(name)")
                .lineLimit(1)
                .help("From \(name) to \(target)")
                .accessibilityLabel("from \(name)")
        } else if isSourceView {
            Text("\(Text("→  ").foregroundStyle(.tertiary))\(target)")
                .lineLimit(1)
                .help("From \(name) to \(target)")
                .accessibilityLabel("to \(target)")
        } else if showsTarget {
            Text("\(name)\(Text("  →  ").foregroundStyle(.tertiary))\(target)")
                .lineLimit(1)
                .help("From \(name) to \(target)")
                .accessibilityLabel("\(name) to \(target)")
        } else {
            Text(name).lineLimit(1).help("From \(name) to \(target)")
        }
    }
}

/// The "To" column: the target of a transfer and, between currencies, what arrived there.
private struct CounterCell: View {
    let row: LedgerRow

    var body: some View {
        if !row.counter.isEmpty {
            let arrived = row.kind == .cashTransfer && row.counterCurrency != row.currency
                ? Fmt.money(minor: row.counterAmount, currency: row.counterCurrency, signed: true) : nil
            HStack(spacing: DS.Spacing.s) {
                Text(row.counter).lineLimit(1)
                if let arrived {
                    Text(arrived).foregroundStyle(.secondary).figure().layoutPriority(1)
                }
            }
            .help(arrived.map { "\(row.counter) received \($0)" } ?? row.counter)
        }
    }
}

private struct SharesCell: View {
    let row: LedgerRow

    var body: some View {
        if row.shares != 0 {
            Text(Fmt.shares(Shares(raw: row.shares), signed: true, maxDecimals: 4)).figure()
                .help(Fmt.shares(Shares(raw: row.shares), signed: true))
        } else if row.infoShares != 0 {
            Text(Fmt.shares(Shares(raw: row.infoShares), maxDecimals: 4)).figure().foregroundStyle(.secondary)
        }
    }
}

private struct PriceCell: View {
    let row: LedgerRow
    let reporting: CurrencyCode?

    var body: some View {
        if row.price != 0 {
            Text(Fmt.price(Price(raw: row.price), currency: row.currency == reporting ? nil : row.currency, maxDecimals: 4))
                .figure()
                .help(Fmt.price(Price(raw: row.price), currency: row.currency))
                .foregroundStyle(row.shares == 0 ? .secondary : .primary)
        }
    }
}

private struct AmountCell: View {
    @Environment(\.gainStyle) private var gainStyle
    let row: LedgerRow
    /// False in an account's statement, where every amount is in the account's currency.
    var showsCurrency = true

    var body: some View {
        if row.movesCash {
            Text(Fmt.money(minor: row.cash, currency: showsCurrency ? row.cashCurrency : nil, signed: true))
                .figure()
                .foregroundStyle(row.cash > 0 ? AnyShapeStyle(gainStyle.gain) : AnyShapeStyle(.primary))
                .help(Fmt.money(minor: row.cash, currency: row.cashCurrency, signed: true))
        } else {
            // No cash effect on the portfolio (deliveries, internal transfers): the value, neutral.
            Text(Fmt.money(minor: row.cash, currency: showsCurrency ? row.cashCurrency : nil))
                .figure()
                .foregroundStyle(.secondary)
                .help(Fmt.money(minor: row.cash, currency: row.cashCurrency))
        }
    }
}

private struct ChargeCell: View {
    let minor: Int64
    /// nil: a bare number (the list is in one currency).
    let currency: CurrencyCode?

    var body: some View {
        if minor != 0 {
            Text(Fmt.money(minor: minor, currency: currency)).figure().foregroundStyle(.secondary)
        }
    }
}

private struct BalanceCell: View {
    @Environment(\.gainStyle) private var gainStyle
    let row: LedgerRow

    var body: some View {
        if let balance = row.balance {
            Text(Fmt.money(minor: balance, currency: row.cashCurrency))
                .figure()
                .foregroundStyle(balance < 0 ? AnyShapeStyle(gainStyle.loss) : AnyShapeStyle(.primary))
        }
    }
}
