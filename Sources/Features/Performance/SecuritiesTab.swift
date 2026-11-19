import SwiftUI
import KontorUI

/// "Securities": what each security contributed in the period. Sortable; Return opens the
/// security, ⌘C copies the selection as TSV.
struct SecuritiesTab: View {
    @Environment(PortfolioStore.self) private var store
    @Binding var model: Loadable<SecuritiesModel>
    let compare: [UUID]
    let addComparison: (UUID) -> Void

    @SceneStorage("performance.securities.columns") private var columns: TableColumnCustomization<SecurityRow>
    @State private var filter = ""
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\SecurityRow.absolutePerformance, order: .reverse)]
    @State private var showsRemainder = false

    private var rows: [SecurityRow] { model.value?.rows ?? [] }
    private var currency: CurrencyCode { model.value?.currency ?? store.baseCurrency }
    private var irrIsAnnualized: Bool { model.value?.irrIsAnnualized ?? true }

    var body: some View {
        let query = SecuritiesQuery(filter: filter, sortOrder: sortOrder)
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.m) {
                    Text("Performance by Security").font(.headline)
                    HelpButton(.absolutePerformance)
                    Text("Amounts in \(currency)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    QuickFilterField(text: $filter, prompt: "Filter securities")
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, DS.Spacing.m)
                Divider()
                table
                    .frame(height: tableHeight)
                    .opacity(model.isRefreshing ? 0.7 : 1)
                    .overlay {
                        if model.value != nil, rows.isEmpty {
                            Text(filter.isEmpty ? "No security was held or traded in this period" : "No security matches “\(filter)”")
                                .font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                footer
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .analysisTask($model, id: "performance.securities", variant: query) { SecuritiesModel($0, query: query) }
        .onAppear(perform: readLaunchState)
        .onChange(of: store.route.securityID, initial: true) { _, id in
            if let id, selection != [id] { selection = [id] }
        }
        .onChange(of: selection) { _, ids in
            store.setFocus(ids.count == 1 ? .security(ids.first!) : nil)
        }
    }

    private var tableHeight: CGFloat {
        let wanted = CGFloat(max(rows.count, 4)) * 24 + 46
        return min(wanted, 560)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            Group {
                // The name is the row's identity: it gets the slack, the figures stay compact.
                TableColumn("Security", value: \.name) { (row: SecurityRow) in nameCell(row) }
                    .width(min: 170, ideal: 212)
                    .customizationID("name")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("Value", value: \.marketValue) { (row: SecurityRow) in plainMoney(row.marketValue) }
                    .width(min: 76, ideal: 86)
                    .alignment(.trailing)
                    .customizationID("value")
                TableColumn("TTWROR", value: \.ttwror) { (row: SecurityRow) in percentCell(row.ttwror) }
                    .width(min: 64, ideal: 76)
                    .alignment(.trailing)
                    .customizationID("ttwror")
                TableColumn(irrIsAnnualized ? "IRR per Year" : "IRR", value: \.irrKey) { (row: SecurityRow) in percentCell(row.irr) }
                    .width(min: 62, ideal: 72)
                    .alignment(.trailing)
                    .customizationID("irr")
                TableColumn("Gain", value: \.absolutePerformance) { (row: SecurityRow) in gainCell(row.absolutePerformance, dashForZero: false) }
                    .width(min: 80, ideal: 88)
                    .alignment(.trailing)
                    .customizationID("gain")
            }
            Group {
                TableColumn("Realized", value: \.realized) { (row: SecurityRow) in gainCell(row.realized, dashForZero: true) }
                    .width(min: 72, ideal: 82)
                    .alignment(.trailing)
                    .customizationID("realized")
                TableColumn("Unrealized", value: \.unrealized) { (row: SecurityRow) in gainCell(row.unrealized, dashForZero: true) }
                    .width(min: 76, ideal: 86)
                    .alignment(.trailing)
                    .customizationID("unrealized")
                TableColumn("Dividends", value: \.dividends) { (row: SecurityRow) in plainMoney(row.dividends) }
                    .width(min: 66, ideal: 74)
                    .alignment(.trailing)
                    .customizationID("dividends")
                TableColumn("Fees", value: \.fees) { (row: SecurityRow) in plainMoney(row.fees) }
                    .width(min: 52, ideal: 62)
                    .alignment(.trailing)
                    .customizationID("fees")
                TableColumn("Taxes", value: \.taxes) { (row: SecurityRow) in plainMoney(row.taxes) }
                    .width(min: 52, ideal: 66)
                    .alignment(.trailing)
                    .customizationID("taxes")
                TableColumn("% of Result", value: \.shareKey) { (row: SecurityRow) in shareCell(row.share) }
                    .width(min: 60, ideal: 70)
                    .alignment(.trailing)
                    .customizationID("share")
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open Security") { ids.first.map { store.navigate(to: .security($0)) } }.disabled(ids.count != 1)
            Button("Compare in Chart") { ids.forEach(addComparison) }
                .disabled(ids.isEmpty || ids.allSatisfy(compare.contains))
            Button("Show Transactions") { ids.first.map(showTransactions) }.disabled(ids.count != 1)
            Divider()
            Button("Copy") { Pasteboard.copy(SecuritiesModel.tsv(rows.filter { ids.contains($0.id) }, currency: currency, irrIsAnnualized: irrIsAnnualized)) }
                .disabled(ids.isEmpty)
        } primaryAction: { ids in
            ids.first.map { store.navigate(to: .security($0)) }
        }
        .onCopyCommand {
            // Nothing selected: nothing to copy (not a lone header line).
            let selected = rows.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return [] }
            return [NSItemProvider(object: SecuritiesModel.tsv(selected, currency: currency, irrIsAnnualized: irrIsAnnualized) as NSString)]
        }
    }

    /// Like `TableFooter` (which can only pluralize by appending "s").
    private var footer: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(countText)
            Spacer(minLength: DS.Spacing.s)
            if let m = model.value {
                HStack(spacing: DS.Spacing.m) {
                    footerFigure("Securities", m.securitiesResult)
                    remainderFigure(m)
                    footerFigure("Total", m.totalResult).fontWeight(.medium)
                }
                .help("The securities' gains plus everything not tied to a security add up to the period's performance")
            }
        }
        .font(.callout)
        .numeric()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider() }
    }

    private var countText: String {
        let count = rows.count
        var parts = ["\(Fmt.integer(count)) \(count == 1 ? "security" : "securities")"]
        if let total = model.value?.totalCount, total != count { parts[0] += " of \(Fmt.integer(total))" }
        // Only rows that are listed count: a focused security may not be part of this period.
        let selected = rows.count { selection.contains($0.id) }
        if selected > 0 { parts.append("\(Fmt.integer(selected)) selected") }
        return parts.joined(separator: " · ")
    }

    private func footerFigure(_ label: String, _ minor: Int64) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(label)
            Text(Fmt.money(minor: minor, currency: currency, signed: true)).foregroundStyle(.primary)
        }
    }

    /// Everything that is not a security's result, with what it is made of behind the ⓘ.
    private func remainderFigure(_ m: SecuritiesModel) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            footerFigure("Not tied to a security", m.totalResult - m.securitiesResult)
            if !m.remainder.isEmpty {
                Button("What is not tied to a security", systemImage: "info.circle") { showsRemainder.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show what this is made of")
                    .popover(isPresented: $showsRemainder, arrowEdge: .top) { remainderBreakdown(m) }
            }
        }
    }

    private func remainderBreakdown(_ m: SecuritiesModel) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Not Tied to a Security").font(.headline)
            Text("Earnings and costs of the period that belong to an account rather than a security. The Taxes column above lists only what was withheld on a security's sales and dividends.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(m.remainder) { part in
                KeyValueRow(part.label) { SignedMoney(minor: part.amount, currency: m.currency) }
            }
            Divider()
            KeyValueRow("Total") { SignedMoney(minor: m.totalResult - m.securitiesResult, currency: m.currency) }
                .fontWeight(.medium)
        }
        .numeric()
        .padding(DS.Spacing.l)
        .frame(width: 320)
    }

    private func nameCell(_ row: SecurityRow) -> some View {
        var tooltip: String = row.symbol.isEmpty ? row.name : row.name + " · " + row.symbol
        if let issue = row.priceIssue { tooltip += "\n" + issue.explanation }
        return HStack(spacing: DS.Spacing.xs) {
            Text(row.name).lineLimit(1).foregroundStyle(row.isHeld ? Color.primary : Color.secondary)
            if !row.isHeld {
                Text("sold").font(.caption).foregroundStyle(.tertiary)
            }
            if let issue = row.priceIssue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.warning)
                    .accessibilityLabel(issue.explanation)
            }
        }
        .help(tooltip)
    }

    private func percentCell(_ value: Double?) -> some View {
        SignedPercent(value: value).numeric().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func shareCell(_ value: Double?) -> some View {
        SignedPercent(value: value, decimals: 1).numeric().frame(maxWidth: .infinity, alignment: .trailing)
            .help("This security's gain or loss relative to the size of the total result")
    }

    private func gainCell(_ minor: Int64, dashForZero: Bool) -> some View {
        SignedMoney(minor: minor, currency: currency, dashForZero: dashForZero, symbol: false)
            .numeric()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func plainMoney(_ minor: Int64) -> some View {
        Text(minor == 0 ? Fmt.missing : Fmt.money(Money(minor: minor, currency: currency), symbol: false))
            .numeric()
            .foregroundStyle(minor == 0 ? Color.secondary.opacity(0.6) : Color.primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func showTransactions(_ id: UUID) {
        // The routing contract's "Show Transactions": the ledger, listing exactly this security's entries.
        store.navigate(to: Route(.transactions, focus: .security(id)))
    }

    private func readLaunchState() {
        if let text = store.launchValue("filter") { filter = text }

        switch store.launchValue("sort") {
        case "name": sortOrder = [KeyPathComparator(\.name, order: .forward)]
        case "value": sortOrder = [KeyPathComparator(\.marketValue, order: .reverse)]
        case "ttwror": sortOrder = [KeyPathComparator(\.ttwror, order: .reverse)]
        case "irr": sortOrder = [KeyPathComparator(\.irrKey, order: .reverse)]
        case "gain": sortOrder = [KeyPathComparator(\.absolutePerformance, order: .reverse)]
        case "share": sortOrder = [KeyPathComparator(\.shareKey, order: .reverse)]
        default: break
        }
    }
}
