import SwiftUI
import KontorUI

/// Input of ``StackedAreaChart``: several series over one shared day axis, stacked in order
/// (first series at the bottom). Plain `Sendable` values, built off the main actor.
struct StackedAreaData: Sendable, Equatable {
    struct Series: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        /// Minor units of `currency`, one per day of `days`.
        var values: [Double]
    }

    var days: [Day]
    var series: [Series]
    var currency: CurrencyCode

    var isEmpty: Bool { days.count < 2 || series.isEmpty }

    static let maxSeries = 8

    /// At most eight series (the palette's size): the smallest ones by final value are summed into "Other".
    static func folded(_ series: [Series]) -> [Series] {
        guard series.count > maxSeries else { return series }
        let ranked = series.indices.sorted { abs(series[$0].values.last ?? 0) > abs(series[$1].values.last ?? 0) }
        let kept = Set(ranked.prefix(maxSeries - 1))
        var result = series.indices.filter(kept.contains).map { series[$0] }
        var other = [Double](repeating: 0, count: series[0].values.count)
        for index in series.indices where !kept.contains(index) {
            for (i, v) in series[index].values.enumerated() where i < other.count { other[i] += v }
        }
        result.append(Series(id: "other", name: "Other", values: other))
        return result
    }

    func total(at index: Int) -> Double { series.reduce(0) { $0 + $1.values[index] } }
}

