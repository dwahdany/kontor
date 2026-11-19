import SwiftUI
import KontorUI

/// "Risk": volatility figures, the drawdown episodes and the distribution of returns.
struct RiskTab: View {
    enum Distribution: String, CaseIterable, Identifiable {
        case daily, monthly
        var id: String { rawValue }
        var title: String { self == .daily ? "Daily" : "Monthly" }
    }

    @Environment(PortfolioStore.self) private var store
    @Binding var model: Loadable<RiskModel>
    let isWide: Bool
    /// Shows a drawdown episode in the main chart.
    let showInChart: (DayInterval) -> Void

    @State private var distribution = Distribution.monthly
    @SceneStorage("performance.distribution") private var storedDistribution = Distribution.monthly

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            tiles.opacity(model.isRefreshing ? 0.6 : 1)
            if isWide {
                HStack(alignment: .top, spacing: DS.Spacing.l) {
                    drawdowns
                    histogram.frame(width: 470)
                }
            } else {
                drawdowns
                histogram
            }
        }
        .analysisTask($model, id: "performance.risk") { RiskModel($0) }
        .onAppear { distribution = store.launchValue("distribution", as: Distribution.self) ?? storedDistribution }
        .onChange(of: distribution) { _, value in storedDistribution = value }
    }

    private var tiles: some View {
        let m = model.value
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.s) { tileViews(m, minWidth: 150) }
            VStack(spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) { tileViews(m, minWidth: 0, range: 0..<3) }
                HStack(spacing: DS.Spacing.s) { tileViews(m, minWidth: 0, range: 3..<5) }
            }
        }
    }

    @ViewBuilder private func tileViews(_ m: RiskModel?, minWidth: CGFloat, range: Range<Int> = 0..<5) -> some View {
        ForEach(Array(range), id: \.self) { index in
            Group {
                switch index {
                case 0:
                    MetricTile("Volatility", topic: .volatility, value: m.map { Fmt.percent($0.volatility) } ?? Fmt.missing,
                               footnote: "per year, from daily returns")
                case 1:
                    MetricTile("Downside Volatility", topic: .semiVolatility, value: m.map { Fmt.percent($0.semiVolatility) } ?? Fmt.missing,
                               footnote: "only the below-average days")
                case 2:
                    MetricTile("Sharpe Ratio", topic: .sharpeRatio,
                               value: m.map { $0.showsSharpeRatio ? Fmt.ratio($0.sharpeRatio) : Fmt.missing } ?? Fmt.missing,
                               footnote: m.map {
                                   $0.showsSharpeRatio
                                       ? "\(Fmt.percent($0.annualizedReturn, signed: true)) per year vs. \(Fmt.percent($0.riskFreeRate)) risk-free"
                                       : "needs a period of at least a year"
                               })
                case 3:
                    MetricTile("Max Drawdown", topic: .maxDrawdown,
                               value: m.map { Fmt.percent(-($0.maxDrawdown?.depth ?? 0)) } ?? Fmt.missing,
                               footnote: m.map { $0.maxDrawdown.map { "\(Fmt.duration(days: $0.declineDays)) from peak to low" } ?? "never below a peak" })
                default:
                    MetricTile("Below Last Peak", topic: .maxDrawdown,
                               value: m.map { Fmt.percent(-$0.currentDrawdown) } ?? Fmt.missing,
                               footnote: m.map { $0.currentDrawdown > 0 ? "at the end of the period" : "at a new high" })
                }
            }
            .frame(minWidth: minWidth)
        }
    }

    // MARK: Drawdowns

    private var drawdowns: some View {
        Card("Drawdowns", symbol: "arrow.down.right") {
            if let m = model.value, !m.episodes.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: 0) {
                        GridRow {
                            ColumnCaption("Depth")
                            ColumnCaption("Peak").frame(maxWidth: .infinity, alignment: .trailing)
                            ColumnCaption("Low").frame(maxWidth: .infinity, alignment: .trailing)
                            ColumnCaption("Recovered").frame(maxWidth: .infinity, alignment: .trailing)
                            ColumnCaption("Decline").frame(maxWidth: .infinity, alignment: .trailing)
                            ColumnCaption("Recovery").frame(maxWidth: .infinity, alignment: .trailing)
                            ColumnCaption("Under Water").frame(maxWidth: .infinity, alignment: .trailing)
                            Text("")
                        }
                        .padding(.bottom, DS.Spacing.xs)
                        ForEach(m.episodes) { episode in
                            Divider().gridCellUnsizedAxes(.horizontal)
                            DrawdownRow(episode: episode, interval: m.interval, show: showInChart)
                        }
                    }
                    .font(.callout)
                    .numeric()
                    Text(m.episodeCount > m.episodes.count
                         ? "The \(m.episodes.count) deepest of \(Fmt.integer(m.episodeCount)) drawdowns of 1% or more. Depth is the fall from the previous peak."
                         : "Every fall of 1% or more from a previous peak. Recovery is the time from the low back to that peak.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, DS.Spacing.xs)
                }
                .opacity(model.isRefreshing ? 0.6 : 1)
            } else if model.value != nil {
                Text("No drawdown of 1% or more in this period")
                    .font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Color.clear.frame(height: 200)
            }
        } accessory: {
            HelpButton(.maxDrawdown)
        }
    }

    // MARK: Distribution

    private var histogram: some View {
        Card("Distribution of Returns", symbol: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                DistributionChart(currentHistogram, format: .percent(decimals: distribution == .daily ? 2 : 1, signed: true),
                                  title: "\(distribution.title) returns")
                    .markers(mean: true, median: true)
                    .loading(model.isLoading)
                    .emptyMessage(distribution == .daily ? "Not enough trading days for a distribution" : "Not enough complete months for a distribution")
                    .frame(height: 250)
                // A blank line keeps the card's height when there is nothing to describe.
                Text(caption ?? " ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } accessory: {
            Picker("Returns", selection: $distribution) {
                ForEach(Distribution.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    private var currentHistogram: Histogram {
        guard let m = model.value else { return Histogram([], targetBins: 1) }
        return distribution == .daily ? m.dailyHistogram : m.monthlyHistogram
    }

    /// Describes the histogram; nil while the chart shows its empty state (fewer than two values).
    private var caption: String? {
        guard let m = model.value, currentHistogram.total >= 2 else { return nil }
        return distribution == .daily
            ? "\(Plural.count(m.dailyCount, "trading day", "trading days")). A wide spread means a bumpy ride."
            : "\(Plural.count(m.monthlyCount, "complete month", "complete months")). A wide spread means a bumpy ride."
    }
}

private struct DrawdownRow: View {
    @Environment(\.gainStyle) private var gainStyle
    let episode: DrawdownEpisode
    let interval: DayInterval
    let show: (DayInterval) -> Void

    var body: some View {
        GridRow {
            Text(Fmt.percent(-episode.depth)).foregroundStyle(gainStyle.loss).fontWeight(.medium)
            Text(Fmt.day(episode.peak, style: .medium))
            Text(Fmt.day(episode.trough, style: .medium))
            if let recovery = episode.recovery {
                Text(Fmt.day(recovery, style: .medium))
            } else {
                Text("not yet").foregroundStyle(.secondary)
            }
            Text(Fmt.duration(days: episode.declineDays, style: .compact))
            Text(episode.recoveryDays.map { Fmt.duration(days: $0, style: .compact) } ?? Fmt.missing)
                .foregroundStyle(episode.recovery == nil ? .tertiary : .primary)
            Text(Fmt.duration(days: episode.durationDays, style: .compact) + (episode.recovery == nil ? "+" : ""))
            Button("Show in Chart", systemImage: "chart.xyaxis.line") {
                show(DayInterval(start: max(episode.peak, interval.start), end: episode.recovery ?? interval.end))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show this drawdown in the chart")
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
