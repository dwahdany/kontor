import SwiftUI
import KontorUI

// MARK: - Header tiles

/// A stat tile with an optional ⓘ and a free-form value (KontorUI's `StatTile` takes plain text only).
struct MetricTile<Value: View>: View {
    let label: String
    var topic: HelpTopic?
    var footnote: String?
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(label)
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let topic { HelpButton(topic).font(.caption) }
                Spacer(minLength: 0)
            }
            value
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

/// The six header figures, all taken from the engine's `TradeStatistics` of the filtered trades.
struct TradeTiles: View {
    @Environment(\.gainStyle) private var gainStyle
    let model: TradeListModel
    let thresholdDays: Int
    let width: CGFloat

    private var stats: TradeStatistics { model.statistics }
    private var isClosed: Bool { model.kind == .closed }
    private var isCompact: Bool { width < 960 }
    private var heroFont: Font { isCompact ? .system(size: 20, weight: .semibold, design: .rounded) : .kontorHero }

    var body: some View {
        HStack(spacing: isCompact ? DS.Spacing.s : DS.Spacing.m) {
            MetricTile(label: isClosed ? "Closed Trades" : "Open Trades", topic: .trade, footnote: outcomeFootnote) {
                Text(Fmt.integer(stats.count)).font(heroFont).numeric()
            }
            MetricTile(label: isClosed ? "Win Rate" : "In Profit", footnote: "\(isCompact ? "avg." : "avg. return") \(Fmt.percent(stats.averageReturn, decimals: 1, signed: true))") {
                Text(Fmt.percent(stats.winRate, decimals: 1)).font(heroFont).numeric()
            }
            MetricTile(
                label: isClosed ? "Realized Gain" : (isCompact ? "Unrealized" : "Unrealized Gain"), topic: isClosed ? .realizedGains : .unrealizedGains,
                footnote: isClosed ? (isCompact ? "before taxes" : "after fees, before taxes") : "at market value"
            ) {
                Text(signedMoney(stats.totalGain))
                    .font(heroFont).numeric()
                    .foregroundStyle(stats.count == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(gainStyle.color(forMinor: stats.totalGain)))
            }
            MetricTile(label: isClosed ? "Avg. Win / Loss" : "Avg. Gain / Loss") {
                VStack(alignment: .leading, spacing: 1) {
                    averageLine("▲", stats.averageGain, sign: 1)
                    averageLine("▼", stats.averageLoss, sign: -1)
                }
            }
            MetricTile(label: "Profit Factor", topic: .profitFactor, footnote: profitFootnote) {
                Text(Fmt.ratio(stats.profitFactor)).font(heroFont).numeric()
            }
            MetricTile(label: isCompact ? "Avg. Holding" : "Avg. Holding Period", topic: .holdingPeriod, footnote: holdingFootnote) {
                Text(stats.averageHoldingDays.map { Fmt.duration(days: Int($0.rounded())) } ?? Fmt.missing).font(heroFont).numeric()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var outcomeFootnote: String {
        guard stats.count > 0 else { return model.totalCount > 0 ? "no trades match" : isClosed ? "none in this period" : "nothing held" }
        return isClosed
            ? "\(Fmt.integer(stats.winners)) won · \(Fmt.integer(stats.losers)) lost"
            : "\(Fmt.integer(stats.winners)) up · \(Fmt.integer(stats.losers)) down"
    }

    private var profitFootnote: String {
        guard stats.count > 0 else { return "profit ÷ loss" }
        if stats.grossLoss == 0 { return isClosed ? "no losing trades" : "no positions at a loss" }
        return "\(Fmt.compactMoney(minor: stats.grossProfit, currency: model.currency)) ÷ \(Fmt.compactMoney(minor: stats.grossLoss, currency: model.currency))"
    }

    private var holdingFootnote: String {
        guard stats.count > 0 else { return "long-term: > \(LongTermThreshold.title(days: thresholdDays))" }
        let share = "\(Fmt.integer(model.longTermCount)) of \(Fmt.integer(stats.count))"
        return isCompact ? "\(share) long-term" : "\(share) over \(LongTermThreshold.title(days: thresholdDays))"
    }

    /// Whole currency units in compact tiles, exact amounts otherwise.
    private func signedMoney(_ minor: Int64) -> String {
        guard stats.count > 0 else { return Fmt.missing }
        let money = Money(minor: minor, currency: model.currency)
        if isCompact || abs(minor) >= 100_000_000 {
            return (minor > 0 ? "+" : "") + Fmt.moneyRounded(money)
        }
        return Fmt.money(money, signed: true)
    }

    private func averageLine(_ arrow: String, _ value: Double?, sign: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(arrow)
                .font(.system(size: 8))
                .baselineOffset(2)
                .accessibilityLabel(sign > 0 ? "Average win" : "Average loss")
            if let value {
                let money = Money(minor: sign * FixedMath.saturatingInt64(value), currency: model.currency)
                Text(isCompact ? (sign > 0 ? "+" : "") + Fmt.moneyRounded(money) : Fmt.money(money, signed: true))
            } else {
                Text(Fmt.missing)
            }
        }
        .font(isCompact ? .system(size: 15, weight: .medium) : .kontorValue)
        .numeric()
        .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(sign > 0 ? gainStyle.gain : gainStyle.loss))
    }
}

// MARK: - Filters

/// Result / holding period / year / depot filters: separate pop-up buttons when there is room,
/// one "Filters" menu otherwise.
struct TradeFilterMenu: View {
    let kind: TradeKind
    /// Separate pop-up buttons (true) or one "Filters" menu (false).
    let isExpanded: Bool
    @Binding var outcome: OutcomeFilter
    @Binding var holding: HoldingFilter
    @Binding var year: Int?
    @Binding var depotID: UUID?
    @Binding var thresholdDays: Int
    let years: [Int]
    let depots: [TradeListModel.NamedID]

