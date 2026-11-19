import SwiftUI
import KontorModel
import KontorUI

// MARK: - By security

struct EarningsSecuritiesTable: View {
    typealias Row = EarningsModel.SecurityRow

    @Environment(PortfolioStore.self) private var store
    @Environment(\.gainStyle) private var gainStyle
    let model: EarningsModel
    let showPayments: (UUID) -> Void

    @State private var selection = Set<Row.ID>()
    @State private var sortOrder: [KeyPathComparator<Row>]
    @State private var rows: [Row]

    init(model: EarningsModel, showPayments: @escaping (UUID) -> Void) {
        self.model = model
        self.showPayments = showPayments
        // The table starts with its rows (a few hundred at most) instead of filling in after it appeared.
        let order = [KeyPathComparator(\Row.amount, order: .reverse)]
        _sortOrder = State(initialValue: order)
        _rows = State(initialValue: model.securities.sorted(using: order))
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Security", value: \.name) { row in
                HStack(spacing: DS.Spacing.s) {
                    Text(row.name)
                        .foregroundStyle(row.securityID == nil || row.isRetired ? .secondary : .primary)
                    Text(row.detail).font(.callout).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
            .width(min: 180, ideal: 300)
            TableColumn(model.kind.title, value: \.amount) { row in
                Text(Fmt.money(minor: row.amount, currency: model.currency))
                    .numeric()
                    .foregroundStyle(row.amount < 0 && model.kind == .net ? AnyShapeStyle(gainStyle.loss) : AnyShapeStyle(.primary))
            }
            .width(min: 90, ideal: 120)
            .alignment(.trailing)
            TableColumn("Share of Total", value: \.share) { row in
                ShareBar(share: row.share, color: model.kind.color)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Payments", value: \.count) { row in
                Text(row.count == 0 ? Fmt.missing : Fmt.integer(row.count))
                    .numeric()
                    .foregroundStyle(row.count == 0 ? .tertiary : .primary)
            }
            .width(min: 60, ideal: 76)
            .alignment(.trailing)
            TableColumn("Last Payment", value: \.lastDaySortKey) { row in
                if let day = row.lastDay {
                    HStack(spacing: DS.Spacing.s) {
                        Text(Fmt.money(minor: row.lastGross, currency: model.currency)).foregroundStyle(.secondary)
                        Text(Fmt.day(day))
                    }
                    .numeric()
                    .lineLimit(1)
                } else {
                    Text(Fmt.missing).foregroundStyle(.tertiary)
                }
            }
            .width(min: 130, ideal: 170)
            .alignment(.trailing)
            TableColumn("Per Share", value: \.perShareSortKey) { row in
                Text(EarningsFormat.perShare(row.perShare, currency: model.currency))
                    .numeric()
                    .foregroundStyle(row.perShare == nil ? .tertiary : .primary)
            }
            .width(min: 70, ideal: 90)
            .alignment(.trailing)
            TableColumn("Yield on Cost", value: \.yieldSortKey) { row in
                Text(Fmt.percent(row.yieldOnCost))
                    .numeric()
                    .foregroundStyle(row.yieldOnCost == nil ? .tertiary : .primary)
            }
            .width(min: 80, ideal: 100)
            .alignment(.trailing)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let securityIDs = securityIDs(ids)
            Button("Show Security") { securityIDs.first.map { store.navigate(to: .security($0)) } }
                .disabled(securityIDs.count != 1)
            Button("Show Payments") { securityIDs.first.map(showPayments) }
                .disabled(securityIDs.count != 1)
            Button("Record Dividend…") {
                store.present(.newTransaction(EarningsActions.prefill(.dividend, securityID: securityIDs.first, store: store)))
            }
            .disabled(securityIDs.count != 1)
            Divider()
            Button("Copy") { Pasteboard.copy(tsv(ids)) }
        } primaryAction: { ids in
            securityIDs(ids).first.map { store.navigate(to: .security($0)) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
        .onChange(of: selection) { _, ids in
            let securityIDs = securityIDs(ids)
            store.setFocus(securityIDs.count == 1 ? .security(securityIDs[0]) : nil)
        }
        .onChange(of: model.securities) { _, new in rows = new.sorted(using: sortOrder) }
        .onChange(of: store.route.securityID, initial: true) { _, id in
            // A deep link or the inspector's focus selects the row.
            if let id, selection != [id], model.securities.contains(where: { $0.id == id }) { selection = [id] }
        }
        .onChange(of: sortOrder) { _, order in rows = model.securities.sorted(using: order) }
        .overlay {
            if rows.isEmpty {
                EmptyState("No \(model.kind.title) by Security", symbol: "building.columns",
                           message: "Nothing in this period can be attributed to a security.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "security", selected: selection.count) {
                HStack(spacing: DS.Spacing.m) {
                    HelpLabel("Yield on cost: last 12 months", topic: .yieldOnCost)
                    Text("Total \(Fmt.money(minor: model.totalValue, currency: model.currency))").numeric()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .tableChrome()
    }

    private func securityIDs(_ ids: Set<Row.ID>) -> [UUID] {
        rows.filter { ids.contains($0.id) }.compactMap(\.securityID)
    }

    private func tsv(_ ids: Set<Row.ID>) -> String {
        let table = EarningsExport.securities(model, rows: ids.isEmpty ? rows : rows.filter { ids.contains($0.id) })
        return TSV.string(header: table.header, rows: table.rows)
    }
}

/// A share of the total as a short bar plus the percentage.
struct ShareBar: View {
    let share: Double
    let color: Color

    /// Costs can outweigh income (Net): then "a share of the total" says nothing.
    private var isMeaningful: Bool { share >= 0 && share <= 1 }

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule().fill(color).frame(width: (isMeaningful ? share : 0) * proxy.size.width)
                }
            }
            .frame(height: 5)
            Text(isMeaningful ? Fmt.percent(share, decimals: 1) : Fmt.missing)
                .numeric()
                .foregroundStyle(isMeaningful ? .secondary : .tertiary)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(isMeaningful ? Fmt.percent(share, decimals: 1) : "No share")
        .help(isMeaningful ? "" : "A share of the total only makes sense while all parts have the same sign.")
    }
}

// MARK: - By account

struct EarningsAccountsTable: View {
    typealias Row = EarningsModel.AccountRow

    @Environment(PortfolioStore.self) private var store
    let model: EarningsModel

    @State private var selection = Set<Row.ID>()
    @State private var sortOrder: [KeyPathComparator<Row>]
    @State private var rows: [Row]

    init(model: EarningsModel) {
        self.model = model
        let order = [KeyPathComparator(\Row.amount, order: .reverse)]
        _sortOrder = State(initialValue: order)
        _rows = State(initialValue: model.accounts.sorted(using: order))
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Account", value: \.name) { row in
                HStack(spacing: DS.Spacing.s) {
                    Text(row.name)
                    Text(row.currency).font(.callout).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
            .width(min: 160, ideal: 260)
            TableColumn("Dividends", value: \.dividends) { money($0.dividends) }
                .width(min: 80, ideal: 110).alignment(.trailing)
            TableColumn("Interest", value: \.interest) { money($0.interest) }
                .width(min: 80, ideal: 110).alignment(.trailing)
            TableColumn("Fees", value: \.fees) { money($0.fees) }
                .width(min: 80, ideal: 110).alignment(.trailing)
            TableColumn("Taxes", value: \.taxes) { money($0.taxes) }
                .width(min: 80, ideal: 110).alignment(.trailing)
            TableColumn("Net", value: \.net) { row in
                Text(Fmt.money(minor: row.net, currency: model.currency)).fontWeight(.medium).numeric()
            }
            .width(min: 80, ideal: 110).alignment(.trailing)
            TableColumn("Share of \(model.kind.title)", value: \.share) { row in
                ShareBar(share: row.share, color: model.kind.color)
            }
            .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            Button("Show Account") { ids.first.map { store.navigate(to: .account($0)) } }
                .disabled(ids.count != 1)
            Button("Record Interest…") {
                store.present(.newTransaction(EarningsActions.prefill(.interest, accountID: ids.first, store: store)))
            }
            .disabled(ids.count != 1)
            Divider()
            Button("Copy") { Pasteboard.copy(tsv(ids)) }
        } primaryAction: { ids in
            ids.first.map { store.navigate(to: .account($0)) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
        .onChange(of: selection) { _, ids in store.setFocus(ids.count == 1 ? .account(ids.first!) : nil) }
        .onChange(of: model.accounts) { _, new in rows = new.sorted(using: sortOrder) }
        .onChange(of: sortOrder) { _, order in rows = model.accounts.sorted(using: order) }
        .overlay {
            if rows.isEmpty {
                EmptyState("Nothing Booked on an Account", symbol: "banknote",
                           message: "No dividends, interest, fees or taxes were booked on a cash account in this period.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "account", selected: selection.count) {
                Text("Amounts in \(model.currency), on the account they were booked on. Fees and taxes of deliveries touch no account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tableChrome()
    }

    private func money(_ minor: Int64) -> some View {
        Text(minor == 0 ? Fmt.missing : Fmt.money(minor: minor, currency: model.currency))
            .numeric()
            .foregroundStyle(minor == 0 ? .tertiary : .primary)
    }

    private func tsv(_ ids: Set<Row.ID>) -> String {
        let table = EarningsExport.accounts(model, rows: ids.isEmpty ? rows : rows.filter { ids.contains($0.id) })
        return TSV.string(header: table.header, rows: table.rows)
    }
}

// MARK: - Payments

/// Every dividend payment of the interval; a double-click reveals the entry in Transactions.
struct EarningsPaymentsView: View {
    @Environment(PortfolioStore.self) private var store
    let interval: DayInterval
    @Binding var filter: PaymentsFilter

    @State private var loaded = Loadable<PaymentsModel>()
    @State private var selection = Set<PaymentRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\PaymentRow.day, order: .reverse)]

    private var rows: [PaymentRow] { loaded.value?.rows ?? [] }
    private var currency: CurrencyCode { loaded.value?.currency ?? store.baseCurrency }

    var body: some View {
        let query = filter.query(sortOrder: sortOrder)
        VStack(spacing: 0) {
            if filter.month != nil || filter.securityID != nil {
                filterBar
            }
            if loaded.value != nil {
                table
            } else {
                Color.clear.loadingOverlay(loaded.isInitialLoad)
            }
        }
        .analysisTask($loaded, id: "earnings.payments", interval: interval, variant: query) { analysis in
            PaymentsModel(analysis, query: query)
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter.text, prompt: "Filter payments") } }
    }

    private var filterBar: some View {
        HStack(spacing: DS.Spacing.s) {
            Text("Showing").foregroundStyle(.secondary)
            if let month = filter.month {
                chip(Fmt.month(year: month / 12, month: month % 12 + 1, long: true)) { filter.month = nil }
            }
            if let id = filter.securityID {
                chip(store.security(id)?.name ?? "Security") { filter.securityID = nil }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.bottom, DS.Spacing.s)
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: DS.Spacing.xs) {
                Text(title)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove this filter")
        .accessibilityLabel("Remove filter \(title)")
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.day) { Text(Fmt.day($0.day)).numeric() }
                .width(min: 80, ideal: 96)
            TableColumn("Security", value: \.security) { Text($0.security).lineLimit(1) }
                .width(min: 150, ideal: 260)
            TableColumn("Account", value: \.account) { Text($0.account).lineLimit(1).foregroundStyle(.secondary) }
                .width(min: 100, ideal: 150)
            TableColumn("Shares", value: \.shares) { row in
                Text(row.shares.isZero ? Fmt.missing : EarningsFormat.shares(row.shares)).numeric()
                    .help(Fmt.shares(row.shares))
            }
            .width(min: 60, ideal: 80).alignment(.trailing)
            TableColumn("Per Share", value: \.perShareSortKey) { row in
                Text(EarningsFormat.perShare(row.perShare, currency: currency)).numeric()
            }
            .width(min: 70, ideal: 90).alignment(.trailing)
            TableColumn("Gross", value: \.gross) { Text(Fmt.money(minor: $0.gross, currency: currency)).numeric() }
                .width(min: 80, ideal: 100).alignment(.trailing)
            TableColumn("Taxes", value: \.taxes) { cost($0.taxes) }
                .width(min: 70, ideal: 90).alignment(.trailing)
            TableColumn("Fees", value: \.fees) { cost($0.fees) }
                .width(min: 60, ideal: 80).alignment(.trailing)
            TableColumn("Net", value: \.net) { row in
                Text(Fmt.money(minor: row.net, currency: currency)).fontWeight(.medium).numeric()
            }
            .width(min: 80, ideal: 100).alignment(.trailing)
            TableColumn("Yield", value: \.yieldSortKey) { row in
                Text(Fmt.percent(row.yield)).numeric().foregroundStyle(row.yield == nil ? .tertiary : .secondary)
            }
            .width(min: 56, ideal: 70).alignment(.trailing)
        }
        .contextMenu(forSelectionType: PaymentRow.ID.self) { ids in
            Button("Show in Transactions") { ids.first.map { store.navigate(to: .transaction($0)) } }
                .disabled(ids.count != 1)
            Button("Edit…") { ids.first.map { store.present(.editTransaction($0)) } }
                .disabled(ids.count != 1)
            Button("Record Again…") {
                if let transaction = store.transaction(ids.first) {
                    store.present(.newTransaction(TransactionPrefill(copying: transaction, date: store.today)))
                }
            }
            .disabled(ids.count != 1)
            Button("Show Security") {
                rows.first { ids.contains($0.id) }.map { store.navigate(to: .security($0.securityID)) }
            }
            .disabled(ids.count != 1)
            Divider()
            Button("Copy") { Pasteboard.copy(tsv(ids)) }
            Divider()
            Button("Delete", role: .destructive) { store.deleteTransactions(ids) }
        } primaryAction: { ids in
            ids.first.map { store.navigate(to: .transaction($0)) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
        .onDeleteCommand { store.deleteTransactions(selection) }
        .onChange(of: selection) { _, ids in store.setFocus(ids.count == 1 ? .transaction(ids.first!) : nil) }
        .overlay {
            if let model = loaded.value, model.rows.isEmpty {
                if model.totalCount == 0 {
                    EmptyState("No Dividend Payments", symbol: "list.bullet",
                               message: "No dividends were paid in this period. Choose All Years, or record one.") {
                        Button("Record Dividend…") {
                            store.present(.newTransaction(EarningsActions.prefill(.dividend, store: store)))
                        }
                    }
                } else {
                    EmptyState("No Matching Payments", symbol: "line.3.horizontal.decrease.circle",
                               message: "No dividend payment matches the filter.") {
                        Button("Clear Filter") { filter = PaymentsFilter() }
                    }
                }
            }
        }
        .loadingOverlay(loaded.isInitialLoad)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "dividend payment", selected: selection.count,
                        filteredFrom: loaded.value.map(\.totalCount)) {
                if let model = loaded.value, !model.rows.isEmpty {
                    HStack(spacing: DS.Spacing.m) {
                        Text("Gross \(Fmt.money(minor: model.gross, currency: model.currency))")
                        Text("Taxes \(Fmt.money(minor: model.taxes, currency: model.currency))")
                        Text("Fees \(Fmt.money(minor: model.fees, currency: model.currency))")
                        Text("Net \(Fmt.money(minor: model.net, currency: model.currency))").foregroundStyle(.primary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
                }
            }
        }
        .tableChrome()
    }

    private func cost(_ minor: Int64) -> some View {
        Text(minor == 0 ? Fmt.missing : Fmt.money(minor: minor, currency: currency))
            .numeric()
            .foregroundStyle(minor == 0 ? .tertiary : .secondary)
    }

    private func tsv(_ ids: Set<PaymentRow.ID>) -> String {
        let table = EarningsExport.payments(ids.isEmpty ? rows : rows.filter { ids.contains($0.id) }, currency: currency)
        return TSV.string(header: table.header, rows: table.rows)
    }
}

extension View {
    /// Tables sit edge to edge under the header, separated by a hairline.
    func tableChrome() -> some View {
        overlay(alignment: .top) { Divider() }
    }
}
