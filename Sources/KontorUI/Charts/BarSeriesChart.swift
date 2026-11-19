import SwiftUI
import KontorModel
import KontorEngine

// MARK: - Data

/// One slot on the category axis of a ``BarSeriesChart``: a month, a year, a security, …
public struct BarCategory: Identifiable, Sendable, Hashable {
    public var id: String
    /// Axis label — keep it short ("Mar", "2024", "Q3").
    public var label: String
    /// Tooltip title; defaults to `label` ("March 2024").
    public var detail: String

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail ?? label
    }

    /// A calendar month: id "2024-03", label "Mar" (or "Mar 2024" with `showsYear`), detail "March 2024".
    public static func month(year: Int, month: Int, showsYear: Bool = false) -> BarCategory {
        BarCategory(
            id: "\(year)-\(month < 10 ? "0" : "")\(month)",
            label: showsYear ? Fmt.month(year: year, month: month) : ChartLabels.shortMonth(month),
            detail: Fmt.month(year: year, month: month, long: true))
    }

    /// A calendar year: id and label "2024".
    public static func year(_ year: Int) -> BarCategory {
        BarCategory(id: String(year), label: String(year))
    }
}

/// One set of bars: a value per category, in category order.
public struct BarSeries: Identifiable, Sendable {
    public var id: String
    public var name: String
    /// `nil` → the palette color of the series' position.
    public var color: Color?
    /// One value per category (missing trailing values count as 0; non-finite values as 0).
    public var values: [Double]

    public init(id: String? = nil, _ name: String, values: [Double], color: Color? = nil) {
        self.id = id ?? name
        self.name = name
        self.values = values.map { $0.isFinite ? $0 : 0 }
        self.color = color
    }

    /// Minor units from the engine.
    public init(id: String? = nil, _ name: String, values: [Int64], color: Color? = nil) {
        self.init(id: id, name, values: values.map(Double.init), color: color)
    }
}

/// A line drawn over the bars on the same value axis (a trailing average, a cumulative total, a target).
public struct BarOverlayLine: Sendable {
    public var name: String
    /// One value per category; `nil` leaves a gap.
    public var values: [Double?]
    public var color: Color?

    public init(_ name: String, values: [Double?], color: Color? = nil) {
        self.name = name
        self.values = values
        self.color = color
    }
}

/// Month names for axes, in the app's formatting locale.
public enum ChartLabels {
    /// "Jan" … "Dec" (1-based month).
    public static func shortMonth(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Fmt.current.locale
        let symbols = calendar.shortStandaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : ""
    }

    /// All twelve, January first.
    public static var shortMonths: [String] { (1...12).map(shortMonth) }
}

// MARK: - Chart

/// Bars over categories or time buckets: one series, several side by side (`.grouped`) or on top
/// of each other (`.stacked`), colored by series or by gain/loss, with hover values, a selection
/// callback and an optional overlay line.
///
/// ```swift
/// // Monthly dividends, stacked by kind
/// BarSeriesChart(categories: months, series: [
///     BarSeries("Dividends", values: model.dividends),
///     BarSeries("Interest", values: model.interest),
/// ], format: .money(currency), layout: .stacked, title: "Earnings per month")
/// .overlayLine(BarOverlayLine("12-month average", values: model.trailingAverage))
/// .selection(selectedMonth) { selectedMonth = $0 }
///
/// // Yearly returns, green/red by sign
/// BarSeriesChart(categories: years, values: model.yearlyReturns, name: "Return",
///                format: .percent(signed: true), coloring: .gainLoss)
/// ```
///
/// ← / → move the highlight, Return selects when the chart has keyboard focus.
public struct BarSeriesChart: View {
    public enum Layout: Sendable, Hashable {
        /// Series side by side within a category.
        case grouped
        /// Series on top of each other (negative values stack downwards).
        case stacked
    }

