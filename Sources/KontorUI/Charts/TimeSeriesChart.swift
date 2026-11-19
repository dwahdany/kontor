import SwiftUI
import KontorModel
import KontorEngine

// MARK: - Data

/// One named line of a ``TimeSeriesChart``.
///
/// Values are `Double`s in the unit of the chart's `ChartValueFormat` (minor units for `.money`,
/// fractions for `.percent`). Build series off the main actor (inside `analysisTask`) — the type
/// is `Sendable`. Any length is fine: the chart reduces to pixel resolution when drawing, so 25
/// years of daily values stay smooth; pre-reducing with the engine's `chartPoints(maxPoints:)`
/// only saves memory.
///
/// ```swift
/// TimeSeries("Portfolio", points: analysis.valuation.chartPoints(maxPoints: 600), style: .area)
/// TimeSeries("Invested", start: interval.start, values: analysis.investedCapital, style: .step, color: ChartColors.comparison)
/// TimeSeries("MSCI World", points: benchmark.chartPoints(maxPoints: 600), dashed: true)
/// ```
public struct TimeSeries: Identifiable, Sendable {
    public enum Style: Sendable, Hashable {
        /// A 2 pt line.
        case line
        /// A line with a soft wash down to the baseline.
        case area
        /// A stepped line (values that change at discrete moments: invested capital, share counts).
        case step
        /// A stepped line with a wash.
        case stepArea
    }

    public var id: String
    public var name: String
    /// `nil` → the palette color of the series' position (`ChartColors.series(index)`).
    public var color: Color?
    public var style: Style
    /// Dashed stroke — for comparison lines (benchmarks, targets).
    public var isDashed: Bool

    /// Ascending day numbers (`Day.rawValue`) and their values.
    public private(set) var days: [Int32]
    public private(set) var values: [Double]
    let minValue: Double
    let maxValue: Double

    /// - Parameters:
    ///   - days: ascending (unsorted input is sorted); pairs with non-finite values are dropped.
    public init(id: String? = nil, _ name: String, days: [Day], values: [Double], style: Style = .line, color: Color? = nil, dashed: Bool = false) {
        var pairs = [(Int32, Double)]()
        pairs.reserveCapacity(min(days.count, values.count))
        var sorted = true
        for (day, value) in zip(days, values) where value.isFinite {
            if let last = pairs.last, last.0 > day.rawValue { sorted = false }
            pairs.append((day.rawValue, value))
        }
        if !sorted { pairs.sort { $0.0 < $1.0 } }
        self.id = id ?? name
        self.name = name
        self.color = color
        self.style = style
        self.isDashed = dashed
        self.days = pairs.map(\.0)
        self.values = pairs.map(\.1)
        minValue = self.values.min() ?? 0
        maxValue = self.values.max() ?? 0
    }

    /// From the engine's reduced chart points (`ReturnSeries.chartPoints`, `rollingReturns.chartPoints`).
    public init(id: String? = nil, _ name: String, points: [ChartPoint<Double>], style: Style = .line, color: Color? = nil, dashed: Bool = false) {
        self.init(id: id, name, days: points.map(\.day), values: points.map(\.value), style: style, color: color, dashed: dashed)
    }

    /// From money chart points in minor units (`ValuationSeries.chartPoints`). Use with `.money(currency)`.
    public init(id: String? = nil, _ name: String, points: [ChartPoint<Int64>], style: Style = .line, color: Color? = nil, dashed: Bool = false) {
        self.init(id: id, name, days: points.map(\.day), values: points.map { Double($0.value) }, style: style, color: color, dashed: dashed)
    }

    /// From a dense daily engine series: `values[i]` belongs to `start + i` (`returns.cumulative`,
    /// `analysis.drawdowns`, …).
    public init(id: String? = nil, _ name: String, start: Day, values: [Double], style: Style = .line, color: Color? = nil, dashed: Bool = false) {
        self.init(id: id, name, days: values.indices.map { start.advanced(by: $0) }, values: values, style: style, color: color, dashed: dashed)
    }

    /// From a dense daily money series in minor units (`valuation.values`, `analysis.investedCapital`).
    public init(id: String? = nil, _ name: String, start: Day, values: [Int64], style: Style = .line, color: Color? = nil, dashed: Bool = false) {
        self.init(id: id, name, start: start, values: values.map(Double.init), style: style, color: color, dashed: dashed)
    }

