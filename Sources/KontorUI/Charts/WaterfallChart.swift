import SwiftUI
import KontorModel
import KontorEngine

/// One row of a ``WaterfallChart``.
public struct WaterfallStep: Identifiable, Sendable {
    public enum Kind: Sendable, Hashable {
        /// An absolute level (initial value, final value, subtotals): a neutral bar from the axis start.
        case total
        /// A signed change that floats from the running level, in the gain/loss color.
        case change
    }

    public var id: String
    public var label: String
    public var value: Double
    public var kind: Kind

    public init(id: String? = nil, _ label: String, value: Double, kind: Kind = .change) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.kind = kind
    }

    public static func total(_ label: String, value: Double, id: String? = nil) -> WaterfallStep {
        WaterfallStep(id: id, label, value: value, kind: .total)
    }

    public static func change(_ label: String, value: Double, id: String? = nil) -> WaterfallStep {
        WaterfallStep(id: id, label, value: value, kind: .change)
    }

    /// The engine's performance breakdown as waterfall rows — initial value, every non-zero line,
    /// final value (ids are the `PerformanceBreakdown.Line` raw values). Use with `.money(currency)`.
    public static func steps(from breakdown: PerformanceBreakdown) -> [WaterfallStep] {
        breakdown.lines.compactMap { line, amount in
            switch line {
            case .initialValue, .finalValue:
                return .total(line.title, value: Double(amount), id: line.rawValue)
            default:
                return amount == 0 ? nil : .change(line.title, value: Double(amount), id: line.rawValue)
            }
        }
    }
}

extension PerformanceBreakdown.Line {
    /// Display name of a breakdown line ("Unrealized Gains").
    public var title: String {
        switch self {
        case .initialValue: "Initial Value"
        case .deposits: "Deposits"
        case .deliveriesIn: "Deliveries In"
        case .transfersIn: "Transfers In"
        case .withdrawals: "Withdrawals"
        case .deliveriesOut: "Deliveries Out"
        case .transfersOut: "Transfers Out"
        case .realizedGains: "Realized Gains"
        case .unrealizedGains: "Unrealized Gains"
        case .dividends: "Dividends"
        case .interest: "Interest"
        case .fees: "Fees"
        case .taxes: "Taxes"
        case .cashCurrencyGains: "Currency Gains on Cash"
        case .roundingResidue: "Rounding"
        case .finalValue: "Final Value"
        }
    }
}

