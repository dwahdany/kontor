import SwiftUI
import KontorUI

/// The positions table: sortable, customizable columns; group subtotals as disclosure rows; a
/// total line at the end. Rows arrive filtered and sorted (`HoldingsDisplay`).
struct HoldingsTable: View {
    typealias Sort = KeyPathComparator<HoldingRow>

    @Environment(PortfolioStore.self) private var store
    let display: HoldingsDisplay
    let reportingCurrency: CurrencyCode
    @Bindable var state: HoldingsViewState
    @Binding var columns: TableColumnCustomization<HoldingRow>

    var body: some View {
        // The reader lets a selection made outside the table (route, chart click) scroll into view.
        ScrollViewReader { proxy in
            table
                .onChange(of: state.revealTarget, initial: true) { _, id in scroll(to: id, with: proxy) }
        }
    }

    private func scroll(to id: String?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        Task { @MainActor in
            // First after the table has taken in the rows of a group that was just expanded; then
            // again, because a far jump lands by estimated row heights and the rows on the way are
            // only measured once they have been on screen.
            for delay in [60, 120, 120] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard state.revealTarget == id else { return }
                // No anchor: the least scrolling that shows the row — none if it is visible already.
                proxy.scrollTo(id)
            }
            if state.revealTarget == id { state.revealTarget = nil }
        }
    }

    private var table: some View {
        Table(of: HoldingRow.self, selection: $state.selection, sortOrder: $state.options.sortOrder, columnCustomization: $columns) {
            identityColumns
            valueColumns
            performanceColumns
            optionalColumns
        } rows: {
            // Subtotal lines are ordinary rows and collapsing simply leaves a group's rows out. (An
            // outline — DisclosureTableRow — re-enters the table update when large groups arrive.)
            ForEach(state.visibleLines) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            HoldingsRowMenu(store: store, rows: rows(ids))
        } primaryAction: { ids in
            if let row = rows(ids).first(where: \.isEntity) {
                HoldingsActions.open(row, in: store)
            } else if let id = ids.first, display.rowsByID[id]?.kind == .group {
                toggle(id)
            }
        }
        .onKeyPress(.rightArrow) { setSelectedGroups(collapsed: false) }
        .onKeyPress(.leftArrow) { setSelectedGroups(collapsed: true) }
        .onCopyCommand {
            let rows = state.selectedRows.isEmpty ? display.lines : state.selectedRows
            return [NSItemProvider(object: HoldingsExport.tsv(rows, reportingCurrency: reportingCurrency) as NSString)]
        }
        .accessibilityLabel("Holdings")
    }

    private func rows(_ ids: Set<String>) -> [HoldingRow] {
        display.lines.filter { ids.contains($0.id) }
    }

    private func toggle(_ id: String) {
        if state.collapsed.contains(id) { state.collapsed.remove(id) } else { state.collapsed.insert(id) }
    }

    /// ← collapses and → expands the selected group lines, like an outline.
    private func setSelectedGroups(collapsed: Bool) -> KeyPress.Result {
        let groups = state.selection.filter { display.rowsByID[$0]?.kind == .group }
        guard !groups.isEmpty else { return .ignored }
        if collapsed { state.collapsed.formUnion(groups) } else { state.collapsed.subtract(groups) }
        return .handled
    }

    // MARK: Columns

    @TableColumnBuilder<HoldingRow, Sort> private var identityColumns: some TableColumnContent<HoldingRow, Sort> {
        TableColumn("Name", value: \.name) { row in
            // One fixed height for every kind of line: uniform rows keep AppKit's automatic
            // row-height bookkeeping from re-entering itself when many rows arrive at once.
            HoldingNameCell(row: row, isCollapsed: state.collapsed.contains(row.id)) { toggle(row.id) }
                .frame(height: 32)
        }
        .width(min: 186, ideal: 204)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)

        TableColumn("Shares", value: \.sharesSort) { row in
            if let shares = row.shares {
                // Never an ellipsis in a number: large counts drop decimals instead (all of them
                // are in the tooltip), and the text does not truncate.
                OneLineCell {
                    NumberText(Fmt.shares(shares, maxDecimals: HoldingsFormat.shareDecimals(shares)), row: row)
                        .fixedSize()
                }
                .help(row.assignedWeight.map { "\(Fmt.shares(shares)) shares — \(Fmt.percent(basisPoints: $0)) of the position" } ?? "\(Fmt.shares(shares)) shares")
            }
        }
        .width(min: 76, ideal: 84)
        .alignment(.trailing)
        .customizationID("shares")

        TableColumn("Price", value: \.priceSort) { row in
            HoldingPriceCell(row: row)
        }
        .width(min: 72, ideal: 84)
        .alignment(.trailing)
        .customizationID("price")

        TableColumn("Day", value: \.dayChangeSort) { row in
            if let change = row.dayChange {
                TwoLineCell {
                    ReturnText(value: change, isEmphasized: row.isSummary)
                } secondary: {
                    Text(row.dayChangeAmount.map { HoldingsFormat.money($0, currency: reportingCurrency, signed: true) } ?? " ")
                }
                .help(HoldingsFormat.dayChangeHelp(row, reportingCurrency: reportingCurrency))
            }
        }
        .width(min: 68, ideal: 72)
        .alignment(.trailing)
        .customizationID("day")
    }

    @TableColumnBuilder<HoldingRow, Sort> private var valueColumns: some TableColumnContent<HoldingRow, Sort> {
        TableColumn("Value", value: \.value) { row in
            // Closed positions (and their subtotal) have no value on the statement day.
            if row.kind != .closed, row.id != HoldingsBase.closedGroupID {
                TwoLineCell {
                    if row.isValued {
                        NumberText(HoldingsFormat.money(row.value, currency: reportingCurrency), row: row)
                            .help(HoldingsFormat.exact(row.value, currency: reportingCurrency))
                    } else {
                        // Says what is missing — a price or an exchange rate — and never truncates.
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                            Text(HoldingsFormat.issueTitle(row))
                        }
                        .fixedSize()
                        .foregroundStyle(DS.Colors.warning)
                        .help(HoldingsFormat.issueHelp(row, reportingCurrency: reportingCurrency))
                        .accessibilityElement(children: .combine)
                    }
                } secondary: {
                    // The value in the security's own currency, where that differs.
                    if let local = row.localValue, row.currency != reportingCurrency {
                        Text(HoldingsFormat.money(local, currency: row.currency))
                    } else {
                        Text(" ")
                    }
                }
            }
        }
        .width(min: 88, ideal: 98)
        .alignment(.trailing)
        .customizationID("value")

        TableColumn("Weight", value: \.weightSort) { row in
            HoldingWeightCell(row: row, maximum: display.maxWeight)
        }
        .width(min: 52, ideal: 58)
        .alignment(.trailing)
        .customizationID("weight")

        TableColumn("Cost Basis", value: \.costSort) { row in
            if let cost = row.costBasis {
                TwoLineCell {
                    NumberText(HoldingsFormat.money(cost, currency: reportingCurrency), row: row)
                        .help(HoldingsFormat.exact(cost, currency: reportingCurrency))
                } secondary: {
                    Text(row.purchasePrice.map { "@ " + Fmt.price($0, currency: reportingCurrency) } ?? " ")
                }
            }
        }
        .width(min: 88, ideal: 98)
        .alignment(.trailing)
        .customizationID("cost")

        TableColumn("Unrealized Gain", value: \.gainSort) { row in
            if let gain = row.gain, row.costBasis != nil {
                TwoLineCell {
                    GainText(HoldingsFormat.money(gain, currency: reportingCurrency, signed: true), trend: Trend(minor: gain))
                        .fontWeight(row.isSummary ? .semibold : .regular)
                        .help(HoldingsFormat.exact(gain, currency: reportingCurrency, signed: true))
                } secondary: {
                    Text(row.gainFraction.map { Fmt.percent($0, signed: true) } ?? " ")
                }
            }
        }
        .width(min: 92, ideal: 96)
        .alignment(.trailing)
        .customizationID("gain")
    }

    @TableColumnBuilder<HoldingRow, Sort> private var performanceColumns: some TableColumnContent<HoldingRow, Sort> {
        TableColumn("TTWROR", value: \.ttwrorSort) { row in
            if let value = row.ttwror {
                OneLineCell { ReturnText(value: value, isEmphasized: row.isSummary) }
            }
        }
        .width(min: 66, ideal: 68)
        .alignment(.trailing)
        .customizationID("ttwror")

        TableColumn("IRR", value: \.irrSort) { row in
            if let value = row.irr {
                OneLineCell { ReturnText(value: value, isEmphasized: row.isSummary) }
            }
        }
        .width(min: 66, ideal: 68)
        .alignment(.trailing)
        .customizationID("irr")

        TableColumn("Dividends", value: \.dividendsSort) { row in
            if let dividends = row.dividends, dividends != 0 {
                // The period's dividends only. (A yield next to it would have to be annual — see
                // the "Yield on Cost" column — and would not belong to this sum.)
                OneLineCell {
                    NumberText(HoldingsFormat.money(dividends, currency: reportingCurrency), row: row)
                }
                .help("Dividends received in the reporting period (gross). \(HoldingsFormat.exact(dividends, currency: reportingCurrency))")
            }
        }
        .width(min: 72, ideal: 78)
        .alignment(.trailing)
        .customizationID("dividends")

        TableColumn("90 Days", value: \.trendSort) { row in
            if row.spark.count >= 2 {
                Sparkline(row.spark)
                    .frame(width: DS.Size.sparkline.width, height: DS.Size.sparkline.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .width(min: 76, ideal: 76)
        .alignment(.trailing)
        .customizationID("trend")
    }

    /// Hidden until the user adds them from the header's context menu.
    @TableColumnBuilder<HoldingRow, Sort> private var optionalColumns: some TableColumnContent<HoldingRow, Sort> {
        TableColumn("Value (Local)", value: \.localValueSort) { row in
            if let local = row.localValue {
                OneLineCell {
                    NumberText(HoldingsFormat.money(local, currency: row.currency), row: row)
                        .help(HoldingsFormat.exact(local, currency: row.currency))
                }
            }
        }
        .width(min: 90, ideal: 112)
        .alignment(.trailing)
        .customizationID("localValue")
        .defaultVisibility(.hidden)

        TableColumn("Currency", value: \.currency) { row in
            if !row.isSummary || row.localValue != nil {
                Text(row.currency).foregroundStyle(.secondary)
            }
        }
        .width(min: 50, ideal: 64)
        .customizationID("currency")
        .defaultVisibility(.hidden)

        TableColumn("Purchase Price", value: \.purchasePriceSort) { row in
            if let price = row.purchasePrice {
                OneLineCell { NumberText(Fmt.price(price, currency: reportingCurrency), row: row) }
            }
        }
        .width(min: 80, ideal: 100)
        .alignment(.trailing)
        .customizationID("purchasePrice")
        .defaultVisibility(.hidden)

        TableColumn("Gain %", value: \.gainFractionSort) { row in
            if let value = row.gainFraction {
                OneLineCell { ReturnText(value: value, isEmphasized: row.isSummary) }
            }
        }
        .width(min: 64, ideal: 78)
        .alignment(.trailing)
        .customizationID("gainPercent")
        .defaultVisibility(.hidden)

        TableColumn("Yield on Cost", value: \.yieldSort) { row in
            // Annual by construction: the dividends of the twelve months before the statement
            // day over the cost basis — the same whatever reporting period the window shows.
            if let value = row.yieldOnCost {
                OneLineCell { NumberText(Fmt.percent(value), row: row) }
                    .help(row.trailingDividends.map {
                        "Dividends of the last 12 months (\(Fmt.money(minor: $0, currency: reportingCurrency))) ÷ cost basis. Independent of the reporting period."
                    } ?? "Dividends of the last 12 months ÷ cost basis.")
            }
        }
        .width(min: 70, ideal: 90)
        .alignment(.trailing)
        .customizationID("yieldOnCost")
        .defaultVisibility(.hidden)

        TableColumn("Realized Gain", value: \.realizedSort) { row in
            if let realized = row.realized, realized != 0 || row.kind == .closed {
                OneLineCell {
                    GainText(HoldingsFormat.money(realized, currency: reportingCurrency, signed: true), trend: Trend(minor: realized))
                        .fontWeight(row.isSummary ? .semibold : .regular)
                        .help(HoldingsFormat.exact(realized, currency: reportingCurrency, signed: true))
                }
            }
        }
        .width(min: 90, ideal: 108)
        .alignment(.trailing)
        .customizationID("realized")
        .defaultVisibility(.hidden)
    }
}

// MARK: - Cells

/// Texts of the table that depend on a row's figures — pure, so tests can pin them down.
enum HoldingsFormat {
    /// Decimals of a share count that fit the column without an ellipsis: four for ordinary
    /// holdings, fewer for very large counts. The tooltip always has the full precision.
    static func shareDecimals(_ shares: Shares) -> Int {
        let magnitude = abs(shares.doubleValue)
        return magnitude < 10_000 ? 4 : magnitude < 1_000_000 ? 2 : 0
    }

    /// A return that fits its column: two decimals up to ±1 000 %, none up to ±10 000 %, beyond
    /// that only "more than" (such figures come from tiny bases or very short periods).
    static func compactReturn(_ value: Double) -> String {
        guard value.isFinite else { return Fmt.missing }
        let magnitude = abs(value)
        if magnitude < 10 { return Fmt.percent(value, signed: true) }
        if magnitude < 100 { return Fmt.percent(value, decimals: 0, signed: true) }
        return (value > 0 ? "> " : "< ") + Fmt.percent(value > 0 ? 99.99 : -99.99, decimals: 0, signed: true)
    }

    /// Amounts of a million and more are shown without cents so they never end in an ellipsis
    /// (the cell's tooltip has the exact figure).
    static func isCompact(_ minor: Int64) -> Bool { minor.magnitude >= 100_000_000 }

    static func money(_ minor: Int64, currency: CurrencyCode, signed: Bool = false) -> String {
        isCompact(minor)
            ? Fmt.moneyRounded(Money(minor: minor, currency: currency), signed: signed)
            : Fmt.money(minor: minor, currency: currency, signed: signed)
    }

    /// The exact amount for the tooltip of a compacted cell; empty (no tooltip) otherwise.
    static func exact(_ minor: Int64?, currency: CurrencyCode, signed: Bool = false) -> String {
        guard let minor, isCompact(minor) else { return "" }
        return Fmt.money(minor: minor, currency: currency, signed: signed)
    }

    static func issueTitle(_ row: HoldingRow) -> String {
        switch row.valuationIssue {
        case .noExchangeRate: "No \(row.currency) rate"
        case .noPrice, nil: "No price"
        }
    }

    static func issueHelp(_ row: HoldingRow, reportingCurrency: CurrencyCode) -> String {
        switch row.valuationIssue {
        case .noExchangeRate:
            "No exchange rate from \(row.currency) to \(reportingCurrency) is known, so this \(row.kind == .cash ? "balance" : "position") cannot be valued and counts as zero. Add \(row.currency) rates (Update Quotes fetches them), or see Portfolio ▸ Check Consistency."
        case .noPrice, nil:
            "This position has no price and counts as zero. Add a quote for the security."
        }
    }

    static func dayChangeHelp(_ row: HoldingRow, reportingCurrency: CurrencyCode) -> String {
        let since = row.dayChangeSince.map { Fmt.day($0, style: .medium) }
        if row.isSummary {
            return "Change in value of these lines since the previous quotes\(since.map { " (earliest: \($0))" } ?? ""), exchange-rate moves included, relative to the value of all of them."
        }
        if row.kind == .cash {
            return "Exchange-rate move of the \(row.currency) balance\(since.map { " since \($0)" } ?? ""), in \(reportingCurrency)."
        }
        var text = "Change in value in \(reportingCurrency)\(since.map { " since the quote of \($0)" } ?? ""), shares unchanged."
        if row.currency != reportingCurrency, let quote = row.quoteChange {
            text += " The quote moved \(Fmt.percent(quote, signed: true)) in \(row.currency); the rest is the exchange rate."
        }
        return text
    }
}

/// A signed, colored return that never truncates (see `HoldingsFormat.compactReturn`).
struct ReturnText: View {
    let value: Double
    var isEmphasized = false

    var body: some View {
        if abs(value) < 10 {
            GainText(percent: value).fontWeight(isEmphasized ? .semibold : .regular)
        } else {
            GainText(HoldingsFormat.compactReturn(value), trend: value.isFinite ? Trend(value) : .flat)
                .fontWeight(isEmphasized ? .semibold : .regular)
                .help(Fmt.percent(value, signed: true))
        }
    }
}

/// A number in tabular digits; summary lines are emphasized.
private struct NumberText: View {
    let text: String
    let row: HoldingRow

    init(_ text: String, row: HoldingRow) {
        self.text = text
        self.row = row
    }

    var body: some View {
        Text(text)
            .numeric()
            .fontWeight(row.isSummary ? .semibold : .regular)
            .foregroundStyle(row.kind == .closed ? .secondary : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

/// A value with a quieter second line, trailing-aligned.
private struct TwoLineCell<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            primary
            secondary
                .font(.caption)
                .numeric()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A single value on the first line of a two-line row, so numbers share a baseline across columns.
private struct OneLineCell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        TwoLineCell {
            content
        } secondary: {
            Text(" ")
        }
    }
}

private struct HoldingNameCell: View {
    let row: HoldingRow
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        switch row.kind {
        case .group:
            HStack(spacing: DS.Spacing.s) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand group (→)" : "Collapse group (←)")
                .accessibilityLabel(isCollapsed ? "Expand \(row.name)" : "Collapse \(row.name)")
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(row.colorIndex == nil && row.colorHex == nil ? ChartColors.neutral : ChartColors.classification(row.colorHex, fallbackIndex: row.colorIndex ?? Int.max))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).fontWeight(.semibold)
                    Text(row.detail.isEmpty ? HoldingsDisplay.holdings(row.count) : "\(row.detail) · \(HoldingsDisplay.holdings(row.count))")
                        .font(.caption)
                        .numeric()
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        case .total:
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).fontWeight(.semibold)
                Text(row.detail).font(.caption).numeric().foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case .position, .cash, .closed:
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .truncationMode(.middle)
                    .foregroundStyle(row.kind == .closed ? .secondary : .primary)
                    .help(row.name)
                Text(secondary)
                    .font(.caption)
                    .numeric()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            // Under a subtotal line, rows are indented to the group's color swatch.
            .padding(.leading, row.groupID == nil ? 0 : 24)
        }
    }

    /// The cue for a partial position comes first: it must survive truncation, the identifiers
    /// need not.
    private var secondary: String {
        var parts: [String] = []
        if let weight = row.assignedWeight { parts.append("\(Fmt.percent(basisPoints: weight, decimals: weight % 100 == 0 ? 0 : 2)) of the position") }
        parts.append(row.detail)
        if row.kind == .closed { parts.append("closed in period") }
        return parts.joined(separator: " · ")
    }
}

