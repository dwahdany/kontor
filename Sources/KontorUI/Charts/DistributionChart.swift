import SwiftUI
import KontorModel
import KontorEngine

/// A histogram: how often values fall into each range (daily or monthly returns, trade results,
/// holding periods). Bins have round edges; with `.gainLoss` coloring, bins below zero take the
/// loss color and bins above the gain color. Mean and median can be marked.
///
/// ```swift
/// // Bin off the main actor, pass the value:
/// let histogram = Histogram(analysis.returns.monthlyReturns().map(\.value), targetBins: 24)
/// DistributionChart(histogram, format: .percent(decimals: 1, signed: true), title: "Monthly returns")
///     .frame(height: 200)
///
/// DistributionChart(values: holdingDays, format: .count, coloring: .neutral)   // small inputs
/// ```
public struct DistributionChart: View {
    public enum Coloring: Sendable, Hashable {
        /// By the sign of the bin (returns, gains).
        case gainLoss
        /// One neutral color (quantities without polarity).
        case neutral
    }

    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }
    @Environment(\.chartSurface) private var surface

    private let histogram: Histogram
    private let format: ChartValueFormat
    private let coloring: Coloring
    private let title: String
    private var showsMean = true
    private var showsMedian = false
    private var pinnedBin: Int?
    private var isLoading = false
    private var emptyMessage = "Not enough data yet"

    @State private var hoverLocation: CGPoint?

    public init(_ histogram: Histogram, format: ChartValueFormat, coloring: Coloring = .gainLoss, title: String = "Distribution") {
        self.histogram = histogram
        self.format = format
        self.coloring = coloring
        self.title = title
    }

    /// Bins on the calling (main) actor — fine for a few thousand values; prefer ``Histogram`` inside `analysisTask`.
    public init(values: [Double], targetBins: Int = 20, format: ChartValueFormat, coloring: Coloring = .gainLoss, title: String = "Distribution") {
        self.init(Histogram(values, targetBins: targetBins), format: format, coloring: coloring, title: title)
    }

    /// Which summary markers are drawn (default: mean only).
    public func markers(mean: Bool = true, median: Bool = false) -> DistributionChart {
        var copy = self
        copy.showsMean = mean
        copy.showsMedian = median
        return copy
    }

    public func pinnedHover(bin: Int?) -> DistributionChart {
        var copy = self
        copy.pinnedBin = bin
        return copy
    }

    public func loading(_ isLoading: Bool) -> DistributionChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> DistributionChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    // MARK: Geometry

    private struct Metrics {
        var plot: CGRect
        var scale: LinearScale
        var labels: [String]
        var lower: Double
        var upper: Double
        var binWidth: CGFloat

        func x(_ value: Double) -> CGFloat {
            upper > lower ? plot.minX + CGFloat((value - lower) / (upper - lower)) * plot.width : plot.midX
        }

        func y(_ count: Double) -> CGFloat { plot.maxY - CGFloat(scale.position(count)) * plot.height }
    }

    @MainActor private func metrics(size: CGSize) -> Metrics? {
        guard let first = histogram.bins.first, let last = histogram.bins.last, size.width > 60, size.height > 50 else { return nil }
        let top: CGFloat = showsMean || showsMedian ? 20 : 7
        let plotHeight = size.height - 18 - top
        let maxCount = Double(histogram.bins.map(\.count).max() ?? 1)
        let scale = LinearScale.nice(min: 0, max: max(maxCount, 1), targetTicks: Int((plotHeight / 46).rounded()).clamped(2, 5), includeZero: true, padding: 0.05, tight: true)
        let labels = ChartValueFormat.count.axisLabels(scale.ticks)
        let labelWidth = labels.map { ChartFont.width($0) }.max() ?? 0
        let plot = CGRect(x: 0, y: top, width: max(20, size.width - labelWidth - 8), height: plotHeight)
        return Metrics(plot: plot, scale: scale, labels: labels, lower: first.lower, upper: last.upper,
                       binWidth: plot.width / CGFloat(histogram.bins.count))
    }

    private func activeBin(_ m: Metrics) -> Int? {
        if let pinnedBin, histogram.bins.indices.contains(pinnedBin) { return pinnedBin }
        guard let location = hoverLocation, location.x >= m.plot.minX, location.x <= m.plot.maxX else { return nil }
        return Int((location.x - m.plot.minX) / m.binWidth).clamped(0, histogram.bins.count - 1)
    }

    private func color(_ bin: Histogram.Bin) -> Color {
        guard coloring == .gainLoss else { return ChartColors.neutral }
        let mid = (bin.lower + bin.upper) / 2
        return gainStyle.color(for: mid)
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { proxy in
            let m = metrics(size: proxy.size)
            let hovered = m.flatMap(activeBin)
            Canvas { context, _ in
                guard let m else { return }
                draw(&context, m, hovered: hovered)
            }
            .chartTooltip(at: hovered.flatMap { i in m.map { CGPoint(x: $0.plot.minX + (CGFloat(i) + 0.5) * $0.binWidth, y: $0.y(Double(histogram.bins[i].count))) } },
                          gap: 8, horizontal: .centered, vertical: .above) {
                if let hovered {
                    let bin = histogram.bins[hovered]
                    ChartTooltip(title: "\(format.value(bin.lower)) to \(format.value(bin.upper))", rows: [
                        .init(id: "count", key: ChartLegendItem(id: "c", name: "Count", color: color(bin)), name: "Count", value: Fmt.integer(bin.count), isEmphasized: true),
                        .init(id: "share", glyph: "", name: "Share", value: Fmt.percent(Double(bin.count) / Double(max(1, histogram.total)), decimals: 1)),
                    ])
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
        }
        .frame(minHeight: 90)
        .chartState(isEmpty: histogram.total < 2, isLoading: isLoading, message: emptyMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
        .accessibilityChartDescriptor(audioGraph)
    }

    private var accessibilitySummary: String {
        var parts = ["\(Fmt.integer(histogram.total)) values"]
        if let first = histogram.bins.first, let last = histogram.bins.last {
            parts.append("from \(format.value(first.lower)) to \(format.value(last.upper))")
        }
        if let mean = histogram.mean { parts.append("mean \(format.value(mean))") }
        if let median = histogram.median { parts.append("median \(format.value(median))") }
        return parts.joined(separator: ", ")
    }

    private var audioGraph: ChartAudioGraph {
        let format = format
        return ChartAudioGraph(
            title: title, summary: accessibilitySummary, xTitle: "Value", yTitle: "Count", categories: nil,
            xDescription: { format.value($0) }, yDescription: { Fmt.integer(Int($0.clamped(0, 1e12))) },
            series: [.init(name: title, isContinuous: false, points: histogram.bins.map { (($0.lower + $0.upper) / 2, nil, Double($0.count)) })])
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ m: Metrics, hovered: Int?) {
        let chrome = ChartChrome(contrast: contrast, surface: surface)
        for (tick, label) in zip(m.scale.ticks, m.labels) {
            let y = m.y(tick)
            if tick != 0 { context.hline(y: y, from: m.plot.minX, to: m.plot.maxX, color: chrome.grid) }
            context.label(label, at: CGPoint(x: m.plot.maxX + 6, y: y), anchor: .leading, color: chrome.axisLabel)
        }

        let gap: CGFloat = m.binWidth >= 8 ? 2 : (m.binWidth >= 4 ? 1 : 0)
        for (i, bin) in histogram.bins.enumerated() where bin.count > 0 {
            let x = m.plot.minX + CGFloat(i) * m.binWidth
            let y = min(m.y(Double(bin.count)), m.plot.maxY - 1.5)
            let rect = CGRect(x: x + gap / 2, y: y, width: m.binWidth - gap, height: m.plot.maxY - y)
            let path = Path.bar(rect, radius: min(3, rect.width / 3), roundedEdge: .top)
            let tint = color(bin)
            var barContext = context
            if let hovered, hovered != i { barContext.opacity = 0.55 }
            barContext.fill(path, with: .color(tint))
            if differentiateWithoutColor, coloring == .gainLoss, bin.upper <= 0 {
                barContext.overlay(.diagonal, in: path, ink: ChartRGB(tint, in: context.environment).ink)
            }
        }
        context.hline(y: m.plot.maxY, from: m.plot.minX, to: m.plot.maxX, color: chrome.baseline)

        // Value axis: bin edges, thinned to fit.
        let edges = histogram.bins.map(\.lower) + [m.upper]
        let labels = format.axisLabels(edges)
        let widest = labels.map { context.textSize($0).width }.max() ?? 0
        var every = max(1, Int(((widest + 12) / m.binWidth).rounded(.up)))
        // Prefer a stride that keeps the zero edge labelled.
        if let zero = edges.firstIndex(of: 0) {
            while every > 1, zero % every != 0, every < edges.count { every += 1 }
        }
        var lastEnd = -CGFloat.infinity
        for i in stride(from: 0, to: edges.count, by: every) {
            let x = m.x(edges[i])
            context.vline(x: x, from: m.plot.maxY, to: m.plot.maxY + 3, color: chrome.baseline)
            let width = context.textSize(labels[i]).width
            let left = (x - width / 2).clamped(0, max(0, m.plot.maxX - width))
            guard left > lastEnd + 10 else { continue }
            context.label(labels[i], at: CGPoint(x: left, y: m.plot.maxY + 5), anchor: .topLeading, color: edges[i] == 0 ? Color.primary : chrome.axisLabel)
            lastEnd = left + width
        }

        // Mean / median markers, labelled at the top: the left one's label hangs to the left of
        // its line, the right one's to the right, so the two never collide.
        var marks = [(value: Double, name: String, dash: [CGFloat])]()
        if showsMean, let mean = histogram.mean, mean >= m.lower, mean <= m.upper { marks.append((mean, "Mean", [4, 3])) }
        if showsMedian, let median = histogram.median, median >= m.lower, median <= m.upper { marks.append((median, "Median", [1.5, 2.5])) }
        marks.sort { $0.value < $1.value }
        for (i, mark) in marks.enumerated() {
            let x = m.x(mark.value)
            context.vline(x: x, from: m.plot.minY - 4, to: m.plot.maxY, color: Color.primary.opacity(0.75), width: 1, dash: mark.dash)
            let text = "\(mark.name) \(format.value(mark.value))"
            let width = context.textSize(text, font: ChartFont.small).width
            let hangsLeft = marks.count > 1 ? i == 0 : x + 4 + width > m.plot.maxX
            let left = (hangsLeft ? x - 4 - width : x + 4).clamped(0, max(0, m.plot.maxX - width))
            context.label(text, at: CGPoint(x: left, y: m.plot.minY - 18), anchor: .topLeading, font: ChartFont.small, color: Color.primary.opacity(0.85))
        }
    }
}

// MARK: - Target vs. actual

/// A compact horizontal bar comparing an actual share with its target: the fill is the actual
/// value, a tick marks the target, an optional band shows the tolerance, and the label states the
/// difference in percentage points (▲ over, ▼ under) — so it reads without color.
///
/// ```swift
/// TargetActualBar(actual: 0.34, target: 0.30, color: ChartColors.series(0))                 // table cell
/// TargetActualBar(actual: node.share, target: node.targetShare, maximum: 0.6, tolerance: 0.05)
///     .frame(width: 160)
/// ```
public struct TargetActualBar: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartSurface) private var surface

    private let actual: Double
    private let target: Double?
    private let maximum: Double
    private let color: Color
    private let tolerance: Double?
    private let showsLabel: Bool
    private let format: ChartValueFormat

    /// - Parameters:
    ///   - actual: the actual value (a fraction with the default format).
    ///   - target: the target; `nil` draws the bar without a tick.
    ///   - maximum: the value at the full width — use the same for all bars of a table so they compare.
    ///   - tolerance: half-width of the acceptable band around the target, in the same unit.
    ///   - showsLabel: appends "▲ +4.00 pp" (difference to the target).
    public init(
        actual: Double?, target: Double?, maximum: Double = 1, color: Color = .accentColor, tolerance: Double? = nil,
        showsLabel: Bool = true, format: ChartValueFormat = .percent(decimals: 1, compounding: false)
    ) {
        self.actual = actual.flatMap { $0.isFinite ? $0 : nil } ?? 0
        self.target = target.flatMap { $0.isFinite ? $0 : nil }
        self.maximum = maximum > 0 ? maximum : 1
        self.color = color
        self.tolerance = tolerance
        self.showsLabel = showsLabel
        self.format = format
    }

    private var delta: Double? { target.map { actual - $0 } }

    private var isOutsideTolerance: Bool {
        guard let delta, let tolerance else { return false }
        return abs(delta) > tolerance
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Canvas { context, size in
                let height: CGFloat = 8
                let track = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
                func x(_ value: Double) -> CGFloat { CGFloat((value / maximum).clamped(0, 1)) * size.width }
                context.fill(Path(roundedRect: track, cornerRadius: height / 2), with: .color(Color.primary.opacity(contrast == .increased ? 0.2 : 0.09)))
                if let target, let tolerance, tolerance > 0 {
                    let band = CGRect(x: x(target - tolerance), y: track.minY - 2, width: max(2, x(target + tolerance) - x(target - tolerance)), height: height + 4)
                    context.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Color.primary.opacity(0.12)))
                }
                let fill = CGRect(x: 0, y: track.minY, width: max(actual > 0 ? 2 : 0, x(actual)), height: height)
                context.fill(Path(roundedRect: fill, cornerRadius: height / 2), with: .color(color))
                if let target {
                    let tick = CGRect(x: x(target).clamped(1, size.width - 1) - 1, y: track.minY - 4, width: 2, height: height + 8)
                    context.fill(Path(roundedRect: tick.insetBy(dx: -1.5, dy: -1), cornerRadius: 2), with: .color(surface))
                    context.fill(Path(roundedRect: tick, cornerRadius: 1), with: .color(Color.primary))
                }
            }
            .frame(minWidth: 40, minHeight: 16, maxHeight: 16)
            if showsLabel, let delta {
                Text("\(delta > 0 ? "▲" : delta < 0 ? "▼" : "–") \(format.change(0, delta))")
                    .font(.caption)
                    .numeric()
                    .foregroundStyle(isOutsideTolerance ? Color.primary : Color.secondary)
                    .fontWeight(isOutsideTolerance ? .semibold : .regular)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Actual versus target")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "actual \(format.value(actual))"
        if let target { text += ", target \(format.value(target))" }
        if let delta { text += ", \(delta >= 0 ? "over" : "under") by \(format.change(0, abs(delta)))" }
        return text
    }
}

#Preview("Distribution & TargetActualBar") {
    let values: [Double] = (0..<400).map { i in
        let a = sin(Double(i) * 12.9898) * 0.04
        return a + cos(Double(i) * 4.1) * 0.02
    }
    VStack(spacing: 24) {
        DistributionChart(values: values, format: .percent(decimals: 1, signed: true))
            .frame(height: 200)
        TargetActualBar(actual: 0.34, target: 0.30, tolerance: 0.03)
        TargetActualBar(actual: 0.12, target: 0.20, color: ChartColors.series(1))
    }
    .frame(width: 480)
    .padding()
}
