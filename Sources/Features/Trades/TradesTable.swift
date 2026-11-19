import SwiftUI
import KontorUI

/// The table of closed or open trades: sortable, multi-selection, ⌘C copies TSV, Return / double-click
/// shows the matched lots in the inspector, context menu with deep links.
struct TradesTable: View {
    @Environment(PortfolioStore.self) private var store
    @SceneStorage("trades.columns.closed") private var closedColumns: TableColumnCustomization<TradeRow>
    @SceneStorage("trades.columns.open") private var openColumns: TableColumnCustomization<TradeRow>

    let model: TradeListModel
    @Binding var selection: Set<TradeRow.ID>
    @Binding var sortOrder: [KeyPathComparator<TradeRow>]
    let isFiltering: Bool
    let clearFilters: () -> Void
    let filterSecurity: (UUID) -> Void

    private var isClosed: Bool { model.kind == .closed }
    private var currency: CurrencyCode { model.currency }

    var body: some View {
        ScrollViewReader { proxy in
            Table(model.rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: isClosed ? $closedColumns : $openColumns) {
                identityColumns
                valueColumns
                resultColumns
            }
            .contextMenu(forSelectionType: TradeRow.ID.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                selection = ids
                store.isInspectorPresented = true
            }
            .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
            .onChange(of: selection) { _, ids in
                if ids.count == 1, let id = ids.first { proxy.scrollTo(id) }
            }
            .overlay {
                if model.rows.isEmpty {
                    EmptyState("No Matching Trades", symbol: "line.3.horizontal.decrease.circle", message: "No \(isClosed ? "closed" : "open") trade matches the current filters.") {
                        if isFiltering { Button("Clear Filters", action: clearFilters) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TableFooter(count: model.rows.count, noun: "trade", selected: selection.count, filteredFrom: model.totalCount) {
                    footerTotals
                }
            }
        }
        .accessibilityLabel(isClosed ? "Closed trades" : "Open trades")
    }

    @TableColumnBuilder<TradeRow, KeyPathComparator<TradeRow>>
    private var identityColumns: some TableColumnContent<TradeRow, KeyPathComparator<TradeRow>> {
        TableColumn("Security", value: \.security) { row in
            HStack(spacing: DS.Spacing.s) {
                Text(row.security).lineLimit(1).truncationMode(.middle).help(row.security)
                if row.isShort {
                    Text("Short")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("Sold short first and covered later")
                }
            }
        }
        .width(min: 190, ideal: 220)
        .customizationID("security")
        .disabledCustomizationBehavior(.visibility)

        TableColumn("Depot", value: \.depot) { row in
            Text(row.depot).lineLimit(1).foregroundStyle(.secondary)
        }
        .width(min: 84, ideal: 96)
        .customizationID("depot")

        TableColumn("Opened", value: \.opened) { row in
            Text(Fmt.day(row.opened)).numeric()
        }
        .width(min: 80, ideal: 84)
        .customizationID("opened")

        if isClosed {
            TableColumn("Closed", value: \.end) { row in
                Text(Fmt.day(row.end)).numeric()
            }
            .width(min: 80, ideal: 84)
            .customizationID("closed")
        }
    }

    @TableColumnBuilder<TradeRow, KeyPathComparator<TradeRow>>
    private var valueColumns: some TableColumnContent<TradeRow, KeyPathComparator<TradeRow>> {
        TableColumn("Held", value: \.holdingDays) { row in
            Text(Fmt.duration(days: row.holdingDays, style: .compact))
                .numeric()
                .help("\(Fmt.integer(row.holdingDays)) days\(row.lotCount > 1 ? ", counted from the oldest of \(row.lotCount) lots" : "")")
        }
        .width(min: 40, ideal: 50)
        .alignment(.trailing)
        .customizationID("held")

        TableColumn("Shares", value: \.shares) { row in
            Text(Fmt.shares(row.shares, maxDecimals: 4)).numeric().help("\(Fmt.shares(row.shares)) shares")
        }
        .width(min: 64, ideal: 84)
        .alignment(.trailing)
        .customizationID("shares")

        TableColumn(isClosed ? "Entry Value" : "Cost", value: \.entryValue) { row in
            Text(Fmt.money(Money(minor: row.entryValue, currency: currency), symbol: false)).numeric()
        }
        .width(min: 70, ideal: 90)
        .alignment(.trailing)
        .customizationID("entry")

        TableColumn(isClosed ? "Exit Value" : "Value", value: \.exitValue) { row in
            Text(Fmt.money(Money(minor: row.exitValue, currency: currency), symbol: false)).numeric()
        }
        .width(min: 70, ideal: 90)
        .alignment(.trailing)
        .customizationID("exit")
    }

    @TableColumnBuilder<TradeRow, KeyPathComparator<TradeRow>>
    private var resultColumns: some TableColumnContent<TradeRow, KeyPathComparator<TradeRow>> {
        TableColumn("Fees", value: \.fees) { row in
            Text(Fmt.money(Money(minor: row.fees, currency: currency), symbol: false))
                .numeric()
                .foregroundStyle(row.fees == 0 ? .tertiary : .primary)
        }
        .width(min: 46, ideal: 62)
        .alignment(.trailing)
        .customizationID("fees")

        if isClosed {
            TableColumn("Taxes", value: \.taxes) { row in
                Text(Fmt.money(Money(minor: row.taxes, currency: currency), symbol: false))
                    .numeric()
                    .foregroundStyle(row.taxes == 0 ? .tertiary : .primary)
            }
            .width(min: 62, ideal: 72)
            .alignment(.trailing)
            .customizationID("taxes")
        }

        TableColumn("Gain", value: \.gain) { row in
            GainText(money: Money(minor: row.gain, currency: currency), symbol: false)
        }
        .width(min: 74, ideal: 92)
        .alignment(.trailing)
        .customizationID("gain")

        TableColumn("Return", value: \.returnKey) { row in
            if let value = row.returnFraction {
                GainText(percent: value)
            } else {
                Text(Fmt.missing).foregroundStyle(.tertiary)
            }
        }
        .width(min: 70, ideal: 82)
        .alignment(.trailing)
        .customizationID("return")

        TableColumn("Return p.a.", value: \.annualizedKey) { row in
            if let value = row.annualized {
                GainText(percent: value)
                    .help("Money-weighted annual return (IRR) of this trade's cash flows")
            } else {
                Text(Fmt.missing)
                    .foregroundStyle(.tertiary)
                    .help("Not defined for trades opened and closed on the same day")
            }
        }
        .width(min: 72, ideal: 84)
        .alignment(.trailing)
        .customizationID("annualized")
    }

    private var footerTotals: some View {
        HStack(spacing: DS.Spacing.l) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.l) {
                    total(isClosed ? "Entry" : "Cost", model.entryTotal)
                    total(isClosed ? "Exit" : "Value", model.exitTotal)
                    total("Fees", model.statistics.totalFees)
                    total("Taxes", model.statistics.totalTaxes)
                }
                HStack(spacing: DS.Spacing.l) {
                    total("Fees", model.statistics.totalFees)
                    total("Taxes", model.statistics.totalTaxes)
                }
                EmptyView()
            }
            HStack(spacing: DS.Spacing.xs) {
                Text("Gain")
                GainText(money: Money(minor: model.statistics.totalGain, currency: currency))
            }
        }
        .lineLimit(1)
    }

