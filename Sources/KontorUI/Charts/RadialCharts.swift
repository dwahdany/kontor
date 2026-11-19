import SwiftUI
import KontorModel
import KontorEngine

// MARK: - Data

/// One part of a whole (``DonutChart``).
public struct ChartSlice: Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Must be positive to be drawn (minor units for `.money`).
    public var value: Double
    /// `nil` → the palette color of the slice's position.
    public var color: Color?

    public init(id: String? = nil, _ name: String, value: Double, color: Color? = nil) {
        self.id = id ?? name
        self.name = name
        self.value = value
        self.color = color
    }

    /// Keeps the `maxCount − 1` largest slices and folds the rest into one neutral "Other" slice —
    /// the palette has eight colors and is never cycled.
    public static func folded(_ slices: [ChartSlice], maxCount: Int = 8, otherName: String = "Other") -> [ChartSlice] {
        let positive = slices.filter { $0.value.isFinite && $0.value > 0 }
        guard positive.count > maxCount, maxCount > 1 else { return positive }
        let sorted = positive.sorted { $0.value > $1.value }
        var result = Array(sorted.prefix(maxCount - 1))
        let rest = sorted.dropFirst(maxCount - 1).reduce(0) { $0 + $1.value }
        result.append(ChartSlice(id: "chart.other", otherName, value: rest, color: ChartColors.other))
        return result
    }
}

/// A node of a hierarchy (``SunburstChart``, ``TreemapChart``).
///
/// `value` is the node's total **including** its children; whatever the children do not account
/// for is drawn as the node's own remainder.
///
/// ```swift
/// ChartNode(node.name, id: node.id.uuidString, value: Double(node.value),
///           color: ChartColors.classification(node.color, fallbackIndex: index),
///           children: node.children.map(makeNode))
/// ```
public struct ChartNode: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var value: Double
    /// `nil` → top level: palette by position; below: a tint of the parent's color.
    public var color: Color?
    /// Performance of the node (a fraction, e.g. period return) — used by `TreemapChart` when
    /// colored by performance, and shown in tooltips.
    public var change: Double?
    public var children: [ChartNode]

    public init(_ name: String, id: String? = nil, value: Double, color: Color? = nil, change: Double? = nil, children: [ChartNode] = []) {
        self.id = id ?? name
        self.name = name
        self.value = value
        self.color = color
        self.change = change
        self.children = children
    }
}

// MARK: - Shared radial plumbing

private struct RadialArc {
    var id: String
    var name: String
    var value: Double
    var depth: Int
    var start: Double       // radians, 0 = 12 o'clock, clockwise
    var end: Double
    var color: Color
    var pattern: ChartPattern
    /// ids from the top-level ancestor down to this arc.
    var path: [String]
    var change: Double?
}

private enum Radial {
    /// A ring segment with parallel-sided gaps to its neighbours.
    static func segment(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double, gap: CGFloat) -> Path {
        let sweep = end - start
        var padOuter = Double(asin(min(1, gap / 2 / max(outer, 1)))), padInner = Double(asin(min(1, gap / 2 / max(inner, 1))))
        if sweep < padInner * 2.4 || sweep > 2 * .pi - 0.0001 {
            padOuter = 0
            padInner = 0
        }
        let offset = -Double.pi / 2
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start + padOuter + offset), endAngle: .radians(end - padOuter + offset), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(end - padInner + offset), endAngle: .radians(start + padInner + offset), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Polar position of a point: angle clockwise from 12 o'clock (0 … 2π) and distance.
    static func polar(_ point: CGPoint, center: CGPoint) -> (angle: Double, radius: CGFloat) {
        let dx = point.x - center.x, dy = point.y - center.y
        var angle = Double(atan2(dx, -dy))
        if angle < 0 { angle += 2 * .pi }
        return (angle, hypot(dx, dy))
    }
}