    /// From a dense daily series with gaps (`rollingReturns.values`); `nil`s are skipped.
    public init(id: String? = nil, _ name: String, start: Day, values: [Double?], style: Style = .line, color: Color? = nil, dashed: Bool = false) {
        self.init(id: id, name, start: start, values: values.map { $0 ?? .nan }, style: style, color: color, dashed: dashed)
    }

    public var isEmpty: Bool { days.isEmpty }

    /// Index of the last point on or before `day`.
    func index(atOrBefore day: Int32) -> Int? {
        var lo = 0, hi = days.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if days[mid] <= day { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// Index of the point closest to `day`.
    func nearestIndex(to day: Int32) -> Int? {
        guard !days.isEmpty else { return nil }
        guard let before = index(atOrBefore: day) else { return 0 }
        let after = before + 1
        if after < days.count, days[after] - day < day - days[before] { return after }
        return before
    }

    /// The value shown for `day`: the point on or before it.
    public func value(on day: Day) -> Double? {
        index(atOrBefore: day.rawValue).map { values[$0] }
    }
}

/// Where the value axis of a chart starts.
public enum ChartBaseline: Sendable, Hashable {
    /// The axis always contains 0 and a rule marks it (money, returns — the default).
    case zero
    /// The axis hugs the data (prices of one security, FX rates).
    case data
}

/// An annotation on a ``TimeSeriesChart``: a transaction or event on a day.
///
/// ```swift
/// ChartMarker(.buy, day: tx.date, label: "Bought 10 × ACME")
/// ChartMarker(.dividend, day: p.day, label: "Dividend \(Fmt.money(net))")       // sits on the time axis
/// ChartMarker(.sell, day: tx.date, value: price, label: "Sold 5")                // explicit height
/// ```
public struct ChartMarker: Identifiable, Sendable {
    public enum Kind: Sendable, Hashable {
        /// ▲ on the line.
        case buy
        /// ▼ on the line.
        case sell
        /// ◆ on the time axis.
        case dividend
        /// ● on the time axis (splits, plan executions, notes).
        case event

        var glyph: String {
            switch self {
            case .buy: "▲"
            case .sell: "▼"
            case .dividend: "◆"
            case .event: "●"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var day: Day
    /// Explicit height; `nil` puts buy/sell markers on the line of `seriesID` (or the first series).
    public var value: Double?
    public var seriesID: String?
    /// Shown in the hover legend, e.g. "Bought 10 × ACME".
    public var label: String

    public init(_ kind: Kind, id: String? = nil, day: Day, value: Double? = nil, seriesID: String? = nil, label: String) {
        self.kind = kind
        self.id = id ?? "\(kind)-\(day.rawValue)-\(label)"
        self.day = day
        self.value = value
        self.seriesID = seriesID
        self.label = label
    }
}

/// What a range selection (drag across a ``TimeSeriesChart``) reports.
public struct ChartRangeSelection: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        public var seriesID: String
        public var name: String
        /// Values at the two ends of the selection.
        public var from: Double
        public var to: Double
    }

    /// `start` is the first selected day — the baseline, as in every engine interval — `end` the last.
    public var interval: DayInterval
    /// One entry per visible series that has data in the range.
    public var changes: [Change]
}

// MARK: - Chart

/// A line / area chart over days: several named series on one shared value axis, month/year
/// ticks, a zero rule, a hover crosshair with a floating legend of exact values, optional
/// drag-to-select ranges, transaction markers, and an optional "underwater" (drawdown) panel.
///
/// ```swift
/// TimeSeriesChart([
///     TimeSeries("Portfolio", points: model.value, style: .area),
///     TimeSeries("Invested", points: model.invested, style: .step, color: ChartColors.comparison),
/// ], format: .money(model.currency))
/// .markers(model.markers)
/// .underwater(TimeSeries("Drawdown", points: model.drawdown))        // fractions ≤ 0
/// .rangeSelection { selection in self.selection = selection }        // drag to measure
/// .loading(loadable.isRefreshing)
/// .frame(height: 280)
/// ```
///
/// Series toggles live in the legend (shown for two or more series). ← / → move the crosshair
/// when the chart has keyboard focus; Escape clears crosshair and selection.
public struct TimeSeriesChart: View {
    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chartSurface) private var surface

    private let series: [TimeSeries]
    private let format: ChartValueFormat
    private var baseline: ChartBaseline
    private var title: String
    private var markerList: [ChartMarker] = []
    private var underwaterSeries: TimeSeries?
    private var underwaterFormat = ChartValueFormat.percent()
    private var domain: ClosedRange<Day>?
    private var showsLegend = true
    private var isLoading = false
    private var emptyMessage = "No data for this period"
    private var pinnedDay: Day?
    private var pinnedRange: ClosedRange<Day>?
    private var allowsRangeSelection = false
    private var onRangeSelected: ((ChartRangeSelection?) -> Void)?
    private var onHoverDay: ((Day?) -> Void)?

    @State private var hoverLocation: CGPoint?
    @State private var keyboardDay: Day?
    @State private var hidden: Set<String> = []
    @State private var dragRange: ClosedRange<Day>?
    @State private var selectedRange: ClosedRange<Day>?

    /// - Parameters:
    ///   - series: drawn back to front in reverse order (the first series is on top and leads the
    ///     hover legend). Colors default to the palette in series order.
    ///   - format: the unit of all series — one value axis, never two.
    ///   - baseline: `.zero` (default) keeps 0 on the axis; `.data` hugs the data (prices).
    ///   - title: what the chart shows, for VoiceOver ("Portfolio value").
    public init(_ series: [TimeSeries], format: ChartValueFormat, baseline: ChartBaseline = .zero, title: String = "Chart") {
        self.series = series
        self.format = format
        self.baseline = baseline
        self.title = title
    }

    // MARK: Configuration

    /// Transaction and event markers (see ``ChartMarker``).
    public func markers(_ markers: [ChartMarker]) -> TimeSeriesChart {
        var copy = self
        copy.markerList = markers
        return copy
    }

    /// Adds a secondary panel below the plot for an "underwater" curve — values ≤ 0 hanging from
    /// a zero line, filled in the loss color (drawdowns: pass `-drawdown`).
    public func underwater(_ series: TimeSeries?, format: ChartValueFormat = .percent()) -> TimeSeriesChart {
        var copy = self
        copy.underwaterSeries = series
        copy.underwaterFormat = format
        return copy
    }

    /// Fixes the time axis (default: the extent of the data), e.g. to `store.periodInterval`.
    public func timeDomain(_ interval: DayInterval?) -> TimeSeriesChart {
        var copy = self
        copy.domain = interval.map { $0.start...max($0.start, $0.end) }
        return copy
    }

    /// Hides the legend (it is only shown for two or more series anyway).
    public func legendHidden(_ hidden: Bool = true) -> TimeSeriesChart {
        var copy = self
        copy.showsLegend = !hidden
        return copy
    }

    /// Dims the chart while newer data is computed (`loadable.isRefreshing`); with no data yet a
    /// spinner replaces the plot.
    public func loading(_ isLoading: Bool) -> TimeSeriesChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    /// The text shown when no series has data.
    public func emptyMessage(_ message: String) -> TimeSeriesChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    /// Lets the user drag across the chart to select a range; the chart shades it and shows the
    /// change of every series between its ends. `action` receives the selection (`nil` when
    /// cleared by a click or Escape).
    public func rangeSelection(_ action: ((ChartRangeSelection?) -> Void)? = nil) -> TimeSeriesChart {
        var copy = self
        copy.allowsRangeSelection = true
        copy.onRangeSelected = action
        return copy
    }

    /// Reports the day under the crosshair (to link several charts, or show details elsewhere).
    public func onHover(_ action: @escaping (Day?) -> Void) -> TimeSeriesChart {
        var copy = self
        copy.onHoverDay = action
        return copy
    }

    /// Shows the crosshair and hover legend at `day` without a pointer — to link charts
    /// (`.onHover` of one feeding `.pinnedHover` of another) and for screenshots.
    public func pinnedHover(_ day: Day?) -> TimeSeriesChart {
        var copy = self
        copy.pinnedDay = day
        return copy
    }

    /// Shows a range selection without a drag (restoring state, screenshots).
    public func pinnedRange(_ interval: DayInterval?) -> TimeSeriesChart {
        var copy = self
        copy.pinnedRange = interval.map { $0.start...max($0.start, $0.end) }
        return copy
    }

    // MARK: Body

    public var body: some View {
        let isEmpty = series.allSatisfy(\.isEmpty)
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if showsLegend, legendItems.count > 1 {
                ChartLegend(legendItems, hidden: $hidden)
            }
            GeometryReader { proxy in
                let geometry = Geometry(self, size: proxy.size)
                let range = activeRange
                let hover = range == nil ? geometry.flatMap { activeDay(in: $0) } : nil
                Canvas { context, size in
                    guard let geometry else { return }
                    draw(&context, geometry, hover: hover, range: range)
                }
                .chartTooltip(at: tooltipAnchor(geometry, hover: hover, range: range), horizontal: range == nil ? .beside : .centered, vertical: .top) {
                    if let geometry {
                        if let range {
                            rangeTooltip(range, geometry)
                        } else if let hover {
                            hoverTooltip(hover, geometry)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                        keyboardDay = nil
                    case .ended:
                        hoverLocation = nil
                    }
                }
                .gesture(rangeGesture(geometry), isEnabled: allowsRangeSelection && geometry != nil)
                .onChange(of: hover) { _, day in onHoverDay?(day) }
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in moveCrosshair(direction, geometry) }
                .onExitCommand {
                    keyboardDay = nil
                    clearSelection()
                }
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityValue(accessibilitySummary)
                .accessibilityChartDescriptor(audioGraph)
            }
            .frame(minHeight: 80)
        }
        .chartState(isEmpty: isEmpty, isLoading: isLoading, message: emptyMessage)
    }

    // MARK: Derived

    private func color(_ index: Int) -> Color { series[index].color ?? ChartColors.series(index) }

    private func dash(_ index: Int) -> [CGFloat] {
        if differentiateWithoutColor, series.count > 1 { return ChartPattern.dash(index) }
        return series[index].isDashed ? [5, 3] : []
    }

    private var legendItems: [ChartLegendItem] {
        series.indices.filter { !series[$0].isEmpty }.map { i in
            ChartLegendItem(id: series[i].id, name: series[i].name, color: color(i), mark: .line(dash: dash(i)))
        }
    }

    private var visibleIndices: [Int] {
        series.indices.filter { !series[$0].isEmpty && !hidden.contains(series[$0].id) }
    }

    private var activeRange: ClosedRange<Day>? { dragRange ?? selectedRange ?? pinnedRange }

    private func activeDay(in geometry: Geometry) -> Day? {
        if let pinnedDay { return snap(pinnedDay.rawValue) }
        if let keyboardDay { return keyboardDay }
        guard let location = hoverLocation, geometry.hoverBand.contains(location) else { return nil }
        return snap(geometry.day(atX: location.x))
    }

    /// The data day closest to `day` among the visible series.
    private func snap(_ day: Int32) -> Day? {
        var best: Int32?
        var candidates = visibleIndices.map { series[$0] }
        if let underwaterSeries { candidates.append(underwaterSeries) }
        for s in candidates {
            guard let i = s.nearestIndex(to: day) else { continue }
            if best == nil || abs(s.days[i] - day) < abs(best! - day) { best = s.days[i] }
        }
        return best.map(Day.init(rawValue:))
    }

    private func tooltipAnchor(_ geometry: Geometry?, hover: Day?, range: ClosedRange<Day>?) -> CGPoint? {
        guard let geometry else { return nil }
        if let range {
            return CGPoint(x: (geometry.x(range.lowerBound.rawValue) + geometry.x(range.upperBound.rawValue)) / 2, y: geometry.plot.minY)
        }
        guard let hover else { return nil }
        return CGPoint(x: geometry.x(hover.rawValue), y: geometry.plot.minY)
    }

    // MARK: Interaction

    private func rangeGesture(_ geometry: Geometry?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let geometry, abs(value.translation.width) > 3 else { return }
                let a = Day(rawValue: geometry.day(atX: value.startLocation.x)), b = Day(rawValue: geometry.day(atX: value.location.x))
                dragRange = min(a, b)...max(a, b)
            }
            .onEnded { _ in
                if let range = dragRange, range.lowerBound < range.upperBound {
                    selectedRange = range
                    dragRange = nil
                    onRangeSelected?(selection(for: range))
                } else {
                    dragRange = nil
                    clearSelection()
                }
            }
    }

