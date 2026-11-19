import SwiftUI
import KontorUI

/// The account or depot of a detail page was deleted while its model was being computed.
struct MissingEntity: Error {}

// MARK: - Header shared by both detail pages

/// Title row of a detail page: way back to the overview, name, quick actions, manage menu.
struct DetailHeader: View {
    @Environment(PortfolioStore.self) private var store
    let entity: AccountsEntity
    let symbol: String
    let name: String
    let badges: [String]
    let note: String
    let kinds: [Transaction.Kind]
    /// Extra entries at the top of the "more" menu.
    var extraMenu: [(title: String, symbol: String, action: () -> Void)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Button {
                store.navigate(to: .accounts)
            } label: {
                Label("Accounts", systemImage: "chevron.left").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Back to all accounts and depots (⌘↑)")

            HStack(alignment: .center, spacing: DS.Spacing.m) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Spacing.s) {
                        Text(name).font(.title2.weight(.semibold)).lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(badges, id: \.self) { Badge($0) }
                    }
                    if !note.isEmpty {
                        Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: DS.Spacing.m)
                ViewThatFits(in: .horizontal) {
                    quickButtons(titled: true)
                    quickButtons(titled: false)
                    Menu("Record", systemImage: "plus") { AccountsActions.recordMenu(entity, store: store) }
                        .fixedSize()
                }
                Menu {
                    ForEach(extraMenu, id: \.title) { item in
                        Button(item.title, systemImage: item.symbol, action: item.action)
                    }
                    if !extraMenu.isEmpty { Divider() }
                    AccountsActions.manageMenu(entity, store: store, includesReorder: false)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Edit, retire or delete")
                .accessibilityLabel("More actions")
            }
        }
    }

    private func quickButtons(titled: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            ForEach(kinds, id: \.self) { kind in
                Button {
                    switch entity {
                    case .account(let id): AccountsActions.record(kind, account: id, in: store)
                    case .depot(let id): AccountsActions.record(kind, depot: id, in: store)
                    }
                } label: {
                    if titled {
                        Label(AccountsActions.verb(kind), systemImage: kind.symbol)
                    } else {
                        Image(systemName: kind.symbol)
                    }
                }
                .help(AccountsActions.help(kind))
                .accessibilityLabel(AccountsActions.verb(kind))
            }
        }
        .fixedSize()
    }
}

/// Lays a detail page out so that the table and its footer always end at the bottom of the
/// window. Header, figures and the table's control bar are always shown; the charts step aside
/// when the window is too short to fit them above a usable table (they return as soon as there is
/// room). Only a window too short even for the compact arrangement scrolls as a whole.
struct DetailPage<Header: View, Charts: View, Bar: View, TableContent: View>: View {
    let minTableHeight: CGFloat
    @ViewBuilder let header: Header
    @ViewBuilder let charts: Charts
    @ViewBuilder let bar: Bar
    @ViewBuilder let table: TableContent

    /// Measured heights (with estimates until the first layout pass). The charts keep their last
    /// measured height while hidden, so showing and hiding them cannot oscillate.
    @State private var headerHeight: CGFloat = 190
    @State private var chartsHeight: CGFloat = 250
    @State private var barHeight: CGFloat = 26

    /// The table's minimum once the charts are gone: about four rows plus header and footer.
    private let compactTableHeight: CGFloat = 170

    var body: some View {
        GeometryReader { proxy in
            let spacing = DS.Spacing.l
            // Top and bottom padding, header, bar, and the gaps header–bar and bar–table.
            let fixed = headerHeight + barHeight + 4 * spacing
            let showsCharts = DetailLayout.showsCharts(
                available: proxy.size.height, fixed: fixed, charts: chartsHeight + spacing, minTable: minTableHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    if showsCharts {
                        charts
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chartsHeight = $0 }
                    }
                    bar
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    table
                        .frame(minHeight: showsCharts ? minTableHeight : compactTableHeight, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Colors.hairline.opacity(0.6), lineWidth: 0.5))
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.vertical, spacing)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// "1Y | All": whether a ledger table lists the reporting period or everything.
struct RangePicker: View {
    @Binding var range: LedgerRange
    let period: ReportingPeriod

    @ViewBuilder var body: some View {
        // "Max | All" would be the same list twice.
        if period != .allTime { picker }
    }

