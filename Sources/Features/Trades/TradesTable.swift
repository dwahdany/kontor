import SwiftUI
import KontorUI

/// Which columns the trades table shows at a given width. Column minimum widths are hard limits —
/// past their sum the table scrolls sideways and the result columns (the reason the screen exists)
/// are the first to disappear. So the table drops supporting columns instead, least important
/// first: fees and taxes, the share count, the opening date, the depot (first of all if there is
/// only one depot). Everything stays available in the inspector and the exports.
struct TradeColumns: Hashable, Sendable {
    var showsCosts = true
    var showsShares = true
    var showsOpened = true
    var showsDepot = true

    /// Minimum widths of the columns, in points.
    enum Width {
        static let security: CGFloat = 140
        static let depot: CGFloat = 70
        static let date: CGFloat = 78
        static let held: CGFloat = 52
        static let shares: CGFloat = 56
        static let money: CGFloat = 70
        static let fees: CGFloat = 44
        static let taxes: CGFloat = 50
        static let gain: CGFloat = 74
        static let percent: CGFloat = 76
        /// Padding and divider a `Table` adds per column.
        static let chrome: CGFloat = 17
    }

    /// Minimum widths of the columns shown for `kind`.
    func widths(_ kind: TradeKind) -> [CGFloat] {
        var widths = [Width.security]
        if showsDepot { widths.append(Width.depot) }
        if showsOpened { widths.append(Width.date) }
        if kind == .closed { widths.append(Width.date) }
        widths.append(Width.held)
        if showsShares { widths.append(Width.shares) }
        widths += [Width.money, Width.money]
        if showsCosts {
            widths.append(Width.fees)
            if kind == .closed { widths.append(Width.taxes) }
        }
        widths += [Width.gain, Width.percent, Width.percent]
        return widths
    }

    /// The width needed so that no column is cut off.
    func requiredWidth(_ kind: TradeKind) -> CGFloat {
        let widths = widths(kind)
        return widths.reduce(0, +) + CGFloat(widths.count) * Width.chrome
    }

    /// The most columns that fit into `width`.
    static func fitting(width: CGFloat, kind: TradeKind, hasSeveralDepots: Bool) -> TradeColumns {
        var columns = TradeColumns()
        var drops: [WritableKeyPath<TradeColumns, Bool>] = [\.showsCosts, \.showsShares, \.showsOpened, \.showsDepot]
        // With a single depot the column says nothing: it goes first.
        if !hasSeveralDepots { drops = [\.showsDepot] + drops.dropLast() }
        for drop in drops {
            if columns.requiredWidth(kind) <= width { break }
            columns[keyPath: drop] = false
        }
        return columns
    }
}

/// An amount without currency symbol that drops the cents rather than being cut off ("135.807,…")
/// when its column is at its minimum width. Sorting, tooltips and exports keep the exact amount.
struct MoneyCell: View {
    let minor: Int64
    let currency: CurrencyCode
    var prefix = ""

    var body: some View {
        let money = Money(minor: minor, currency: currency)
        ViewThatFits(in: .horizontal) {
            Text(prefix + Fmt.money(money, symbol: false))
            Text(prefix + Fmt.moneyRounded(money, symbol: false))
        }
        .numeric()
        .lineLimit(1)
    }
}

/// The table of closed or open trades: sortable, multi-selection, ⌘C copies TSV, Return / double-click
/// shows the matched lots in the inspector, context menu with deep links.
struct TradesTable: View {
    @Environment(PortfolioStore.self) private var store
    @SceneStorage("trades.columns.closed") private var closedColumns: TableColumnCustomization<TradeRow>
    @SceneStorage("trades.columns.open") private var openColumns: TableColumnCustomization<TradeRow>

    let model: TradeListModel
    @Binding var selection: Set<TradeRow.ID>
    @Binding var sortOrder: [KeyPathComparator<TradeRow>]
    /// Width available to the table.
    let width: CGFloat
    let isFiltering: Bool
    let clearFilters: () -> Void
    let filterSecurity: (UUID) -> Void
    let exportCSV: () -> Void