    private func clearSelection() {
        guard selectedRange != nil else { return }
        selectedRange = nil
        onRangeSelected?(nil)
    }

    private func moveCrosshair(_ direction: MoveCommandDirection, _ geometry: Geometry?) {
        guard let lead = visibleIndices.first.map({ series[$0] }), !lead.isEmpty else { return }
        let current = keyboardDay ?? geometry.flatMap { activeDay(in: $0) }
        var index = current.flatMap { lead.nearestIndex(to: $0.rawValue) } ?? lead.days.count - 1
        switch direction {
        case .left: index = max(0, index - 1)
        case .right: index = min(lead.days.count - 1, index + 1)
        default: return
        }
        keyboardDay = Day(rawValue: lead.days[index])
    }

    private func selection(for range: ClosedRange<Day>) -> ChartRangeSelection {
        ChartRangeSelection(
            interval: DayInterval(start: range.lowerBound, end: range.upperBound),
            changes: visibleIndices.compactMap { i in
                let s = series[i]
                guard let to = s.value(on: range.upperBound) else { return nil }
                let from = s.value(on: range.lowerBound) ?? s.values[0]
                return .init(seriesID: s.id, name: s.name, from: from, to: to)
            })
    }

    // MARK: Tooltips

    private func hoverTooltip(_ day: Day, _ geometry: Geometry) -> ChartTooltip {
        var rows = visibleIndices.map { i in
            ChartTooltip.Row(
                id: series[i].id, key: ChartLegendItem(id: series[i].id, name: series[i].name, color: color(i), mark: .line(dash: dash(i))),
                name: series[i].name, value: series[i].value(on: day).map(format.value) ?? Fmt.missing)
        }
        if let underwaterSeries, let value = underwaterSeries.value(on: day) {
            rows.append(.init(id: "underwater", key: ChartLegendItem(id: "underwater", name: underwaterSeries.name, color: gainStyle.loss),
                              name: underwaterSeries.name, value: underwaterFormat.value(value)))
        }
        // Markers at (or visually at) the crosshair.
        let x = geometry.x(day.rawValue)
        for marker in markerList where abs(geometry.x(marker.day.rawValue) - x) <= 4 {
            if rows.count >= 9 { break }
            rows.append(.init(id: "m-" + marker.id, glyph: marker.kind.glyph, name: marker.label, value: marker.day == day ? "" : Fmt.day(marker.day, style: .dayMonth)))
        }
        return ChartTooltip(title: Fmt.day(day, style: .medium), rows: rows)
    }

