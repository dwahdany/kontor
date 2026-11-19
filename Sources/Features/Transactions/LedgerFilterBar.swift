import SwiftUI
import KontorUI

/// The ledger's filters besides the search text (which lives in the toolbar).
struct LedgerFilterState: Equatable {
    enum Dates: Equatable { case all, period, custom }

    /// Empty = every kind.
    var groups: Set<KindGroup> = []
    var accountID: UUID?
    var depotID: UUID?
    var securityID: UUID?
    var dates = Dates.all
    var from: Day?
    var to: Day?
    var issuesOnly = false

    /// The days to show, or nil for all of them.
    func interval(period: DayInterval) -> DayInterval? {
        switch dates {
        case .all: return nil
        case .period: return period
        case .custom:
            guard let from, let to else { return nil }
            return DayInterval(start: min(from, to).advanced(by: -1), end: max(from, to))
        }
    }
}

/// One line of filter controls above the table: kind groups, account, depot, security, dates, issues.
struct LedgerFilterBar: View {
    @Environment(PortfolioStore.self) private var store
    @Binding var filter: LedgerFilterState
    let issueCount: Int
    let isFiltering: Bool
    let clear: () -> Void

    @State private var showsDateRange = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if compact {
                kindMenu
            } else {
                ForEach(KindGroup.allCases) { group in
                    Chip(title: group.title, isOn: filter.groups.contains(group)) { toggle(group) }
                        .help("Show \(group.kinds.map(\.title).joined(separator: ", "))")
                }
            }
            Divider().frame(height: 16)
            SearchablePicker("Account", selection: $filter.accountID, items: accountItems, placeholder: "All Accounts", allowsNone: true)
                .frame(width: compact ? 132 : 150)
                .help("Show one account — with its running balance")
            SearchablePicker("Depot", selection: $filter.depotID, items: depotItems, placeholder: "All Depots", allowsNone: true)
                .frame(width: compact ? 124 : 140)
            SearchablePicker("Security", selection: $filter.securityID, items: securityItems, placeholder: "All Securities", allowsNone: true)
                .frame(width: compact ? 140 : 170)
            dateMenu
            if issueCount > 0 || filter.issuesOnly {
                Chip(title: compact ? Fmt.integer(issueCount) : "Issues  \(Fmt.integer(issueCount))", symbol: "exclamationmark.triangle", isOn: filter.issuesOnly) {
                    filter.issuesOnly.toggle()
                }
                .help("Only entries the consistency check complains about: missing fields, impossible positions, probable duplicates")
            }
            Spacer(minLength: 0)
            if isFiltering {
                Button("Clear", action: clear)
                    .buttonStyle(.link)
                    .help("Remove all filters")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var kindMenu: some View {
        Menu {
            ForEach(KindGroup.allCases) { group in
                Toggle(group.title, isOn: Binding(get: { filter.groups.contains(group) }, set: { _ in toggle(group) }))
            }
            Divider()
            Button("All Types") { filter.groups = [] }
        } label: {
            Text(filter.groups.isEmpty ? "All Types" : KindGroup.allCases.filter(filter.groups.contains).map(\.title).joined(separator: ", "))
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityLabel("Types")
    }

    private var dateMenu: some View {
        Menu {
            Picker("Dates", selection: Binding(get: { filter.dates }, set: { setDates($0) })) {
                Text("All Dates").tag(LedgerFilterState.Dates.all)
                Text("Reporting Period (\(store.period.shortTitle))").tag(LedgerFilterState.Dates.period)
                Text("Custom Range…").tag(LedgerFilterState.Dates.custom)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(dateTitle, systemImage: "calendar").lineLimit(1)
        }
        .fixedSize()
        .popover(isPresented: $showsDateRange, arrowEdge: .bottom) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
                GridRow {
                    Text("From").foregroundStyle(.secondary)
                    DayField("From", day: Binding(get: { filter.from ?? store.today }, set: { filter.from = $0 }))
                }
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    DayField("To", day: Binding(get: { filter.to ?? store.today }, set: { filter.to = $0 }))
                }
            }
            .padding(DS.Spacing.l)
        }
        .accessibilityLabel("Dates")
        .help("Limit the list to a date range")
    }