/// How a value got from its initial to its final level: one row per step, changes floating from
/// the running level in the gain/loss color, totals as neutral bars. Rows carry their label on the
/// left and the exact value on the right, so nothing needs a legend.
///
/// ```swift
/// WaterfallChart(WaterfallStep.steps(from: analysis.breakdown), format: .money(currency), title: "Performance breakdown")
///
/// WaterfallChart([.total("Start", value: 100), .change("Gains", value: 12), .change("Fees", value: -2), .total("End", value: 110)],
///                format: .number(decimals: 0))
/// ```
///
/// The chart has an intrinsic height (`rowHeight` × steps + axis). When the changes are small
/// against the totals the value axis does not start at zero; total bars then fade in from the
/// left to show that they are cut.
public struct WaterfallChart: View {
    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }
    @Environment(\.chartSurface) private var surface

    private let steps: [WaterfallStep]
    private let format: ChartValueFormat
    private let title: String
    private var rowHeight: CGFloat = 26
    private var pinnedID: String?
    private var onSelect: ((String) -> Void)?
    private var isLoading = false
    private var emptyMessage = "No data for this period"

    @State private var hoverLocation: CGPoint?

    public init(_ steps: [WaterfallStep], format: ChartValueFormat, title: String = "Breakdown") {
        self.steps = steps.filter { $0.value.isFinite }
        self.format = format
        self.title = title
    }

    public func rowHeight(_ height: CGFloat) -> WaterfallChart {
        var copy = self
        copy.rowHeight = max(18, height)
        return copy
    }

    /// Makes rows clickable (`action(stepID)`).
    public func selection(_ action: @escaping (String) -> Void) -> WaterfallChart {
        var copy = self
        copy.onSelect = action
        return copy
    }

    public func pinnedHover(_ id: String?) -> WaterfallChart {
        var copy = self
        copy.pinnedID = id
        return copy
    }

    public func loading(_ isLoading: Bool) -> WaterfallChart {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> WaterfallChart {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    // MARK: Model

    private struct Span {
        var from: Double
        var to: Double
    }

    /// Start and end level of every step.
    private var spans: [Span] {
        var running = 0.0
        return steps.map { step in
            switch step.kind {
            case .total:
                running = step.value
                return Span(from: 0, to: step.value)
            case .change:
                defer { running += step.value }
                return Span(from: running, to: running + step.value)
            }
        }
    }

    private func valueText(_ step: WaterfallStep) -> String {
        switch step.kind {
        case .total: format.value(step.value)
        case .change: (differentiateWithoutColor ? (step.value > 0 ? "▲ " : step.value < 0 ? "▼ " : "") : "") + format.change(0, step.value)
        }
    }

    private struct Metrics {
        var labelWidth: CGFloat
        var valueWidth: CGFloat
        var plot: CGRect
        var scale: LinearScale
        var tickLabels: [String]
        var isTruncated: Bool

        func x(_ value: Double) -> CGFloat { plot.minX + CGFloat(scale.position(value).clamped(0, 1)) * plot.width }
    }

    private let axisHeight: CGFloat = 20

    @MainActor private func metrics(size: CGSize, spans: [Span]) -> Metrics {
        let labelWidth = min(size.width * 0.34, (steps.map { ChartFont.width($0.label, size: 12) }.max() ?? 0) + 12)
        let valueWidth = (steps.map { ChartFont.width(valueText($0), size: 12, weight: .medium) }.max() ?? 0) + 12
        let plotWidth = max(40, size.width - labelWidth - valueWidth)
        // Levels the changes move between; totals additionally reach down to zero.
        let levels = zip(steps, spans).flatMap { step, span in step.kind == .total ? [span.to] : [span.from, span.to] }
        let lo = levels.min() ?? 0, hi = levels.max() ?? 1
        let truncated = lo > 0 && hi > 0 && lo / hi > 0.55 && steps.contains { $0.kind == .change }
        let targetTicks = Int((plotWidth / 90).rounded()).clamped(2, 6)
        let scale: LinearScale = truncated
            ? .nice(min: lo - (hi - lo) * 0.35, max: hi, targetTicks: targetTicks, padding: 0.03, tight: true)
            : .nice(min: min(lo, 0), max: max(hi, 0), targetTicks: targetTicks, includeZero: true, padding: 0.03, tight: true)
        return Metrics(
            labelWidth: labelWidth, valueWidth: valueWidth,
            plot: CGRect(x: labelWidth, y: 0, width: plotWidth, height: CGFloat(steps.count) * rowHeight),
            scale: scale, tickLabels: format.axisLabels(scale.ticks), isTruncated: truncated)
    }

    // MARK: Body

    public var body: some View {
        let spans = spans
        GeometryReader { proxy in
            let m = metrics(size: proxy.size, spans: spans)
            let hovered = activeRow
            Canvas { context, _ in draw(&context, m, spans: spans, hovered: hovered) }
                .chartTooltip(at: hovered.map { CGPoint(x: (m.x(spans[$0].from) + m.x(spans[$0].to)) / 2, y: CGFloat($0) * rowHeight) },
                              gap: 6, vertical: .above) {
                    if let hovered {
                        let step = steps[hovered]
                        ChartTooltip(title: step.label, rows: step.kind == .total
                            ? [.init(id: "v", glyph: "", name: "Level", value: format.value(step.value), isEmphasized: true)]
                            : [.init(id: "v", glyph: step.value > 0 ? "▲" : step.value < 0 ? "▼" : "–", name: "Change", value: format.change(0, step.value), isEmphasized: true),
                               .init(id: "r", glyph: "", name: "Level after", value: format.value(spans[hovered].to))])
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverLocation = location
                    case .ended: hoverLocation = nil
                    }
                }
                .onTapGesture { location in
                    let row = Int(location.y / rowHeight)
                    if let onSelect, steps.indices.contains(row), location.y >= 0 { onSelect(steps[row].id) }
                }
        }
        .frame(height: steps.isEmpty ? 120 : CGFloat(steps.count) * rowHeight + axisHeight)
        .chartState(isEmpty: steps.isEmpty, isLoading: isLoading, message: emptyMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(steps.map { "\($0.label) \(valueText($0))" }.joined(separator: ", "))
    }

    private var activeRow: Int? {
        if let pinnedID { return steps.firstIndex { $0.id == pinnedID } }
        guard let location = hoverLocation, location.y >= 0 else { return nil }
        let row = Int(location.y / rowHeight)
        return steps.indices.contains(row) ? row : nil
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ m: Metrics, spans: [Span], hovered: Int?) {
        let chrome = ChartChrome(contrast: contrast, surface: surface)
        let barHeight = min(16, rowHeight - 10)

        if let hovered {
            let band = CGRect(x: 0, y: CGFloat(hovered) * rowHeight, width: m.plot.maxX + m.valueWidth, height: rowHeight).insetBy(dx: 0, dy: 1)
            context.fill(Path(roundedRect: band, cornerRadius: 5, style: .continuous), with: .color(Color.primary.opacity(0.06)))
        }

        // Vertical grid and axis labels.
        var lastEnd = -CGFloat.infinity
        for (tick, label) in zip(m.scale.ticks, m.tickLabels) {
            let x = m.x(tick)
            context.vline(x: x, from: m.plot.minY, to: m.plot.maxY, color: tick == 0 ? chrome.baseline : chrome.grid)
            let width = context.textSize(label).width
            let left = (x - width / 2).clamped(m.plot.minX, max(m.plot.minX, m.plot.maxX - width))
            guard left > lastEnd + 8 else { continue }
            context.label(label, at: CGPoint(x: left, y: m.plot.maxY + 5), anchor: .topLeading, color: chrome.axisLabel)
            lastEnd = left + width
        }

        for (i, step) in steps.enumerated() {
            let span = spans[i]
            let midY = (CGFloat(i) + 0.5) * rowHeight
            let x0 = m.x(span.from), x1 = m.x(span.to)
            var rect = CGRect(x: min(x0, x1), y: midY - barHeight / 2, width: abs(x1 - x0), height: barHeight)
            if rect.width < 2 {
                // Keep tiny changes visible.
                rect = CGRect(x: rect.midX - 1, y: rect.minY, width: 2, height: rect.height)
            }

            // Connector from the previous row's end level.
            if i > 0 {
                let x = m.x(spans[i - 1].to)
                context.vline(x: x, from: midY - rowHeight + barHeight / 2, to: midY - barHeight / 2, color: chrome.baseline)
            }

            context.label(step.label, at: CGPoint(x: m.labelWidth - 10, y: midY), anchor: .trailing,
                          font: .system(size: 12, weight: step.kind == .total ? .semibold : .regular),
                          color: step.kind == .total || hovered == i ? Color.primary : Color.primary.opacity(0.8))

            switch step.kind {
            case .total:
                let path = Path.bar(rect, radius: 3, roundedEdge: span.to >= span.from ? .trailing : .leading)
                if m.isTruncated {
                    // The axis does not start at zero: fade the cut end in.
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [ChartColors.neutral.opacity(0.15), ChartColors.neutral]),
                        startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: min(rect.maxX, rect.minX + 36), y: 0)))
                } else {
                    context.fill(path, with: .color(ChartColors.neutral))
                }
            case .change:
                let color = gainStyle.color(for: step.value)
                let path = Path(roundedRect: rect, cornerRadius: min(3, rect.width / 2), style: .continuous)
                context.fill(path, with: .color(color))
                if differentiateWithoutColor, step.value < 0 {
                    context.overlay(.diagonal, in: path, ink: ChartRGB(color, in: context.environment).ink)
                }
            }

            context.label(valueText(step), at: CGPoint(x: m.plot.maxX + m.valueWidth, y: midY), anchor: .trailing,
                          font: .system(size: 12, weight: step.kind == .total ? .semibold : .medium).monospacedDigit(), color: Color.primary)
        }
    }
}

#Preview("WaterfallChart") {
    WaterfallChart([
        .total("Initial Value", value: 100_000_00), .change("Deposits", value: 12_000_00), .change("Unrealized Gains", value: 9_400_00),
        .change("Dividends", value: 1_850_00), .change("Fees", value: -320_00), .change("Taxes", value: -480_00), .total("Final Value", value: 122_450_00),
    ], format: .money("EUR"))
    .frame(width: 560)
    .padding()
}