    public enum Coloring: Sendable, Hashable {
        /// Each series in its own color (identity).
        case series
        /// Each bar by the sign of its value, in the user's gain/loss colors (polarity).
        case gainLoss
    }

    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }
    @Environment(\.chartSurface) private var surface

    private let categories: [BarCategory]
    private let series: [BarSeries]
    private let format: ChartValueFormat
    private let layout: Layout
    private let coloring: Coloring
    private let title: String
    private var overlay: BarOverlayLine?
    private var selectedID: String?
    private var onSelect: ((String?) -> Void)?
    private var showsValueLabels = false
    private var showsLegend = true
    private var isLoading = false
    private var emptyMessage = "No data for this period"
    private var pinnedID: String?

    @State private var hoverLocation: CGPoint?
    @State private var keyboardIndex: Int?

    public init(
        categories: [BarCategory], series: [BarSeries], format: ChartValueFormat,
        layout: Layout = .grouped, coloring: Coloring = .series, title: String = "Chart"
    ) {
        self.categories = categories
        self.series = series
        self.format = format
        self.layout = layout
        self.coloring = coloring
        self.title = title
    }

    /// A single series.
    public init(
        categories: [BarCategory], values: [Double], name: String, format: ChartValueFormat,
        coloring: Coloring = .gainLoss, title: String? = nil
    ) {
        self.init(categories: categories, series: [BarSeries(name, values: values)], format: format, coloring: coloring, title: title ?? name)
    }

    // MARK: Configuration

    /// A line over the bars, on the same value axis.
    public func overlayLine(_ line: BarOverlayLine?) -> BarSeriesChart {
        var copy = self
        copy.overlay = line
        return copy
    }

    /// Makes categories clickable. `selected` is highlighted; `action` receives the clicked
    /// category id, or `nil` when the selected one is clicked again.
    public func selection(_ selected: String?, action: @escaping (String?) -> Void) -> BarSeriesChart {
        var copy = self
        copy.selectedID = selected
        copy.onSelect = action
        return copy
    }

    /// Prints the value above each bar (stack totals for `.stacked`) where there is room.
    public func valueLabels(_ shown: Bool = true) -> BarSeriesChart {
        var copy = self
        copy.showsValueLabels = shown
        return copy
    }

    public func legendHidden(_ hidden: Bool = true) -> BarSeriesChart {
        var copy = self
        copy.showsLegend = !hidden
        return copy
    }

    public func loading(_ isLoading: Bool) -> BarSeriesChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> BarSeriesChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    /// Shows the hover highlight and legend for a category without a pointer (screenshots, linking).
    public func pinnedHover(_ categoryID: String?) -> BarSeriesChart {
        var copy = self
        copy.pinnedID = categoryID
        return copy
    }

    // MARK: Body

    public var body: some View {
        let isEmpty = categories.isEmpty || series.allSatisfy { s in s.values.allSatisfy { $0 == 0 } } && overlay == nil
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if showsLegend, !isEmpty, !legendItems.isEmpty {
                ChartLegend(legendItems)
            }
            GeometryReader { proxy in
                let geometry = Geometry(self, size: proxy.size)
                let hover = geometry.flatMap { activeIndex(in: $0) }
                Canvas { context, _ in
                    guard let geometry else { return }
                    draw(&context, geometry, hover: hover)
                }
                .chartTooltip(at: hover.flatMap { i in geometry.map { CGPoint(x: $0.center(i), y: $0.plot.minY) } }, gap: 14, vertical: .top) {
                    if let hover { tooltip(hover) }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                        keyboardIndex = nil
                    case .ended:
                        hoverLocation = nil
                    }
                }
                .onTapGesture { location in
                    guard let onSelect, let geometry, let index = geometry.index(atX: location.x) else { return }
                    let id = categories[index].id
                    onSelect(id == selectedID ? nil : id)
                }
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    let current = keyboardIndex ?? hover ?? categories.firstIndex { $0.id == selectedID } ?? categories.count
                    switch direction {
                    case .left: keyboardIndex = max(0, current - 1)
                    case .right: keyboardIndex = min(categories.count - 1, current + 1)
                    default: break
                    }
                }
                .onKeyPress(.return) {
                    guard let onSelect, let index = keyboardIndex else { return .ignored }
                    onSelect(categories[index].id == selectedID ? nil : categories[index].id)
                    return .handled
                }
                .onExitCommand { keyboardIndex = nil }
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

    private func seriesColor(_ index: Int) -> Color { series[index].color ?? ChartColors.series(index) }

    private func barColor(series index: Int, value: Double) -> Color {
        coloring == .gainLoss ? gainStyle.color(for: value) : seriesColor(index)
    }

    private var overlayColor: Color { overlay?.color ?? Color.primary.opacity(0.75) }

    private var legendItems: [ChartLegendItem] {
        var items = [ChartLegendItem]()
        if coloring == .series, series.count > 1 || overlay != nil {
            items = series.indices.map {
                ChartLegendItem(id: series[$0].id, name: series[$0].name, color: seriesColor($0),
                                pattern: differentiateWithoutColor ? .slot($0) : .solid)
            }
        }
        if let overlay, !items.isEmpty || coloring == .gainLoss {
            items.append(ChartLegendItem(id: "overlay", name: overlay.name, color: overlayColor, mark: .line(dash: [])))
        }
        return items
    }

    private func value(_ s: Int, _ c: Int) -> Double { series[s].values.indices.contains(c) ? series[s].values[c] : 0 }

    private func activeIndex(in geometry: Geometry) -> Int? {
        if let pinnedID, let i = categories.firstIndex(where: { $0.id == pinnedID }) { return i }
        if let keyboardIndex, categories.indices.contains(keyboardIndex) { return keyboardIndex }
        guard let location = hoverLocation, location.y <= geometry.plot.maxY + 20 else { return nil }
        return geometry.index(atX: location.x)
    }

    private func tooltip(_ index: Int) -> ChartTooltip {
        var rows = series.indices.map { s in
            let v = value(s, index)
            return ChartTooltip.Row(
                id: series[s].id,
                key: ChartLegendItem(id: series[s].id, name: series[s].name, color: barColor(series: s, value: v),
                                     pattern: differentiateWithoutColor && coloring == .series ? .slot(s) : .solid),
                name: series[s].name, value: format.value(v))
        }
        if layout == .stacked, series.count > 1 {
            let total = series.indices.reduce(0) { $0 + value($1, index) }
            rows.append(.init(id: "total", glyph: "", name: "Total", value: format.value(total), isEmphasized: true))
        }
        if let overlay, overlay.values.indices.contains(index), let v = overlay.values[index] {
            rows.append(.init(id: "overlay", key: ChartLegendItem(id: "overlay", name: overlay.name, color: overlayColor, mark: .line(dash: [])),
                              name: overlay.name, value: format.value(v)))
        }
        return ChartTooltip(title: categories[index].detail, rows: rows)
    }

    private var accessibilitySummary: String {
        guard let first = series.first else { return "" }
        let pairs = categories.indices.map { (categories[$0].detail, value(0, $0)) }
        guard let best = pairs.max(by: { $0.1 < $1.1 }), let worst = pairs.min(by: { $0.1 < $1.1 }) else { return "" }
        return "\(categories.count) bars. \(first.name): highest \(format.value(best.1)) in \(best.0), lowest \(format.value(worst.1)) in \(worst.0)."
    }

    private var audioGraph: ChartAudioGraph {
        let format = format
        return ChartAudioGraph(
            title: title, summary: accessibilitySummary, xTitle: "Category", yTitle: "Value",
            categories: categories.map(\.detail), yDescription: { format.value($0) },
            series: series.indices.map { s in
                .init(name: series[s].name, isContinuous: false, points: categories.indices.map { (Double($0), categories[$0].detail, value(s, $0)) })
            })
    }

    // MARK: Geometry

    fileprivate struct Geometry {
        var plot: CGRect
        var scale: LinearScale
        var labels: [String]
        var band: CGFloat
        var count: Int

        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(scale.position(value)) * plot.height }
        func center(_ index: Int) -> CGFloat { plot.minX + (CGFloat(index) + 0.5) * band }

        func index(atX x: CGFloat) -> Int? {
            guard count > 0, x >= plot.minX - 2, x <= plot.maxX + 2 else { return nil }
            return Int((x - plot.minX) / band).clamped(0, count - 1)
        }

        @MainActor init?(_ chart: BarSeriesChart, size: CGSize) {
            guard !chart.categories.isEmpty, size.width > 60, size.height > 40 else { return nil }
            count = chart.categories.count
            var lo = 0.0, hi = 0.0
            for c in 0..<count {
                if chart.layout == .stacked {
                    var positive = 0.0, negative = 0.0
                    for s in chart.series.indices {
                        let v = chart.value(s, c)
                        if v >= 0 { positive += v } else { negative += v }
                    }
                    lo = min(lo, negative)
                    hi = max(hi, positive)
                } else {
                    for s in chart.series.indices {
                        lo = min(lo, chart.value(s, c))
                        hi = max(hi, chart.value(s, c))
                    }
                }
                if let overlay = chart.overlay, overlay.values.indices.contains(c), let v = overlay.values[c], v.isFinite {
                    lo = min(lo, v)
                    hi = max(hi, v)
                }
            }
            let top: CGFloat = chart.showsValueLabels ? 18 : 7
            let plotHeight = size.height - 18 - top
            scale = .nice(min: lo, max: hi, targetTicks: Int((plotHeight / 46).rounded()).clamped(2, 7), includeZero: true,
                          padding: chart.showsValueLabels && lo < 0 ? 0.1 : 0.04, tight: true)
            labels = chart.format.axisLabels(scale.ticks)
            let labelWidth = labels.map { ChartFont.width($0) }.max() ?? 0
            plot = CGRect(x: 0, y: top, width: max(20, size.width - labelWidth - 8), height: plotHeight)
            band = plot.width / CGFloat(count)
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ g: Geometry, hover: Int?) {
        let chrome = ChartChrome(contrast: contrast, surface: surface)
        let selected = categories.firstIndex { $0.id == selectedID }

        // Highlight bands sit behind everything.
        func bandRect(_ i: Int) -> CGRect {
            CGRect(x: g.plot.minX + CGFloat(i) * g.band, y: g.plot.minY - 3, width: g.band, height: g.plot.height + 3).insetBy(dx: g.band > 6 ? 1 : 0, dy: 0)
        }
        if let selected {
            context.fill(Path(roundedRect: bandRect(selected), cornerRadius: 4), with: .color(Color.accentColor.opacity(0.16)))
        }
        if let hover, hover != selected {
            context.fill(Path(roundedRect: bandRect(hover), cornerRadius: 4), with: .color(Color.primary.opacity(0.06)))
        }

        for (tick, label) in zip(g.scale.ticks, g.labels) {
            let y = g.y(tick)
            if tick != 0 { context.hline(y: y, from: g.plot.minX, to: g.plot.maxX, color: chrome.grid) }
            context.label(label, at: CGPoint(x: g.plot.maxX + 6, y: y), anchor: .leading, color: chrome.axisLabel)
        }

        // Bars.
        let zero = g.y(0).rounded()
        let seriesCount = max(1, series.count)
        let slots = layout == .grouped ? seriesCount : 1
        let inner: CGFloat = g.band >= 14 ? 2 : (g.band >= 6 ? 1 : 0)
        let groupWidth = min(g.band * 0.74, CGFloat(slots) * 24 + CGFloat(slots - 1) * inner)
        let barWidth = max(1, (groupWidth - CGFloat(slots - 1) * inner) / CGFloat(slots))
        let radius = min(4, barWidth / 2.5)
        let gap: CGFloat = 2

        for c in 0..<g.count {
            let dim = selected != nil && selected != c
            var barContext = context
            if dim { barContext.opacity = 0.5 }
            let left = g.center(c) - groupWidth / 2
            var positiveTop = zero, negativeBottom = zero
            var stackTotal = 0.0
            for s in series.indices {
                let v = value(s, c)
                stackTotal += v
                guard v != 0 else { continue }
                let color = barColor(series: s, value: v)
                var rect: CGRect
                var rounded = true
                if layout == .stacked {
                    let height = abs(g.y(v) - g.y(0))
                    if v > 0 {
                        rect = CGRect(x: left, y: positiveTop - height, width: barWidth, height: height)
                        positiveTop -= height
                    } else {
                        rect = CGRect(x: left, y: negativeBottom, width: barWidth, height: height)
                        negativeBottom += height
                    }
                    // Only the outermost segment of a stack has the rounded data end; segments
                    // are separated by a 2 pt gap in the surface color.
                    let isOutermost = !series.indices.contains { $0 > s && (value($0, c) > 0) == (v > 0) && value($0, c) != 0 }
                    rounded = isOutermost
                    if !isOutermost, rect.height > gap + 1 {
                        if v > 0 { rect = CGRect(x: rect.minX, y: rect.minY + gap, width: rect.width, height: rect.height - gap) } else {
                            rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - gap)
                        }
                    }
                } else {
                    let x = left + CGFloat(s) * (barWidth + inner)
                    let y = g.y(v)
                    rect = CGRect(x: x, y: min(y, zero), width: barWidth, height: max(1, abs(y - zero)))
                }
                let path = rounded ? Path.bar(rect, radius: radius, roundedEdge: v > 0 ? .top : .bottom) : Path(rect)
                barContext.fill(path, with: .color(color))
                if differentiateWithoutColor {
                    let pattern: ChartPattern = coloring == .series ? .slot(s) : (v < 0 ? .diagonal : .solid)
                    barContext.overlay(pattern, in: path, ink: ChartRGB(color, in: context.environment).ink)
                }
            }
            if showsValueLabels {
                let total = layout == .stacked ? stackTotal : (series.count == 1 ? value(0, c) : .nan)
                if total.isFinite, total != 0 || series.count == 1 {
                    let text = format.compact(total)
                    if context.textSize(text, font: ChartFont.small).width <= g.band - 2 {
                        let y = layout == .stacked ? (total >= 0 ? positiveTop : negativeBottom) : g.y(total)
                        context.label(text, at: CGPoint(x: g.center(c), y: total >= 0 ? y - 3 : y + 3),
                                         anchor: total >= 0 ? .bottom : .top, font: ChartFont.small, color: Color.primary.opacity(dim ? 0.6 : 0.9))
                    }
                }
            }
        }

        // Zero baseline on top of the bars' square ends.
        context.hline(y: zero, from: g.plot.minX, to: g.plot.maxX, color: chrome.baseline)

        // Overlay line.
        if let overlay {
            var path = Path()
            var points = [CGPoint]()
            var pen = false
            for c in 0..<g.count {
                guard overlay.values.indices.contains(c), let v = overlay.values[c], v.isFinite else {
                    pen = false
                    continue
                }
                let p = CGPoint(x: g.center(c), y: g.y(v))
                if pen { path.addLine(to: p) } else { path.move(to: p) }
                pen = true
                points.append(p)
            }
            context.stroke(path, with: .color(chrome.surface), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(overlayColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if g.band >= 14 {
                for p in points {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(chrome.surface))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(overlayColor))
                }
            }
        }

        // Category labels: every k-th so they never collide; the hovered one is always shown.
        let widths = categories.map { context.textSize($0.label).width }
        let widest = widths.max() ?? 0
        let every = max(1, Int(((widest + 10) / g.band).rounded(.up)))
        let y = g.plot.maxY + 5
        func frame(_ i: Int) -> (x: CGFloat, end: CGFloat) {
            let x = (g.center(i) - widths[i] / 2).clamped(0, max(0, g.plot.maxX - widths[i]))
            return (x, x + widths[i])
        }
        // The hovered label is always shown; the regular ones make room for it and for each other.
        let hoverFrame = hover.map(frame)
        var lastEnd = -CGFloat.infinity
        for i in stride(from: 0, to: g.count, by: every) where i != hover {
            let f = frame(i)
            guard f.x >= lastEnd + 8 else { continue }
            if let hoverFrame, f.end + 8 > hoverFrame.x, f.x - 8 < hoverFrame.end { continue }
            context.label(categories[i].label, at: CGPoint(x: f.x, y: y), anchor: .topLeading, color: chrome.axisLabel)
            lastEnd = f.end
        }
        if let hover, let hoverFrame {
            context.label(categories[hover].label, at: CGPoint(x: hoverFrame.x, y: y), anchor: .topLeading, color: Color.primary)
        }
    }
}

#Preview("BarSeriesChart") {
    let months = (1...12).map { BarCategory.month(year: 2025, month: $0) }
    let dividends: [Double] = [12_000, 4_000, 31_000, 9_000, 15_000, 42_000, 6_000, 8_000, 33_000, 11_000, 7_000, 46_000]
    let interest: [Double] = [3_000, 3_000, 3_200, 3_100, 3_300, 3_500, 3_600, 3_600, 3_800, 4_000, 4_100, 4_300]
    BarSeriesChart(categories: months, series: [
        BarSeries("Dividends", values: dividends),
        BarSeries("Interest", values: interest),
    ], format: .money("EUR"), layout: .stacked)
    .frame(width: 560, height: 240)
    .padding()
}