    private var dateTitle: String {
        switch filter.dates {
        case .all: "All Dates"
        case .period: "Period: \(store.period.shortTitle)"
        case .custom: filter.interval(period: store.periodInterval).map { Fmt.interval($0, style: .short) } ?? "Custom"
        }
    }

    private func setDates(_ dates: LedgerFilterState.Dates) {
        if dates == .custom {
            // Start from the reporting period, which is usually close to what is wanted.
            if filter.from == nil { filter.from = min(store.periodInterval.firstDay, store.periodInterval.end) }
            if filter.to == nil { filter.to = store.periodInterval.end }
            showsDateRange = true
        }
        filter.dates = dates
    }

    private func toggle(_ group: KindGroup) {
        if filter.groups.contains(group) { filter.groups.remove(group) } else { filter.groups.insert(group) }
    }

    private var accountItems: [PickerItem<UUID>] {
        store.file.accounts
            .sorted { ($0.isRetired ? 1 : 0, $0.name.lowercased()) < ($1.isRetired ? 1 : 0, $1.name.lowercased()) }
            .map { PickerItem(id: $0.id, title: $0.name, detail: $0.currency, isDimmed: $0.isRetired) }
    }

    private var depotItems: [PickerItem<UUID>] {
        store.file.depots
            .sorted { ($0.isRetired ? 1 : 0, $0.name.lowercased()) < ($1.isRetired ? 1 : 0, $1.name.lowercased()) }
            .map { PickerItem(id: $0.id, title: $0.name, isDimmed: $0.isRetired) }
    }

    private var securityItems: [PickerItem<UUID>] {
        store.file.securities
            .sorted { ($0.isRetired ? 1 : 0, $0.name.lowercased()) < ($1.isRetired ? 1 : 0, $1.name.lowercased()) }
            .map { PickerItem(id: $0.id, title: $0.name, detail: $0.ticker.isEmpty ? $0.isin : $0.ticker, keywords: [$0.isin, $0.wkn, $0.ticker], isDimmed: $0.isRetired) }
    }
}

/// A small on/off capsule.
private struct Chip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).numeric()
            }
            .font(.callout.weight(isOn ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
            .overlay { Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Bulk action "Change Date…": one day for all selected entries (times of day are kept).
struct ChangeDateSheet: View {
    static let requestID = "transactions.change-date"

    @Environment(PortfolioStore.self) private var store
    /// `ids=<uuid>,<uuid>…` from the ledger, or `count=<n>` (the first n entries; for screenshots).
    let payload: [String: String]
    @State private var day: Day?

    private var ids: Set<UUID> {
        if let count = payload["count"].flatMap({ Int($0) }) {
            return Set(store.file.transactions.sorted(by: Transaction.chronological).prefix(count).map(\.id))
        }
        return Set((payload["ids"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private var transactions: [Transaction] {
        let ids = ids
        return store.file.transactions.filter { ids.contains($0.id) }
    }

    var body: some View {
        let transactions = transactions
        let days = Set(transactions.map(\.date))
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(transactions.count == 1 ? "Change Date" : "Change Date of \(Fmt.integer(transactions.count)) Transactions")
                    .font(.headline)
                Text(summary(days: days))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Spacing.m) {
                Text("New date").foregroundStyle(.secondary)
                DayField("New date", day: Binding(get: { day ?? store.today }, set: { day = $0 }))
                Spacer()
            }
            if (day ?? store.today) > store.today {
                Label("This date is in the future.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(DS.Colors.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Change Date") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(transactions.isEmpty)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 400)
        .onAppear { if day == nil { day = days.max() ?? store.today } }
    }

    private func summary(days: Set<Day>) -> String {
        guard let first = days.min(), let last = days.max() else { return "The selected transactions no longer exist." }
        let range = first == last ? "on \(Fmt.day(first, style: .medium))" : "between \(Fmt.day(first, style: .medium)) and \(Fmt.day(last, style: .medium))"
        return "Currently \(range). Times of day stay as they are; you can undo the change."
    }

    private func apply() {
        let target = day ?? store.today
        let ids = ids
        store.mutate(ids.count == 1 ? "Change Date" : "Change Date of \(ids.count) Transactions") { file in
            for index in file.transactions.indices where ids.contains(file.transactions[index].id) {
                file.transactions[index].date = target
            }
        }
        store.dismissSheet()
    }
}