/// A stacked area chart over days: what each part contributes to a total over time.
///
/// The shared chart kit has line and wash-area series but no stacking, so this one composition is
/// built here from the kit's building blocks (`LinearScale`, `DayAxis`, `ChartLegend`,
/// `ChartColors`, `ChartValueFormat`) and follows its conventions: value labels on the trailing
/// side, tight axis, hover crosshair with exact values drawn inside the chart's own bounds,
/// ←/→ under keyboard focus, `pinnedHover` for screenshots.
struct StackedAreaChart: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chartSurface) private var surface
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let data: StackedAreaData
    var title = "Chart"
    var isLoading = false
    var pinnedHover: Day?
    var emptyMessage = "No data in this period"

    @State private var hoverIndex: Int?
    @State private var keyboardIndex: Int?

    private var format: ChartValueFormat { .money(data.currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if data.isEmpty {
                VStack(spacing: DS.Spacing.s) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    Text(isLoading ? "Calculating…" : emptyMessage).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let geometry = Geometry(data, size: proxy.size, format: format)
                    let active = activeIndex
                    let width = proxy.size.width
                    Canvas { context, _ in
                        draw(&context, geometry, active: active)
                    }
                    .overlay(alignment: .topLeading) {
                        if let active {
                            tooltip(active)
                                .alignmentGuide(.leading) { d in
                                    let x = geometry.x(active)
                                    var left = x + 12
                                    if left + d.width > width { left = x - 12 - d.width }
                                    return -min(max(0, left), max(0, width - d.width))
                                }
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            keyboardIndex = nil
                            hoverIndex = geometry.index(atX: point.x)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                }
                .opacity(isLoading ? 0.55 : 1)
                .focusable()
                .onMoveCommand { direction in
                    let current = keyboardIndex ?? activeIndex ?? data.days.count - 1
                    switch direction {
                    case .left: keyboardIndex = max(0, current - 1)
                    case .right: keyboardIndex = min(data.days.count - 1, current + 1)
                    default: break
                    }
                }
                .onExitCommand { keyboardIndex = nil }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilitySummary)

                ChartLegend(data.series.enumerated().map { index, series in
                    ChartLegendItem(id: series.id, name: series.name, color: ChartColors.series(index),
                                    pattern: differentiateWithoutColor ? ChartPattern.slot(index) : .solid)
                })
            }
        }
    }

    private var activeIndex: Int? {
        if let keyboardIndex { return min(keyboardIndex, data.days.count - 1) }
        if let hoverIndex { return min(hoverIndex, data.days.count - 1) }
        guard let pinnedHover, let first = data.days.first else { return nil }
        // Nearest sampled day.
        var best = 0
        var distance = abs(first.distance(to: pinnedHover))
        for (index, day) in data.days.enumerated() where abs(day.distance(to: pinnedHover)) < distance {
            best = index
            distance = abs(day.distance(to: pinnedHover))
        }
        return best
    }

    private var accessibilitySummary: String {
        guard let last = data.days.indices.last else { return "" }
        let parts = data.series.map { "\($0.name) \(format.value($0.values[last]))" }
        return "Total \(format.value(data.total(at: last))) on \(Fmt.day(data.days[last], style: .medium)): " + parts.joined(separator: ", ")
    }

    // MARK: Tooltip

    private func tooltip(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Fmt.day(data.days[index], style: .medium)).font(.caption.weight(.semibold)).numeric()
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: 3) {
                // Top of the stack first, like the picture.
                ForEach(Array(data.series.enumerated()).reversed(), id: \.element.id) { i, series in
                    GridRow {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(ChartColors.series(i)).frame(width: 9, height: 9)
                            Text(series.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        Text(format.value(series.values[index])).numeric().lineLimit(1).fixedSize().gridColumnAlignment(.trailing)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total").foregroundStyle(.secondary)
                    Text(format.value(data.total(at: index))).numeric().fontWeight(.semibold).lineLimit(1).fixedSize()
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        .fixedSize()
        .accessibilityHidden(true)
    }

    // MARK: Geometry

    private struct Geometry {
        var plot: CGRect
        var scale: LinearScale
        var labels: [String]
        var ticks: [DayTick]
        var first: Day
        var span: Int
        var days: [Day]
        /// Stack boundaries: `bounds[k][i]` is the top of series k (bottom of k+1) on day i. `bounds[0]` is the base.
        var positive: [[Double]]
        var negative: [[Double]]

        @MainActor init(_ data: StackedAreaData, size: CGSize, format: ChartValueFormat) {
            days = data.days
            first = data.days.first ?? Day(rawValue: 0)
            span = max(1, first.distance(to: data.days.last ?? first))
            let count = data.days.count
            // Positive values stack upwards from zero, negative ones (overdrawn accounts) downwards.
            var up = [[Double]](repeating: [Double](repeating: 0, count: count), count: data.series.count + 1)
            var down = up
            for (k, series) in data.series.enumerated() {
                for i in 0..<count {
                    let v = i < series.values.count ? series.values[i] : 0
                    up[k + 1][i] = up[k][i] + max(0, v)
                    down[k + 1][i] = down[k][i] + min(0, v)
                }
            }
            positive = up
            negative = down
            let hi = up.last?.max() ?? 1, lo = down.last?.min() ?? 0
            let top: CGFloat = 7, xAxisHeight: CGFloat = 18
            let plotHeight = max(20, size.height - top - xAxisHeight)
            scale = .nice(min: lo, max: hi, targetTicks: min(7, max(2, Int((plotHeight / 46).rounded()))), includeZero: true, padding: 0.06, tight: true)
            labels = format.axisLabels(scale.ticks)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            let labelWidth = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
            let plotWidth = max(20, size.width - labelWidth - 8)
            plot = CGRect(x: 0, y: top, width: plotWidth, height: plotHeight)
            ticks = DayAxis.ticks(from: first, to: data.days.last ?? first, maxTicks: max(2, Int(plotWidth / 92)))
        }

        func x(_ day: Day) -> CGFloat { plot.minX + CGFloat(first.distance(to: day)) / CGFloat(span) * plot.width }
        func x(_ index: Int) -> CGFloat { x(days[index]) }
        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(scale.position(value)) * plot.height }

        func index(atX x: CGFloat) -> Int {
            let target = Double(min(max(0, (x - plot.minX) / max(1, plot.width)), 1)) * Double(span)
            var lo = 0, hi = days.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if Double(first.distance(to: days[mid])) < target { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, abs(Double(first.distance(to: days[lo - 1])) - target) <= abs(Double(first.distance(to: days[lo])) - target) { return lo - 1 }
            return lo
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ g: Geometry, active: Int?) {
        let strong = contrast == .increased
        let grid = Color.primary.opacity(strong ? 0.22 : 0.08)
        let baseline = Color.primary.opacity(strong ? 0.55 : 0.28)
        let axisLabel = strong ? Color.primary : Color.secondary
        let axisFont = Font.system(size: 10).monospacedDigit()

        func hline(_ y: CGFloat, _ color: Color) {
            var path = Path()
            let py = y.rounded() + 0.5
            path.move(to: CGPoint(x: g.plot.minX, y: py))
            path.addLine(to: CGPoint(x: g.plot.maxX, y: py))
            context.stroke(path, with: .color(color), lineWidth: 1)
        }

        // Bands, clipped to the plot.
        var plotContext = context
        plotContext.clip(to: Path(g.plot))
        for (k, _) in data.series.enumerated() {
            let color = ChartColors.series(k)
            for bounds in [g.positive, g.negative] {
                let lower = bounds[k], upper = bounds[k + 1]
                guard zip(lower, upper).contains(where: { $0 != $1 }) else { continue }
                var band = Path()
                band.move(to: CGPoint(x: g.x(0), y: g.y(upper[0])))
                for i in 1..<upper.count { band.addLine(to: CGPoint(x: g.x(i), y: g.y(upper[i]))) }
                for i in stride(from: lower.count - 1, through: 0, by: -1) { band.addLine(to: CGPoint(x: g.x(i), y: g.y(lower[i]))) }
                band.closeSubpath()
                plotContext.fill(band, with: .color(color.opacity(strong ? 0.95 : 0.82)))
                if differentiateWithoutColor { hatch(&plotContext, band, slot: k) }
                // A surface-colored seam separates neighbouring bands without adding ink.
                var edge = Path()
                edge.move(to: CGPoint(x: g.x(0), y: g.y(upper[0])))
                for i in 1..<upper.count { edge.addLine(to: CGPoint(x: g.x(i), y: g.y(upper[i]))) }
                plotContext.stroke(edge, with: .color(surface), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }

        // Grid over the bands (thin, so values stay readable against the fills), labels beside.
        for (tick, label) in zip(g.scale.ticks, g.labels) {
            let y = g.y(tick)
            hline(y, tick == 0 ? baseline : grid)
            let text = context.resolve(Text(label).font(axisFont).foregroundStyle(axisLabel))
            context.draw(text, at: CGPoint(x: g.plot.maxX + 6, y: y), anchor: .leading)
        }

        // Time axis.
        let bottom = g.plot.maxY
        hline(bottom, baseline)
        var lastLabelEnd = -CGFloat.infinity
        for tick in g.ticks {
            let x = g.x(tick.day)
            var mark = Path()
            mark.move(to: CGPoint(x: x.rounded() + 0.5, y: bottom))
            mark.addLine(to: CGPoint(x: x.rounded() + 0.5, y: bottom + 3))
            context.stroke(mark, with: .color(baseline), lineWidth: 1)
            let text = context.resolve(Text(tick.label).font(axisFont).foregroundStyle(axisLabel))
            let width = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
            let left = min(max(0, x - width / 2), max(0, g.plot.maxX - width))
            guard left > lastLabelEnd + 10 else { continue }
            context.draw(text, at: CGPoint(x: left, y: bottom + 5), anchor: .topLeading)
            lastLabelEnd = left + width
        }

        // Crosshair with a dot on every boundary.
        if let active {
            let x = g.x(active)
            var rule = Path()
            rule.move(to: CGPoint(x: x.rounded() + 0.5, y: g.plot.minY))
            rule.addLine(to: CGPoint(x: x.rounded() + 0.5, y: g.plot.maxY))
            context.stroke(rule, with: .color(Color.primary.opacity(strong ? 0.7 : 0.38)), lineWidth: 1)
            for k in data.series.indices where g.positive[k + 1][active] != g.positive[k][active] {
                let center = CGPoint(x: x, y: g.y(g.positive[k + 1][active]))
                let dot = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(surface))
                context.fill(Path(ellipseIn: dot.insetBy(dx: 1.5, dy: 1.5)), with: .color(ChartColors.series(k)))
            }
        }
    }

    /// Differentiate Without Color: a different line texture per band.
    private func hatch(_ context: inout GraphicsContext, _ band: Path, slot: Int) {
        guard slot % 4 != 0 else { return }
        var clipped = context
        clipped.clip(to: band)
        let bounds = band.boundingRect
        var lines = Path()
        let spacing: CGFloat = 6
        switch slot % 4 {
        case 1:
            var x = bounds.minX - bounds.height
            while x < bounds.maxX {
                lines.move(to: CGPoint(x: x, y: bounds.maxY))
                lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
                x += spacing
            }
        case 2:
            var y = bounds.minY
            while y < bounds.maxY {
                lines.move(to: CGPoint(x: bounds.minX, y: y))
                lines.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
        default:
            var x = bounds.minX
            while x < bounds.maxX {
                lines.move(to: CGPoint(x: x, y: bounds.minY))
                lines.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += spacing
            }
        }
        clipped.stroke(lines, with: .color(surface.opacity(0.7)), lineWidth: 1)
    }
}