    private func rangeTooltip(_ range: ClosedRange<Day>, _ geometry: Geometry) -> ChartTooltip {
        let selection = selection(for: range)
        let rows = selection.changes.map { change in
            let i = series.firstIndex { $0.id == change.seriesID } ?? 0
            return ChartTooltip.Row(
                id: change.seriesID, key: ChartLegendItem(id: change.seriesID, name: change.name, color: color(i), mark: .line(dash: dash(i))),
                name: change.name, value: format.change(change.from, change.to), isEmphasized: true)
        }
        return ChartTooltip(
            title: "\(Fmt.day(range.lowerBound, style: .medium)) – \(Fmt.day(range.upperBound, style: .medium))",
            subtitle: Fmt.duration(days: range.lowerBound.distance(to: range.upperBound)), rows: rows)
    }

    // MARK: Accessibility

    private var accessibilitySummary: String {
        visibleIndices.prefix(4).compactMap { i -> String? in
            let s = series[i]
            guard let first = s.values.first, let last = s.values.last else { return nil }
            return "\(s.name): \(format.value(first)) on \(Fmt.day(Day(rawValue: s.days[0]), style: .medium)), "
                + "\(format.value(last)) on \(Fmt.day(Day(rawValue: s.days[s.days.count - 1]), style: .medium)), "
                + "low \(format.value(s.minValue)), high \(format.value(s.maxValue))"
        }.joined(separator: ". ")
    }