    private var picker: some View {
        Picker("Range", selection: $range) {
            Text(period.shortTitle).tag(LedgerRange.period)
            Text("All").tag(LedgerRange.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("List the transactions of the reporting period (\(period.title)), or all of them")
        .accessibilityLabel("Transactions shown")
    }
}

/// An empty state in place of a table (never on top of one: an empty `Table` still draws its
/// alternating row stripes, which would cut through the text).
private struct TablePlaceholder<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        EmptyState(title, symbol: symbol, message: message) { actions }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cash account

struct AccountDetailView: View {
    @Environment(PortfolioStore.self) private var store
    let accountID: UUID

    @State private var model = Loadable<AccountDetailModel>()
    @State private var statement = Loadable<Statement>()
    @State private var selection = Set<StatementRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\StatementRow.order, order: .reverse)]
    @State private var filter = ""
    @State private var range = LedgerRange.period
    @State private var pinnedDay: Day?
    @SceneStorage("accounts.statement.columns") private var columns: TableColumnCustomization<StatementRow>

    private struct Query: Hashable, Sendable {
        var account: UUID
        var filter: String
        /// nil = all bookings.
        var interval: DayInterval?
        var sortOrder: [KeyPathComparator<StatementRow>]
    }

    /// The part of the table's selection that is still listed — what every action works on.
    private var selected: Set<UUID> {
        guard let ids = statement.value?.ids, !selection.isEmpty else { return [] }
        return TableSelection.effective(selection, visible: ids)
    }

