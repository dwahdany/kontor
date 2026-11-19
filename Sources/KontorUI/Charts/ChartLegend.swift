import Accessibility
import SwiftUI

// MARK: - Legend

/// One entry of a chart legend.
public struct ChartLegendItem: Identifiable, Sendable {
    /// How the key next to the name is drawn.
    public enum Mark: Sendable, Hashable {
        /// A short line (line series); `dash` is the stroke pattern.
        case line(dash: [CGFloat])
        /// A rounded square (bars, areas, slices).
        case square
    }

    public var id: String
    public var name: String
    public var color: Color
    public var mark: Mark
    /// Optional value column ("€12,300.00").
    public var value: String?
    /// Optional secondary column ("32.1%").
    public var detail: String?
    /// Texture drawn into square keys (Differentiate Without Color).
    public var pattern: ChartPattern

    public init(id: String, name: String, color: Color, mark: Mark = .square, value: String? = nil, detail: String? = nil, pattern: ChartPattern = .solid) {
        self.id = id
        self.name = name
        self.color = color
        self.mark = mark
        self.value = value
        self.detail = detail
        self.pattern = pattern
    }
}

/// The key of a legend entry: a line sample or a swatch.
struct ChartLegendKey: View {
    let item: ChartLegendItem
    var isHidden = false

    var body: some View {
        Canvas { context, size in
            switch item.mark {
            case .line(let dash):
                var path = Path()
                path.move(to: CGPoint(x: 1, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                context.stroke(path, with: .color(item.color.opacity(isHidden ? 0.35 : 1)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            case .square:
                let side = min(size.height, 9)
                let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                let path = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
                if isHidden {
                    context.stroke(path, with: .color(item.color.opacity(0.6)), lineWidth: 1)
                } else {
                    context.fill(path, with: .color(item.color))
                    context.overlay(item.pattern, in: path, ink: ChartRGB(item.color, in: context.environment).ink)
                }
            }
        }
        .frame(width: item.mark == .square ? 9 : 16, height: 10)
        .accessibilityHidden(true)
    }
}

/// A chart legend. Horizontal legends wrap; vertical legends align name, value and detail in
/// columns. With `hidden`, entries are toggles; with `highlighted`, hovering an entry highlights
/// the matching mark.
///
/// ```swift
/// ChartLegend(items)                                         // static, wrapping row
/// ChartLegend(items, hidden: $hidden)                        // click to show/hide a series
/// ChartLegend(items, axis: .vertical, highlighted: $hovered) // name · value · share, hover-linked
/// ```
public struct ChartLegend: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let items: [ChartLegendItem]
    private let axis: Axis
    private let hidden: Binding<Set<String>>?
    private let highlighted: Binding<String?>?
    private let onSelect: ((String) -> Void)?

    public init(
        _ items: [ChartLegendItem], axis: Axis = .horizontal, hidden: Binding<Set<String>>? = nil,
        highlighted: Binding<String?>? = nil, onSelect: ((String) -> Void)? = nil
    ) {
        self.items = items
        self.axis = axis
        self.hidden = hidden
        self.highlighted = highlighted
        self.onSelect = onSelect
    }

    public var body: some View {
        switch axis {
        case .horizontal:
            ChartFlowLayout(spacing: DS.Spacing.m, lineSpacing: DS.Spacing.xs) {
                ForEach(items) { item in entry(item) }
            }
        case .vertical:
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: 5) {
                ForEach(items) { item in
                    GridRow {
                        HStack(spacing: DS.Spacing.xs + 2) {
                            ChartLegendKey(item: item)
                            Text(item.name).lineLimit(1).truncationMode(.tail)
                        }
                        if let value = item.value {
                            Text(value).numeric().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        }
                        if let detail = item.detail {
                            Text(detail).numeric().gridColumnAlignment(.trailing)
                        }
                    }
                    .opacity(dimmed(item) ? 0.45 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard let highlighted else { return }
                        if inside { highlighted.wrappedValue = item.id } else if highlighted.wrappedValue == item.id { highlighted.wrappedValue = nil }
                    }
                    .onTapGesture { onSelect?(item.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
                }
            }
            .font(.callout)
        }
    }

    private func dimmed(_ item: ChartLegendItem) -> Bool {
        if let h = highlighted?.wrappedValue { return h != item.id }
        return false
    }

    @ViewBuilder private func entry(_ item: ChartLegendItem) -> some View {
        let isHidden = hidden?.wrappedValue.contains(item.id) ?? false
        let label = HStack(spacing: DS.Spacing.xs + 1) {
            ChartLegendKey(item: item, isHidden: isHidden)
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(isHidden ? .tertiary : .secondary)
            if let value = item.value, !isHidden {
                Text(value).numeric().foregroundStyle(.primary)
            }
        }
        .font(.caption)
        .contentShape(Rectangle())
        if let hidden {
            Button {
                withAnimation(DS.Motion.standard(reduceMotion)) {
                    if isHidden { hidden.wrappedValue.remove(item.id) } else if hidden.wrappedValue.count < items.count - 1 {
                        // The last visible series stays: an empty chart is never useful.
                        hidden.wrappedValue.insert(item.id)
                    }
                }
            } label: { label }
                .buttonStyle(.plain)
                .help(isHidden ? "Show \(item.name)" : "Hide \(item.name)")
                .accessibilityLabel(item.name)
                .accessibilityValue(isHidden ? "hidden" : (item.value ?? "shown"))
                .accessibilityHint(isHidden ? "Shows the series" : "Hides the series")
        } else {
            label
                .onHover { inside in
                    guard let highlighted else { return }
                    if inside { highlighted.wrappedValue = item.id } else if highlighted.wrappedValue == item.id { highlighted.wrappedValue = nil }
                }
                .accessibilityElement(children: .combine)
        }
    }
}

/// A wrapping horizontal layout (legend rows).
struct ChartFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins = [CGPoint]()
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}

// MARK: - Tooltip

/// The floating value legend shown next to the pointer: a title and one row per series.
struct ChartTooltip: View {
    struct Row: Identifiable {
        var id: String
        var key: ChartLegendItem?
        /// A text glyph instead of a key (markers: ▲ ▼ ◆).
        var glyph: String?
        var name: String
        var value: String
        var isEmphasized = false
    }

    @Environment(\.colorSchemeContrast) private var contrast

    var title: String
    var subtitle: String?
    var rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).numeric()
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).numeric()
                }
            }
            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: 3) {
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 5) {
                                if let key = row.key {
                                    ChartLegendKey(item: key)
                                } else if let glyph = row.glyph {
                                    Text(glyph).font(.system(size: 8)).frame(width: 9)
                                }
                                Text(row.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            }
                            Text(row.value)
                                .numeric()
                                .fontWeight(row.isEmphasized ? .semibold : .regular)
                                .lineLimit(1)
                                .fixedSize()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.caption)
            }
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
}

