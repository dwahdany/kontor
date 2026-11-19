import SwiftUI
import KontorModel
import KontorUI

/// The Earnings screen: income (dividends, interest) and costs (fees, taxes) over time, by
/// security and by account, with a payment calendar and a simple twelve-month projection.
///
/// Every number comes from the engine's `EarningsReport` through the store's analysis layer.
///
/// Launch state (`--state key=value`, screenshot mode):
///
/// | key | values | meaning |
/// |---|---|---|
/// | `metric` | `dividends` (default) · `interest` · `earnings` · `fees` · `taxes` · `net` | the figure shown everywhere |
/// | `view` | `chart` (default) · `matrix` · `securities` · `accounts` · `payments` · `calendar` | the sub-view |
/// | `range` | `all` (default) · `period` | all years, or the window's reporting period (`--period`) |
/// | `group` | `month` (default) · `quarter` · `year` | bar width of the chart |
/// | `stack` | `security` | chart: stack the bars by security (dividend figures only) |
/// | `average` | `off` | chart: hide the 12-month average line |
/// | `select` | a bar id: `2025-05`, `2025-Q2`, `2025` | chart: select a bar (breakdown card follows) |
/// | `hover` | a bar id (as above); calendar: `2026-7` (year-month of an upcoming month) | pin the chart tooltip |
/// | `month` | `2025-05` | payments: only that month |
/// | `filter` | text | payments: quick filter |
///
/// Scope comes from `--scope`, the period from `--period` (used with `range=period`).
public struct EarningsScreen: View {
    @Environment(PortfolioStore.self) private var store

    @State private var model = Loadable<EarningsModel>()
    @State private var kind = EarningsKind.dividends
    @State private var view = EarningsView.chart
    @State private var range = EarningsRange.all
    @State private var chartOptions = EarningsChartOptions()
    @State private var paymentsFilter = PaymentsFilter()
    @State private var didReadLaunchState = false

    public init() {}

    private var interval: DayInterval {
        range == .all ? store.interval(for: .allTime) : store.periodInterval
    }

    private var query: EarningsModel.Query {
        EarningsModel.Query(kind: kind, today: store.today, allYears: store.interval(for: .allTime))
    }