    var body: some View {
        let id = accountID
        let today = store.today
        let query = Query(account: id, filter: filter, interval: range == .period ? store.periodInterval : nil, sortOrder: sortOrder)
        let account = store.account(id)
        let currency = account?.currency ?? store.baseCurrency
        DetailPage(minTableHeight: 240) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                DetailHeader(
                    entity: .account(id), symbol: "creditcard", name: account?.name ?? "",
                    badges: [account?.currency ?? ""] + (account?.isRetired == true ? ["Retired"] : []),
                    note: account?.note ?? "", kinds: AccountsActions.accountKinds)
                if let detail = model.value {
                    figures(detail)
                } else {
                    Color.clear.frame(height: 86)
                }
            }
        } charts: {
            if let detail = model.value {
                charts(detail)
            } else {
                Color.clear.frame(height: 230)
            }
        } bar: {
            statementBar(currency: currency)
        } table: {
            table(currency: currency)
        }
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "accounts.account-detail", scope: .account(id), variant: today) { analysis in
            guard let detail = AccountDetailModel(analysis, account: id, today: today) else { throw MissingEntity() }
            return detail
        }
        .ledgerTask($statement, id: "accounts.statement", variant: query) { ledger in
            var statement = Statement(ledger, account: query.account, interval: query.interval, filter: QuickFilter(query.filter))
            statement.rows.sort(using: query.sortOrder)
            return statement
        }
        // Rows changed (filter, period, edit, undo): what is no longer listed is no longer selected.
        .onChange(of: statement.value?.stamp) { _, _ in
            let kept = selected
            if kept != selection { selection = kept }
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: "Filter statement") } }
        .onAppear {
            filter = store.launchValue("filter") ?? filter
            range = store.launchValue("range", as: LedgerRange.self) ?? range
            pinnedDay = AccountsScreen.launchHover(store.launchState, interval: store.periodInterval)
        }
    }

    // MARK: Figures

    private func figures(_ detail: AccountDetailModel) -> some View {
        let reporting = detail.reportingCurrency
        let currency = detail.currency
        let foreign = currency != reporting
        let period = store.period.shortTitle
        let flows = "in \(Fmt.compactMoney(minor: detail.moneyIn, currency: currency)) · out \(Fmt.compactMoney(minor: detail.moneyOut, currency: currency))"
        // Every tile is in the account's own currency and shows what was booked on the account,
        // so each figure can be found in the statement below.
        return HStack(spacing: DS.Spacing.m) {
            FigureTile("Balance", value: Fmt.money(detail.balance),
                       footnote: foreign ? "≈ \(Fmt.money(detail.value)) today" : "as of \(Fmt.day(store.today, style: .medium))",
                       warning: detail.isValued ? nil : "no exchange rate to \(reporting)")
            FigureTile("Change · \(period)", value: Fmt.money(minor: detail.periodChange, currency: currency, signed: true), footnote: flows)
            FigureTile("Net Interest · \(period)", value: Fmt.money(minor: detail.income.interestNet, currency: currency),
                       footnote: detail.income.interestFootnote(currency: currency), topic: .grossVersusNet)
            FigureTile("Fees · \(period)", value: Fmt.money(minor: detail.income.fees, currency: currency),
                       footnote: detail.income.feesFootnote(currency: currency))
        }
        .opacity(model.isRefreshing ? 0.6 : 1)
    }

    // MARK: Charts

    private func charts(_ detail: AccountDetailModel) -> some View {
        // Long periods read better per year than as a hundred monthly bars.
        let byYear = detail.months.count > 36
        let categories: [BarCategory]
        let moneyIn: [Int64], moneyOut: [Int64]
        if byYear {
            var years = [Int](), ins = [Int: Int64](), outs = [Int: Int64]()
            for month in detail.months {
                if years.last != month.year { years.append(month.year) }
                ins[month.year, default: 0] += month.moneyIn
                outs[month.year, default: 0] += month.moneyOut
            }
            categories = years.map { BarCategory.year($0) }
            moneyIn = years.map { ins[$0] ?? 0 }
            moneyOut = years.map { outs[$0] ?? 0 }
        } else {
            categories = BarCategory.months(detail.months.map { ($0.year, $0.month) })
            moneyIn = detail.months.map(\.moneyIn)
            moneyOut = detail.months.map(\.moneyOut)
        }
        let pinnedCategory = pinnedDay.flatMap { day -> String? in
            guard let index = byYear
                ? categories.indices.last
                : detail.months.firstIndex(where: { $0.year == day.year && $0.month == day.month }) else { return nil }
            return categories[index].id
        }
        return HStack(alignment: .top, spacing: DS.Spacing.l) {
            Card("Balance", symbol: "chart.line.uptrend.xyaxis") {
                TimeSeriesChart(
                    detail.balances.contains { $0 != 0 }
                        ? [TimeSeries("Balance", start: detail.interval.start, values: detail.balances, style: .stepArea)] : [],
                    format: .money(detail.currency), title: "Account balance")
                    .timeDomain(detail.interval)
                    .pinnedHover(pinnedDay)
                    .loading(model.isRefreshing)
                    .emptyMessage("No balance in this period")
                    .frame(height: 170)
            } accessory: {
                Text(Fmt.interval(detail.interval)).font(.callout).foregroundStyle(.secondary).numeric().lineLimit(1)
            }
            Card(byYear ? "Money In and Out per Year" : "Money In and Out per Month", symbol: "chart.bar") {
                BarSeriesChart(
                    categories: categories,
                    series: [BarSeries("In", values: moneyIn), BarSeries("Out", values: moneyOut)],
                    format: .money(detail.currency), layout: .grouped, title: "Money booked in and out")
                    .pinnedHover(pinnedCategory)
                    .loading(model.isRefreshing)
                    .emptyMessage("No transactions in this period")
                    .frame(height: 170)
            }
        }
    }

    // MARK: Statement

    /// Title, period switch, and the balances the listed bookings lead from and to.
    private func statementBar(currency: CurrencyCode) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Text("Statement").font(.headline)
            RangePicker(range: $range, period: store.period)
            Spacer(minLength: DS.Spacing.m)
            if let statement = statement.value, let interval = statement.interval {
                let opening = Fmt.money(minor: statement.opening, currency: currency)
                let closing = Fmt.money(minor: statement.closing, currency: currency)
                ViewThatFits(in: .horizontal) {
                    balances("Opening balance \(Fmt.day(interval.start, style: .medium))", opening,
                             "Closing balance \(Fmt.day(interval.end, style: .medium))", closing)
                    balances("Opening", opening, "Closing", closing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minHeight: 24)
    }

    private func balances(_ openingLabel: String, _ opening: String, _ closingLabel: String, _ closing: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(openingLabel).foregroundStyle(.secondary)
            Text(opening).fontWeight(.medium)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(closingLabel).foregroundStyle(.secondary)
            Text(closing).fontWeight(.medium)
        }
        .font(.callout)
        .numeric()
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func table(currency: CurrencyCode) -> some View {
        // The table is created once its rows exist: filling an already laid-out table from the
        // first asynchronous result makes AppKit re-enter its table delegate.
        if let statement = statement.value {
            if statement.totalCount == 0 {
                TablePlaceholder(title: "No Transactions Yet", symbol: "tray", message: "Record a first deposit to give this account a balance.") {
                    Button("Deposit…") { AccountsActions.record(.deposit, account: accountID, in: store) }
                }
            } else if statement.rangeCount == 0 {
                TablePlaceholder(
                    title: "No Transactions in This Period", symbol: "calendar",
                    message: "Nothing was booked on this account in the period (\(statement.interval.map { Fmt.interval($0) } ?? "")). It has \(Fmt.integer(statement.totalCount)) transaction\(statement.totalCount == 1 ? "" : "s") in total."
                ) {
                    Button("Show All") { range = .all }
                }
            } else if statement.rows.isEmpty {
                TablePlaceholder(title: "No Matches", symbol: "line.3.horizontal.decrease", message: "No transaction \(range == .period ? "in this period" : "of this account") matches “\(filter)”.") {
                    Button("Clear Filter") { filter = "" }
                    if range == .period { Button("Search All") { range = .all } }
                }
            } else {
                statementTable(statement, currency: currency)
            }
        } else {
            Color.clear
        }
    }

    private func statementTable(_ statement: Statement, currency: CurrencyCode) -> some View {
        let selected = selected
        return Table(statement.rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Date", value: \.order) { row in
                Text(Fmt.day(row.date)).numeric()
            }
            .width(min: 84, ideal: 90, max: 120)
            .customizationID("date")
            TableColumn("Type", value: \.kindTitle) { row in
                Label(row.kindTitle, systemImage: row.kind.symbol).lineLimit(1)
            }
            .width(min: 110, ideal: 130)
            .customizationID("type")
            TableColumn("Details", value: \.counterpart) { row in
                HStack(spacing: DS.Spacing.s) {
                    if !row.counterpart.isEmpty { Text(row.counterpart).lineLimit(1) }
                    if !row.note.isEmpty { Text(row.note).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .width(min: 120, ideal: 200)
            .customizationID("details")
            TableColumn("Amount", value: \.amount) { row in
                Text(Fmt.money(minor: row.amount, currency: currency, signed: true))
                    .numeric()
                    .foregroundStyle(row.amount < 0 ? .secondary : .primary)
            }
            .width(min: 96, ideal: 110)
            .alignment(.trailing)
            .customizationID("amount")
            TableColumn("Balance", value: \.balance) { row in
                Text(Fmt.money(minor: row.balance, currency: currency)).numeric()
            }
            .width(min: 96, ideal: 110)
            .alignment(.trailing)
            .customizationID("balance")
        }
        .contextMenu(forSelectionType: StatementRow.ID.self) { ids in
            transactionMenu(TableSelection.effective(ids, visible: statement.ids), statement, currency: currency)
        } primaryAction: { ids in
            if let first = TableSelection.effective(ids, visible: statement.ids).first { store.present(.editTransaction(first)) }
        }
        .onCopyCommand { [NSItemProvider(object: statement.tsv(only: self.selected, currency: currency) as NSString)] }
        .onDeleteCommand { delete(self.selected) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: statement.rows.count, noun: "transaction", selected: selected.count,
                        filteredFrom: statement.rows.count == statement.rangeCount ? nil : statement.rangeCount) {
                if selected.count > 1 {
                    let sum = statement.rows.reduce(Int64(0)) { selected.contains($1.id) ? $0 + $1.amount : $0 }
                    Text("Sum \(Fmt.money(minor: sum, currency: currency, signed: true))").numeric().foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Deletes listed transactions only, and forgets them as selection.
    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.deleteTransactions(ids)
        selection.subtract(ids)
    }

    @ViewBuilder
    private func transactionMenu(_ ids: Set<UUID>, _ statement: Statement, currency: CurrencyCode) -> some View {
        Button("Edit…", systemImage: "pencil") { ids.first.map { store.present(.editTransaction($0)) } }
            .disabled(ids.count != 1)
        Button("Duplicate…", systemImage: "plus.square.on.square") {
            if let t = store.transaction(ids.first) { store.present(.newTransaction(TransactionPrefill(copying: t, date: store.today))) }
        }
        .disabled(ids.count != 1)
        Button("Show in Transactions", systemImage: "arrow.right.circle") { ids.first.map { store.navigate(to: .transaction($0)) } }
            .disabled(ids.count != 1)
        Divider()
        Button(ids.isEmpty ? "Copy Statement" : "Copy", systemImage: "doc.on.doc") { Pasteboard.copy(statement.tsv(only: ids, currency: currency)) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(ids) }
            .disabled(ids.isEmpty)
    }
}

// MARK: - Depot

struct DepotDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case positions, transactions
        var id: String { rawValue }
        var title: String { self == .positions ? "Positions" : "Transactions" }
    }

    @Environment(PortfolioStore.self) private var store
    let depotID: UUID

    @State private var model = Loadable<DepotDetailModel>()
    @State private var transactions = Loadable<DepotLedger>()
    @State private var tab = Tab.positions
    @State private var positionSelection = Set<UUID>()
    @State private var positionSort = [KeyPathComparator(\DepotDetailModel.Position.value, order: .reverse)]
    @State private var transactionSelection = Set<UUID>()
    @State private var transactionSort = [KeyPathComparator(\DepotTransactionRow.order, order: .reverse)]
    @State private var filter = ""
    @State private var range = LedgerRange.period
    @State private var pinnedDay: Day?
    /// Narrow windows show the positions without the price column and the weight bars.
    @State private var isCompact = false
    @SceneStorage("accounts.positions.columns") private var positionColumns: TableColumnCustomization<DepotDetailModel.Position>
    @SceneStorage("accounts.depot-transactions.columns") private var transactionColumns: TableColumnCustomization<DepotTransactionRow>

    private struct Query: Hashable, Sendable {
        var depot: UUID
        var filter: String
        var interval: DayInterval?
        var sortOrder: [KeyPathComparator<DepotTransactionRow>]
    }

    private var positions: [DepotDetailModel.Position] {
        guard let all = model.value?.positions else { return [] }
        let quick = QuickFilter(filter)
        return (quick.isEmpty ? all : all.filter { quick.matches($0.name, $0.symbol) }).sorted(using: positionSort)
    }

    /// The listed part of the transaction selection.
    private var selectedTransactions: Set<UUID> {
        guard let ids = transactions.value?.ids, !transactionSelection.isEmpty else { return [] }
        return TableSelection.effective(transactionSelection, visible: ids)
    }

    var body: some View {
        let id = depotID
        let today = store.today
        let query = Query(depot: id, filter: filter, interval: range == .period ? store.periodInterval : nil, sortOrder: transactionSort)
        let depot = store.depot(id)
        let reference = store.account(depot?.referenceAccountID)
        DetailPage(minTableHeight: 240) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                DetailHeader(
                    entity: .depot(id), symbol: "briefcase", name: depot?.name ?? "",
                    badges: depot?.isRetired == true ? ["Retired"] : [],
                    note: [reference.map { "Settles on \($0.name)" } ?? "No reference account", depot?.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                    kinds: AccountsActions.depotKinds,
                    extraMenu: [
                        ("Analyze in Performance", "chart.line.uptrend.xyaxis", {
                            store.scopeSelection = .depot(id)
                            store.navigate(to: .performance)
                        }),
                    ] + (reference.map { account in
                        [("Show \(account.name)", "creditcard", { store.navigate(to: .account(account.id)) })]
                    } ?? []))
                if let detail = model.value {
                    figures(detail)
                } else {
                    Color.clear.frame(height: 86)
                }
            }
        } charts: {
            if let detail = model.value {
                chart(detail)
            } else {
                Color.clear.frame(height: 240)
            }
        } bar: {
            HStack(spacing: DS.Spacing.m) {
                Picker("Table", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if tab == .transactions { RangePicker(range: $range, period: store.period) }
                Spacer()
                if tab == .positions {
                    Text("as of \(Fmt.day(today, style: .medium))").font(.callout).foregroundStyle(.secondary).numeric()
                }
            }
            .frame(minHeight: 24)
        } table: {
            switch tab {
            case .positions: positionsTable(today: today)
            case .transactions: transactionsTable
            }
        }
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "accounts.depot-detail", scope: .depot(id), variant: today) { analysis in
            guard let detail = DepotDetailModel(analysis, depot: id, today: today) else { throw MissingEntity() }
            return detail
        }
        .ledgerTask($transactions, id: "accounts.depot-transactions", variant: query) { ledger in
            var result = DepotLedger(ledger, depot: query.depot, interval: query.interval, filter: QuickFilter(query.filter))
            result.rows.sort(using: query.sortOrder)
            return result
        }
        // Rows changed: what is no longer listed is no longer selected.
        .onChange(of: transactions.value?.stamp) { _, _ in
            let kept = selectedTransactions
            if kept != transactionSelection { transactionSelection = kept }
        }
        .onChange(of: positions.map(\.id)) { _, ids in
            let kept = TableSelection.effective(positionSelection, visible: Set(ids))
            if kept != positionSelection { positionSelection = kept }
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: tab == .positions ? "Filter positions" : "Filter transactions") } }
        .onGeometryChange(for: Bool.self) { $0.size.width < 880 } action: { isCompact = $0 }
        .onAppear {
            tab = store.launchValue("tab", as: Tab.self) ?? tab
            filter = store.launchValue("filter") ?? filter
            range = store.launchValue("range", as: LedgerRange.self) ?? range
            pinnedDay = AccountsScreen.launchHover(store.launchState, interval: store.periodInterval)
        }
    }

    // MARK: Figures and chart

    private func figures(_ detail: DepotDetailModel) -> some View {
        let period = store.period.shortTitle
        return HStack(spacing: DS.Spacing.m) {
            // Market value and positions are always today's; the other three follow the period.
            FigureTile("Market Value · Today", value: Fmt.money(detail.marketValue),
                       footnote: "\(Fmt.integer(detail.positions.count)) position\(detail.positions.count == 1 ? "" : "s") · cost \(Fmt.compactMoney(detail.costBasis))",
                       warning: detail.valuationWarning)
            FigureTile("Gain · \(period)", value: Fmt.money(detail.absolutePerformance, signed: true),
                       footnote: "incl. \(Fmt.compactMoney(detail.dividends)) dividends", topic: .absolutePerformance,
                       trend: Trend(minor: detail.absolutePerformance.minor))
            FigureTile("TTWROR · \(period)", value: detail.hasHistory ? Fmt.percent(detail.ttwror, signed: true) : Fmt.missing,
                       footnote: (detail.hasHistory ? detail.ttwrorAnnualized : nil).map { "\(Fmt.percent($0, signed: true)) per year" } ?? "time-weighted",
                       topic: .ttwror, trend: detail.hasHistory ? Trend(detail.ttwror) : nil)
            FigureTile("IRR · \(period)", value: Fmt.percent(detail.irr, signed: true), footnote: "money-weighted, per year",
                       topic: .irr, trend: detail.irr.map { Trend($0) })
        }
        .opacity(model.isRefreshing ? 0.6 : 1)
    }

    private func chart(_ detail: DepotDetailModel) -> some View {
        Card("Value Over Time", symbol: "chart.line.uptrend.xyaxis") {
            TimeSeriesChart(detail.hasHistory ? [
                TimeSeries("Market value", points: detail.valuePoints, style: .area),
                TimeSeries("Invested", start: detail.interval.start, values: detail.invested, style: .step, color: ChartColors.comparison),
            ] : [], format: .money(detail.currency), baseline: .data, title: "Depot value over time")
                .timeDomain(detail.interval)
                .pinnedHover(pinnedDay)
                .loading(model.isRefreshing)
                .emptyMessage("This depot held nothing in the period")
                .frame(height: 180)
        } accessory: {
            HStack(spacing: DS.Spacing.s) {
                HelpLabel("Invested", topic: .investedCapital).font(.callout).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(Fmt.interval(detail.interval)).font(.callout).foregroundStyle(.secondary).numeric().lineLimit(1)
            }
        }
    }

    // MARK: Positions

    @ViewBuilder
    private func positionsTable(today: Day) -> some View {
        let rows = positions
        if model.value == nil {
            Color.clear
        } else if rows.isEmpty, filter.isEmpty {
            TablePlaceholder(title: "No Positions", symbol: "briefcase", message: "This depot holds no securities today. Record a purchase, or a delivery for holdings you already own.") {
                Button("Buy…") { AccountsActions.record(.buy, depot: depotID, in: store) }
                Button("Deliver In…") { AccountsActions.record(.deliveryIn, depot: depotID, in: store) }
            }
        } else if rows.isEmpty {
            TablePlaceholder(title: "No Matches", symbol: "line.3.horizontal.decrease", message: "No position matches “\(filter)”.") {
                Button("Clear Filter") { filter = "" }
            }
        } else {
            loadedPositionsTable(rows, today: today)
        }
    }

    private func loadedPositionsTable(_ rows: [DepotDetailModel.Position], today: Day) -> some View {
        let currency = model.value?.currency ?? store.baseCurrency
        let visible = Set(rows.map(\.id))
        let selected = TableSelection.effective(positionSelection, visible: visible)
        return Table(rows, selection: $positionSelection, sortOrder: $positionSort, columnCustomization: $positionColumns) {
            TableColumn("Security", value: \.name) { row in
                HStack(spacing: DS.Spacing.s) {
                    Text(row.name).lineLimit(1)
                    if !row.symbol.isEmpty, !isCompact { Text(row.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .width(min: 140, ideal: 150)
            .customizationID("security")
            TableColumn("Shares", value: \.shares) { row in
                Text(Fmt.shares(row.shares, maxDecimals: 4)).numeric()
            }
            .width(min: 80, ideal: 96)
            .alignment(.trailing)
            .customizationID("shares")
            if !isCompact {
                TableColumn("Price", value: \.sortablePrice) { row in
                    HStack(spacing: DS.Spacing.xs) {
                        if row.staleDays(on: today) != nil, let note = row.priceWarning(on: today) {
                            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary).help(note).accessibilityLabel(note)
                        }
                        Text(row.price.map { Fmt.price($0, currency: row.priceCurrency) } ?? Fmt.missing).numeric()
                            .foregroundStyle(row.pricing == .quoted ? .primary : .secondary)
                    }
                }
                .width(min: 76, ideal: 84)
                .alignment(.trailing)
                .customizationID("price")
            }
            TableColumn("Value", value: \.value) { row in
                HStack(spacing: DS.Spacing.xs) {
                    // A value that is not based on a market price is marked where it is shown.
                    if row.pricing != .quoted, let note = row.priceWarning(on: today) {
                        Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(DS.Colors.warning).help(note).accessibilityLabel(note)
                    }
                    Text(Fmt.money(minor: row.value, currency: currency)).numeric()
                }
            }
            .width(min: 96, ideal: 104)
            .alignment(.trailing)
            .customizationID("value")
            TableColumn("Weight", value: \.weight) { row in
                HStack(spacing: DS.Spacing.s) {
                    if !isCompact { WeightBar(fraction: row.weight) }
                    // Never truncated: "100,0 %" (a depot with a single position) is the widest value.
                    Text(Fmt.percent(row.weight, decimals: 1)).numeric().lineLimit(1).fixedSize()
                }
            }
            .width(min: 60, ideal: isCompact ? 64 : 96)
            .alignment(.trailing)
            .customizationID("weight")
            TableColumn("Gain", value: \.gain) { row in
                GainText(money: Money(minor: row.gain, currency: currency))
            }
            .width(min: 92, ideal: 96)
            .alignment(.trailing)
            .customizationID("gain")
            TableColumn("Gain %", value: \.sortableGainFraction) { row in
                if let fraction = row.gainFraction { GainText(percent: fraction) } else { Text(Fmt.missing).foregroundStyle(.secondary) }
            }
            .width(min: 68, ideal: 72)
            .alignment(.trailing)
            .customizationID("gain-percent")
        }
        .contextMenu(forSelectionType: UUID.self) { raw in
            let ids = TableSelection.effective(raw, visible: visible)
            Button("Show Security", systemImage: "arrow.right.circle") { ids.first.map { store.navigate(to: .security($0)) } }
                .disabled(ids.count != 1)
            Divider()
            Button("Buy More…", systemImage: Transaction.Kind.buy.symbol) { record(.buy, ids.first) }.disabled(ids.count != 1)
            Button("Sell…", systemImage: Transaction.Kind.sell.symbol) { record(.sell, ids.first) }.disabled(ids.count != 1)
            Button("Record Dividend…", systemImage: Transaction.Kind.dividend.symbol) { record(.dividend, ids.first) }.disabled(ids.count != 1)
            Button("Transfer to Another Depot…", systemImage: Transaction.Kind.securityTransfer.symbol) { record(.securityTransfer, ids.first) }
                .disabled(ids.count != 1)
            Divider()
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(positionsTSV(rows, only: ids, currency: currency)) }
        } primaryAction: { raw in
            if let first = TableSelection.effective(raw, visible: visible).first { store.navigate(to: .security(first)) }
        }
        .onCopyCommand { [NSItemProvider(object: positionsTSV(rows, only: selected, currency: currency) as NSString)] }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "position", selected: selected.count,
                        filteredFrom: filter.isEmpty ? nil : model.value?.positions.count) {
                let chosen = selected.isEmpty ? rows : rows.filter { selected.contains($0.id) }
                Text("\(selected.isEmpty ? "Total" : "Selected") \(Fmt.money(minor: chosen.reduce(0) { $0 + $1.value }, currency: currency))")
                    .numeric().foregroundStyle(.secondary)
            }
        }
    }

    private func record(_ kind: Transaction.Kind, _ security: UUID?) {
        guard let security else { return }
        let account = kind == .securityTransfer ? nil : store.depot(depotID)?.referenceAccountID
        store.present(.newTransaction(TransactionPrefill(kind: kind, date: store.today, securityID: security, accountID: account, depotID: depotID)))
    }

    private func positionsTSV(_ rows: [DepotDetailModel.Position], only ids: Set<UUID>, currency: CurrencyCode) -> String {
        let chosen = ids.isEmpty ? rows : rows.filter { ids.contains($0.id) }
        return TSV.string(
            header: ["Security", "Symbol", "Shares", "Value", "Cost", "Gain", "Currency"],
            rows: chosen.map {
                [$0.name, $0.symbol, TSV.number($0.shares.decimalValue), TSV.number(Money(minor: $0.value, currency: currency).decimalValue),
                 TSV.number(Money(minor: $0.costBasis, currency: currency).decimalValue),
                 TSV.number(Money(minor: $0.gain, currency: currency).decimalValue), currency]
            })
    }

    // MARK: Transactions

    @ViewBuilder
    private var transactionsTable: some View {
        if let ledger = transactions.value {
            if ledger.totalCount == 0 {
                TablePlaceholder(title: "No Transactions Yet", symbol: "tray", message: "Purchases, sales, deliveries and transfers of this depot appear here.") {
                    Button("Buy…") { AccountsActions.record(.buy, depot: depotID, in: store) }
                }
            } else if ledger.rangeCount == 0 {
                TablePlaceholder(
                    title: "No Transactions in This Period", symbol: "calendar",
                    message: "Nothing was booked in this depot in the period (\(ledger.interval.map { Fmt.interval($0) } ?? "")). It has \(Fmt.integer(ledger.totalCount)) transaction\(ledger.totalCount == 1 ? "" : "s") in total."
                ) {
                    Button("Show All") { range = .all }
                }
            } else if ledger.rows.isEmpty {
                TablePlaceholder(title: "No Matches", symbol: "line.3.horizontal.decrease", message: "No transaction \(range == .period ? "in this period" : "of this depot") matches “\(filter)”.") {
                    Button("Clear Filter") { filter = "" }
                    if range == .period { Button("Search All") { range = .all } }
                }
            } else {
                loadedTransactionsTable(ledger)
            }
        } else {
            Color.clear
        }
    }

    private func loadedTransactionsTable(_ ledger: DepotLedger) -> some View {
        let selected = selectedTransactions
        return Table(ledger.rows, selection: $transactionSelection, sortOrder: $transactionSort, columnCustomization: $transactionColumns) {
            TableColumn("Date", value: \.order) { row in
                Text(Fmt.day(row.date)).numeric()
            }
            .width(min: 84, ideal: 90, max: 120)
            .customizationID("date")
            TableColumn("Type", value: \.kindTitle) { row in
                HStack(spacing: DS.Spacing.s) {
                    Label(row.kindTitle, systemImage: row.kind.symbol).lineLimit(1)
                    if row.isAttributed {
                        Text("attributed").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(DepotTransactionRow.attributedHelp)
                    }
                }
            }
            .width(min: 110, ideal: 150)
            .customizationID("type")
            TableColumn("Security", value: \.security) { row in
                Text(row.security).lineLimit(1)
            }
            .width(min: 130, ideal: 170)
            .customizationID("security")
            TableColumn("Shares", value: \.shares) { row in
                Text(row.shares.isZero ? Fmt.missing : Fmt.shares(row.shares, signed: true, maxDecimals: 4)).numeric()
                    .foregroundStyle(row.shares.raw < 0 ? .secondary : .primary)
            }
            .width(min: 80, ideal: 92)
            .alignment(.trailing)
            .customizationID("shares")
            TableColumn("Amount", value: \.amount.minor) { row in
                Text(Fmt.money(row.amount)).numeric()
            }
            .width(min: 92, ideal: 100)
            .alignment(.trailing)
            .customizationID("amount")
            TableColumn("Note", value: \.note) { row in
                Text(row.note).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            .customizationID("note")
        }
        .contextMenu(forSelectionType: UUID.self) { raw in
            let ids = TableSelection.effective(raw, visible: ledger.ids)
            Button("Edit…", systemImage: "pencil") { ids.first.map { store.present(.editTransaction($0)) } }
                .disabled(ids.count != 1)
            Button("Duplicate…", systemImage: "plus.square.on.square") {
                if let t = store.transaction(ids.first) { store.present(.newTransaction(TransactionPrefill(copying: t, date: store.today))) }
            }
            .disabled(ids.count != 1)
            Button("Show in Transactions", systemImage: "arrow.right.circle") { ids.first.map { store.navigate(to: .transaction($0)) } }
                .disabled(ids.count != 1)
            Divider()
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(ledger.tsv(only: ids)) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { delete(ids) }
                .disabled(ids.isEmpty)
        } primaryAction: { raw in
            if let first = TableSelection.effective(raw, visible: ledger.ids).first { store.present(.editTransaction(first)) }
        }
        .onCopyCommand { [NSItemProvider(object: ledger.tsv(only: selectedTransactions) as NSString)] }
        .onDeleteCommand { delete(selectedTransactions) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: ledger.rows.count, noun: "transaction", selected: selected.count,
                        filteredFrom: ledger.rows.count == ledger.rangeCount ? nil : ledger.rangeCount) {
                if ledger.attributedCount > 0 {
                    Label("\(Fmt.integer(ledger.attributedCount)) attributed dividend\(ledger.attributedCount == 1 ? "" : "s")", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(DepotTransactionRow.attributedHelp)
                }
            }
        }
    }

    /// Deletes listed transactions only, and forgets them as selection.
    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.deleteTransactions(ids)
        transactionSelection.subtract(ids)
    }
}

extension DepotDetailModel.Position {
    /// Positions without a cost basis sort below every real percentage.
    var sortableGainFraction: Double { gainFraction ?? -.infinity }
    var sortablePrice: Int64 { price?.raw ?? -1 }
}

/// A thin proportional bar for the weight column.
private struct WeightBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(ChartColors.neutral).frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .frame(minWidth: 24, maxWidth: 60)
        .accessibilityHidden(true)
    }
}
