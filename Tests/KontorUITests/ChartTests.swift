import Foundation
import SwiftUI
import Testing
import KontorModel
import KontorEngine
import KontorSampleData
@testable import KontorUI

@Suite struct ChartScaleTests {
    @Test func niceScaleRoundsOutwardsAndIncludesZero() {
        let scale = LinearScale.nice(min: 3, max: 97, targetTicks: 5, includeZero: true)
        #expect(scale.lower == 0)
        #expect(scale.upper == 100)
        #expect(scale.ticks == [0, 20, 40, 60, 80, 100])
        #expect(scale.position(50) == 0.5)
    }

    @Test func tightScaleKeepsTheDataRangeAndPlacesRoundTicksInside() {
        let scale = LinearScale.nice(min: -0.14, max: 0.32, targetTicks: 4, includeZero: true, padding: 0.04, tight: true)
        #expect(scale.lower < -0.14 && scale.lower > -0.2)
        #expect(scale.upper > 0.32 && scale.upper < 0.4)
        #expect(scale.ticks.contains(0))
        #expect(scale.ticks.allSatisfy { $0 >= scale.lower && $0 <= scale.upper })
        #expect(scale.ticks.count >= 3)
    }

    @Test func zeroAnchoredEndIsNotPadded() {
        let scale = LinearScale.nice(min: 0, max: 250_000, targetTicks: 5, includeZero: true, padding: 0.06, tight: true)
        #expect(scale.lower == 0)
        #expect(scale.upper == 265_000)
        #expect(scale.ticks.first == 0)
    }

    @Test func degenerateInputsNeverProduceAnEmptyOrInfiniteScale() {
        for (lo, hi) in [(0.0, 0.0), (5.0, 5.0), (-3.0, -3.0), (Double.nan, 1.0), (1.0, Double.infinity), (2.0, 1.0)] {
            for tight in [false, true] {
                let scale = LinearScale.nice(min: lo, max: hi, includeZero: tight, tight: tight)
                #expect(scale.upper > scale.lower)
                #expect(scale.lower.isFinite && scale.upper.isFinite)
                #expect(!scale.ticks.isEmpty && scale.ticks.count < 20)
            }
        }
    }

    @Test func dayAxisPicksCoarserUnitsForLongerSpans() {
        let start = Day(year: 2020, month: 1, day: 15)
        #expect(DayAxis.unit(from: start, to: start.advanced(by: 6), maxTicks: 7) == .days(1))
        #expect(DayAxis.unit(from: start, to: start.addingMonths(6), maxTicks: 7) == .months(1))
        #expect(DayAxis.unit(from: start, to: start.addingYears(3), maxTicks: 7) == .months(6))
        #expect(DayAxis.unit(from: start, to: start.addingYears(9), maxTicks: 6) == .years(2))
        #expect(DayAxis.unit(from: start, to: start.addingYears(25), maxTicks: 6) == .years(5))
    }

    @Test func dayAxisTicksStayInsideTheRangeAndWithinTheBudget() {
        let start = Day(year: 2017, month: 6, day: 30), end = Day(year: 2026, month: 6, day: 30)
        for maxTicks in 2...12 {
            let ticks = DayAxis.ticks(from: start, to: end, maxTicks: maxTicks)
            #expect(!ticks.isEmpty)
            #expect(ticks.count <= maxTicks + 1)
            #expect(ticks.allSatisfy { $0.day >= start && $0.day <= end })
            #expect(ticks.map(\.day) == ticks.map(\.day).sorted())
        }
        // Year ticks are labelled with the plain year and sit on January 1st.
        let years = DayAxis.ticks(from: start, to: end, maxTicks: 6)
        #expect(years.allSatisfy { $0.day.month == 1 && $0.day.dayOfMonth == 1 && $0.label == String($0.day.year) })
        // Quarter ticks align to January / April / July / October.
        let quarters = DayAxis.ticks(from: start, to: start.addingYears(1), maxTicks: 5)
        #expect(quarters.allSatisfy { ($0.day.month - 1) % 3 == 0 && $0.day.dayOfMonth == 1 })
    }

