import SwiftUI
import KontorUI

/// Draws a widget's computed data. No engine calls here — only formatting (through `Fmt`) and the
/// shared chart kit.
struct WidgetContent: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.gainStyle) private var gainStyle

    let widget: Dashboard.Widget
    let kind: WidgetKind
    let request: WidgetRequest
    let data: WidgetData
    /// Outer width of the tile — content adapts (two columns vs. one, fewer table columns).
    let width: CGFloat
    let isRefreshing: Bool
    let mode: WidgetMode

    private var pinsHover: Bool { mode == .live && store.dashboardSession.pinsHover }
    private var isCompact: Bool { width < 420 }

    var body: some View {
        switch data {
        case .netWorth(let d): netWorth(d).opacity(dim)
        case .stat(let d): stat(d).opacity(dim)
        case .performance(let d): performance(d)
        case .value(let d): valueChart(d)
        case .allocation(let d): allocation(d)
        case .movers(let d): movers(d).opacity(dim)
        case .holdings(let d): holdings(d).opacity(dim)
        case .earnings(let d): earnings(d)
        case .heatmap(let rows): heatmap(rows)
        case .cash(let d): cash(d).opacity(dim)
        case .plans(let rows): plans(rows).opacity(dim)
        case .transactions(let rows): transactions(rows).opacity(dim)
        case .watchlist(let rows): watchlist(rows).opacity(dim)
        case .consistency(let d): consistency(d).opacity(dim)
        case .checklist(let d): GettingStartedList(checklist: d, isCompact: isCompact)
        }
    }

    /// Stale content stays visible, slightly dimmed, while newer numbers are computed.
    private var dim: Double { isRefreshing ? 0.6 : 1 }

    // MARK: Tiles

    private func netWorth(_ d: WidgetData.NetWorth) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .center, spacing: DS.Spacing.s) {
                Text(d.hasData ? Fmt.money(d.total) : Fmt.missing)
                    .font(.kontorHero)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if d.sparkline.count >= 2, d.hasData {
                    Sparkline(d.sparkline)
                        .frame(minWidth: 36, maxWidth: 96)
                        .frame(height: 30)
                        .help("Value over the period")
                }
            }
            if d.hasData {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    DeltaLabel(fraction: d.dayFraction, amount: d.dayChange)
                    Text(Fmt.relativeDay(d.changeDay, today: store.today).lowercased())
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else {
                Text("No transactions yet").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ d: WidgetData.Stat) -> some View {
        let text: String = switch d.value {
        case .percent(let v): Fmt.percent(v, signed: d.isSigned)
        case .money(let m): m.map { Fmt.money($0, signed: d.isSigned) } ?? Fmt.missing
        case .ratio(let v): Fmt.ratio(v)
        }
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(text)
                .font(.kontorHero)
                .foregroundStyle(d.isSigned && d.sign != 0 ? AnyShapeStyle(gainStyle.color(for: d.sign)) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let detail = d.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func consistency(_ d: WidgetData.Consistency) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                if d.total == 0 {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).font(.title2)
                    Text("All clear").font(.kontorHero).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    let severity: ConsistencyIssue.Severity = d.errors > 0 ? .error : d.warnings > 0 ? .warning : .info
                    Image(systemName: severity.symbol).foregroundStyle(severity.color).font(.title2)
                    Text(Fmt.integer(d.total)).font(.kontorHero)
                    Text(d.total == 1 ? "issue" : "issues").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(d.total == 0 ? "No problems found in your data" : breakdown(d))
                .font(.callout)
                .foregroundStyle(.secondary)
                .numeric()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    private func breakdown(_ d: WidgetData.Consistency) -> String {
        func part(_ n: Int, _ severity: ConsistencyIssue.Severity) -> String? {
            n == 0 ? nil : "\(Fmt.integer(n)) \((n == 1 ? severity.title : severity.pluralTitle).lowercased())"
        }
        return [part(d.errors, .error), part(d.warnings, .warning), part(d.hints, .info)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Charts

    private func pinnedDay(_ interval: DayInterval) -> Day? {
        pinsHover ? interval.start.advanced(by: Int(Double(interval.dayCount) * 0.62)) : nil
    }

    private func performance(_ d: WidgetData.PerformanceChart) -> some View {
        var series = [TimeSeries("Portfolio", points: d.portfolio)]
        for (index, benchmark) in d.benchmarks.enumerated() {
            series.append(TimeSeries(id: benchmark.id.uuidString, benchmark.name, points: benchmark.points,
                                     color: index == 0 ? ChartColors.comparison : ChartColors.series(index), dashed: true))
        }
        return TimeSeriesChart(d.hasData ? series : [], format: .percent(signed: true), title: "Cumulative return of the portfolio and its benchmarks")
            .timeDomain(d.interval)
            .pinnedHover(pinnedDay(d.interval))
            .loading(isRefreshing)
            .emptyMessage("Record a transaction to see your performance")
            .frame(minHeight: 200, idealHeight: 250, maxHeight: .infinity)
    }

    private func valueChart(_ d: WidgetData.ValueChart) -> some View {
        let series = d.hasData ? [
            TimeSeries("Value", points: d.value, style: .area),
            TimeSeries("Invested", start: d.start, values: d.invested, style: .step, color: ChartColors.comparison),
        ] : []
        let interval = DayInterval(start: d.start, end: d.start.advanced(by: max(d.invested.count - 1, 1)))
        return TimeSeriesChart(series, format: .money(d.currency), title: "Portfolio value and invested capital")
            .pinnedHover(pinnedDay(interval))
            .loading(isRefreshing)
            .emptyMessage("Record a transaction to see your portfolio grow")
            .frame(minHeight: 200, idealHeight: 250, maxHeight: .infinity)
    }

    private func allocation(_ d: WidgetData.Allocation) -> some View {
        DonutChart(d.slices, format: .money(d.currency), centerTitle: store.isWholePortfolioScope && request.scopeLabel == nil ? "Net Worth" : "Total",
                   title: d.taxonomyName.isEmpty ? "Allocation" : "Allocation by \(d.taxonomyName)")
            .selection(nil) { id in
                guard let id, let classification = UUID(uuidString: id) else { return }
                store.navigate(to: .classification(taxonomy: d.taxonomyID, id: classification))
            }
            .pinnedHover(pinsHover ? d.slices.first?.id : nil)
            .loading(isRefreshing)
            .emptyMessage(d.taxonomyName.isEmpty ? "Create a taxonomy on the Allocation screen" : "Nothing to allocate yet")
            .frame(minHeight: 180, idealHeight: 220, maxHeight: .infinity)
    }

    private func earnings(_ d: WidgetData.Earnings) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(Fmt.money(d.total)).font(.kontorValue).numeric()
                Text(d.byYear ? "since \(d.categories.first?.label ?? "")" : "in 12 months")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: DS.Spacing.s)
                Text("\(String(d.year)) so far").font(.callout).foregroundStyle(.secondary)
                Text(Fmt.money(d.thisYear)).font(.callout.weight(.medium)).numeric()
            }
            .lineLimit(1)
            .opacity(dim)
            BarSeriesChart(categories: d.isEmpty ? [] : d.categories, series: [
                BarSeries("Dividends", values: d.dividends),
                BarSeries("Interest", values: d.interest),
            ], format: .money(d.currency), layout: .stacked, title: "Dividends and interest")
            .selection(nil) { _ in store.navigate(to: .earnings) }
            .pinnedHover(pinsHover ? d.categories.dropLast(2).last?.id : nil)
            .loading(isRefreshing)
            .emptyMessage("No dividends or interest yet")
            .frame(minHeight: 150, idealHeight: 190, maxHeight: .infinity)
        }
    }

    private func heatmap(_ rows: [HeatmapRow]) -> some View {
        var format = ChartValueFormat.percent(decimals: 2, signed: true)
        format.compact = { Fmt.percent($0, decimals: abs($0) >= 0.0995 ? 0 : 1) }
        return HeatmapGrid(rows: rows, columns: ChartLabels.shortMonths, format: format, totalTitle: "Year", title: "Monthly returns")
            .pinnedHover(row: pinsHover ? rows.first?.id ?? "" : "", column: 2)
            .loading(isRefreshing)
            .emptyMessage("No returns yet")
    }

    // MARK: Lists

    private func movers(_ d: WidgetData.Movers) -> some View {
        Group {
            if d.best.isEmpty && d.worst.isEmpty {
                WidgetEmpty(d.positionCount == 0 ? "No positions in this period" : "Nothing moved in this period")
            } else if isCompact {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    moverColumn("Best", d.best, empty: "No gainers")
                    moverColumn("Worst", d.worst, empty: "No losers")
                }
            } else {
                HStack(alignment: .top, spacing: DS.Spacing.xl) {
                    moverColumn("Best", d.best, empty: "No gainers")
                    moverColumn("Worst", d.worst, empty: "No losers")
                }
            }
        }
    }

    private func moverColumn(_ title: String, _ rows: [WidgetData.Mover], empty: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(title).font(.kontorCaption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary).padding(.vertical, DS.Spacing.xs)
            }
            ForEach(rows) { row in
                RowLink(help: "Show \(row.name)") { store.navigate(to: .security(row.id)) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Text(row.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: DS.Spacing.s)
                        if (isCompact ? width : width / 2) >= 400 {
                            GainText(money: row.gain).font(.callout).opacity(0.85).layoutPriority(1)
                        }
                        GainText(percent: row.change).frame(minWidth: 62, alignment: .trailing)
                            .layoutPriority(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func holdings(_ d: WidgetData.Holdings) -> some View {
        Group {
            if d.rows.isEmpty {
                WidgetEmpty("No positions yet")
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(d.rows) { row in
                        RowLink(help: "Show \(row.name)") { store.navigate(to: .security(row.id)) } label: {
                            HStack(alignment: .center, spacing: DS.Spacing.m) {
                                Text(row.name).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !isCompact {
                                    TargetActualBar(actual: row.weight, target: nil, maximum: max(d.maxWeight, 0.01),
                                                    color: ChartColors.series(0), showsLabel: false)
                                        .frame(width: 64, height: 14)
                                        .accessibilityHidden(true)
                                }
                                Text(Fmt.percent(row.weight, decimals: 1)).numeric().foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                if !isCompact {
                                    Text(Fmt.moneyRounded(row.value)).numeric()
                                        .frame(width: 84, alignment: .trailing)
                                }
                                Group {
                                    if let gain = row.gainFraction { GainText(percent: gain, decimals: 1) } else { Text(Fmt.missing).foregroundStyle(.tertiary) }
                                }
                                .frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                    if d.total > d.rows.count {
                        Text("and \(Fmt.integer(d.total - d.rows.count)) more")
                            .font(.caption).foregroundStyle(.tertiary).padding(.top, DS.Spacing.xs)
                    }
                }
            }
        }
    }

    private func cash(_ d: WidgetData.Cash) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(Fmt.money(d.total)).font(.kontorHero).lineLimit(1).minimumScaleFactor(0.6)
            if d.rows.isEmpty {
                Text("No cash accounts in this scope").font(.callout).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(d.rows) { row in
                        RowLink(help: "Show \(row.name)") { store.navigate(to: .account(row.id)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                                Text(row.name).lineLimit(1).foregroundStyle(.secondary)
                                Spacer(minLength: DS.Spacing.s)
                                Text(Fmt.money(row.balance)).numeric().layoutPriority(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func plans(_ rows: [WidgetData.PlanRow]) -> some View {
        Group {
            if rows.isEmpty {
                WidgetEmpty(store.file.plans.isEmpty ? "No savings plans yet" : "No upcoming executions") {
                    if store.file.plans.isEmpty {
                        Button("New Plan…") { store.present(.newPlan) }.buttonStyle(.link)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(rows) { row in
                        RowLink(help: "Show plan \(row.name)") { store.navigate(to: .plan(row.id)) } label: {
                            HStack(alignment: .center, spacing: DS.Spacing.s) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name).lineLimit(1)
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: DS.Spacing.s)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(Fmt.money(row.amount)).numeric()
                                    if row.overdue > 0 {
                                        Label("\(Fmt.integer(row.overdue)) overdue", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundStyle(DS.Colors.warning)
                                    } else if let due = row.nextDue {
                                        Text(dueText(due)).font(.caption).foregroundStyle(.secondary).numeric()
                                    }
                                }
                                .layoutPriority(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dueText(_ due: Day) -> String {
        let days = store.today.distance(to: due)
        switch days {
        case ...1: return Fmt.relativeDay(due, today: store.today)
        case 2...13: return "in \(days) days · \(Fmt.day(due, style: .dayMonth))"
        default: return Fmt.day(due, style: .medium)
        }
    }

    private func transactions(_ rows: [WidgetData.TransactionRow]) -> some View {
        Group {
            if rows.isEmpty {
                WidgetEmpty("No transactions yet") {
                    Button("New Transaction…") { store.present(.newTransaction) }.buttonStyle(.link)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(rows) { row in
                        RowLink(help: "Show this transaction") { store.navigate(to: .transaction(row.id)) } label: {
                            HStack(alignment: .center, spacing: DS.Spacing.s) {
                                Image(systemName: row.kind.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(row.kind.title).lineLimit(1).frame(width: isCompact ? nil : 104, alignment: .leading)
                                    .layoutPriority(1)
                                Text(row.title).lineLimit(1).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !isCompact {
                                    Text(Fmt.day(row.date, style: .medium)).numeric().foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(Fmt.money(row.amount, signed: row.kind.cashSign != 0)).numeric().lineLimit(1)
                                    .frame(minWidth: 88, alignment: .trailing)
                                    .layoutPriority(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func watchlist(_ rows: [WidgetData.WatchRow]) -> some View {
        Group {
            if rows.isEmpty {
                WidgetEmpty(store.file.watchlists.isEmpty ? "No watchlist yet — create one on the Securities screen" : "This watchlist is empty")
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(rows) { row in
                        RowLink(help: "Show \(row.name)") { store.navigate(to: .security(row.id)) } label: {
                            HStack(alignment: .center, spacing: DS.Spacing.m) {
                                Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if !isCompact {
                                    Sparkline(row.sparkline).frame(width: DS.Size.sparkline.width, height: DS.Size.sparkline.height)
                                }
                                Text(row.price.map { Fmt.price($0, currency: row.currency) } ?? Fmt.missing).numeric()
                                    .frame(minWidth: 76, alignment: .trailing)
                                Group {
                                    if let change = row.change { GainText(percent: change, decimals: 1) } else { Text(Fmt.missing).foregroundStyle(.tertiary) }
                                }
                                .frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

/// A quiet one-line empty state inside a widget, with an optional next action.
struct WidgetEmpty<Actions: View>: View {
    private let message: String
    private let actions: Actions

    init(_ message: String, @ViewBuilder actions: () -> Actions) {
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            actions
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity)
    }
}

extension WidgetEmpty where Actions == EmptyView {
    init(_ message: String) { self.init(message) { EmptyView() } }
}

/// A list row that deep-links somewhere: full-width hit area, hover highlight, keyboard reachable.
struct RowLink<Label: View>: View {
    private let help: String
    private let action: () -> Void
    private let label: Label
    @State private var isHovered = false

    init(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.help = help
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .padding(.vertical, 3)
                .padding(.horizontal, DS.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous))
        .padding(.horizontal, -DS.Spacing.s)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// The "getting started" checklist — used by the widget and by the onboarding screen.
struct GettingStartedList: View {
    @Environment(PortfolioStore.self) private var store
    let checklist: WidgetData.Checklist
    var isCompact = false

    private struct Step: Identifiable {
        var id: Int
        var isDone: Bool
        var title: String
        var detail: String
        var actionTitle: String
        var action: @MainActor () -> Void
    }

    private var steps: [Step] {
        [
            Step(id: 0, isDone: checklist.hasAccount, title: "Add an account",
                 detail: "A cash account pays for purchases and receives dividends; a depot holds your securities.",
                 actionTitle: "New Account…") { store.present(.newAccount) },
            Step(id: 1, isDone: checklist.hasSecurity, title: "Add a security",
                 detail: "A share, fund or ETF you own or want to follow — quotes are downloaded for you.",
                 actionTitle: "New Security…") { store.present(.newSecurity) },
            Step(id: 2, isDone: checklist.hasTransaction, title: "Record your first transaction",
                 detail: "A deposit or a purchase. Everything on the dashboard is calculated from your transactions.",
                 actionTitle: "New Transaction…") { store.present(.newTransaction) },
            Step(id: 3, isDone: checklist.hasImport, title: "Import your history",
                 detail: "Bring existing data from a CSV file or from Portfolio Performance instead of typing it in.",
                 actionTitle: "Import…") { store.present(.importFile) },
        ]
    }

    var body: some View {
        let next = steps.first { !$0.isDone }?.id
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: DS.Spacing.m) {
                    Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(step.isDone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .accessibilityLabel(step.isDone ? "Done" : "To do")
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(step.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(step.isDone ? .secondary : .primary)
                        if !isCompact || step.id == next {
                            Text(step.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: DS.Spacing.s)
                    if step.id == next {
                        Button(step.actionTitle, action: step.action).buttonStyle(.borderedProminent)
                    } else {
                        Button(step.actionTitle, action: step.action).buttonStyle(.bordered)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .controlSize(.regular)
    }
}
