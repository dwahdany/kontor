import SwiftUI
import KontorUI

/// Bars per month, quarter or year with the rolling 12-month average, and the breakdown of the
/// whole interval — or of the selected bar — next to it.
struct EarningsChartView: View {
    let model: EarningsModel
    @Binding var options: EarningsChartOptions
    let isRefreshing: Bool
    /// Show the dividend payments of a range of months (each `year × 12 + month − 1`).
    let showPayments: (ClosedRange<Int>) -> Void

    private var chart: EarningsModel.Chart { model.charts[options.grouping] ?? EarningsModel.Chart() }
    private var stacks: Bool { options.stacksBySecurity && chart.bySecurity != nil }

    var body: some View {
        GeometryReader { proxy in
            // The chart takes the height the window offers (never less than a readable minimum).
            let chartHeight = max(280, min(560, proxy.size.height - 132))
            ScrollView {
                Group {
                    if proxy.size.width >= 980 {
                        HStack(alignment: .top, spacing: DS.Spacing.l) {
                            chartCard(height: chartHeight)
                            breakdownCard.frame(width: 290)
                        }
                    } else {
                        VStack(spacing: DS.Spacing.l) {
                            chartCard(height: 280)
                            breakdownCard
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
        .onChange(of: options.grouping) { _, _ in options.selection = nil }
    }

    // MARK: Chart

    private func chartCard(height: CGFloat) -> some View {
        let chart = chart
        let series = stacks ? chart.bySecurity! : chart.plain
        return Card {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text("\(model.kind.title) per \(options.grouping.title)")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(Fmt.money(minor: model.totalValue, currency: model.currency)) in total")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .numeric()
                    }
                    Spacer(minLength: DS.Spacing.s)
                    Toggle("By Security", isOn: $options.stacksBySecurity)
                        .disabled(chart.bySecurity == nil)
                        .help(chart.bySecurity == nil
                              ? "Only dividends can be split by security."
                              : "Stack each bar by the securities that paid.")
                    Toggle("12-Month Average", isOn: $options.showsAverage)
                        .disabled(chart.average == nil)
                        .help(chart.average == nil
                              ? "Needs at least twelve months of monthly or quarterly bars."
                              : "A line through the average of the twelve months up to each bar: the trend without the seasons.")
                    Picker("Bars", selection: $options.grouping) {
                        ForEach(EarningsGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                // All bars zero: let the chart say so instead of drawing an empty axis.
                BarSeriesChart(
                    categories: chart.isEmpty ? [] : chart.categories, series: chart.isEmpty ? [] : series, format: .money(model.currency),
                    layout: .stacked, coloring: model.kind == .net ? .gainLoss : .series,
                    title: "\(model.kind.title) per \(options.grouping.title.lowercased())")
                    .overlayLine(options.showsAverage ? chart.average.map { BarOverlayLine("12-month average", values: $0) } : nil)
                    .selection(options.selection) { options.selection = $0 }
                    .pinnedHover(options.pinnedHover)
                    .legendHidden(series.count < 2 && !(options.showsAverage && chart.average != nil))
                    .loading(isRefreshing)
                    .emptyMessage("No \(model.kind.title.lowercased()) in this period — try another figure above")
                    .frame(height: height)
            }
        }
    }

    // MARK: Breakdown

    private var selectedIndex: Int? {
        guard let id = options.selection else { return nil }
        return chart.categories.firstIndex { $0.id == id }
    }

    private var breakdownCard: some View {
        let index = selectedIndex
        let amounts = index.map { chart.amounts[$0] } ?? model.total
        let title = index.map { chart.categories[$0].detail } ?? "Whole Period"
        return Card(title, symbol: "list.bullet.indent") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                line("Dividends", amounts.dividends, kind: .dividends)
                line("Interest", amounts.interest, kind: .interest)
                if amounts.interestCharges != 0 {
                    line("Interest Paid", -amounts.interestCharges, kind: nil)
                }
                line("Fees", -amounts.fees, kind: .fees)
                line("Taxes", -amounts.taxes, kind: .taxes)
                Divider()
                HStack {
                    HelpLabel("Net", topic: .grossVersusNet).fontWeight(.semibold)
                    Spacer()
                    Text(Fmt.money(minor: amounts.net, currency: model.currency))
                        .fontWeight(.semibold)
                        .numeric()
                }
                if index == nil {
                    Divider()
                    fact("Dividend Payments", Fmt.integer(model.paymentCount))
                    fact("Months", Fmt.integer(model.monthCount))
                    if model.monthCount > 0 {
                        fact("\(model.kind.shortTitle) per Month",
                             Fmt.money(minor: model.totalValue / Int64(model.monthCount), currency: model.currency))
                    }
                } else {
                    // The Payments view lists dividend payments: offered where the bar has any.
                    let months = amounts.dividends != 0 ? options.selection.flatMap(EarningsRules.months(ofBar:)) : nil
                    HStack {
                        if let months {
                            Button("Dividend Payments", systemImage: "list.bullet") { showPayments(months) }
                                .help("Lists the dividend payments of \(title). Interest, fees and taxes have no list of their own here — find them under Transactions.")
                        }
                        Spacer()
                        Button("Clear Selection") { options.selection = nil }
                            .buttonStyle(.link)
                    }
                    .lineLimit(1)
                    .controlSize(.small)
                    .padding(.top, DS.Spacing.xs)
                }
                Text(index == nil ? "Select a bar to see its breakdown. \(model.kind.explanation)" : model.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.xs)
            }
        }
    }

    private func line(_ title: String, _ minor: Int64, kind: EarningsKind?) -> some View {
        let isSelected = kind != nil && (kind == model.kind
            || (model.kind == .earnings && (kind == .dividends || kind == .interest)))
        return HStack(spacing: DS.Spacing.s) {
            Circle()
                .fill(kind?.color ?? ChartColors.neutral)
                .frame(width: 8, height: 8)
                .opacity(isSelected || model.kind == .net ? 1 : 0.35)
            Text(title)
                .foregroundStyle(isSelected || model.kind == .net ? .primary : .secondary)
            Spacer()
            Text(minor == 0 ? Fmt.missing : Fmt.money(minor: minor, currency: model.currency))
                .numeric()
                .foregroundStyle(minor == 0 ? .tertiary : .primary)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(value).numeric()
        }
    }
}