    private var audioGraph: ChartAudioGraph {
        let format = format
        return ChartAudioGraph(
            title: title, summary: accessibilitySummary, xTitle: "Date", yTitle: "Value", categories: nil,
            xDescription: { Fmt.day(Day(rawValue: Int32($0.clamped(-1e9, 1e9))), style: .medium) },
            yDescription: { format.value($0) },
            series: visibleIndices.map { i in
                let s = series[i]
                let stride = max(1, s.days.count / 240)
                return .init(name: s.name, isContinuous: true, points: Swift.stride(from: 0, to: s.days.count, by: stride).map {
                    (Double(s.days[$0]), nil, s.values[$0])
                })
            })
    }

    // MARK: Geometry

    fileprivate struct Geometry {
        var size: CGSize
        var plot: CGRect
        var under: CGRect?
        var d0: Int32
        var d1: Int32
        var scale: LinearScale
        var labels: [String]
        var underScale: LinearScale?
        var underLabels: [String] = []
        var xTicks: [DayTick]

        /// Everything the pointer can hover: both panels.
        var hoverBand: CGRect {
            CGRect(x: plot.minX - 6, y: 0, width: plot.width + 12, height: (under ?? plot).maxY + 4)
        }

        func x(_ day: Int32) -> CGFloat {
            d1 > d0 ? plot.minX + CGFloat(day - d0) / CGFloat(d1 - d0) * plot.width : plot.midX
        }

        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(scale.position(value)) * plot.height }