    private var activeCount: Int {
        (outcome != .all ? 1 : 0) + (holding != .all ? 1 : 0) + (year != nil ? 1 : 0) + (depotID != nil ? 1 : 0)
    }

    var body: some View {
        Group {
            if isExpanded {
            HStack(spacing: DS.Spacing.s) {
                Menu(outcome.title(kind)) { outcomeItems }
                Menu(holdingTitle) { holdingItems }
                Menu(year.map { String($0) } ?? "All Years") { yearItems }
                if depots.count > 1 {
                    Menu(depots.first { $0.id == depotID }?.name ?? "All Depots") { depotItems }
                }
            }
            .fixedSize()
            } else {
            Menu {
                Section("Result") { outcomeItems }
                Section("Holding Period") { holdingItems }
                Menu(kind == .closed ? "Closing Year" : "Opening Year") { yearItems }
                if depots.count > 1 {
                    Menu("Depot") { depotItems }
                }
                if activeCount > 0 {
                    Divider()
                    Button("Clear Filters") {
                        outcome = .all
                        holding = .all
                        year = nil
                        depotID = nil
                    }
                }
            } label: {
                Label(activeCount > 0 ? "Filters (\(activeCount))" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            }
        }
        .menuStyle(.button)
        .controlSize(.regular)
    }

    private var holdingTitle: String {
        switch holding {
        case .all: "Any Holding Period"
        case .longTerm: "Long-Term (> \(LongTermThreshold.title(days: thresholdDays)))"
        case .shortTerm: "Short-Term (≤ \(LongTermThreshold.title(days: thresholdDays)))"
        }
    }

    @ViewBuilder private var outcomeItems: some View {
        Picker("Result", selection: $outcome) {
            ForEach(OutcomeFilter.allCases) { Text($0.title(kind)).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    @ViewBuilder private var holdingItems: some View {
        Picker("Holding Period", selection: $holding) {
            Text("Any Holding Period").tag(HoldingFilter.all)
            Text("Long-Term — held more than \(LongTermThreshold.title(days: thresholdDays))").tag(HoldingFilter.longTerm)
            Text("Short-Term — held up to \(LongTermThreshold.title(days: thresholdDays))").tag(HoldingFilter.shortTerm)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Picker("Long-Term After", selection: $thresholdDays) {
            ForEach(thresholdChoices, id: \.self) { Text(LongTermThreshold.title(days: $0)).tag($0) }
        }
        .pickerStyle(.menu)
    }

    private var thresholdChoices: [Int] {
        LongTermThreshold.presets.contains(thresholdDays) ? LongTermThreshold.presets : (LongTermThreshold.presets + [thresholdDays]).sorted()
    }

    @ViewBuilder private var yearItems: some View {
        Picker("Year", selection: $year) {
            Text("All Years").tag(Int?.none)
            ForEach(yearChoices, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var yearChoices: [Int] {
        guard let year, !years.contains(year) else { return years }
        return (years + [year]).sorted(by: >)
    }

    @ViewBuilder private var depotItems: some View {
        Picker("Depot", selection: $depotID) {
            Text("All Depots").tag(UUID?.none)
            ForEach(depots) { Text($0.name).tag(UUID?.some($0.id)) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

// MARK: - Charts

/// The charts of the trade lists (`--state chart=…`).
enum TradeChartKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case period, distribution, cumulative, holding

    var id: String { rawValue }

    static func available(for kind: TradeKind) -> [TradeChartKind] {
        kind == .closed ? [.period, .distribution, .cumulative, .holding] : [.period, .distribution, .holding]
    }

    func title(_ model: TradeListModel) -> String {
        switch self {
        case .period: model.charts.byPeriodTitle
        case .distribution: "Distribution of Returns"
        case .cumulative: "Cumulative Realized Gain"
        case .holding: "Avg. Return by Holding Period"
        }
    }
}

/// As many chart cards as fit side by side; the first one can be switched when not all fit.
struct TradeChartStrip: View {
    let model: TradeListModel
    @Binding var lead: TradeChartKind
    let width: CGFloat
    let isRefreshing: Bool
    let pinsHover: Bool

    private var visible: [TradeChartKind] {
        let all = TradeChartKind.available(for: model.kind)
        let count = min(all.count, max(1, Int(width / 340)))
        guard count < all.count else { return all }
        let start = all.firstIndex(of: lead) ?? 0
        return (0..<count).map { all[(start + $0) % all.count] }
    }

    var body: some View {
        let all = TradeChartKind.available(for: model.kind)
        let shown = visible
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, kind in
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    if index == 0, shown.count < all.count {
                        Menu {
                            Picker("Chart", selection: $lead) {
                                ForEach(all) { Text($0.title(model)).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                Text(kind.title(model)).font(.headline)
                                Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Choose the chart shown here")
                    } else {
                        Text(kind.title(model))
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                    }
                    chart(kind)
                        .frame(height: 128)
                }
                .padding(DS.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        }
    }

    @ViewBuilder private func chart(_ kind: TradeChartKind) -> some View {
        let charts = model.charts
        let noun = model.kind == .closed ? "closed trades" : "open trades"
        switch kind {
        case .period:
            BarSeriesChart(
                categories: charts.byPeriod.categories, values: charts.byPeriod.values,
                name: model.kind == .closed ? "Realized gain" : "Unrealized gain", format: .money(model.currency), title: kind.title(model))
                .pinnedHover(pinsHover ? charts.byPeriod.categories.last?.id : nil)
                .loading(isRefreshing)
                .emptyMessage("No \(noun) match")
        case .distribution:
            DistributionChart(charts.returns, format: .percent(decimals: 0, signed: true, compounding: false), title: kind.title(model))
                .markers(mean: false, median: true)
                .pinnedHover(bin: pinsHover ? charts.fullestBin : nil)
                .loading(isRefreshing)
                .emptyMessage(model.rows.isEmpty ? "No \(noun) match" : "A distribution needs a few more trades")
        case .cumulative:
            TimeSeriesChart(
                [TimeSeries("Realized gain", days: charts.cumulativeDays, values: charts.cumulativeValues, style: .stepArea)],
                format: .money(model.currency), title: kind.title(model))
                .legendHidden()
                .pinnedHover(pinsHover ? charts.cumulativeDays.last : nil)
                .loading(isRefreshing)
                .emptyMessage("No \(noun) match")
        case .holding:
            BarSeriesChart(
                categories: charts.byHolding.categories, values: charts.byHolding.values, name: "Average return",
                format: .percent(decimals: 1, signed: true, compounding: false), title: kind.title(model))
                .pinnedHover(pinsHover ? pinnedHoldingBucket : nil)
                .loading(isRefreshing)
                .emptyMessage("No \(noun) match")
        }
    }

    /// The bucket with the largest average return, for pinned tooltips.
    private var pinnedHoldingBucket: String? {
        let charts = model.charts
        guard let index = charts.byHolding.values.indices.max(by: { abs(charts.byHolding.values[$0]) < abs(charts.byHolding.values[$1]) }) else { return nil }
        return charts.byHolding.categories[index].id
    }
}