    @Test func reducerKeepsEnvelopeAndEndpoints() {
        let n = 10_000
        let xs = (0..<n).map { CGFloat($0) * 400 / CGFloat(n) }
        var ys = (0..<n).map { CGFloat(sin(Double($0) / 50)) }
        ys[4_321] = 99          // a spike must survive
        ys[7_777] = -99
        let keep = ChartReducer.indices(xs: xs, ys: ys)
        #expect(keep.count <= 400 * 4 + 4)
        #expect(keep.first == 0 && keep.last == n - 1)
        #expect(keep.contains(4_321) && keep.contains(7_777))
        #expect(keep == keep.sorted())
        // Short series are untouched.
        #expect(ChartReducer.indices(xs: [0, 1, 2], ys: [1, 2, 3]) == [0, 1, 2])
    }
}

@Suite struct ChartLayoutTests {
    @Test func treemapAreasAreProportionalAndFillTheRectangle() {
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let rects = Treemap.layout(weights: weights, in: bounds)
        let total = weights.reduce(0, +)
        for (w, r) in zip(weights, rects) {
            #expect(abs(Double(r.width * r.height) - w / total * 240_000) < 1)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        // No two cells overlap.
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(rects[i].insetBy(dx: 0.01, dy: 0.01).intersects(rects[j].insetBy(dx: 0.01, dy: 0.01)) == false)
            }
        }
        // Squarified: no extreme slivers for this classic example.
        #expect(rects.allSatisfy { max($0.width / $0.height, $0.height / $0.width) < 4 })
    }

    @Test func treemapIgnoresInvalidWeights() {
        let rects = Treemap.layout(weights: [0, -1, .nan, 5], in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(rects[0] == .zero && rects[1] == .zero && rects[2] == .zero)
        #expect(rects[3] == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(Treemap.layout(weights: [], in: .zero).isEmpty)
    }

    @Test func histogramBinsHaveRoundEdgesIncludingZero() {
        let values = stride(from: -0.081, through: 0.092, by: 0.0013).map { $0 }
        let histogram = Histogram(values + [.nan, .infinity], targetBins: 20)
        #expect(histogram.total == values.count)
        #expect(histogram.bins.reduce(0) { $0 + $1.count } == values.count)
        #expect(histogram.bins.contains { $0.lower == 0 })
        #expect(histogram.bins.contains { $0.upper == 0 })
        for (a, b) in zip(histogram.bins, histogram.bins.dropFirst()) { #expect(a.upper == b.lower) }
        #expect(histogram.bins.first!.count > 0 && histogram.bins.last!.count > 0)
        #expect(abs(histogram.mean! - values.reduce(0, +) / Double(values.count)) < 1e-12)
        #expect(Histogram([]).bins.isEmpty)
        #expect(Histogram([2, 2, 2]).total == 3)
    }

    @Test func timeSeriesSortsDropsNonFiniteAndLooksUpByDay() {
        let d = Day(year: 2024, month: 1, day: 1)
        let series = TimeSeries("S", days: [d.advanced(by: 5), d, d.advanced(by: 2), d.advanced(by: 3)], values: [5, 0, .nan, 3])
        #expect(series.days == [d.rawValue, d.rawValue + 3, d.rawValue + 5])
        #expect(series.values == [0, 3, 5])
        #expect(series.value(on: d.advanced(by: -1)) == nil)
        #expect(series.value(on: d.advanced(by: 4)) == 3)          // last known value
        #expect(series.nearestIndex(to: d.rawValue + 4) == 1 || series.nearestIndex(to: d.rawValue + 4) == 2)
        #expect(series.nearestIndex(to: d.rawValue + 100) == 2)

        let dense = TimeSeries("D", start: d, values: [1, nil, 3] as [Double?])
        #expect(dense.values == [1, 3])
        #expect(TimeSeries("M", start: d, values: [100, 250] as [Int64]).values == [100, 250])
    }

    @Test func foldingKeepsTheLargestSlicesAndSumsTheRest() {
        let slices = (1...12).map { ChartSlice("S\($0)", value: Double($0)) } + [ChartSlice("zero", value: 0)]
        let folded = ChartSlice.folded(slices, maxCount: 8)
        #expect(folded.count == 8)
        #expect(folded.prefix(7).map(\.value) == [12, 11, 10, 9, 8, 7, 6])
        #expect(folded.last?.id == "chart.other")
        #expect(folded.last?.value == 15)
        #expect(ChartSlice.folded(Array(slices.prefix(3))).count == 3)
    }

    @Test func waterfallStepsReconcileWithTheBreakdown() {
        let file = SampleDataProbe.file
        let today = SampleDataProbe.today
        let analysis = Analysis(file: file, interval: ReportingPeriod.lastYears(3).interval(today: today, firstTransactionDay: nil))
        let steps = WaterfallStep.steps(from: analysis.breakdown)
        #expect(steps.first?.kind == .total && steps.last?.kind == .total)
        #expect(steps.first?.id == "initialValue" && steps.last?.id == "finalValue")
        let running = steps.dropLast().reduce(0) { $0 + $1.value }
        #expect(abs(running - steps.last!.value) < 0.5)
        #expect(steps.dropFirst().dropLast().allSatisfy { $0.kind == .change && $0.value != 0 })
    }

    @Test func allocationAdaptersPreserveTotals() {
        let file = SampleDataProbe.file
        let analysis = Analysis(file: file, interval: ReportingPeriod.ytd.interval(today: SampleDataProbe.today, firstTransactionDay: nil))
        let taxonomy = file.taxonomies[0]
        let allocation = analysis.allocation(for: taxonomy)
        let slices = ChartSlice.slices(from: allocation)
        #expect(abs(slices.reduce(0) { $0 + $1.value } - Double(allocation.totalValue)) < 0.5)
        let nodes = ChartNode.nodes(from: allocation, includesItems: true)
        #expect(abs(nodes.reduce(0) { $0 + $1.value } - Double(allocation.totalValue)) < 0.5)
        // Children never exceed their parent.
        func check(_ node: ChartNode) {
            #expect(node.children.reduce(0) { $0 + $1.value } <= node.value + 0.5)
            node.children.forEach(check)
        }
        nodes.forEach(check)
        let markers = ChartMarker.markers(for: file.transactions)
        #expect(markers.contains { $0.kind == .buy } && markers.contains { $0.kind == .sell } && markers.contains { $0.kind == .dividend })
        #expect(Set(markers.map(\.id)).count == markers.count)
    }
}

@Suite struct ChartColorTests {
    @Test func divergingScaleInkAlwaysReadsOnItsFill() {
        for style in GainStyle.allCases {
            let scale = DivergingScale(limit: 0.08, gainStyle: style)
            for scheme in [ColorScheme.light, .dark] {
                for value in stride(from: -0.12, through: 0.12, by: 0.005) {
                    let fill = scale.rgb(for: value, scheme: scheme)
                    let ink: ChartRGB = fill.prefersDarkInk ? .black : .white
                    #expect(fill.contrast(with: ink) >= 4.5, "value \(value) \(scheme) \(style)")
                }
                let empty = scale.rgb(for: nil, scheme: scheme)
                #expect(empty == scale.rgb(for: 0, scheme: scheme))
            }
        }
    }

    @Test func divergingScaleHonoursTheGainStyleAndGrowsWithMagnitude() {
        let green = DivergingScale(limit: 0.1, gainStyle: .greenUp), red = DivergingScale(limit: 0.1, gainStyle: .redUp)
        let up = green.rgb(for: 0.1, scheme: .light), down = green.rgb(for: -0.1, scheme: .light)
        #expect(up.g > up.r && down.r > down.g)
        #expect(red.rgb(for: 0.1, scheme: .light) == down)
        #expect(red.rgb(for: -0.1, scheme: .light) == up)
        #expect(green.intensity(0) == 0)
        #expect(green.intensity(0.01) > 0.1)                      // small values are visibly tinted
        #expect(green.intensity(0.05) < green.intensity(0.1))
        #expect(green.intensity(5) == 1)                          // clamped
        // Robust limit: one outlier does not define the scale.
        let robust = DivergingScale(covering: Array(repeating: 0.02, count: 40) + [0.9], gainStyle: .greenUp)
        #expect(robust.limit == 0.02)
    }

    @Test func classificationColorsAreMovedAwayFromTheSurface() {
        let white = ChartRGB(hex: "#FFFFFF")!, nearWhite = ChartRGB(hex: "#F4F4F0")!
        let fixed = ChartColors.legible(nearWhite, on: white)
        #expect(fixed.contrast(with: white) >= 1.6)
        #expect(ChartColors.legible(ChartRGB(hex: "#2A78D6")!, on: white) == ChartRGB(hex: "#2A78D6")!)   // already fine: untouched
        let dark = ChartRGB(r: 0.118, g: 0.118, b: 0.118)
        #expect(ChartColors.legible(ChartRGB(hex: "#101010")!, on: dark).contrast(with: dark) >= 1.6)
        #expect(ChartRGB(hex: "nonsense") == nil)
        #expect(ChartRGB.white.contrast(with: .black) == 21)
        #expect(ChartRGB(hex: "#EDA100")!.prefersDarkInk)          // yellow takes dark text
        #expect(!ChartRGB(hex: "#184F95")!.prefersDarkInk)         // deep blue takes white text
    }

    @Test func valueFormatsGoThroughFmt() {
        // Locale-independent: compare against Fmt itself.
        let money = ChartValueFormat.money("USD")
        #expect(money.value(123_456) == Fmt.money(minor: 123_456, currency: "USD"))
        #expect(money.axisLabels([0, 250_000, 500_000]) == [0, 250_000, 500_000].map { Fmt.moneyRounded(Money(minor: $0, currency: "USD")) })
        #expect(money.axisLabels([0, 100_000_000, 200_000_000]) == [0, 100_000_000, 200_000_000].map { Fmt.compactMoney(minor: $0, currency: "USD") })
        // Compact labels that would repeat fall back to whole units.
        #expect(Set(money.axisLabels([123_000_000, 124_000_000, 125_000_000])).count == 3)
        #expect(money.change(100_000, 110_000) == "\(Fmt.money(minor: 10_000, currency: "USD", signed: true)) (\(Fmt.percent(0.1, signed: true)))")
        #expect(money.change(0, 5_000) == Fmt.money(minor: 5_000, currency: "USD", signed: true))
        #expect(money.value(.nan) == Fmt.missing)
        let percent = ChartValueFormat.percent(signed: true)
        #expect(percent.value(0.0734) == Fmt.percent(0.0734, signed: true))
        #expect(percent.axisLabels([0, 0.1, 0.2]) == [0, 0.1, 0.2].map { Fmt.percent($0, decimals: 0) })
        #expect(percent.axisLabels([0, 0.005, 0.01]) == [0, 0.005, 0.01].map { Fmt.percent($0, decimals: 1) })
        #expect(percent.change(0.10, 0.21) == Fmt.percent(0.1, signed: true))            // compounding
        #expect(ChartValueFormat.percent(compounding: false).change(0.10, 0.21) == Fmt.percentagePoints(0.11))
        #expect(ChartValueFormat.price("USD").value(101.5) == Fmt.price(Price(101.5), currency: "USD"))
    }
}

/// The demo portfolio, built once for the adapter tests.
enum SampleDataProbe {
    static let today = Day(year: 2026, month: 6, day: 30)
    static let file = SampleData.demoPortfolio(today: today)
}

/// Compile-checks the snippets of the "Charts" section in `Sources/KontorUI/API.md` and builds
/// every chart once from demo data (construction must never trap, whatever the data).
@Suite @MainActor struct ChartSnippetTests {
    struct PerformanceChartModel: Sendable {
        var currency: CurrencyCode, start: Day
        var value: [ChartPoint<Int64>], invested: [Int64], returns: [ChartPoint<Double>], drawdown: [Double]
        init(_ a: Analysis) {
            currency = a.currency; start = a.interval.start
            value = a.valuation.chartPoints(maxPoints: 900)
            invested = a.investedCapital
            returns = a.returns.chartPoints(maxPoints: 900)
            drawdown = a.drawdowns.map { -$0 }
        }
    }

    @Test func documentedSnippetsCompileAndBuild() {
        let file = SampleDataProbe.file
        let interval = ReportingPeriod.lastYears(3).interval(today: SampleDataProbe.today, firstTransactionDay: nil)
        let analysis = Analysis(file: file, interval: interval)
        let m = PerformanceChartModel(analysis)
        let currency = m.currency
        var views = [AnyView]()

        views.append(AnyView(TimeSeriesChart([
            TimeSeries("Portfolio", points: m.value, style: .area),
            TimeSeries("Invested", start: m.start, values: m.invested, style: .step, color: ChartColors.comparison),
        ], format: .money(m.currency), title: "Portfolio value")
        .timeDomain(interval)
        .rangeSelection { _ in }
        .loading(false)
        .frame(height: 280)))

        let security = file.securities[0]
        let benchmarkPoints = analysis.benchmark(securityID: security.id)?.chartPoints(maxPoints: 900) ?? []
        views.append(AnyView(TimeSeriesChart([
            TimeSeries("Portfolio", points: m.returns),
            TimeSeries("MSCI World", points: benchmarkPoints, color: ChartColors.comparison, dashed: true),
        ], format: .percent(signed: true), title: "Cumulative return")
        .underwater(TimeSeries("Drawdown", start: m.start, values: m.drawdown))))

        let levels = analysis.ledger.priceLevels(securityID: security.id, in: interval) ?? []
        let transactions = analysis.ledger.transactions(forSecurity: security.id)
        views.append(AnyView(TimeSeriesChart([TimeSeries(security.name, start: interval.start, values: levels)],
                                             format: .price(currency), baseline: .data, title: "Price")
            .markers(ChartMarker.markers(for: transactions))
            .onHover { _ in }
            .pinnedHover(interval.end)
            .pinnedRange(interval)
            .legendHidden()
            .emptyMessage("No quotes")))

        let report = analysis.earnings
        let months = BarCategory.months(report.months.map { ($0.year, $0.month) })
        let trailingAverage: [Double?] = report.trailingTwelveMonths(.earnings).map { $0.isComplete ? Double($0.value) / 12 : nil }
        views.append(AnyView(BarSeriesChart(categories: months, series: [
            BarSeries("Dividends", values: report.months.map(\.amounts.dividends)),
            BarSeries("Interest", values: report.months.map(\.amounts.interest)),
        ], format: .money(currency), layout: .stacked, title: "Earnings per month")
        .overlayLine(BarOverlayLine("12-month average", values: trailingAverage))
        .selection(nil) { _ in }
        .frame(height: 240)))

        let yearly = analysis.returns.yearlyReturns()
        views.append(AnyView(BarSeriesChart(categories: yearly.map { BarCategory.year($0.year) }, values: yearly.map(\.value),
                                            name: "Return", format: .percent(signed: true))
            .valueLabels()
            .pinnedHover(yearly.first.map { String($0.year) })))

        let taxonomy = file.taxonomies[0]
        let allocation = analysis.allocation(for: taxonomy)
        let ttwrorBySecurityID = Dictionary(uniqueKeysWithValues: analysis.securities.map { ($0.securityID, $0.ttwror) })
        views.append(AnyView(DonutChart(ChartSlice.slices(from: allocation), format: .money(currency), centerTitle: "Net Worth", title: "Asset classes")
            .selection(nil) { _ in }
            .frame(height: 220)))
        views.append(AnyView(SunburstChart(ChartNode.nodes(from: allocation, includesItems: true), format: .money(currency), centerTitle: taxonomy.name)
            .levels(3)
            .selection(nil) { _ in }))
        views.append(AnyView(TreemapChart(ChartNode.nodes(from: allocation, includesItems: true), format: .money(currency), title: "Holdings")))
        views.append(AnyView(TreemapChart(ChartNode.nodes(from: allocation, includesItems: true, changes: ttwrorBySecurityID), format: .money(currency),
                                          coloring: .performance(limit: 0.10))))

        views.append(AnyView(HeatmapGrid(analysis.heatmap)))
        views.append(AnyView(HeatmapGrid(rows: [HeatmapRow(label: "2024", cells: [0.01, nil, -0.02], total: -0.01)], columns: ChartLabels.shortMonths,
                                         format: .percent(decimals: 1), totalTitle: "Year", limit: 0.08)
            .selection { _, _ in }
            .rowHeight(22)
            .scaleHidden()))
        views.append(AnyView(WaterfallChart(WaterfallStep.steps(from: analysis.breakdown), format: .money(currency), title: "Performance breakdown")
            .selection { _ in }))
        views.append(AnyView(WaterfallChart([.total("Start", value: 100), .change("Gains", value: 12), .change("Fees", value: -2), .total("End", value: 110)],
                                            format: .number(decimals: 0))))
        let monthlyReturns = analysis.returns.monthlyReturns().map(\.value)
        views.append(AnyView(DistributionChart(Histogram(monthlyReturns, targetBins: 24), format: .percent(decimals: 1, signed: true), title: "Monthly returns")
            .markers(mean: true, median: true)
            .frame(height: 200)))
        if let node = allocation.roots.first {
            views.append(AnyView(TargetActualBar(actual: node.share, target: node.targetShare, maximum: 0.6,
                                                 color: ChartColors.classification(node.color, fallbackIndex: 0), tolerance: 0.03)))
        }
        views.append(AnyView(ChartLegend([ChartLegendItem(id: "a", name: "A", color: ChartColors.series(2))])
            .environment(\.chartPatternsForced, true)
            .environment(\.chartSurface, ChartColors.other)))
        #expect(views.count == 16)
        #expect(ChartLabels.shortMonths.count == 12)
        #expect(PerformanceBreakdown.Line.unrealizedGains.title == "Unrealized Gains")
    }

    @Test func galleryModelBuildsForDemoAndEmptyPortfolios() {
        let demo = SampleDataProbe.file
        let analysis = Analysis(file: demo, interval: ReportingPeriod.allTime.interval(today: SampleDataProbe.today, firstTransactionDay: demo.transactions.map(\.date).min()))
        let model = ChartGallery.Model(analysis, taxonomy: demo.taxonomies.first)
        #expect(!model.value.isEmpty && !model.slices.isEmpty && !model.treemap.isEmpty && !model.waterfall.isEmpty)
        #expect(model.longSeries.allSatisfy { $0.days.count == 9131 })

        let empty = SampleData.starterPortfolio(name: "Empty", baseCurrency: "EUR")
        let emptyAnalysis = Analysis(file: empty, interval: ReportingPeriod.ytd.interval(today: SampleDataProbe.today, firstTransactionDay: nil))
        let emptyModel = ChartGallery.Model(emptyAnalysis, taxonomy: empty.taxonomies.first)
        #expect(emptyModel.slices.isEmpty && emptyModel.markers.isEmpty)
    }
}
