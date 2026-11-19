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

/// Lays a detail page out so that the table fills what is left of the window, and the whole page
/// scrolls when the window is too short for a usable table.
struct DetailPage<Top: View, TableContent: View>: View {
    let minTableHeight: CGFloat
    @ViewBuilder let top: Top
    @ViewBuilder let table: TableContent

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    top
                    table
                        .frame(minHeight: minTableHeight, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Colors.hairline.opacity(0.6), lineWidth: 0.5))
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.top, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.l)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Cash account

struct AccountDetailView: View {
    @Environment(PortfolioStore.self) private var store
    let accountID: UUID

    @State private var model = Loadable<AccountDetailModel>()
    @State private var rows = Loadable<[StatementRow]>()
    @State private var selection = Set<StatementRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\StatementRow.order, order: .reverse)]
    @State private var filter = ""
    @State private var pinnedDay: Day?
    @SceneStorage("accounts.statement.columns") private var columns: TableColumnCustomization<StatementRow>

    private struct Query: Hashable, Sendable {
        var account: UUID
        var filter: String
        var sortOrder: [KeyPathComparator<StatementRow>]
    }

    private var statement: [StatementRow] { rows.value ?? [] }

    var body: some View {
        let id = accountID
        let today = store.today
        let query = Query(account: id, filter: filter, sortOrder: sortOrder)
        let account = store.account(id)
        DetailPage(minTableHeight: 240) {
            DetailHeader(
                entity: .account(id), symbol: "creditcard", name: account?.name ?? "",
                badges: [account?.currency ?? ""] + (account?.isRetired == true ? ["Retired"] : []),
                note: account?.note ?? "", kinds: AccountsActions.accountKinds,
                extraMenu: [("Show All Transactions", "list.bullet.rectangle", { store.navigate(to: .transactions) })])
            if let detail = model.value {
                figures(detail)
                charts(detail)
            } else {
                Color.clear.frame(height: 320)
            }
        } table: {
            table(currency: account?.currency ?? store.baseCurrency)
        }
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "accounts.account-detail", scope: .account(id), variant: today) { analysis in
            guard let detail = AccountDetailModel(analysis, account: id, today: today) else { throw MissingEntity() }
            return detail
        }
        .ledgerTask($rows, id: "accounts.statement", variant: query) { ledger in
            StatementRow.rows(ledger, account: query.account, filter: QuickFilter(query.filter)).sorted(using: query.sortOrder)
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: "Filter statement") } }
        .onAppear {
            filter = store.launchValue("filter") ?? filter
            pinnedDay = AccountsScreen.launchHover(store.launchState, interval: store.periodInterval)
        }
    }

    // MARK: Figures

    private func figures(_ detail: AccountDetailModel) -> some View {
        let reporting = detail.reportingCurrency
        let foreign = detail.currency != reporting
        let balanceNote: String = if !detail.isValued {
            "no exchange rate to \(reporting)"
        } else if foreign {
            "≈ \(Fmt.money(detail.value)) today"
        } else {
            "as of \(Fmt.day(store.today, style: .medium))"
        }
        let flows = "in \(Fmt.compactMoney(minor: detail.moneyIn, currency: detail.currency)) · out \(Fmt.compactMoney(minor: detail.moneyOut, currency: detail.currency))"
        return HStack(spacing: DS.Spacing.m) {
            FigureTile("Balance", value: Fmt.money(detail.balance), footnote: balanceNote)
            FigureTile("Change · \(store.period.shortTitle)", value: Fmt.money(minor: detail.periodChange, currency: detail.currency, signed: true), footnote: flows)
            FigureTile("Interest · \(store.period.shortTitle)", value: Fmt.money(minor: detail.interest, currency: reporting),
                       footnote: detail.dividends != 0 ? "plus \(Fmt.money(minor: detail.dividends, currency: reporting)) dividends" : "net of interest charged")
            FigureTile("Fees · \(store.period.shortTitle)", value: Fmt.money(minor: detail.fees, currency: reporting),
                       footnote: detail.taxes < 0
                           ? "\(Fmt.money(minor: -detail.taxes, currency: reporting)) taxes refunded"
                           : "plus \(Fmt.money(minor: detail.taxes, currency: reporting)) taxes",
                       topic: .grossVersusNet)
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

    @ViewBuilder
    private func table(currency: CurrencyCode) -> some View {
        // The table is created once its rows exist: filling an already laid-out table from the
        // first asynchronous result makes AppKit re-enter its table delegate.
        if rows.value == nil {
            Color.clear
        } else {
            statementTable(currency: currency)
        }
    }

    private func statementTable(currency: CurrencyCode) -> some View {
        Table(statement, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
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
            transactionMenu(ids)
        } primaryAction: { ids in
            if let first = ids.first { store.present(.editTransaction(first)) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection, currency: currency) as NSString)] }
        .onDeleteCommand { store.deleteTransactions(selection) }
        .overlay {
            if rows.value != nil, statement.isEmpty {
                if filter.isEmpty {
                    EmptyState("No Transactions Yet", symbol: "tray", message: "Record a first deposit to give this account a balance.") {
                        Button("Deposit…") { AccountsActions.record(.deposit, account: accountID, in: store) }
                    }
                } else {
                    EmptyState("No Matches", symbol: "line.3.horizontal.decrease", message: "No transaction of this account matches “\(filter)”.") {
                        Button("Clear Filter") { filter = "" }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: statement.count, noun: "transaction", selected: selection.count,
                        filteredFrom: filter.isEmpty ? nil : store.transactions(forAccount: accountID).count) {
                if selection.count > 1 {
                    let sum = statement.reduce(Int64(0)) { selection.contains($1.id) ? $0 + $1.amount : $0 }
                    Text("Sum \(Fmt.money(minor: sum, currency: currency, signed: true))").numeric().foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func transactionMenu(_ ids: Set<UUID>) -> some View {
        Button("Edit…", systemImage: "pencil") { ids.first.map { store.present(.editTransaction($0)) } }
            .disabled(ids.count != 1)
        Button("Duplicate…", systemImage: "plus.square.on.square") {
            if let t = store.transaction(ids.first) { store.present(.newTransaction(TransactionPrefill(copying: t, date: store.today))) }
        }
        .disabled(ids.count != 1)
        Button("Show in Transactions", systemImage: "arrow.right.circle") { ids.first.map { store.navigate(to: .transaction($0)) } }
            .disabled(ids.count != 1)
        Divider()
        Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(tsv(ids, currency: store.account(accountID)?.currency ?? "")) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { store.deleteTransactions(ids) }
    }

    private func tsv(_ ids: Set<UUID>, currency: CurrencyCode) -> String {
        let chosen = ids.isEmpty ? statement : statement.filter { ids.contains($0.id) }
        return TSV.string(
            header: ["Date", "Type", "Details", "Note", "Amount", "Balance", "Currency"],
            rows: chosen.map {
                [$0.date.iso, $0.kindTitle, $0.counterpart, $0.note,
                 TSV.number(Money(minor: $0.amount, currency: currency).decimalValue),
                 TSV.number(Money(minor: $0.balance, currency: currency).decimalValue), currency]
            })
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
    @State private var transactions = Loadable<[DepotTransactionRow]>()
    @State private var tab = Tab.positions
    @State private var positionSelection = Set<UUID>()
    @State private var positionSort = [KeyPathComparator(\DepotDetailModel.Position.value, order: .reverse)]
    @State private var transactionSelection = Set<UUID>()
    @State private var transactionSort = [KeyPathComparator(\DepotTransactionRow.order, order: .reverse)]
    @State private var filter = ""
    @State private var pinnedDay: Day?
    /// Narrow windows show the positions without the price column and the weight bars.
    @State private var isCompact = false
    @SceneStorage("accounts.positions.columns") private var positionColumns: TableColumnCustomization<DepotDetailModel.Position>
    @SceneStorage("accounts.depot-transactions.columns") private var transactionColumns: TableColumnCustomization<DepotTransactionRow>

    private struct Query: Hashable, Sendable {
        var depot: UUID
        var filter: String
        var sortOrder: [KeyPathComparator<DepotTransactionRow>]
    }

    private var positions: [DepotDetailModel.Position] {
        guard let all = model.value?.positions else { return [] }
        let quick = QuickFilter(filter)
        return (quick.isEmpty ? all : all.filter { quick.matches($0.name, $0.symbol) }).sorted(using: positionSort)
    }

    var body: some View {
        let id = depotID
        let today = store.today
        let query = Query(depot: id, filter: filter, sortOrder: transactionSort)
        let depot = store.depot(id)
        let reference = store.account(depot?.referenceAccountID)
        DetailPage(minTableHeight: 240) {
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
                chart(detail)
            } else {
                Color.clear.frame(height: 320)
            }
            HStack {
                Picker("Table", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        } table: {
            switch tab {
            case .positions: positionsTable
            case .transactions: transactionsTable
            }
        }
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "accounts.depot-detail", scope: .depot(id), variant: today) { analysis in
            guard let detail = DepotDetailModel(analysis, depot: id, today: today) else { throw MissingEntity() }
            return detail
        }
        .ledgerTask($transactions, id: "accounts.depot-transactions", variant: query) { ledger in
            DepotTransactionRow.rows(ledger, depot: query.depot, filter: QuickFilter(query.filter)).sorted(using: query.sortOrder)
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: tab == .positions ? "Filter positions" : "Filter transactions") } }
        .onGeometryChange(for: Bool.self) { $0.size.width < 880 } action: { isCompact = $0 }
        .onAppear {
            tab = store.launchValue("tab", as: Tab.self) ?? tab
            filter = store.launchValue("filter") ?? filter
            pinnedDay = AccountsScreen.launchHover(store.launchState, interval: store.periodInterval)
        }
    }

    // MARK: Figures and chart

    private func figures(_ detail: DepotDetailModel) -> some View {
        let period = store.period.shortTitle
        return HStack(spacing: DS.Spacing.m) {
            FigureTile("Market Value", value: Fmt.money(detail.marketValue),
                       footnote: "\(Fmt.integer(detail.positions.count)) position\(detail.positions.count == 1 ? "" : "s") · cost \(Fmt.compactMoney(detail.costBasis))")
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

    private var positionsTable: some View {
        let currency = model.value?.currency ?? store.baseCurrency
        let rows = positions
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
                    Text(row.price.map { Fmt.price($0, currency: row.priceCurrency) } ?? Fmt.missing).numeric()
                        .foregroundStyle(row.isValued ? .primary : .secondary)
                }
                .width(min: 76, ideal: 80)
                .alignment(.trailing)
                .customizationID("price")
            }
            TableColumn("Value", value: \.value) { row in
                Text(Fmt.money(minor: row.value, currency: currency)).numeric()
            }
            .width(min: 92, ideal: 96)
            .alignment(.trailing)
            .customizationID("value")
            TableColumn("Weight", value: \.weight) { row in
                HStack(spacing: DS.Spacing.s) {
                    if !isCompact { WeightBar(fraction: row.weight) }
                    Text(Fmt.percent(row.weight, decimals: 1)).numeric().frame(width: 48, alignment: .trailing)
                }
            }
            .width(min: 56, ideal: isCompact ? 60 : 88)
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
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Show Security", systemImage: "arrow.right.circle") { ids.first.map { store.navigate(to: .security($0)) } }
                .disabled(ids.count != 1)
            Divider()
            Button("Buy More…", systemImage: Transaction.Kind.buy.symbol) { record(.buy, ids.first) }.disabled(ids.count != 1)
            Button("Sell…", systemImage: Transaction.Kind.sell.symbol) { record(.sell, ids.first) }.disabled(ids.count != 1)
            Button("Record Dividend…", systemImage: Transaction.Kind.dividend.symbol) { record(.dividend, ids.first) }.disabled(ids.count != 1)
            Button("Transfer to Another Depot…", systemImage: Transaction.Kind.securityTransfer.symbol) { record(.securityTransfer, ids.first) }
                .disabled(ids.count != 1)
            Divider()
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(positionsTSV(ids, currency: currency)) }
        } primaryAction: { ids in
            if let first = ids.first { store.navigate(to: .security(first)) }
        }
        .onCopyCommand { [NSItemProvider(object: positionsTSV(positionSelection, currency: currency) as NSString)] }
        .overlay {
            if model.value != nil, rows.isEmpty {
                if filter.isEmpty {
                    EmptyState("No Positions", symbol: "briefcase", message: "This depot holds no securities today. Record a purchase, or a delivery for holdings you already own.") {
                        Button("Buy…") { AccountsActions.record(.buy, depot: depotID, in: store) }
                        Button("Deliver In…") { AccountsActions.record(.deliveryIn, depot: depotID, in: store) }
                    }
                } else {
                    EmptyState("No Matches", symbol: "line.3.horizontal.decrease", message: "No position matches “\(filter)”.") {
                        Button("Clear Filter") { filter = "" }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "position", selected: positionSelection.count,
                        filteredFrom: filter.isEmpty ? nil : model.value?.positions.count) {
                let chosen = positionSelection.isEmpty ? rows : rows.filter { positionSelection.contains($0.id) }
                Text("\(positionSelection.isEmpty ? "Total" : "Selected") \(Fmt.money(minor: chosen.reduce(0) { $0 + $1.value }, currency: currency))")
                    .numeric().foregroundStyle(.secondary)
            }
        }
    }

    private func record(_ kind: Transaction.Kind, _ security: UUID?) {
        guard let security else { return }
        let account = kind == .securityTransfer ? nil : store.depot(depotID)?.referenceAccountID
        store.present(.newTransaction(TransactionPrefill(kind: kind, date: store.today, securityID: security, accountID: account, depotID: depotID)))
    }

    private func positionsTSV(_ ids: Set<UUID>, currency: CurrencyCode) -> String {
        let chosen = ids.isEmpty ? positions : positions.filter { ids.contains($0.id) }
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
        if transactions.value == nil {
            Color.clear
        } else {
            loadedTransactionsTable
        }
    }

    private var loadedTransactionsTable: some View {
        let rows = transactions.value ?? []
        return Table(rows, selection: $transactionSelection, sortOrder: $transactionSort, columnCustomization: $transactionColumns) {
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
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Edit…", systemImage: "pencil") { ids.first.map { store.present(.editTransaction($0)) } }
                .disabled(ids.count != 1)
            Button("Duplicate…", systemImage: "plus.square.on.square") {
                if let t = store.transaction(ids.first) { store.present(.newTransaction(TransactionPrefill(copying: t, date: store.today))) }
            }
            .disabled(ids.count != 1)
            Button("Show in Transactions", systemImage: "arrow.right.circle") { ids.first.map { store.navigate(to: .transaction($0)) } }
                .disabled(ids.count != 1)
            Divider()
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(transactionsTSV(ids)) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteTransactions(ids) }
        } primaryAction: { ids in
            if let first = ids.first { store.present(.editTransaction(first)) }
        }
        .onCopyCommand { [NSItemProvider(object: transactionsTSV(transactionSelection) as NSString)] }
        .onDeleteCommand { store.deleteTransactions(transactionSelection) }
        .overlay {
            if transactions.value != nil, rows.isEmpty {
                if filter.isEmpty {
                    EmptyState("No Transactions Yet", symbol: "tray", message: "Purchases, sales, deliveries and transfers of this depot appear here.") {
                        Button("Buy…") { AccountsActions.record(.buy, depot: depotID, in: store) }
                    }
                } else {
                    EmptyState("No Matches", symbol: "line.3.horizontal.decrease", message: "No transaction of this depot matches “\(filter)”.") {
                        Button("Clear Filter") { filter = "" }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "transaction", selected: transactionSelection.count,
                        filteredFrom: filter.isEmpty ? nil : store.transactions(forDepot: depotID).count)
        }
    }

    private func transactionsTSV(_ ids: Set<UUID>) -> String {
        let all = transactions.value ?? []
        let chosen = ids.isEmpty ? all : all.filter { ids.contains($0.id) }
        return TSV.string(
            header: ["Date", "Type", "Security", "Shares", "Amount", "Currency", "Note"],
            rows: chosen.map {
                [$0.date.iso, $0.kindTitle, $0.security, TSV.number($0.shares.decimalValue), TSV.number($0.amount.decimalValue), $0.amount.currency, $0.note]
            })
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