        func underY(_ value: Double) -> CGFloat {
            guard let under, let underScale else { return 0 }
            return under.maxY - CGFloat(underScale.position(value)) * under.height
        }

        func day(atX x: CGFloat) -> Int32 {
            guard d1 > d0, plot.width > 0 else { return d0 }
            let t = ((x - plot.minX) / plot.width).clamped(0, 1)
            return d0 + Int32((t * CGFloat(d1 - d0)).rounded())
        }

        @MainActor init?(_ chart: TimeSeriesChart, size: CGSize) {
            let visible = chart.visibleIndices.map { chart.series[$0] }
            let all = chart.series.filter { !$0.isEmpty } + (chart.underwaterSeries.map { [$0] } ?? [])
            guard !all.isEmpty, size.width > 60, size.height > 40 else { return nil }
            self.size = size
            if let domain = chart.domain {
                d0 = domain.lowerBound.rawValue
                d1 = domain.upperBound.rawValue
            } else {
                d0 = all.map { $0.days[0] }.min() ?? 0
                d1 = all.map { $0.days[$0.days.count - 1] }.max() ?? 0
            }

            let xAxisHeight: CGFloat = 18, top: CGFloat = 7
            var plotHeight = size.height - xAxisHeight - top
            var underHeight: CGFloat = 0
            let underGap: CGFloat = 12
            if let u = chart.underwaterSeries, !u.isEmpty, plotHeight > 150 {
                underHeight = min(72, (plotHeight * 0.24).rounded())
                plotHeight -= underHeight + underGap
            }

            // Value axis.
            var lo = visible.map(\.minValue).min() ?? 0, hi = visible.map(\.maxValue).max() ?? 1
            for marker in chart.markerList {
                if let v = marker.value, v.isFinite {
                    lo = min(lo, v)
                    hi = max(hi, v)
                }
            }
            scale = .nice(min: lo, max: hi, targetTicks: Int((plotHeight / 46).rounded()).clamped(2, 7),
                          includeZero: chart.baseline == .zero, padding: 0.06, tight: true)
            if chart.baseline == .data, lo >= 0, scale.lower < 0 {
                // Prices never go below zero: do not pad into negative territory.
                scale.lower = 0
            }
            labels = chart.format.axisLabels(scale.ticks)
            var labelWidth = labels.map { ChartFont.width($0) }.max() ?? 0

            if underHeight > 0, let u = chart.underwaterSeries {
                let s = LinearScale.nice(min: min(u.minValue, 0), max: 0, targetTicks: 2, includeZero: true, padding: 0.08, tight: true)
                underScale = s
                underLabels = chart.underwaterFormat.axisLabels(s.ticks)
                labelWidth = max(labelWidth, underLabels.map { ChartFont.width($0) }.max() ?? 0)
            }

            let plotWidth = max(20, size.width - labelWidth - 8)
            plot = CGRect(x: 0, y: top, width: plotWidth, height: plotHeight)
            if underHeight > 0 {
                under = CGRect(x: 0, y: plot.maxY + underGap, width: plotWidth, height: underHeight)
            }
            xTicks = DayAxis.ticks(from: Day(rawValue: d0), to: Day(rawValue: d1), maxTicks: max(2, Int(plotWidth / 92)))
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ g: Geometry, hover: Day?, range: ClosedRange<Day>?) {
        let chrome = ChartChrome(contrast: contrast, surface: surface)
        let bottom = (g.under ?? g.plot).maxY

        // Grid and value labels.
        for (tick, label) in zip(g.scale.ticks, g.labels) {
            let y = g.y(tick)
            context.hline(y: y, from: g.plot.minX, to: g.plot.maxX, color: tick == 0 && baseline == .zero ? chrome.baseline : chrome.grid)
            context.label(label, at: CGPoint(x: g.plot.maxX + 6, y: y), anchor: .leading, color: chrome.axisLabel)
        }

        // Time axis.
        context.hline(y: bottom, from: g.plot.minX, to: g.plot.maxX, color: chrome.baseline)
        var lastLabelEnd = -CGFloat.infinity
        for tick in g.xTicks {
            let x = g.x(tick.day.rawValue)
            context.vline(x: x, from: bottom, to: bottom + 3, color: chrome.baseline)
            let width = context.textSize(tick.label).width
            let left = (x - width / 2).clamped(0, max(0, g.plot.maxX - width))
            guard left > lastLabelEnd + 10 else { continue }
            context.label(tick.label, at: CGPoint(x: left, y: bottom + 5), anchor: .topLeading, color: chrome.axisLabel)
            lastLabelEnd = left + width
        }

        // Range selection band (behind the data).
        if let range {
            let x0 = g.x(range.lowerBound.rawValue), x1 = g.x(range.upperBound.rawValue)
            let band = CGRect(x: x0, y: g.plot.minY, width: max(1, x1 - x0), height: bottom - g.plot.minY)
            context.fill(Path(band), with: .color(Color.accentColor.opacity(0.12)))
            context.vline(x: x0, from: band.minY, to: band.maxY, color: Color.accentColor.opacity(0.8))
            context.vline(x: x1, from: band.minY, to: band.maxY, color: Color.accentColor.opacity(0.8))
        }

        // Series, last first so the first series ends up on top.
        var plotContext = context
        plotContext.clip(to: Path(g.plot.insetBy(dx: -2, dy: -4)))
        let zeroY = g.y(0.clamped(g.scale.lower, g.scale.upper))
        for i in visibleIndices.reversed() {
            let s = series[i]
            let points = Self.points(s, g: g, y: g.y)
            guard !points.isEmpty else { continue }
            let tint = color(i)
            let isStep = s.style == .step || s.style == .stepArea
            let line = Self.path(points, step: isStep)
            if s.style == .area || s.style == .stepArea {
                var area = line
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: zeroY))
                area.addLine(to: CGPoint(x: points[0].x, y: zeroY))
                area.closeSubpath()
                plotContext.fill(area, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.24), tint.opacity(0.04)]),
                    startPoint: CGPoint(x: 0, y: g.plot.minY), endPoint: CGPoint(x: 0, y: g.plot.maxY)))
            }
            if points.count == 1 {
                plotContext.fill(Path(ellipseIn: CGRect(x: points[0].x - 3, y: points[0].y - 3, width: 6, height: 6)), with: .color(tint))
            } else {
                plotContext.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: i == visibleIndices.first ? 2 : 1.5, lineCap: .round, lineJoin: .round, dash: dash(i)))
            }
        }

        // Underwater panel.
        if let under = g.under, let u = underwaterSeries, let underScale = g.underScale {
            let loss = gainStyle.loss
            for (tick, label) in zip(underScale.ticks, g.underLabels) {
                let y = g.underY(tick)
                context.hline(y: y, from: under.minX, to: under.maxX, color: tick == 0 ? chrome.baseline : chrome.grid)
                context.label(label, at: CGPoint(x: under.maxX + 6, y: y), anchor: .leading, color: chrome.axisLabel)
            }
            let points = Self.points(u, g: g, y: g.underY)
            if points.count > 1 {
                let line = Self.path(points, step: false)
                var area = line
                let top = g.underY(0)
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: top))
                area.addLine(to: CGPoint(x: points[0].x, y: top))
                area.closeSubpath()
                var underContext = context
                underContext.clip(to: Path(under.insetBy(dx: -2, dy: -1)))
                underContext.fill(area, with: .color(loss.opacity(0.22)))
                if differentiateWithoutColor { underContext.overlay(.diagonal, in: area, ink: loss) }
                underContext.stroke(line, with: .color(loss), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            }
            context.label(u.name, at: CGPoint(x: under.minX + 2, y: under.maxY - 3), anchor: .bottomLeading, font: ChartFont.small, color: chrome.axisLabel)
        }

        drawMarkers(&context, g, chrome)

        // Crosshair.
        if let hover {
            let x = g.x(hover.rawValue)
            context.vline(x: x, from: g.plot.minY, to: bottom, color: chrome.crosshair)
            for i in visibleIndices.reversed() {
                guard let value = series[i].value(on: hover) else { continue }
                Self.dot(&context, at: CGPoint(x: x, y: g.y(value)), radius: 4, color: color(i), ring: chrome.surface)
            }
            if g.under != nil, let u = underwaterSeries, let value = u.value(on: hover) {
                Self.dot(&context, at: CGPoint(x: x, y: g.underY(value)), radius: 3.5, color: gainStyle.loss, ring: chrome.surface)
            }
        }
    }

    private func drawMarkers(_ context: inout GraphicsContext, _ g: Geometry, _ chrome: ChartChrome) {
        guard !markerList.isEmpty else { return }
        let dense = CGFloat(markerList.count) > g.plot.width / 9
        let s: CGFloat = dense ? 2.8 : 4.6
        let ink = Color.primary.opacity(dense ? 0.7 : 1)
        for marker in markerList {
            let day = marker.day.rawValue
            guard day >= g.d0, day <= g.d1 else { continue }
            let x = g.x(day)
            var y: CGFloat
            if let value = marker.value {
                y = g.y(value)
            } else if marker.kind == .dividend || marker.kind == .event {
                y = g.plot.maxY - s - 3
            } else {
                let host = series.first { $0.id == marker.seriesID && !hidden.contains($0.id) } ?? visibleIndices.first.map { series[$0] }
                guard let value = host?.value(on: marker.day) else { continue }
                y = g.y(value)
            }
            // Buys sit just below the line pointing up, sells just above pointing down, so the
            // line itself stays visible.
            if marker.value == nil {
                if marker.kind == .buy { y += s + 3 } else if marker.kind == .sell { y -= s + 3 }
            }
            y = y.clamped(g.plot.minY + s, g.plot.maxY - s)
            var path = Path()
            switch marker.kind {
            case .buy:
                path.move(to: CGPoint(x: x, y: y - s))
                path.addLine(to: CGPoint(x: x + s, y: y + s * 0.8))
                path.addLine(to: CGPoint(x: x - s, y: y + s * 0.8))
                path.closeSubpath()
            case .sell:
                path.move(to: CGPoint(x: x, y: y + s))
                path.addLine(to: CGPoint(x: x + s, y: y - s * 0.8))
                path.addLine(to: CGPoint(x: x - s, y: y - s * 0.8))
                path.closeSubpath()
            case .dividend:
                path.move(to: CGPoint(x: x, y: y - s))
                path.addLine(to: CGPoint(x: x + s, y: y))
                path.addLine(to: CGPoint(x: x, y: y + s))
                path.addLine(to: CGPoint(x: x - s, y: y))
                path.closeSubpath()
            case .event:
                path.addEllipse(in: CGRect(x: x - s * 0.8, y: y - s * 0.8, width: s * 1.6, height: s * 1.6))
            }
            // Surface ring first, so markers stay legible on top of lines and each other.
            context.stroke(path, with: .color(chrome.surface), style: StrokeStyle(lineWidth: dense ? 2 : 3, lineJoin: .round))
            switch marker.kind {
            case .buy, .event:
                context.fill(path, with: .color(ink))
            case .sell, .dividend:
                // Hollow: direction and kind read without color.
                context.fill(path, with: .color(chrome.surface))
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            }
        }
    }

    private static func dot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color, ring: Color) {
        let outer = CGRect(x: point.x - radius - 2, y: point.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2)
        context.fill(Path(ellipseIn: outer), with: .color(ring))
        context.fill(Path(ellipseIn: outer.insetBy(dx: 2, dy: 2)), with: .color(color))
    }

    /// View-space points of a series, reduced to pixel resolution.
    private static func points(_ s: TimeSeries, g: Geometry, y: (Double) -> CGFloat) -> [CGPoint] {
        // Only the part inside the time domain, plus one neighbour on each side for continuity.
        var first = 0, last = s.days.count - 1
        if let i = s.index(atOrBefore: g.d0) { first = i }
        if let i = s.index(atOrBefore: g.d1) { last = min(s.days.count - 1, i + 1) } else { return [] }
        guard first <= last else { return [] }
        var xs = [CGFloat](), ys = [CGFloat]()
        xs.reserveCapacity(last - first + 1)
        ys.reserveCapacity(last - first + 1)
        for i in first...last {
            xs.append(g.x(s.days[i]))
            ys.append(y(s.values[i]))
        }
        return ChartReducer.indices(xs: xs, ys: ys).map { CGPoint(x: xs[$0], y: ys[$0]) }
    }

    private static func path(_ points: [CGPoint], step: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if step {
            for i in 1..<max(1, points.count) {
                path.addLine(to: CGPoint(x: points[i].x, y: points[i - 1].y))
                path.addLine(to: points[i])
            }
        } else {
            path.addLines(points)
        }
        return path
    }
}

#Preview("TimeSeriesChart") {
    let start = Day(year: 2016, month: 1, day: 1)
    let wave: [Double] = (0..<3650).map { i in
        let trend = 10_000_000 + Double(i) * 9_000
        return trend + sin(Double(i) / 40) * 1_500_000
    }
    let steps: [Double] = (0..<3650).map { i in 10_000_000 + Double(i / 30) * 250_000 }
    TimeSeriesChart([
        TimeSeries("Portfolio", start: start, values: wave, style: .area),
        TimeSeries("Invested", start: start, values: steps, style: .step, color: ChartColors.comparison),
    ], format: .money("EUR"), title: "Portfolio value")
    .rangeSelection()
    .frame(width: 640, height: 300)
    .padding()
}
