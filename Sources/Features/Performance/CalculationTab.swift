import SwiftUI
import KontorUI

/// "Calculation": how the initial value became the final value — as a reconciling statement and a
/// waterfall. Selecting a line lists the transactions (and securities) behind it.
struct CalculationTab: View {
    @Environment(PortfolioStore.self) private var store
    @Binding var model: Loadable<CalculationModel>
    @Binding var selectedLine: StatementLine?
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            if isWide {
                HStack(alignment: .top, spacing: DS.Spacing.l) {
                    statement.frame(width: 440)
                    waterfall
                }
            } else {
                statement
                waterfall
            }
            if let line = selectedLine, let model = model.value {
                LineDetailCard(line: line, amount: model.amount(line), currency: model.currency) { selectedLine = nil }
            }
        }
        .opacity(model.isRefreshing ? 0.6 : 1)
        .analysisTask($model, id: "performance.calculation") { CalculationModel($0) }
    }

    private var statement: some View {
        Card("Statement", symbol: "list.bullet.indent") {
            if let model = model.value {
                StatementList(model: model, selection: $selectedLine)
            } else {
                Color.clear.frame(height: 320)
            }
        } accessory: {
            Text("Select a line to see what is behind it")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var waterfall: some View {
        Card("From Initial to Final Value", symbol: "chart.bar.doc.horizontal") {
            WaterfallChart(model.value?.waterfall ?? [], format: .money(model.value?.currency ?? store.baseCurrency),
                           title: "Performance breakdown")
                .selection { id in
                    let line = StatementLine(rawValue: id)
                    selectedLine = selectedLine == line ? nil : line
                }
                .loading(model.isLoading)
                .emptyMessage("Nothing to break down in this period")
        }
    }
}

/// The statement: totals, flows, components and subtotals; keyboard navigable (↑ ↓, Esc).
private struct StatementList: View {
    let model: CalculationModel
    @Binding var selection: StatementLine?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.entries) { entry in
                if entry.line == .netFlows || entry.line == .performance { rule(strong: false) }
                if entry.line == .finalValue { rule(strong: true) }
                StatementRow(entry: entry, currency: model.currency, isSelected: selection == entry.line, isFocused: isFocused) {
                    selection = selection == entry.line ? nil : entry.line
                    isFocused = true
                }
                if entry.line == .initialValue || entry.line == .netFlows { Color.clear.frame(height: DS.Spacing.xs) }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let lines = model.entries.map(\.line)
            guard !lines.isEmpty else { return }
            let current = selection.flatMap(lines.firstIndex(of:))
            switch direction {
            case .down: selection = lines[min((current ?? -1) + 1, lines.count - 1)]
            case .up: selection = lines[max((current ?? lines.count) - 1, 0)]
            default: break
            }
        }
        .onExitCommand { selection = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Performance statement")
    }

    private func rule(strong: Bool) -> some View {
        Rectangle()
            .fill(DS.Colors.hairline.opacity(strong ? 1 : 0.7))
            .frame(height: strong ? 1 : 0.5)
            .padding(.vertical, DS.Spacing.xs)
    }
}

private struct StatementRow: View {
    @Environment(\.gainStyle) private var gainStyle
    let entry: StatementEntry
    let currency: CurrencyCode
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(entry.line.title)
                    if let topic = entry.line.helpTopic { HelpButton(topic) }
                }
                if entry.currencyPart != nil {
                    Text("of which exchange rates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, entry.line.role == .component ? DS.Spacing.l : 0)
            Spacer(minLength: DS.Spacing.s)
            VStack(alignment: .trailing, spacing: 0) {
                amount
                if let part = entry.currencyPart {
                    Text(Fmt.money(minor: part, currency: currency, signed: true))
                        .font(.caption)
                        .numeric()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(entry.line.role == .component ? .body : .body.weight(.semibold))
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }

    @ViewBuilder private var amount: some View {
        switch entry.line.role {
        case .total:
            Text(Fmt.money(minor: entry.amount, currency: currency)).numeric()
        case .subtotal:
            if entry.line == .netFlows {
                // Your own money moving — signed, but neither a gain nor a loss.
                Text(Fmt.money(minor: entry.amount, currency: currency, signed: true)).numeric()
            } else {
                GainText(money: Money(minor: entry.amount, currency: currency))
            }
        case .component:
            if entry.amount == 0 {
                Text(Fmt.missing).foregroundStyle(.tertiary)
            } else if StatementLine.flowLines.contains(entry.line) {
                Text(Fmt.money(minor: entry.amount, currency: currency, signed: true)).numeric()
            } else {
                GainText(money: Money(minor: entry.amount, currency: currency))
            }
        }
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(isFocused ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.1)) }
        return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.05 : 0))
    }
}

/// The entries behind one statement line.
private struct LineDetailCard: View {
    @Environment(PortfolioStore.self) private var store
    let line: StatementLine
    let amount: Int64
    let currency: CurrencyCode
    let close: () -> Void

    @State private var detail = Loadable<LineDetail>()
    @State private var sortOrder = [KeyPathComparator(\ContributionRow.date, order: .reverse)]
    @State private var selection = Set<UUID>()

    /// The loaded detail, unless it still belongs to the previously selected line.
    private var current: LineDetail? { detail.value.flatMap { $0.line == line ? $0 : nil } }