    private func total(_ label: String, _ minor: Int64) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(label)
            Text(Fmt.money(minor: minor, currency: currency)).foregroundStyle(.primary)
        }
    }

    @ViewBuilder private func contextMenu(_ ids: Set<TradeRow.ID>) -> some View {
        let rows = model.rows.filter { ids.contains($0.id) }
        if let row = rows.first, rows.count == 1 {
            Button("Show Matched Lots") {
                selection = ids
                store.isInspectorPresented = true
            }
            Divider()
            if let transaction = row.closingTransactionID {
                Button("Show Closing Transaction") { store.navigate(to: .transaction(transaction)) }
                Button("Edit Closing Transaction…") { store.present(.editTransaction(transaction)) }
            } else {
                Button("Sell…") {
                    store.present(.newTransaction(TransactionPrefill(
                        kind: row.isShort ? .buy : .sell, date: store.today, securityID: row.securityID, depotID: row.id.depotID, shares: row.shares)))
                }
                Button("Buy More…") {
                    store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today, securityID: row.securityID, depotID: row.id.depotID)))
                }
            }
            Button("Show Security") { store.navigate(to: .security(row.securityID)) }
            Button("Show Depot") { store.navigate(to: .depot(row.id.depotID)) }
            Divider()
            Button("Only Trades in \(row.security)") { filterSecurity(row.securityID) }
            Divider()
        }
        if !rows.isEmpty {
            Button(rows.count == 1 ? "Copy" : "Copy \(Fmt.integer(rows.count)) Trades") { Pasteboard.copy(tsv(ids)) }
        } else {
            Button("Copy All Trades") { Pasteboard.copy(TradeExport.tsv(model.rows, kind: model.kind, currency: currency)) }
                .disabled(model.rows.isEmpty)
        }
    }

    private func tsv(_ ids: Set<TradeRow.ID>) -> String {
        TradeExport.tsv(model.rows.filter { ids.contains($0.id) }, kind: model.kind, currency: currency)
    }

    /// A sort order from its launch-state form: `<column>[:asc|:desc]`.
    static func comparator(_ text: String) -> KeyPathComparator<TradeRow>? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard let column = parts.first else { return nil }
        let explicit: SortOrder? = parts.count > 1 ? (parts[1] == "asc" ? .forward : .reverse) : nil
        switch column {
        case "security": return KeyPathComparator(\.security, order: explicit ?? .forward)
        case "depot": return KeyPathComparator(\.depot, order: explicit ?? .forward)
        case "opened": return KeyPathComparator(\.opened, order: explicit ?? .reverse)
        case "closed": return KeyPathComparator(\.end, order: explicit ?? .reverse)
        case "held": return KeyPathComparator(\.holdingDays, order: explicit ?? .reverse)
        case "shares": return KeyPathComparator(\.shares, order: explicit ?? .reverse)
        case "entry": return KeyPathComparator(\.entryValue, order: explicit ?? .reverse)
        case "exit": return KeyPathComparator(\.exitValue, order: explicit ?? .reverse)
        case "fees": return KeyPathComparator(\.fees, order: explicit ?? .reverse)
        case "taxes": return KeyPathComparator(\.taxes, order: explicit ?? .reverse)
        case "gain": return KeyPathComparator(\.gain, order: explicit ?? .reverse)
        case "return": return KeyPathComparator(\.returnKey, order: explicit ?? .reverse)
        case "annualized": return KeyPathComparator(\.annualizedKey, order: explicit ?? .reverse)
        default: return nil
        }
    }
}