/// Chart on the leading side with a vertical legend next to it, or — when narrow — above a
/// wrapping legend.
private struct RadialLayout<Chart: View>: View {
    var legend: [ChartLegendItem]
    @Binding var highlighted: String?
    var onSelect: ((String) -> Void)?
    @ViewBuilder var chart: Chart

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if legend.isEmpty {
                chart.frame(width: size.width, height: size.height)
            } else if size.width >= 330, size.width >= size.height * 1.5 {
                let side = min(size.height, size.width * 0.46)
                HStack(spacing: DS.Spacing.xl) {
                    chart.frame(width: side, height: side)
                    ScrollView(.vertical) {
                        ChartLegend(legend, axis: .vertical, highlighted: $highlighted, onSelect: onSelect)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: min(size.height, CGFloat(legend.count) * 23 + 4))
                }
                .frame(width: size.width, height: size.height, alignment: .leading)
            } else {
                VStack(spacing: DS.Spacing.m) {
                    chart.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ChartLegend(legend.map { item in
                        var item = item
                        item.value = item.detail
                        return item
                    }, highlighted: $highlighted)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(minHeight: 120)
    }
}

private struct RadialCenterLabel: View {
    var caption: String
    var value: String
    var detail: String?
    var width: CGFloat

    var body: some View {
        VStack(spacing: 1) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .numeric()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption).numeric().foregroundStyle(.secondary)
            }
        }
        .frame(width: max(20, width))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Donut

/// Parts of a whole as a ring, with a center label, hover highlight, selection and a legend with
/// values and percentages.
///
/// ```swift
/// DonutChart(ChartSlice.folded(slices), format: .money(currency), centerTitle: "Net Worth", title: "Asset classes")
///     .selection(selectedID) { selectedID = $0 }
///     .frame(height: 220)
/// ```
///
/// Use it for up to eight parts (`ChartSlice.folded` does that); for a two-level breakdown use
/// ``SunburstChart``, for many parts ``TreemapChart``.
public struct DonutChart: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let slices: [ChartSlice]
    private let format: ChartValueFormat
    private let centerTitle: String
    private let title: String
    private var selectedID: String?
    private var onSelect: ((String?) -> Void)?
    private var showsLegend = true
    private var isLoading = false
    private var emptyMessage = "Nothing to show yet"
    private var pinnedID: String?

    @State private var hoveredID: String?

    public init(_ slices: [ChartSlice], format: ChartValueFormat, centerTitle: String = "Total", title: String = "Chart") {
        self.slices = slices.filter { $0.value.isFinite && $0.value > 0 }
        self.format = format
        self.centerTitle = centerTitle
        self.title = title
    }

    /// Makes slices clickable; `action` receives the id, or `nil` when the selected slice is clicked again.
    public func selection(_ selected: String?, action: @escaping (String?) -> Void) -> DonutChart {
        var copy = self
        copy.selectedID = selected
        copy.onSelect = action
        return copy
    }

    public func legendHidden(_ hidden: Bool = true) -> DonutChart {
        var copy = self
        copy.showsLegend = !hidden
        return copy
    }

    public func loading(_ isLoading: Bool) -> DonutChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> DonutChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    /// Highlights a slice without a pointer (screenshots, linking with a table selection).
    public func pinnedHover(_ id: String?) -> DonutChart {
        var copy = self
        copy.pinnedID = id
        return copy
    }

    private var total: Double { slices.reduce(0) { $0 + $1.value } }
    private func color(_ index: Int) -> Color { slices[index].color ?? ChartColors.series(index) }
    private var activeID: String? { pinnedID ?? hoveredID ?? selectedID }

    private var arcs: [RadialArc] {
        var angle = 0.0
        let total = total
        return slices.indices.map { i in
            let sweep = total > 0 ? slices[i].value / total * 2 * .pi : 0
            defer { angle += sweep }
            return RadialArc(id: slices[i].id, name: slices[i].name, value: slices[i].value, depth: 0, start: angle, end: angle + sweep,
                             color: color(i), pattern: differentiateWithoutColor ? .slot(i) : .solid, path: [slices[i].id])
        }
    }

    private var legendItems: [ChartLegendItem] {
        guard showsLegend else { return [] }
        let total = total
        return slices.indices.map { i in
            ChartLegendItem(id: slices[i].id, name: slices[i].name, color: color(i), value: format.value(slices[i].value),
                            detail: Fmt.percent(slices[i].value / total, decimals: 1), pattern: differentiateWithoutColor ? .slot(i) : .solid)
        }
    }

    public var body: some View {
        let arcs = arcs
        RadialLayout(legend: legendItems, highlighted: $hoveredID, onSelect: onSelect.map { action in { id in action(id == selectedID ? nil : id) } }) {
            RadialPlot(arcs: arcs, levels: 1, holeFraction: 0.64, activeID: activeID, showsArcLabels: false, hoveredID: $hoveredID) { id in
                onSelect?(id == selectedID ? nil : id)
            } center: { width in
                if let active = arcs.first(where: { $0.id == activeID }) {
                    RadialCenterLabel(caption: active.name, value: format.value(active.value),
                                      detail: Fmt.percent(active.value / total, decimals: 1), width: width)
                } else {
                    RadialCenterLabel(caption: centerTitle, value: format.value(total), detail: nil, width: width)
                }
            }
        }
        .animation(DS.Motion.standard(reduceMotion), value: activeID)
        .chartState(isEmpty: slices.isEmpty, isLoading: isLoading, message: emptyMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
        .accessibilityChartDescriptor(audioGraph)
    }

    private var accessibilitySummary: String {
        let total = total
        return "\(centerTitle) \(format.value(total)). " + slices.map { "\($0.name) \(Fmt.percent($0.value / total, decimals: 1))" }.joined(separator: ", ")
    }

    private var audioGraph: ChartAudioGraph {
        let format = format
        return ChartAudioGraph(
            title: title, summary: accessibilitySummary, xTitle: "Part", yTitle: "Value", categories: slices.map(\.name),
            yDescription: { format.value($0) },
            series: [.init(name: title, isContinuous: false, points: slices.indices.map { (Double($0), slices[$0].name, slices[$0].value) })])
    }
}