extension View {
    /// Floats `tooltip` next to `anchor` (in this view's coordinate space), flipping to the other
    /// side and clamping so it never leaves the view.
    func chartTooltip<T: View>(at anchor: CGPoint?, gap: CGFloat = 12, horizontal: ChartTooltipHorizontal = .beside, vertical: ChartTooltipVertical = .centered, @ViewBuilder _ tooltip: () -> T) -> some View {
        let content = tooltip()
        return overlay(alignment: .topLeading) {
            if let anchor {
                GeometryReader { geometry in
                    let bounds = geometry.size
                    content
                        .alignmentGuide(.leading) { d in
                            var x = anchor.x + gap
                            if horizontal == .centered {
                                x = anchor.x - d.width / 2
                            } else if x + d.width > bounds.width {
                                x = anchor.x - gap - d.width
                            }
                            return -x.clamped(0, max(0, bounds.width - d.width))
                        }
                        .alignmentGuide(.top) { d in
                            let y: CGFloat = switch vertical {
                            case .centered: anchor.y - d.height / 2
                            case .top: 0
                            case .above: anchor.y - d.height - gap
                            }
                            return -y.clamped(0, max(0, bounds.height - d.height))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

enum ChartTooltipVertical { case centered, top, above }
enum ChartTooltipHorizontal { case beside, centered }

// MARK: - Empty and loading states

/// The quiet placeholder a chart shows instead of an empty plot.
struct ChartPlaceholder: View {
    var message: String
    var isLoading: Bool

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.m)
    }
}

extension View {
    /// Standard chart states: a placeholder when there is nothing to draw, dimmed content with a
    /// small spinner while newer data is being computed.
    func chartState(isEmpty: Bool, isLoading: Bool, message: String) -> some View {
        modifier(ChartStateModifier(isEmpty: isEmpty, isLoading: isLoading, message: message))
    }
}

private struct ChartStateModifier: ViewModifier {
    let isEmpty: Bool
    let isLoading: Bool
    let message: String

    func body(content: Content) -> some View {
        if isEmpty {
            ChartPlaceholder(message: message, isLoading: isLoading)
                .accessibilityElement(children: .combine)
        } else {
            content
                .opacity(isLoading ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    if isLoading { ProgressView().controlSize(.small).padding(DS.Spacing.xs) }
                }
        }
    }
}

// MARK: - Audio graph

/// Describes a chart to VoiceOver's audio graph ("Describe chart", "Play audio graph").
struct ChartAudioGraph: AXChartDescriptorRepresentable {
    struct Series {
        var name: String
        var isContinuous: Bool
        /// Either categories (`label`) or numeric x positions (`x`).
        var points: [(x: Double, label: String?, y: Double)]
    }

    var title: String
    var summary: String?
    var xTitle: String
    var yTitle: String
    var categories: [String]?
    var xDescription: @Sendable (Double) -> String = { Fmt.number($0, decimals: 0) }
    var yDescription: @Sendable (Double) -> String
    var series: [Series]

    func makeChartDescriptor() -> AXChartDescriptor {
        let ys = series.flatMap { $0.points.map(\.y) }.filter(\.isFinite)
        let yRange = (ys.min() ?? 0)...(Swift.max(ys.max() ?? 1, (ys.min() ?? 0) + .leastNonzeroMagnitude))
        let yDescription = yDescription
        let yAxis = AXNumericDataAxisDescriptor(title: yTitle, range: yRange, gridlinePositions: []) { yDescription($0) }
        let xAxis: any AXDataAxisDescriptor
        if let categories {
            xAxis = AXCategoricalDataAxisDescriptor(title: xTitle, categoryOrder: categories)
        } else {
            let xs = series.flatMap { $0.points.map(\.x) }
            let xDescription = xDescription
            let lower = xs.min() ?? 0
            xAxis = AXNumericDataAxisDescriptor(title: xTitle, range: lower...Swift.max(xs.max() ?? 1, lower + 1), gridlinePositions: []) { xDescription($0) }
        }
        let descriptors = series.map { s in
            AXDataSeriesDescriptor(name: s.name, isContinuous: s.isContinuous, dataPoints: s.points.map { p in
                if categories != nil, let label = p.label { return AXDataPoint(x: label, y: p.y) }
                return AXDataPoint(x: p.x, y: p.y)
            })
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: descriptors)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}