    var body: some View {
        let query = LineDetailQuery(line: line, sortOrder: sortOrder)
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text(line.title).font(.headline)
                    if let topic = line.helpTopic { HelpButton(topic) }
                    Text(Fmt.money(minor: amount, currency: currency, signed: line.role != .total))
                        .font(.headline)
                        .numeric()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Close")
                }
                Text(line.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = current {
                    content(detail)
                }
            }
        }
        .opacity(detail.isRefreshing ? 0.7 : 1)
        .analysisTask($detail, id: "performance.calculation.detail", variant: query) { LineDetail($0, query: query) }
        .onChange(of: line) { _, _ in selection = [] }
        // Rows disappear (delete, undo, another period or scope): a selection never outlives them.
        .onChange(of: current?.transactions.map(\.id)) { _, ids in
            let valid = LineSelection.valid(selection, rows: ids ?? [])
            if valid != selection { selection = valid }
        }
    }

    @ViewBuilder private func content(_ detail: LineDetail) -> some View {
        if detail.transactions.isEmpty && detail.securities.isEmpty {
            switch line {
            case .initialValue, .finalValue:
                Button("Show Holdings") { store.navigate(to: .holdings) }.buttonStyle(.link)
            case .netFlows, .performance:
                EmptyView()
            default:
                if amount == 0 {
                    Text("No transactions in this period.").font(.callout).foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                if !detail.securities.isEmpty {
                    securityList(detail).frame(maxWidth: detail.transactions.isEmpty ? .infinity : 340)
                }
                if !detail.transactions.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        transactionTable(detail)
                        if detail.unconvertedCount > 0 {
                            Text("\(Plural.count(detail.unconvertedCount, "amount has", "amounts have")) no exchange rate into \(detail.currency) and \(detail.unconvertedCount == 1 ? "is" : "are") not part of the line.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if detail.isWeighted {
                            Text("Amounts are shown in full; this scope counts each by its classification weight.")
                                .font(.caption).foregroundStyle(.tertiary)
                        } else if !detail.isSingleCurrency {
                            Text("Amounts are shown in the currency of each transaction; the line converts them at each day's rate.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func securityList(_ detail: LineDetail) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("By Security").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(detail.securities) { item in
                        Button {
                            store.navigate(to: .security(item.id))
                        } label: {
                            HStack(spacing: DS.Spacing.s) {
                                Text(item.name).lineLimit(1)
                                Spacer(minLength: DS.Spacing.s)
                                GainText(money: Money(minor: item.amount, currency: detail.currency))
                            }
                            .font(.callout)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(item.name)")
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(height: min(CGFloat(detail.securities.count) * 26 + 2, 262))
        }
    }

    private func transactionTable(_ detail: LineDetail) -> some View {
        let rows = detail.transactions
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(line == .realizedGains ? "Sales" : "Transactions")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text(Fmt.integer(rows.count)).font(.subheadline).numeric().foregroundStyle(.tertiary)
                Spacer()
                if let id = LineSelection.single(selection, rows: rows.map(\.id)) {
                    Button("Show in Transactions") { store.navigate(to: .transaction(id)) }.buttonStyle(.link).font(.callout)
                }
            }
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.date) { Text(Fmt.day($0.date)).numeric() }
                    .width(min: 80, ideal: 92, max: 110)
                TableColumn("Type", value: \.kindTitle) { Text($0.kindTitle) }
                    .width(min: 70, ideal: 96, max: 170)
                TableColumn("For", value: \.subject) { Text($0.subject).lineLimit(1) }
                    .width(min: 120, ideal: 210)
                TableColumn("Note", value: \.note) { Text($0.note).lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 130)
                // Sorted by the value in the reporting currency: rows may be in different currencies.
                TableColumn(line == .realizedGains ? "Proceeds" : "Amount", value: \.sortValue) { row in
                    Group {
                        if line == .realizedGains || StatementLine.flowLines.contains(line) {
                            Text(Fmt.money(row.amount, signed: line != .realizedGains)).numeric()
                        } else {
                            GainText(money: row.amount)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 104, max: 160)
                .alignment(.trailing)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Show in Transactions") { ids.first.map { store.navigate(to: .transaction($0)) } }.disabled(ids.count != 1)
                Button("Edit…") { ids.first.map { store.present(.editTransaction($0)) } }.disabled(ids.count != 1)
                Button("Copy") { Pasteboard.copy(tsv(rows.filter { ids.contains($0.id) })) }.disabled(ids.isEmpty)
                Divider()
                Button("Delete", role: .destructive) { store.deleteTransactions(ids) }.disabled(ids.isEmpty)
            } primaryAction: { ids in
                ids.first.map { store.navigate(to: .transaction($0)) }
            }
            .onCopyCommand {
                // Nothing selected: nothing to copy (not a lone header line).
                let selected = rows.filter { selection.contains($0.id) }
                return selected.isEmpty ? [] : [NSItemProvider(object: tsv(selected) as NSString)]
            }
            .onDeleteCommand { store.deleteTransactions(LineSelection.valid(selection, rows: rows.map(\.id))) }
            .onChange(of: selection) { _, ids in
                if let id = LineSelection.single(ids, rows: rows.map(\.id)) { store.setFocus(.transaction(id)) }
            }
            .frame(height: min(CGFloat(rows.count) * 24 + 46, 310))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Colors.hairline.opacity(0.6), lineWidth: 0.5))
        }
    }

    private func tsv(_ rows: [ContributionRow]) -> String {
        TSV.string(header: ["Date", "Type", "For", "Note", "Amount", "Currency"],
                   rows: rows.map { [$0.date.iso, $0.kindTitle, $0.subject, $0.note, TSV.number($0.amount.decimalValue), $0.amount.currency] })
    }
}