    public var body: some View {
        let query = query
        Group {
            if let value = model.value {
                if value.isEmpty {
                    emptyState
                } else {
                    // The screen never asks for more width than the window gives it; sub-views size
                    // their columns from this width instead.
                    GeometryReader { proxy in
                        content(value, width: proxy.size.width)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "earnings.model", interval: interval, variant: query) { analysis in
            EarningsModel(analysis, query: query)
        }
        .toolbar { toolbar }
        .background { shortcuts }
        .onAppear(perform: readLaunchState)
        .onChange(of: store.period) { _, _ in
            // Choosing a period in the toolbar means "show me that period".
            range = .period
        }
    }

    // MARK: Content

    private func content(_ value: EarningsModel, width: CGFloat) -> some View {
        let isCompact = width < 900
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(spacing: DS.Spacing.m) {
                    Picker("Figure", selection: $kind) {
                        ForEach(EarningsKind.allCases) { kind in
                            Text(isCompact ? kind.shortTitle : kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("What to look at. Dividends and interest are shown before fees and taxes; Net is what is left after them.")
                    HelpButton(.grossVersusNet)
                    Spacer(minLength: DS.Spacing.s)
                    rangePicker
                }
                EarningsTiles(model: value, isCompact: isCompact)
                HStack(spacing: DS.Spacing.m) {
                    Picker("View", selection: $view) {
                        ForEach(EarningsView.allCases) { view in
                            Label(view.title, systemImage: view.symbol).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: DS.Spacing.s)
                    Text(Fmt.interval(value.interval))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .numeric()
                        .lineLimit(1)
                }
            }
            .frame(width: max(0, width - 2 * DS.Spacing.xl), alignment: .leading)
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.top, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.m)

            Group {
                switch view {
                case .chart:
                    EarningsChartView(model: value, options: $chartOptions, isRefreshing: model.isRefreshing) { month in
                        paymentsFilter = PaymentsFilter(month: month)
                        view = .payments
                    }
                case .matrix:
                    EarningsMatrixView(model: value, width: width) { month in
                        paymentsFilter = PaymentsFilter(month: month)
                        view = .payments
                    }
                case .securities:
                    EarningsSecuritiesTable(model: value) { securityID in
                        paymentsFilter = PaymentsFilter(securityID: securityID)
                        view = .payments
                    }
                case .accounts:
                    EarningsAccountsTable(model: value)
                case .payments:
                    EarningsPaymentsView(interval: interval, filter: $paymentsFilter)
                case .calendar:
                    EarningsCalendarView(model: value, pinnedMonth: chartOptions.pinnedHover, width: width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(model.isRefreshing ? 0.7 : 1)
        }
    }

    private var rangePicker: some View {
        Picker("Years", selection: $range) {
            Text("All Years").tag(EarningsRange.all)
            Text(store.period.title).tag(EarningsRange.period)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("All Years shows everything since the first transaction. The other choice follows the period selected in the toolbar.")
    }

    private var emptyState: some View {
        EmptyState(
            store.isWholePortfolioScope ? "No Earnings Yet" : "No Earnings in \(store.scopeTitle)",
            symbol: "banknote",
            message: store.isWholePortfolioScope
                ? "Record a dividend or an interest payment and Kontor shows what your portfolio pays you: per month, per security, after fees and taxes."
                : "Nothing was paid or charged in this part of the portfolio. Choose another scope in the toolbar, or record a payment."
        ) {
            Button("Record Dividend…") { record(.dividend) }
                .keyboardShortcut(.defaultAction)
            Button("Record Interest…") { record(.interest) }
            if store.isWholePortfolioScope {
                Button("Import…") { store.present(.importFile) }
            } else {
                Button("Show Whole Portfolio") { store.scopeSelection = .portfolio }
            }
        }
    }

    // MARK: Toolbar, shortcuts

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem { ScopePicker() }
        ToolbarItem {
            Menu {
                Button("Record Dividend…", systemImage: Transaction.Kind.dividend.symbol) { record(.dividend) }
                    .keyboardShortcut("d", modifiers: [.command, .control])
                Button("Record Interest…", systemImage: Transaction.Kind.interest.symbol) { record(.interest) }
                    .keyboardShortcut("i", modifiers: [.command, .control])
                Divider()
                Button("Record Fee…", systemImage: Transaction.Kind.fee.symbol) { record(.fee) }
                Button("Record Tax…", systemImage: Transaction.Kind.tax.symbol) { record(.tax) }
            } label: {
                Label("Record", systemImage: "plus")
            }
            .help("Record a dividend, interest, fee or tax")
        }
        ToolbarItem {
            Button("Export CSV", systemImage: "square.and.arrow.up") { export() }
                .keyboardShortcut("e", modifiers: [.command, .control])
                .help("Export the table of this view as CSV (⌃⌘E)")
                .disabled(model.value?.isEmpty ?? true)
        }
    }

    /// ⌃1…⌃6 switch the view, ⌃⇧1…⌃⇧6 the figure.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(EarningsView.allCases.enumerated()), id: \.element) { index, target in
                Button(target.title) { view = target }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
            }
            ForEach(Array(EarningsKind.allCases.enumerated()), id: \.element) { index, target in
                Button(target.title) { kind = target }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .shift])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func record(_ transactionKind: Transaction.Kind) {
        store.present(.newTransaction(EarningsActions.prefill(transactionKind, store: store)))
    }

    private func export() {
        guard let value = model.value else { return }
        let view = view, interval = interval, filter = paymentsFilter
        Task {
            var payments: PaymentsModel?
            if view == .payments {
                let query = filter.query(sortOrder: [KeyPathComparator(\PaymentRow.day, order: .reverse)])
                payments = try? await store.analyze("earnings.payments", interval: interval, variant: query) { analysis in
                    PaymentsModel(analysis, query: query)
                }
                if payments == nil { return }
            }
            let table = EarningsExport.table(for: view, model: value, grouping: chartOptions.grouping, payments: payments)
            EarningsExport.save(table, store: store)
        }
    }

    private func readLaunchState() {
        guard !didReadLaunchState else { return }
        didReadLaunchState = true
        kind = store.launchValue("metric", as: EarningsKind.self) ?? kind
        view = store.launchValue("view", as: EarningsView.self) ?? view
        range = store.launchValue("range", as: EarningsRange.self) ?? range
        chartOptions.grouping = store.launchValue("group", as: EarningsGrouping.self) ?? chartOptions.grouping
        chartOptions.stacksBySecurity = store.launchValue("stack") == "security"
        chartOptions.showsAverage = store.launchValue("average") != "off"
        chartOptions.selection = store.launchValue("select")
        chartOptions.pinnedHover = store.launchValue("hover")
        if let month = store.launchValue("month") {
            let parts = month.split(separator: "-").compactMap { Int($0) }
            if parts.count == 2, (1...12).contains(parts[1]) { paymentsFilter.month = parts[0] * 12 + parts[1] - 1 }
        }
        paymentsFilter.text = store.launchValue("filter") ?? ""
    }
}

// MARK: - Shared view state

struct EarningsChartOptions: Equatable {
    var grouping = EarningsGrouping.month
    var stacksBySecurity = false
    var showsAverage = true
    var selection: String?
    var pinnedHover: String?
}

struct PaymentsFilter: Equatable {
    var text = ""
    /// `year × 12 + month − 1`
    var month: Int?
    var securityID: UUID?

    func query(sortOrder: [KeyPathComparator<PaymentRow>]) -> PaymentsModel.Query {
        PaymentsModel.Query(filter: text, month: month, securityID: securityID, sortOrder: sortOrder)
    }
}

// MARK: - Actions shared by the screen, tables, palette and inspector

@MainActor enum EarningsActions {
    /// A prefilled "new transaction" request: today, the scope's depot or account, and — for a
    /// dividend of a known security — the shares held today.
    static func prefill(_ kind: Transaction.Kind, securityID: UUID? = nil, accountID: UUID? = nil, store: PortfolioStore) -> TransactionPrefill {
        var prefill = TransactionPrefill(kind: kind, date: store.today, securityID: securityID, accountID: accountID)
        switch store.scopeSelection {
        case .depot(let id): prefill.depotID = id
        case .account(let id): if accountID == nil { prefill.accountID = id }
        default: break
        }
        return prefill
    }
}

// MARK: - Header tiles

struct EarningsTiles: View {
    let model: EarningsModel
    var isCompact = false

    var body: some View {
        let tiles = model.tiles
        let currency = model.currency
        HStack(spacing: isCompact ? DS.Spacing.s : DS.Spacing.m) {
            StatTile("\(String(tiles.year)) so far", value: money(tiles.thisYear),
                     footnote: "through \(Fmt.day(model.today, style: .dayMonth))")
                .help("\(model.kind.title) from January 1 through today: \(exact(tiles.thisYear))")
            StatTile(String(tiles.year - 1), value: money(tiles.lastYear),
                     delta: delta(tiles.lastYearGrowth), footnote: growthFootnote(tiles.lastYearGrowth, reference: "vs. \(String(tiles.year - 2))"))
                .help("\(model.kind.title) in \(String(tiles.year - 1)): \(exact(tiles.lastYear))")
            StatTile("Last 12 Months", value: money(tiles.trailing),
                     footnote: "since \(Fmt.day(tiles.trailingInterval.firstDay, style: .shortMonthYear))")
                .help("\(model.kind.title) in the current month and the eleven before it: \(exact(tiles.trailing))")
            StatTile(isCompact ? "Per Month" : "Average per Month", value: money(tiles.averagePerMonth), footnote: "last 12 months")
                .help("The last 12 months divided by twelve: \(exact(tiles.averagePerMonth))")
            StatTile(isCompact ? "Growth" : "Growth vs. Last Year", value: Fmt.percent(tiles.samePeriodGrowth, decimals: 1, signed: true),
                     footnote: tiles.samePeriodGrowth == nil
                        ? "nothing a year earlier"
                        : isCompact ? "vs. \(Fmt.money(minor: tiles.samePeriodLastYear, currency: currency))"
                        : "\(Fmt.money(minor: tiles.samePeriodLastYear, currency: currency)) same days \(String(tiles.year - 1))")
                .help("\(String(tiles.year)) so far compared with \(Fmt.interval(tiles.samePeriodInterval)) — the same part of last year, so a year in progress is compared fairly.")
        }
        .numeric()
    }

    /// Whole currency units in narrow windows, so all five values keep the same size.
    private func money(_ minor: Int64) -> String {
        let money = Money(minor: minor, currency: model.currency)
        return isCompact ? Fmt.moneyRounded(money) : Fmt.money(money)
    }

    /// Growth of income is good news and gets the gain color; growth of fees or taxes is stated neutrally.
    private func delta(_ growth: Double?) -> DeltaLabel? {
        guard let growth, !model.kind.isCost else { return nil }
        return DeltaLabel(fraction: growth)
    }

    private func exact(_ minor: Int64) -> String { Fmt.money(minor: minor, currency: model.currency) }

    private func growthFootnote(_ growth: Double?, reference: String) -> String {
        guard let growth else { return "full year" }
        if isCompact { return model.kind.isCost ? Fmt.percent(growth, decimals: 1, signed: true) : "" }
        return model.kind.isCost ? "\(Fmt.percent(growth, decimals: 1, signed: true)) \(reference)" : reference
    }
}
