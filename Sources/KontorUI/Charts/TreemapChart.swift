import SwiftUI
import KontorModel
import KontorEngine

/// A squarified treemap: every leaf is a rectangle whose area is its value. Top-level nodes with
/// children become labelled groups holding all leaves below them (intermediate levels are skipped). Colored by category (identity) or by performance on the
/// diverging gain/loss scale.
///
/// ```swift
/// // Holdings by asset class, colored by category
/// TreemapChart(groups, format: .money(currency), title: "Holdings")
///
/// // The same cells colored by period return (ChartNode.change), ±10 % = full color
/// TreemapChart(groups, format: .money(currency), coloring: .performance(limit: 0.10), title: "Performance map")
///     .selection(selectedID) { id in … }
///     .frame(height: 320)
/// ```
public struct TreemapChart: View {
    public enum Coloring: Sendable, Hashable {
        /// The node's color; children of a group are tints of the group's color.
        case category
        /// `ChartNode.change` on the diverging gain/loss scale; `limit` is the change that gets
        /// full color (`nil` → derived from the data).
        case performance(limit: Double?)
    }

    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }

    private let nodes: [ChartNode]
    private let format: ChartValueFormat
    private let coloring: Coloring
    private let title: String
    private var selectedID: String?
    private var onSelect: ((String?) -> Void)?
    private var isLoading = false
    private var emptyMessage = "Nothing to show yet"
    private var pinnedID: String?

    @State private var hoverLocation: CGPoint?

    public init(_ nodes: [ChartNode], format: ChartValueFormat, coloring: Coloring = .category, title: String = "Chart") {
        self.nodes = nodes.filter { $0.value.isFinite && $0.value > 0 }
        self.format = format
        self.coloring = coloring
        self.title = title
    }

    public func selection(_ selected: String?, action: @escaping (String?) -> Void) -> TreemapChart {
        var copy = self
        copy.selectedID = selected
        copy.onSelect = action
        return copy
    }

    public func loading(_ isLoading: Bool) -> TreemapChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> TreemapChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    public func pinnedHover(_ id: String?) -> TreemapChart {
        var copy = self
        copy.pinnedID = id
        return copy
    }

    // MARK: Layout

    fileprivate struct Cell {
        var id: String
        var name: String
        var group: String?
        var value: Double
        var change: Double?
        var rect: CGRect
        var color: Color
        var pattern: ChartPattern
    }

    fileprivate struct GroupHeader {
        var name: String
        var rect: CGRect
    }

    private var total: Double { nodes.reduce(0) { $0 + $1.value } }

    private var scale: DivergingScale {
        if case .performance(let limit) = coloring, let limit { return DivergingScale(limit: limit, gainStyle: gainStyle) }
        let changes = nodes.flatMap(Self.leaves).compactMap(\.change)
        return DivergingScale(covering: changes, minimum: 0.02, gainStyle: gainStyle)
    }

    private func layout(in size: CGSize) -> (cells: [Cell], headers: [GroupHeader]) {
        var cells = [Cell](), headers = [GroupHeader]()
        let bounds = CGRect(origin: .zero, size: size)
        let rects = Treemap.layout(weights: nodes.map(\.value), in: bounds)
        let scale = scale
        let isPerformance: Bool = { if case .performance = coloring { true } else { false } }()
        func fill(_ node: ChartNode, base: Color, index: Int, count: Int, isChild: Bool) -> Color {
            if isPerformance { return scale.color(for: node.change, scheme: colorScheme) }
            if let color = node.color, isChild { return color }
            return isChild ? ChartColors.shade(of: base, index: index, count: count) : base
        }
        for (i, node) in nodes.enumerated() {
            let rect = rects[i]
            guard rect.width > 0, rect.height > 0 else { continue }
            let base = node.color ?? ChartColors.series(i)
            let pattern: ChartPattern = differentiateWithoutColor && !isPerformance ? .slot(i) : .solid
            let children = Self.leaves(of: node).sorted { $0.value > $1.value }
            if node.children.isEmpty || children.isEmpty {
                cells.append(Cell(id: node.id, name: node.name, group: nil, value: node.value, change: node.change, rect: rect.insetBy(dx: 1, dy: 1),
                                  color: fill(node, base: base, index: 0, count: 1, isChild: false), pattern: pattern))
                continue
            }
            // A group: a header strip with the group's name, children below it.
            var inner = rect.insetBy(dx: 2, dy: 2)
            if inner.height > 54, inner.width > 44 {
                headers.append(GroupHeader(name: node.name, rect: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 15)))
                inner = CGRect(x: inner.minX, y: inner.minY + 16, width: inner.width, height: inner.height - 16)
            }
            let childRects = Treemap.layout(weights: children.map(\.value), in: inner)
            for (j, child) in children.enumerated() where childRects[j].width > 0 {
                cells.append(Cell(id: child.id, name: child.name, group: node.name, value: child.value, change: child.change,
                                  rect: childRects[j].insetBy(dx: min(1, childRects[j].width / 4), dy: min(1, childRects[j].height / 4)),
                                  color: fill(child, base: base, index: j, count: children.count, isChild: true), pattern: pattern))
            }
        }
        return (cells, headers)
    }

    /// The leaves below a node, however deep (a group shows its securities, not its sub-groups).
    private static func leaves(of node: ChartNode) -> [ChartNode] {
        let children = node.children.filter { $0.value.isFinite && $0.value > 0 }
        return children.isEmpty ? [node] : children.flatMap(leaves)
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { proxy in
            let layout = layout(in: proxy.size)
            let hovered = activeCell(layout.cells)
            Canvas { context, _ in draw(&context, layout, hovered: hovered) }
                .chartTooltip(at: hovered.map { CGPoint(x: $0.rect.midX, y: $0.rect.minY) }, gap: 6, vertical: .above) {
                    if let hovered { tooltip(hovered) }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverLocation = location
                    case .ended: hoverLocation = nil
                    }
                }
                .onTapGesture { location in
                    guard let onSelect, let cell = layout.cells.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(location) }) else { return }
                    onSelect(cell.id == selectedID ? nil : cell.id)
                }
        }
        .frame(minHeight: 100)
        .chartState(isEmpty: nodes.isEmpty, isLoading: isLoading, message: emptyMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
    }

    private func activeCell(_ cells: [Cell]) -> Cell? {
        if let pinnedID { return cells.first { $0.id == pinnedID } }
        guard let location = hoverLocation else { return nil }
        return cells.first { $0.rect.insetBy(dx: -1, dy: -1).contains(location) }
    }

    private func tooltip(_ cell: Cell) -> ChartTooltip {
        var rows = [ChartTooltip.Row(id: "value", glyph: "", name: "Value", value: format.value(cell.value))]
        let total = total
        if total > 0 { rows.append(.init(id: "share", glyph: "", name: "Share", value: Fmt.percent(cell.value / total, decimals: 1))) }
        if let change = cell.change {
            rows.append(.init(id: "change", glyph: change > 0 ? "▲" : change < 0 ? "▼" : "–", name: "Change", value: Fmt.percent(change, signed: true), isEmphasized: true))
        }
        return ChartTooltip(title: cell.name, subtitle: cell.group, rows: rows)
    }

    private var accessibilitySummary: String {
        let total = total
        let leaves = nodes.flatMap(Self.leaves).sorted { $0.value > $1.value }
        return leaves.prefix(30).map { leaf in
            "\(leaf.name) \(Fmt.percent(leaf.value / total, decimals: 1))" + (leaf.change.map { ", \(Fmt.percent($0, signed: true))" } ?? "")
        }.joined(separator: "; ")
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ layout: (cells: [Cell], headers: [GroupHeader]), hovered: Cell?) {
        let isPerformance: Bool = { if case .performance = coloring { true } else { false } }()
        for header in layout.headers {
            let text = Self.fitted(header.name, width: header.rect.width - 4, font: ChartFont.small, context: context)
            if let text {
                context.label(text, at: CGPoint(x: header.rect.minX + 2, y: header.rect.midY), anchor: .leading, font: ChartFont.small, color: .secondary)
            }
        }
        for cell in layout.cells {
            let path = Path(roundedRect: cell.rect, cornerRadius: min(3, cell.rect.width / 3, cell.rect.height / 3), style: .continuous)
            var cellContext = context
            if let selectedID, selectedID != cell.id { cellContext.opacity = 0.5 }
            cellContext.fill(path, with: .color(cell.color))
            let rgb = ChartRGB(cell.color, in: context.environment)
            let ink = rgb.ink
            // Textures stay faint here: the cells carry text.
            if cell.pattern != .solid { cellContext.overlay(cell.pattern, in: path, ink: ink, strength: 0.25) }
            if isPerformance, differentiateWithoutColor, let change = cell.change, change < 0 {
                cellContext.overlay(.diagonal, in: path, ink: ink, strength: 0.25)
            }

            // Labels: name, then value or change — only what fits, never clipped.
            let padding: CGFloat = 5
            let width = cell.rect.width - padding * 2
            guard width >= 22, cell.rect.height >= 18 else { continue }
            guard let name = Self.fitted(cell.name, width: width, font: ChartFont.label, context: context) else { continue }
            cellContext.label(name, at: CGPoint(x: cell.rect.minX + padding, y: cell.rect.minY + 4), anchor: .topLeading, font: ChartFont.label, color: ink)
            guard cell.rect.height >= 34 else { continue }
            let secondary: String
            if isPerformance, let change = cell.change {
                secondary = (differentiateWithoutColor ? (change > 0 ? "▲ " : change < 0 ? "▼ " : "") : "") + Fmt.percent(change, decimals: 1, signed: true)
            } else {
                secondary = format.compact(cell.value)
            }
            if context.textSize(secondary, font: ChartFont.axis).width <= width {
                cellContext.label(secondary, at: CGPoint(x: cell.rect.minX + padding, y: cell.rect.minY + 18), anchor: .topLeading,
                                  font: ChartFont.axis, color: ink.opacity(0.8))
            }
        }
        if let hovered {
            let ring = Path(roundedRect: hovered.rect.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 3.5, style: .continuous)
            context.stroke(ring, with: .color(Color.primary), lineWidth: contrast == .increased ? 2.5 : 1.5)
        }
        if let selectedID, let cell = layout.cells.first(where: { $0.id == selectedID }) {
            let ring = Path(roundedRect: cell.rect.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 3.5, style: .continuous)
            context.stroke(ring, with: .color(Color.accentColor), lineWidth: 2)
        }
    }

    /// `text` if it fits `width`, else the longest prefix + "…" that does (at least three
    /// characters), else nil.
    private static func fitted(_ text: String, width: CGFloat, font: Font, context: GraphicsContext) -> String? {
        guard width > 0 else { return nil }
        if context.textSize(text, font: font).width <= width { return text }
        let characters = Array(text)
        var lo = 3, hi = characters.count - 1
        var best: String?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = String(characters[..<mid]).trimmingCharacters(in: .whitespaces) + "…"
            if context.textSize(candidate, font: font).width <= width {
                best = candidate
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}

#Preview("TreemapChart") {
    TreemapChart([
        ChartNode("Equity", value: 62, children: [
            ChartNode("MSCI World ETF", value: 30, change: 0.062), ChartNode("Emerging Markets", value: 12, change: -0.031),
            ChartNode("ACME Corp", value: 11, change: 0.12), ChartNode("Globex", value: 9, change: -0.004),
        ]),
        ChartNode("Bonds", value: 21, children: [ChartNode("Government Bonds", value: 14, change: 0.008), ChartNode("Corporate Bonds", value: 7, change: -0.012)]),
        ChartNode("Cash", value: 17, change: 0),
    ], format: .number(decimals: 0), coloring: .performance(limit: 0.1))
    .frame(width: 560, height: 300)
    .padding()
}