    private var isClosed: Bool { model.kind == .closed }
    private var currency: CurrencyCode { model.currency }
    private var columns: TradeColumns { .fitting(width: width, kind: model.kind, hasSeveralDepots: model.depots.count > 1) }

    var body: some View {
        let tier = columns
        ScrollViewReader { proxy in
            Table(model.rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: isClosed ? $closedColumns : $openColumns) {
                identityColumns(tier)
                valueColumns(tier)
                resultColumns(tier)
            }
            // The set of columns changes with the width; a table cannot change its structure in place.
            .id(tier)
            .contextMenu(forSelectionType: TradeRow.ID.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                selection = ids
                store.isInspectorPresented = true
            }
            .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
            .onChange(of: selection) { _, ids in
                if ids.count == 1, let id = ids.first { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.5)) }
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
    private func identityColumns(_ tier: TradeColumns) -> some TableColumnContent<TradeRow, KeyPathComparator<TradeRow>> {
        TableColumn("Security", value: \.security) { row in
            securityCell(row, showsDepot: !tier.showsDepot && model.depots.count > 1)
        }
        .width(min: TradeColumns.Width.security, ideal: 200)
        .customizationID("security")
        .disabledCustomizationBehavior(.visibility)

        if tier.showsDepot {
            TableColumn("Depot", value: \.depot) { row in
                Text(row.depot).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: TradeColumns.Width.depot, ideal: 90)
            .customizationID("depot")
        }

        if tier.showsOpened {
            TableColumn("Opened", value: \.opened) { row in
                Text(Fmt.day(row.opened))
                    .numeric()
                    .help(row.lotCount > 1 ? "Oldest of \(Fmt.integer(row.lotCount)) lots" : "")
            }
            .width(min: TradeColumns.Width.date, ideal: 82)
            .customizationID("opened")
        }

        if isClosed {
            TableColumn("Closed", value: \.end) { row in
                Text(Fmt.day(row.end)).numeric()
            }
            .width(min: TradeColumns.Width.date, ideal: 82)
            .customizationID("closed")
        }
    }

    private func securityCell(_ row: TradeRow, showsDepot: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(row.security).lineLimit(1).truncationMode(.middle).help(row.security)
            if row.isShort {
                badge("Short").help("Sold short first and covered later")
            }
            if row.isPartial {
                badge("\(Fmt.integer(row.lotCount)) of \(Fmt.integer(row.totalLots)) lots")
                    .help("Only the lots that match the holding-period or year filter; the figures of this row cover those lots")
            }
            if showsDepot {
                // No room for the depot column: keep enough of the name to tell two depots apart.
                Text(row.depot).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: 64, alignment: .leading).layoutPriority(1)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    @TableColumnBuilder<TradeRow, KeyPathComparator<TradeRow>>
    private func valueColumns(_ tier: TradeColumns) -> some TableColumnContent<TradeRow, KeyPathComparator<TradeRow>> {
        TableColumn("Held", value: \.holdingDays) { row in
            Text(Fmt.duration(days: row.holdingDays, style: .compact))
                .numeric()
                .help(row.lotCount > 1
                    ? "Average of \(Fmt.integer(row.lotCount)) lots, weighted by shares: \(Fmt.integer(row.holdingDays)) days. The oldest lot was held \(Fmt.duration(days: row.oldestDays))."
                    : "\(Fmt.integer(row.holdingDays)) days")
        }
        .width(min: TradeColumns.Width.held, ideal: 50)
        .alignment(.trailing)
        .customizationID("held")

        if tier.showsShares {
            TableColumn("Shares", value: \.shares) { row in
                // Whole digits matter more than decimals in a narrow column; the tooltip has the exact count.
                ViewThatFits(in: .horizontal) {
                    Text(Fmt.shares(row.countedShares, maxDecimals: 4))
                    Text(Fmt.shares(row.countedShares, maxDecimals: 2))
                    Text(Fmt.shares(row.countedShares, maxDecimals: 0))
                }
                .numeric()
                .lineLimit(1)
                    .help(row.weight == ScopeWeights.full
                        ? "\(Fmt.shares(row.shares)) shares"
                        : "\(Fmt.percent(basisPoints: row.weight)) of \(Fmt.shares(row.shares)) shares are counted in this scope, like cost and value")
            }
            .width(min: TradeColumns.Width.shares, ideal: 80)
            .alignment(.trailing)
            .customizationID("shares")
        }

        TableColumn(isClosed ? "Entry Value" : "Cost", value: \.entryValue) { row in
            MoneyCell(minor: row.entryValue, currency: currency)
                .help(row.isShort ? "Net proceeds of the short sale" : "")
        }
        .width(min: TradeColumns.Width.money, ideal: 88)
        .alignment(.trailing)
        .customizationID("entry")

        TableColumn(isClosed ? "Exit Value" : "Value", value: \.exitValue) { row in
            exitCell(row)
        }
        .width(min: TradeColumns.Width.money, ideal: 88)
        .alignment(.trailing)
        .customizationID("exit")
    }

    @ViewBuilder private func exitCell(_ row: TradeRow) -> some View {
        let explanation = row.valuation.explanation(reportingCurrency: currency)
        HStack(spacing: DS.Spacing.xs) {
            if row.isValued {
                // "≈": valued without a quote, at the price of the security's own transactions.
                MoneyCell(minor: row.exitValue, currency: currency, prefix: row.valuation == .derivedPrice ? "≈\u{2009}" : "")
                    .accessibilityLabel(row.valuation == .derivedPrice ? "approximately \(Fmt.money(minor: row.exitValue, currency: currency))" : Fmt.money(minor: row.exitValue, currency: currency))
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .imageScale(.small)
                    .foregroundStyle(DS.Colors.warning)
                    .accessibilityLabel("Not valued")
                Text(Fmt.missing).foregroundStyle(.tertiary)
            }
        }
        .help(explanation ?? (row.isShort ? (row.isOpen ? "Cost of buying the shares back at today's price" : "Cost of covering the short position") : ""))
    }

    @TableColumnBuilder<TradeRow, KeyPathComparator<TradeRow>>
    private func resultColumns(_ tier: TradeColumns) -> some TableColumnContent<TradeRow, KeyPathComparator<TradeRow>> {
        if tier.showsCosts {
            TableColumn("Fees", value: \.fees) { row in
                MoneyCell(minor: row.fees, currency: currency)
                    .foregroundStyle(row.fees == 0 ? .tertiary : .primary)
            }
            .width(min: TradeColumns.Width.fees, ideal: 60)
            .alignment(.trailing)
            .customizationID("fees")
        }

        if tier.showsCosts, isClosed {
            TableColumn("Taxes", value: \.taxes) { row in
                MoneyCell(minor: row.taxes, currency: currency)
                    .foregroundStyle(row.taxes == 0 ? .tertiary : .primary)
            }
            .width(min: TradeColumns.Width.taxes, ideal: 66)
            .alignment(.trailing)
            .customizationID("taxes")
        }

        TableColumn("Gain", value: \.gain) { row in
            if row.isValued {
                ViewThatFits(in: .horizontal) {
                    GainText(money: Money(minor: row.gain, currency: currency), symbol: false)
                    GainText(Fmt.moneyRounded(Money(minor: row.gain, currency: currency), symbol: false, signed: true), trend: Trend(minor: row.gain))
                }
                .help("After fees, before taxes. Dividends received while holding are not included.")
            } else {
                Text(Fmt.missing).foregroundStyle(.tertiary).help(row.valuation.explanation(reportingCurrency: currency) ?? "")
            }
        }
        .width(min: TradeColumns.Width.gain, ideal: 90)
        .alignment(.trailing)
        .customizationID("gain")

        TableColumn("Return", value: \.returnKey) { row in
            if let value = row.returnFraction {
                GainText(percent: value)
                    .help("Price gain ÷ \(isClosed ? "entry value" : "cost"). Dividends received while holding are not included.")
            } else {
                Text(Fmt.missing).foregroundStyle(.tertiary)
            }
        }
        .width(min: TradeColumns.Width.percent, ideal: 78)
        .alignment(.trailing)
        .customizationID("return")

        TableColumn("Per Year", value: \.annualizedKey) { row in
            if let value = row.annualized {
                GainText(percent: value)
                    .help("Money-weighted annual return (IRR) of this trade's cash flows, without dividends")
            } else {
                Text(Fmt.missing)
                    .foregroundStyle(.tertiary)
                    .help(row.isValued ? "Not defined for trades opened and closed on the same day" : "")
            }
        }
        .width(min: TradeColumns.Width.percent, ideal: 78)
        .alignment(.trailing)
        .customizationID("annualized")
    }

    private var footerTotals: some View {
        // Entry and exit of a short trade are sale proceeds and the cost of covering — adding them to
        // purchase costs and market values would mean nothing, so the totals cover long trades only.
        let figures = model.figures
        let longOnly = figures.shortCount > 0 ? " (long)" : ""
        let help = figures.shortCount > 0
            ? "Long trades only. \(Fmt.integer(figures.shortCount)) short \(figures.shortCount == 1 ? "trade is" : "trades are") left out of these two totals; the gain includes \(figures.shortCount == 1 ? "it" : "them")."
            : figures.unvalued > 0 ? "Without the \(Fmt.integer(figures.unvalued)) \(figures.unvalued == 1 ? "position" : "positions") that could not be valued" : ""
        return HStack(spacing: DS.Spacing.l) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.l) {
                    total((isClosed ? "Entry" : "Cost") + longOnly, figures.longEntry).help(help)
                    total((isClosed ? "Exit" : "Value") + longOnly, figures.longExit).help(help)
                    total("Fees", figures.totalFees)
                    total("Taxes", figures.totalTaxes)
                }
                HStack(spacing: DS.Spacing.l) {
                    total("Fees", figures.totalFees)
                    total("Taxes", figures.totalTaxes)
                }
                EmptyView()
            }
            HStack(spacing: DS.Spacing.xs) {
                Text("Gain")
                if figures.valued > 0 {
                    GainText(money: Money(minor: figures.totalGain, currency: currency))
                } else {
                    Text(Fmt.missing)
                }
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
                // The list may show an earlier day; a new transaction starts from today's holding.
                let close = TradeActions.close(store.ledger, securityID: row.securityID, depotID: row.id.depotID, today: store.today)
                Button(close.title) {
                    if let prefill = TradeActions.closePrefill(close, securityID: row.securityID, depotID: row.id.depotID, today: store.today) {
                        store.present(.newTransaction(prefill))
                    }
                }
                .disabled(close == .nothingHeld)
                // Buying into a short position covers it; there is no "more" to buy.
                if !close.isCover {
                    Button("Buy More…") {
                        store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today, securityID: row.securityID, depotID: row.id.depotID)))
                    }
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
        Button("Export Trades as CSV…", action: exportCSV)
            .disabled(model.rows.isEmpty)
    }

    private func tsv(_ ids: Set<TradeRow.ID>) -> String {
        TradeExport.tsv(model.rows.filter { ids.contains($0.id) }, kind: model.kind, currency: currency)
    }

    // MARK: Sort order ⇄ text

    private static let sortKeys = ["security", "depot", "opened", "closed", "held", "shares", "entry", "exit", "fees", "taxes", "gain", "return", "annualized"]

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

    /// The launch-state form of a sort order (the inverse of `comparator`), for restoring it per window.
    static func sortKey(_ comparator: KeyPathComparator<TradeRow>) -> String? {
        for key in sortKeys {
            if let known = Self.comparator(key), known.keyPath == comparator.keyPath {
                return "\(key):\(comparator.order == .forward ? "asc" : "desc")"
            }
        }
        return nil
    }
}