// MARK: - Sunburst

/// A two- or three-level hierarchy as concentric rings (a classification tree: asset class →
/// region → sector). The inner ring shows the top level; children sit outside their parent in
/// tints of its color. Hovering highlights a node with its ancestors and descendants and shows
/// its value and share in the center.
///
/// ```swift
/// SunburstChart(nodes, format: .money(currency), centerTitle: "Asset Classes", title: "Allocation")
///     .levels(3)
///     .selection(selectedID) { store.navigate(to: .classification(taxonomy: t, id: UUID(uuidString: $0)!)) }
///     .frame(height: 260)
/// ```
public struct SunburstChart: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let nodes: [ChartNode]
    private let format: ChartValueFormat
    private let centerTitle: String
    private let title: String
    private var maxLevels = 3
    private var selectedID: String?
    private var onSelect: ((String?) -> Void)?
    private var showsLegend = true
    private var isLoading = false
    private var emptyMessage = "Nothing to show yet"
    private var pinnedID: String?

    @State private var hoveredID: String?

    public init(_ nodes: [ChartNode], format: ChartValueFormat, centerTitle: String = "Total", title: String = "Chart") {
        self.nodes = nodes.filter { $0.value.isFinite && $0.value > 0 }
        self.format = format
        self.centerTitle = centerTitle
        self.title = title
    }

    /// How many levels of the tree are drawn (1…3, default 3).
    public func levels(_ count: Int) -> SunburstChart {
        var copy = self
        copy.maxLevels = count.clamped(1, 3)
        return copy
    }

    public func selection(_ selected: String?, action: @escaping (String?) -> Void) -> SunburstChart {
        var copy = self
        copy.selectedID = selected
        copy.onSelect = action
        return copy
    }

    public func legendHidden(_ hidden: Bool = true) -> SunburstChart {
        var copy = self
        copy.showsLegend = !hidden
        return copy
    }

    public func loading(_ isLoading: Bool) -> SunburstChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> SunburstChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    public func pinnedHover(_ id: String?) -> SunburstChart {
        var copy = self
        copy.pinnedID = id
        return copy
    }

    private var total: Double { nodes.reduce(0) { $0 + $1.value } }
    private var activeID: String? { pinnedID ?? hoveredID ?? selectedID }

    private var arcs: (arcs: [RadialArc], levels: Int) {
        var result = [RadialArc]()
        var deepest = 0
        let total = total
        guard total > 0 else { return ([], 1) }
        func add(_ node: ChartNode, depth: Int, start: Double, sweep: Double, color: Color, pattern: ChartPattern, path: [String]) {
            let path = path + [node.id]
            result.append(RadialArc(id: node.id, name: node.name, value: node.value, depth: depth, start: start, end: start + sweep,
                                    color: color, pattern: pattern, path: path, change: node.change))
            deepest = max(deepest, depth)
            guard depth + 1 < maxLevels, node.value > 0 else { return }
            let children = node.children.filter { $0.value.isFinite && $0.value > 0 }
            // Children never claim more than their parent's sweep.
            let childTotal = max(node.value, children.reduce(0) { $0 + $1.value })
            var angle = start
            for (i, child) in children.enumerated() {
                let childSweep = sweep * child.value / childTotal
                add(child, depth: depth + 1, start: angle, sweep: childSweep,
                    color: child.color ?? ChartColors.shade(of: color, index: i, count: children.count), pattern: pattern, path: path)
                angle += childSweep
            }
        }
        var angle = 0.0
        for (i, node) in nodes.enumerated() {
            let sweep = node.value / total * 2 * .pi
            add(node, depth: 0, start: angle, sweep: sweep, color: node.color ?? ChartColors.series(i),
                pattern: differentiateWithoutColor ? .slot(i) : .solid, path: [])
            angle += sweep
        }
        return (result, deepest + 1)
    }

    private var legendItems: [ChartLegendItem] {
        guard showsLegend else { return [] }
        let total = total
        return nodes.enumerated().map { i, node in
            ChartLegendItem(id: node.id, name: node.name, color: node.color ?? ChartColors.series(i), value: format.value(node.value),
                            detail: Fmt.percent(node.value / total, decimals: 1), pattern: differentiateWithoutColor ? .slot(i) : .solid)
        }
    }

    public var body: some View {
        let layout = arcs
        let total = total
        RadialLayout(legend: legendItems, highlighted: $hoveredID, onSelect: onSelect.map { action in { id in action(id == selectedID ? nil : id) } }) {
            RadialPlot(arcs: layout.arcs, levels: layout.levels, holeFraction: layout.levels == 1 ? 0.64 : 0.42, activeID: activeID,
                       showsArcLabels: true, hoveredID: $hoveredID) { id in
                onSelect?(id == selectedID ? nil : id)
            } center: { width in
                if let active = layout.arcs.first(where: { $0.id == activeID }) {
                    RadialCenterLabel(caption: active.name, value: format.compact(active.value),
                                      detail: Fmt.percent(active.value / total, decimals: 1), width: width)
                } else {
                    RadialCenterLabel(caption: centerTitle, value: format.compact(total), detail: nil, width: width)
                }
            }
        }
        .animation(DS.Motion.standard(reduceMotion), value: activeID)
        .chartState(isEmpty: nodes.isEmpty, isLoading: isLoading, message: emptyMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary(layout.arcs, total: total))
    }

    private func accessibilitySummary(_ arcs: [RadialArc], total: Double) -> String {
        arcs.prefix(40).map { arc in
            "\(String(repeating: "sub-", count: arc.depth))\(arc.name) \(Fmt.percent(arc.value / total, decimals: 1))"
        }.joined(separator: ", ")
    }
}