private struct HoldingPriceCell: View {
    let row: HoldingRow

    var body: some View {
        if let price = row.price {
            TwoLineCell {
                Text(Fmt.price(price, currency: row.currency)).numeric()
            } secondary: {
                if let day = row.priceDay {
                    if row.isStale {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                            Text(Fmt.day(day, style: .dayMonth))
                        }
                        .foregroundStyle(DS.Colors.warning)
                        .help("Stale price: the latest quote is from \(Fmt.day(day, style: .medium)).")
                        .accessibilityLabel("Stale price from \(Fmt.day(day, style: .medium))")
                    } else {
                        Text(Fmt.day(day, style: .dayMonth))
                    }
                }
            }
        } else if row.kind == .position {
            Text("No price")
                .foregroundStyle(DS.Colors.warning)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Weight as a number plus a bar relative to the largest line, so the eye can rank without reading.
private struct HoldingWeightCell: View {
    let row: HoldingRow
    let maximum: Double

    var body: some View {
        if let weight = row.weight, row.kind != .closed, row.id != HoldingsBase.closedGroupID {
            TwoLineCell {
                NumberText(Fmt.percent(weight, decimals: 1), row: row)
            } secondary: {
                // The bar sits in the second text line.
                Text(" ")
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if !row.isSummary {
                            GeometryReader { proxy in
                                let fraction = maximum > 0 ? min(1, max(0, weight / maximum)) : 0
                                Capsule()
                                    .fill(.tint.opacity(0.55))
                                    .frame(width: max(2, proxy.size.width * fraction), height: 3)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Row actions

/// The context menu of the table (also used by the inspector's action menu).
struct HoldingsRowMenu: View {
    /// Passed in rather than read from the environment: menus are hosted outside the view tree.
    let store: PortfolioStore
    let rows: [HoldingRow]

    var body: some View {
        let entities = rows.filter(\.isEntity)
        if let row = entities.first, entities.count == 1 {
            if row.securityID != nil {
                Button("Buy…", systemImage: "plus.circle") { HoldingsActions.buy(row, in: store) }
                    .keyboardShortcut(HoldingsShortcut.buy.key, modifiers: HoldingsShortcut.buy.modifiers)
                Button("Sell…", systemImage: "minus.circle") { HoldingsActions.sell(row, in: store) }
                    .keyboardShortcut(HoldingsShortcut.sell.key, modifiers: HoldingsShortcut.sell.modifiers)
                    .disabled(row.kind != .position)
                Button("Record Dividend…", systemImage: "banknote") { HoldingsActions.recordDividend(row, in: store) }
                    .keyboardShortcut(HoldingsShortcut.dividend.key, modifiers: HoldingsShortcut.dividend.modifiers)
                Divider()
                Button("Open Security", systemImage: "building.columns") { HoldingsActions.open(row, in: store) }
                Button("Show Transactions", systemImage: "list.bullet.rectangle") { HoldingsActions.showTransactions(row, in: store) }
                    .keyboardShortcut(HoldingsShortcut.transactions.key, modifiers: HoldingsShortcut.transactions.modifiers)
                Button("Show Performance", systemImage: "chart.xyaxis.line") { HoldingsActions.showPerformance(row, in: store) }
                Button("Edit Security…", systemImage: "pencil") { HoldingsActions.edit(row, in: store) }
            } else {
                Button("Deposit…", systemImage: "arrow.down.circle") { HoldingsActions.deposit(row, in: store) }
                Button("Withdraw…", systemImage: "arrow.up.circle") { HoldingsActions.withdraw(row, in: store) }
                Divider()
                Button("Open Account", systemImage: "creditcard") { HoldingsActions.open(row, in: store) }
                Button("Show Transactions", systemImage: "list.bullet.rectangle") { HoldingsActions.showTransactions(row, in: store) }
                    .keyboardShortcut(HoldingsShortcut.transactions.key, modifiers: HoldingsShortcut.transactions.modifiers)
                Button("Edit Account…", systemImage: "pencil") { HoldingsActions.edit(row, in: store) }
            }
            Divider()
        }
        Button(rows.isEmpty ? "Copy Table" : rows.count == 1 ? "Copy Row" : "Copy \(rows.count) Rows", systemImage: "doc.on.doc") {
            HoldingsActions.copy(rows, in: store)
        }
        .keyboardShortcut("c", modifiers: .command)
        Button("Export Table as CSV…", systemImage: "square.and.arrow.up") { HoldingsActions.exportCSV(in: store) }
    }
}
