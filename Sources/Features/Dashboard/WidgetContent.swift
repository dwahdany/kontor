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
                if d.hasData { GapBadge(gaps: d.gaps) }
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
                    // The header already carries the date when the tile is a statement of that very day.
                    if d.changeDay != request.asOf {
                        Text(WidgetText.changeDay(d.changeDay, today: store.today))
                            .foregroundStyle(.tertiary)
                    }
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
        // The line is named after what it measures: the portfolio, or the depot / account / classification.
        var series = [TimeSeries(request.isPartialScope ? request.scopeTitle : "Portfolio", points: d.portfolio)]
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
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            DonutChart(d.slices, format: .money(d.currency), centerTitle: request.isPartialScope ? "Total" : "Net Worth",
                       title: d.taxonomyName.isEmpty ? "Allocation" : "Allocation by \(d.taxonomyName)")
                .selection(nil) { id in
                    guard let id, let classification = UUID(uuidString: id) else { return }
                    store.navigate(to: .classification(taxonomy: d.taxonomyID, id: classification))
                }
                .pinnedHover(pinsHover ? d.slices.first?.id : nil)
                .loading(isRefreshing)
                .emptyMessage(d.taxonomyName.isEmpty ? "Create a taxonomy on the Allocation screen" : "Nothing to allocate yet")
                .frame(minHeight: 180, idealHeight: 220, maxHeight: .infinity)
            GapNote(gaps: d.gaps)
        }
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
        // Tooltips show the exact signed value; cells the longest form that still fits a loss
        // ("-0,8 %" is one glyph wider than "5,4 %" — and a loss is what one looks for here).
        var format = ChartValueFormat.percent(decimals: 2, signed: true)
        let text = HeatmapCellText.best(forTileWidth: width, yearLabel: rows.first?.label ?? "2000")
        format.compact = text.format
        return HeatmapGrid(rows: rows, columns: ChartLabels.shortMonths, format: format, totalTitle: "Year", title: "Monthly returns")
            .pinnedHover(row: pinsHover ? rows.first?.id ?? "" : "", column: 2)
            .loading(isRefreshing)
            .emptyMessage("No returns yet")
            .overlay(alignment: .bottomTrailing) {
                // Cells without a percent sign: name the unit once, next to the scale.
                if text != .percent, !rows.isEmpty {
                    Text("Returns in %").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 5)
                }
            }
    }

    // MARK: Lists

    private func movers(_ d: WidgetData.Movers) -> some View {
        Group {
            if d.best.isEmpty && d.worst.isEmpty {
                WidgetEmpty(d.positionCount == 0 ? (request.query.dayMode ? "No positions with a recent quote" : "No positions in this period")
                            : (request.query.dayMode ? "No price changes on the latest quoted day" : "Nothing moved in this period"))
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
                                Text(row.isValued ? Fmt.percent(row.weight, decimals: 1) : Fmt.missing).numeric().foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                if !isCompact {
                                    Group {
                                        if row.isValued {
                                            Text(Fmt.moneyRounded(row.value)).numeric()
                                        } else {
                                            UnvaluedMark(help: "\(row.name) has no price or exchange rate — its value is unknown and not part of any total.")
                                        }
                                    }
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
                    GapNote(gaps: d.gaps).padding(.top, DS.Spacing.xs)
                }
            }
        }
    }

    private func cash(_ d: WidgetData.Cash) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .center, spacing: DS.Spacing.s) {
                Text(Fmt.money(d.total)).font(.kontorHero).lineLimit(1).minimumScaleFactor(0.6)
                GapBadge(gaps: d.gaps)
            }
            if d.rows.isEmpty {
                Text("No cash accounts in this scope").font(.callout).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(d.rows) { row in
                        RowLink(help: "Show \(row.name)") { store.navigate(to: .account(row.id)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                                Text(row.name).lineLimit(1).foregroundStyle(.secondary)
                                Spacer(minLength: DS.Spacing.s)
                                if !row.isValued {
                                    UnvaluedMark(help: "No \(row.balance.currency) → \(d.total.currency) exchange rate: this balance is not part of the total.")
                                }
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

// MARK: - Text

enum WidgetText {
    /// The day a change refers to, for the middle of a sentence: "today", "yesterday", "3 days
    /// ago" — or a date, which keeps its capitals ("Dec 31, 2024", "31. Dez. 2024").
    static func changeDay(_ day: Day, today: Day) -> String {
        let text = Fmt.relativeDay(day, today: today)
        // Fmt falls back to a medium date beyond ±6 days; only the relative words are lower-cased.
        return abs(today.distance(to: day)) <= 6 ? text.lowercased() : text
    }
}

/// The text inside the cells of the monthly-returns grid, from most to least detailed. The grid
/// drops a label that does not fit its cell, so the widget picks the first form whose widest
/// realistic value — a two-digit loss — fits the cells it will get.
enum HeatmapCellText: CaseIterable {
    /// "5,4 %", "-0,8 %", "-12 %"
    case percent
    /// "5,4", "-0,8", "-12" — the unit is in the title and the tooltip.
    case number
    /// "5", "-1", "-12"
    case rounded

    var format: @Sendable (Double) -> String {
        switch self {
        case .percent: { Fmt.percent($0, decimals: abs($0) >= 0.0995 ? 0 : 1) }
        case .number: { Fmt.number($0 * 100, decimals: abs($0) >= 0.0995 ? 0 : 1) }
        case .rounded: { Fmt.number($0 * 100, decimals: 0) }
        }
    }

    /// Width of the widest label this form produces for monthly returns (losses up to −99 %), in
    /// the grid's cell font (10 pt, tabular digits).
    @MainActor var widestLabel: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        return [-0.088, -0.888].map { (format($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    /// The width of a month cell of a `HeatmapGrid` with twelve columns and a total column that is
    /// `gridWidth` wide (mirrors the grid's metrics: year label + 10, 8 pt before the total column,
    /// which is 1.25 cells wide).
    @MainActor static func cellWidth(gridWidth: CGFloat, yearLabel: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let label = (yearLabel as NSString).size(withAttributes: [.font: font]).width + 10
        return max(4, (gridWidth - label - 8) / 13.25)
    }

    @MainActor static func best(forCellWidth cell: CGFloat) -> HeatmapCellText {
        // The grid keeps 2 pt between cells and wants 4 pt of air around a label.
        allCases.first { $0.widestLabel <= cell - 7 } ?? .rounded
    }

    @MainActor static func best(forTileWidth width: CGFloat, yearLabel: String) -> HeatmapCellText {
        best(forCellWidth: cellWidth(gridWidth: width - 2 * DS.Spacing.l, yearLabel: yearLabel))
    }
}

// MARK: - Building blocks

/// A warning next to a total that leaves something out because it cannot be valued (missing
/// exchange rate or price). The tooltip lists what is missing; a click opens the consistency report.
struct GapBadge: View {
    @Environment(PortfolioStore.self) private var store
    let gaps: WidgetData.Gaps

    var body: some View {
        if !gaps.isEmpty {
            Button { store.present(.consistencyReport) } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(DS.Colors.warning)
            }
            .buttonStyle(.plain)
            .help(gaps.help + "\nClick to open the consistency report.")
            .accessibilityLabel("Incomplete: \(gaps.summary)")
        }
    }
}

/// The same warning as a line of text below a chart or list.
struct GapNote: View {
    @Environment(PortfolioStore.self) private var store
    let gaps: WidgetData.Gaps

    var body: some View {
        if !gaps.isEmpty {
            Button { store.present(.consistencyReport) } label: {
                Label(gaps.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.warning)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help(gaps.help + "\nClick to open the consistency report.")
        }
    }
}

/// Marks one row whose value is unknown.
struct UnvaluedMark: View {
    let help: String

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(DS.Colors.warning)
            .help(help)
            .accessibilityLabel(help)
    }
}

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