// MARK: - The ring plot

private struct RadialPlot<Center: View>: View {
    @Environment(\.chartSurface) private var surface

    var arcs: [RadialArc]
    var levels: Int
    var holeFraction: CGFloat
    var activeID: String?
    var showsArcLabels: Bool
    @Binding var hoveredID: String?
    var onTap: (String) -> Void
    @ViewBuilder var center: (CGFloat) -> Center

    private struct Metrics {
        var center: CGPoint
        var hole: CGFloat
        var ring: CGFloat
        var outer: CGFloat

        init(size: CGSize, levels: Int, holeFraction: CGFloat) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            // 4 pt of room for the hover "lift".
            outer = max(10, min(size.width, size.height) / 2 - 4)
            hole = outer * holeFraction
            ring = (outer - hole) / CGFloat(max(1, levels))
        }

        func radii(depth: Int) -> (inner: CGFloat, outer: CGFloat) {
            (hole + CGFloat(depth) * ring, hole + CGFloat(depth + 1) * ring)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(size: proxy.size, levels: levels, holeFraction: holeFraction)
            let active = arcs.first { $0.id == activeID }
            Canvas { context, _ in
                for arc in arcs {
                    let radii = metrics.radii(depth: arc.depth)
                    // Emphasis: the active arc, its ancestors and its descendants.
                    let related = active.map { a in a.path.contains(arc.id) || arc.path.contains(a.id) } ?? true
                    let lift: CGFloat = arc.id == activeID && levels == 1 ? 3 : 0
                    let path = Radial.segment(center: metrics.center, inner: radii.inner, outer: radii.outer + lift,
                                              start: arc.start, end: arc.end, gap: 2)
                    var arcContext = context
                    if !related { arcContext.opacity = 0.32 }
                    arcContext.fill(path, with: .color(arc.color))
                    if arc.pattern != .solid {
                        arcContext.overlay(arc.pattern, in: path, ink: ChartRGB(arc.color, in: context.environment).ink)
                    }
                    if showsArcLabels, metrics.ring >= 18 {
                        let mid = (arc.start + arc.end) / 2, r = (radii.inner + radii.outer) / 2
                        // The (horizontal) label is drawn only where its whole box lies inside
                        // the segment — all four corners within the ring and the angular range.
                        let size = context.textSize(arc.name, font: ChartFont.small)
                        let anchor = CGPoint(x: metrics.center.x + r * CGFloat(sin(mid)), y: metrics.center.y - r * CGFloat(cos(mid)))
                        let box = CGRect(x: anchor.x - size.width / 2 - 3, y: anchor.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
                        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
                        let fits = corners.allSatisfy { corner in
                            let polar = Radial.polar(corner, center: metrics.center)
                            guard polar.radius >= radii.inner + 1, polar.radius <= radii.outer - 1 else { return false }
                            // Compare angles relative to the segment's middle, so wrap-around at 12 o'clock works.
                            var delta = polar.angle - mid
                            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
                            return abs(delta) <= (arc.end - arc.start) / 2
                        }
                        if fits {
                            let point = CGPoint(x: metrics.center.x + r * CGFloat(sin(mid)), y: metrics.center.y - r * CGFloat(cos(mid)))
                            arcContext.label(arc.name, at: point, font: ChartFont.small, color: ChartRGB(arc.color, in: context.environment).ink)
                        }
                    }
                }
            }
            .overlay { center(metrics.hole * 1.62) }
            .contentShape(Circle().inset(by: -2))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoveredID = arc(at: location, metrics)?.id
                case .ended: hoveredID = nil
                }
            }
            .onTapGesture { location in
                if let arc = arc(at: location, metrics) { onTap(arc.id) }
            }
        }
    }

    private func arc(at location: CGPoint, _ metrics: Metrics) -> RadialArc? {
        let polar = Radial.polar(location, center: metrics.center)
        guard polar.radius >= metrics.hole, polar.radius <= metrics.outer + 4 else { return nil }
        let depth = min(levels - 1, Int((polar.radius - metrics.hole) / metrics.ring))
        return arcs.first { $0.depth == depth && polar.angle >= $0.start && polar.angle < $0.end }
    }
}

#Preview("Donut & Sunburst") {
    HStack(spacing: 32) {
        DonutChart([
            ChartSlice("Equity", value: 62), ChartSlice("Bonds", value: 21), ChartSlice("Cash", value: 9), ChartSlice("Gold", value: 8),
        ], format: .number(decimals: 0))
        SunburstChart([
            ChartNode("Equity", value: 62, children: [ChartNode("World", value: 40), ChartNode("Emerging", value: 12), ChartNode("Europe", value: 10)]),
            ChartNode("Bonds", value: 21, children: [ChartNode("Government", value: 14), ChartNode("Corporate", value: 7)]),
            ChartNode("Cash", value: 17),
        ], format: .number(decimals: 0))
    }
    .frame(width: 900, height: 240)
    .padding()
}
