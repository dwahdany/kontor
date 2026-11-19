import SwiftUI
import KontorModel
import KontorEngine

/// A debug gallery of every chart component, fed with the open portfolio's data. It is not part
/// of the app's navigation — only the screenshot mode shows it:
///
/// ```sh
/// Scripts/shot.sh none chart-gallery /tmp/charts/ --appearance both --today 2026-06-30 --period ALL --state page=time
/// ```
///
/// Launch state: `page` = `time` (default) | `bars` | `parts` | `grids` | `states`;
/// `patterns` = `on` forces the Differentiate-Without-Color textures.
///
/// It doubles as the reference for how the charts are fed: everything is derived once, off the
/// main actor, into the `Sendable` ``Model``.
public struct ChartGallery: View {
    enum Page: String { case time, bars, parts, grids, states }

    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<Model>()
    @State private var page = Page.time
    @State private var patterns = false
    @State private var selectedSlice: String?

    public init() {}

    public var body: some View {
        // Value snapshot of what the model needs besides the analysis; part of the cache key.
        let taxonomy = store.file.taxonomies.first
        ScrollView {
            Group {
                if let model = model.value {
                    switch page {
                    case .time: timePage(model)
                    case .bars: barsPage(model)
                    case .parts: partsPage(model)
                    case .grids: gridsPage(model)
                    case .states: statesPage(model)
                    }
                }
            }
            .padding(DS.Spacing.l)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.chartPatternsForced, patterns)
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "chart-gallery.model", variant: taxonomy) { analysis in Model(analysis, taxonomy: taxonomy) }
        .onAppear {
            page = store.launchValue("page", as: Page.self) ?? page
            patterns = store.launchValue("patterns") == "on"
        }
    }

    private let columns2 = [
        GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top), GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top),
    ]

    // MARK: Pages

    private func timePage(_ m: Model) -> some View {
        LazyVGrid(columns: columns2, spacing: DS.Spacing.l) {
            Card("TimeSeriesChart — area + step, hovered", symbol: "chart.xyaxis.line") {
                TimeSeriesChart([
                    TimeSeries("Portfolio", points: m.value, style: .area),
                    TimeSeries("Invested", start: m.start, values: m.invested, style: .step, color: ChartColors.comparison),
                ], format: .money(m.currency), title: "Portfolio value")
                .pinnedHover(m.day(0.62))
                .frame(height: 300)
            }
            Card("Returns vs. benchmark — underwater panel", symbol: "chart.line.uptrend.xyaxis") {
                TimeSeriesChart([
                    TimeSeries("Portfolio", points: m.returns),
                    TimeSeries(m.benchmarkName, points: m.benchmark, color: ChartColors.comparison, dashed: true),
                ], format: .percent(signed: true), title: "Cumulative return")
                .underwater(TimeSeries("Drawdown", start: m.start, values: m.drawdown))
                .pinnedHover(m.day(0.34))
                .frame(height: 300)
            }
            Card("Price with markers — range selected", symbol: "arrow.left.and.right") {
                TimeSeriesChart([TimeSeries(m.securityName, start: m.start, values: m.price)],
                                format: .price(m.currency), baseline: .data, title: "Price of \(m.securityName)")
                    .markers(m.markers)
                    .rangeSelection()
                    .pinnedRange(DayInterval(start: m.day(0.42), end: m.day(0.63)))
                    .frame(height: 280)
            }
            Card("25 years of daily data — three series", symbol: "speedometer") {
                TimeSeriesChart(m.longSeries, format: .percent(decimals: 1, signed: true), title: "Synthetic long series")
                    .frame(height: 280)
            }
        }
    }

    private func barsPage(_ m: Model) -> some View {
        LazyVGrid(columns: columns2, spacing: DS.Spacing.l) {
            Card("BarSeriesChart — stacked, overlay line, hovered", symbol: "chart.bar") {
                BarSeriesChart(categories: m.months, series: [
                    BarSeries("Dividends", values: m.dividends),
                    BarSeries("Interest", values: m.interest),
                ], format: .money(m.currency), layout: .stacked, title: "Earnings per month")
                .overlayLine(BarOverlayLine("12-month average", values: m.trailingAverage))
                .pinnedHover(m.months.indices.contains(m.months.count * 2 / 3) ? m.months[m.months.count * 2 / 3].id : nil)
                .frame(height: 250)
            }
            Card("BarSeriesChart — gain/loss, value labels, selection", symbol: "plusminus") {
                BarSeriesChart(categories: m.years, values: m.yearlyReturns, name: "Return", format: .percent(signed: true), title: "Return per year")
                    .valueLabels()
                    .selection(m.years.dropLast().last?.id) { _ in }
                    .frame(height: 250)
            }
            Card("BarSeriesChart — grouped", symbol: "chart.bar.xaxis") {
                BarSeriesChart(categories: m.years, series: [
                    BarSeries("Dividends", values: m.yearlyDividends),
                    BarSeries("Fees", values: m.yearlyFees),
                    BarSeries("Taxes", values: m.yearlyTaxes),
                ], format: .money(m.currency), title: "Earnings and costs per year")
                .frame(height: 230)
            }
            Card("DistributionChart — monthly returns", symbol: "chart.bar.fill") {
                DistributionChart(m.monthlyHistogram, format: .percent(decimals: 1, signed: true), title: "Monthly returns")
                    .markers(mean: true, median: true)
                    .pinnedHover(bin: m.monthlyHistogram.bins.count / 3)
                    .frame(height: 230)
            }
        }
    }

    private func partsPage(_ m: Model) -> some View {
        LazyVGrid(columns: columns2, spacing: DS.Spacing.l) {
            Card("DonutChart", symbol: "chart.pie") {
                DonutChart(m.slices, format: .money(m.currency), centerTitle: "Net Worth", title: "Asset classes")
                    .selection(selectedSlice) { selectedSlice = $0 }
                    .frame(height: 220)
            }
            Card("SunburstChart — hovered", symbol: "circle.circle") {
                SunburstChart(m.sunburst, format: .money(m.currency), centerTitle: m.taxonomyName, title: "Allocation")
                    .pinnedHover(m.sunburst.first?.children.first?.id)
                    .frame(height: 220)
            }
            Card("TreemapChart — by category", symbol: "square.grid.3x3.topleft.filled") {
                TreemapChart(m.treemap, format: .money(m.currency), title: "Holdings")
                    .frame(height: 290)
            }
            Card("TreemapChart — by performance, hovered", symbol: "square.grid.3x3.middle.filled") {
                TreemapChart(m.treemap, format: .money(m.currency), coloring: .performance(limit: nil), title: "Performance map")
                    .pinnedHover(m.treemapHoverID)
                    .frame(height: 290)
            }
        }
    }

    private func gridsPage(_ m: Model) -> some View {
        LazyVGrid(columns: columns2, alignment: .leading, spacing: DS.Spacing.l) {
            Card("HeatmapGrid — year × month, hovered", symbol: "tablecells") {
                HeatmapGrid(m.heatmap)
                    .pinnedHover(row: m.heatmap.rows.dropLast().last.map { String($0.year) } ?? "", column: 4)
            }
            Card("WaterfallChart — performance breakdown", symbol: "chart.bar.doc.horizontal") {
                WaterfallChart(m.waterfall, format: .money(m.currency), title: "Performance breakdown")
                    .pinnedHover(m.waterfall.dropFirst(2).first?.id)
            }
            Card("TargetActualBar", symbol: "target") {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
                    ForEach(m.targets) { target in
                        GridRow {
                            CategoryTag(target.name, color: target.color)
                            Text(Fmt.percent(target.actual, decimals: 1)).numeric().gridColumnAlignment(.trailing)
                            TargetActualBar(actual: target.actual, target: target.target, maximum: m.targetMaximum, color: target.color, tolerance: 0.03)
                        }
                    }
                }
                .font(.callout)
            }
            Card("Sparkline · ChartLegend", symbol: "waveform.path.ecg") {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    HStack(spacing: DS.Spacing.xl) {
                        ForEach(Array(m.sparklines.enumerated()), id: \.offset) { _, values in
                            Sparkline(values).frame(width: 96, height: 28)
                        }
                    }
                    ChartLegend((0..<CategoryPalette.count).map {
                        ChartLegendItem(id: "\($0)", name: "Series \($0 + 1)", color: ChartColors.series($0), pattern: .slot($0))
                    })
                    ChartLegend([
                        ChartLegendItem(id: "a", name: "Line", color: ChartColors.series(0), mark: .line(dash: [])),
                        ChartLegendItem(id: "b", name: "Benchmark", color: ChartColors.comparison, mark: .line(dash: [5, 3])),
                        ChartLegendItem(id: "c", name: "Other", color: ChartColors.other),
                    ])
                }
            }
        }
    }

    private func statesPage(_ m: Model) -> some View {
        LazyVGrid(columns: columns2, spacing: DS.Spacing.l) {
            Card("Empty") {
                TimeSeriesChart([], format: .money(m.currency)).frame(height: 150)
            }
            Card("Loading without data") {
                BarSeriesChart(categories: [], series: [], format: .money(m.currency)).loading(true).frame(height: 150)
            }
            Card("Refreshing (last good value dimmed)") {
                TimeSeriesChart([TimeSeries("Portfolio", points: m.value, style: .area)], format: .money(m.currency))
                    .loading(true)
                    .frame(height: 170)
            }
            Card("Narrow donut — legend wraps below") {
                DonutChart(m.slices, format: .money(m.currency)).frame(width: 240, height: 230)
            }
            Card("Many months — labels thin out") {
                BarSeriesChart(categories: m.allMonths, values: m.allMonthlyReturns, name: "Monthly return", format: .percent(signed: true))
                    .frame(height: 190)
            }
            Card("Single-level sunburst, small heatmap") {
                HStack(alignment: .top, spacing: DS.Spacing.l) {
                    SunburstChart(m.sunburst, format: .money(m.currency)).levels(1).legendHidden().frame(width: 150, height: 150)
                    HeatmapGrid(m.heatmap).rowHeight(18).scaleHidden()
                }
            }
        }
    }

    // MARK: Model

    struct Target: Identifiable, Sendable {
        var id: String
        var name: String
        var color: Color
        var actual: Double
        var target: Double?
    }

    /// Everything the gallery shows — computed off the main actor from the shared `Analysis`.
    struct Model: Sendable {
        var currency: CurrencyCode
        var start: Day
        var end: Day
        var value: [ChartPoint<Int64>]
        var invested: [Int64]
        var returns: [ChartPoint<Double>]
        var benchmarkName = "Benchmark"
        var benchmark: [ChartPoint<Double>] = []
        var drawdown: [Double]
        var securityName = "Security"
        var price: [Double] = []
        var markers: [ChartMarker] = []
        var longSeries: [TimeSeries]
        var months: [BarCategory]
        var dividends: [Int64]
        var interest: [Int64]
        var trailingAverage: [Double?]
        var years: [BarCategory]
        var yearlyReturns: [Double]
        var yearlyDividends: [Int64]
        var yearlyFees: [Int64]
        var yearlyTaxes: [Int64]
        var allMonths: [BarCategory]
        var allMonthlyReturns: [Double]
        var monthlyHistogram: Histogram
        var taxonomyName = "Allocation"
        var slices: [ChartSlice] = []
        var sunburst: [ChartNode] = []
        var treemap: [ChartNode] = []
        var treemapHoverID: String?
        var heatmap: ReturnHeatmap
        var waterfall: [WaterfallStep]
        var targets: [Target] = []
        var targetMaximum = 1.0
        var sparklines: [[Double]]

        func day(_ fraction: Double) -> Day {
            start.advanced(by: Int((Double(start.distance(to: end)) * fraction).rounded()))
        }

        init(_ analysis: Analysis, taxonomy: Taxonomy?) {
            let ledger = analysis.ledger
            currency = analysis.currency
            start = analysis.interval.start
            end = analysis.interval.end
            value = analysis.valuation.chartPoints(maxPoints: 900)
            invested = analysis.investedCapital
            returns = analysis.returns.chartPoints(maxPoints: 900)
            drawdown = analysis.drawdowns.map { -$0 }
            if let id = ledger.settings.benchmarkSecurityIDs.first, let series = analysis.benchmark(securityID: id) {
                benchmarkName = ledger.security(id)?.name ?? benchmarkName
                benchmark = series.chartPoints(maxPoints: 900)
            }

            // The security with the most buys/sells in the period, with its markers.
            let interval = analysis.interval
            let candidates = ledger.securities.map { s in
                (s, ledger.transactions(forSecurity: s.id).filter { interval.contains($0.date) })
            }
            // Prefer one that was also sold and has a readable number of transactions.
            func rank(_ transactions: [KontorModel.Transaction]) -> Int {
                let sells = transactions.filter { $0.kind == .sell }.count
                return (sells > 0 ? 1_000 : 0) + (transactions.count >= 4 && transactions.count <= 40 ? 500 : 0) - transactions.count
            }
            if let (security, transactions) = candidates.max(by: { rank($0.1) < rank($1.1) }), let levels = ledger.priceLevels(securityID: security.id, in: interval) {
                securityName = security.name
                price = levels
                markers = ChartMarker.markers(for: transactions)
            }

            // 25 years of daily values × 3, deterministic.
            let longStart = Day(year: 2001, month: 1, day: 1)
            longSeries = (0..<3).map { k in
                var level = 0.0
                var seed = UInt64(k + 1) &* 0x9E37_79B9_7F4A_7C15
                let values: [Double] = (0..<9131).map { _ in
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let unit = Double(seed >> 11) / Double(1 << 53)
                    level += (unit - 0.497 + Double(k) * 0.0008) * 0.012
                    return exp(level) - 1
                }
                return TimeSeries(["Growth", "Balanced", "Defensive"][k], start: longStart, values: values)
            }

            let earnings = analysis.earnings
            let recent = Array(earnings.months.suffix(24))
            months = BarCategory.months(recent.map { ($0.year, $0.month) })
            dividends = recent.map(\.amounts.dividends)
            interest = recent.map(\.amounts.interest)
            let trailing = earnings.trailingTwelveMonths(.earnings).suffix(24)
            trailingAverage = trailing.map { $0.isComplete ? Double($0.value) / 12 : nil }

            let yearly = analysis.returns.yearlyReturns()
            years = yearly.map { BarCategory.year($0.year) }
            yearlyReturns = yearly.map(\.value)
            let byYear = Dictionary(uniqueKeysWithValues: earnings.years.map { ($0.year, $0.total) })
            yearlyDividends = yearly.map { byYear[$0.year]?.dividends ?? 0 }
            yearlyFees = yearly.map { byYear[$0.year]?.fees ?? 0 }
            yearlyTaxes = yearly.map { byYear[$0.year]?.taxes ?? 0 }

            let monthly = analysis.returns.monthlyReturns()
            allMonths = BarCategory.months(monthly.map { ($0.year, $0.month) })
            allMonthlyReturns = monthly.map(\.value)
            monthlyHistogram = Histogram(monthly.map(\.value), targetBins: 22)

            heatmap = analysis.heatmap
            waterfall = WaterfallStep.steps(from: analysis.breakdown)

            if let taxonomy {
                let allocation = analysis.allocation(for: taxonomy)
                let changes = Dictionary(uniqueKeysWithValues: analysis.securities.map { ($0.securityID, $0.ttwror) })
                taxonomyName = taxonomy.name
                slices = ChartSlice.slices(from: allocation)
                sunburst = ChartNode.nodes(from: allocation, includesItems: true)
                treemap = ChartNode.nodes(from: allocation, includesItems: true, changes: changes)
                // A mid-sized security to show the hover state on.
                func leaves(_ node: ChartNode) -> [ChartNode] { node.children.isEmpty ? [node] : node.children.flatMap(leaves) }
                treemapHoverID = treemap.first.map(leaves)?.sorted { $0.value > $1.value }.dropFirst(2).first?.id
                let total = Double(allocation.totalValue)
                targets = allocation.roots.enumerated().map { i, node in
                    Target(id: node.id.uuidString, name: node.name, color: ChartColors.classification(node.color, fallbackIndex: i),
                           actual: total > 0 ? Double(node.value) / total : 0, target: node.targetShare)
                }
                targetMaximum = max(0.1, (targets.flatMap { [$0.actual, $0.target ?? 0] }.max() ?? 1) * 1.15)
            }

            sparklines = ledger.securities.prefix(5).compactMap { ledger.priceLevels(securityID: $0.id, in: interval) }
        }
    }
}
