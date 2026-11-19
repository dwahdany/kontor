import SwiftUI
import KontorModel
import KontorEngine

/// One row of a ``HeatmapGrid`` (a year of monthly returns).
public struct HeatmapRow: Identifiable, Sendable {
    public var id: String
    /// Row header ("2024").
    public var label: String
    /// One value per column; `nil` = no data (outside the period).
    public var cells: [Double?]
    /// Optional summary cell at the end of the row (the year's return).
    public var total: Double?

    public init(id: String? = nil, label: String, cells: [Double?], total: Double? = nil) {
        self.id = id ?? label
        self.label = label
        self.cells = cells
        self.total = total
    }
}

/// A grid of numbers colored on the diverging gain/loss scale — year × month returns. Every cell
/// prints its value in a color that keeps at least 4.5 : 1 contrast, so the grid reads without
/// relying on color; the scale below names the ends.
///
/// ```swift
/// HeatmapGrid(analysis.heatmap)                                   // engine ReturnHeatmap (compute off-main, pass the value)
/// HeatmapGrid(rows: rows, columns: ChartLabels.shortMonths, format: .percent(decimals: 1), totalTitle: "Year")
///     .selection { rowID, column in … }
/// ```
///
/// The grid has an intrinsic height (`rowHeight` × rows); give it the width you have.
public struct HeatmapGrid: View {
    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.chartPatternsForced) private var patternsForced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || patternsForced }

    private let rows: [HeatmapRow]
    private let columns: [String]
    private let format: ChartValueFormat
    private let totalTitle: String?
    private let limit: Double?
    private let title: String
    private var rowHeight: CGFloat = 26
    private var showsScale = true
    private var onSelect: ((String, Int) -> Void)?
    private var pinned: (row: String, column: Int)?
    private var isLoading = false
    private var emptyMessage = "No data for this period"

    @State private var hoverLocation: CGPoint?

    /// - Parameters:
    ///   - columns: column headers ("Jan" … "Dec": `ChartLabels.shortMonths`).
    ///   - totalTitle: header of the summary column; `nil` hides the column.
    ///   - limit: the magnitude with full color; `nil` derives it from the data (95th percentile,
    ///     so one extreme month does not wash out the rest).
    public init(
        rows: [HeatmapRow], columns: [String], format: ChartValueFormat = .percent(decimals: 1),
        totalTitle: String? = nil, limit: Double? = nil, title: String = "Heatmap"
    ) {
        self.rows = rows
        self.columns = columns
        self.format = format
        self.totalTitle = totalTitle
        self.limit = limit
        self.title = title
    }

    /// Year × month returns from the engine (`analysis.heatmap`, `returns.heatmap()`).
    public init(_ heatmap: ReturnHeatmap, newestFirst: Bool = true, title: String = "Monthly returns") {
        let rows = heatmap.rows.map { HeatmapRow(label: String($0.year), cells: $0.months, total: $0.total) }
        // Cells: one decimal ("5.4%", "-0.8%"); tooltips: the exact signed value.
        var format = ChartValueFormat.percent(decimals: 2, signed: true)
        format.compact = { Fmt.percent($0, decimals: abs($0) >= 0.0995 ? 0 : 1) }
        self.init(rows: newestFirst ? rows.reversed() : rows, columns: ChartLabels.shortMonths,
                  format: format, totalTitle: "Year", title: title)
    }

    public func rowHeight(_ height: CGFloat) -> HeatmapGrid {
        var copy = self
        copy.rowHeight = max(16, height)
        return copy
    }

    /// Hides the color scale below the grid.
    public func scaleHidden(_ hidden: Bool = true) -> HeatmapGrid {
        var copy = self
        copy.showsScale = !hidden
        return copy
    }

    /// Makes cells clickable: `action(rowID, columnIndex)`.
    public func selection(_ action: @escaping (_ rowID: String, _ column: Int) -> Void) -> HeatmapGrid {
        var copy = self
        copy.onSelect = action
        return copy
    }

    public func pinnedHover(row: String, column: Int) -> HeatmapGrid {
        var copy = self
        copy.pinned = (row, column)
        return copy
    }

    public func loading(_ isLoading: Bool) -> HeatmapGrid {
        var copy = self
        copy.isLoading = isLoading
        return copy
    }

    public func emptyMessage(_ message: String) -> HeatmapGrid {
        var copy = self
        copy.emptyMessage = message
        return copy
    }

    // MARK: Layout

    private let headerHeight: CGFloat = 20
    private let scaleHeight: CGFloat = 26
    private let gap: CGFloat = 2

    private var hasTotals: Bool { totalTitle != nil && rows.contains { $0.total != nil } }

    private var cellScale: DivergingScale {
        if let limit { return DivergingScale(limit: limit, gainStyle: gainStyle) }
        return DivergingScale(covering: rows.flatMap { $0.cells.compactMap { $0 } }, minimum: 0.0001, gainStyle: gainStyle)
    }

    private var totalScale: DivergingScale {
        DivergingScale(covering: rows.compactMap(\.total), minimum: cellScale.limit, gainStyle: gainStyle)
    }

    private struct Metrics {
        var labelWidth: CGFloat
        var cellWidth: CGFloat
        var totalX: CGFloat
        var totalWidth: CGFloat
        var columns: Int

        func x(_ column: Int) -> CGFloat { labelWidth + CGFloat(column) * cellWidth }
    }

    @MainActor private func metrics(width: CGFloat) -> Metrics {
        let labelWidth = (rows.map { ChartFont.width($0.label, size: ChartFont.labelSize, weight: .medium) }.max() ?? 0) + 10
        let n = max(1, columns.count)
        // The summary column is 1.25 cells wide, separated by a wider gap.
        let separator: CGFloat = hasTotals ? 8 : 0
        let units = CGFloat(n) + (hasTotals ? 1.25 : 0)
        let cell = max(4, (width - labelWidth - separator) / units)
        return Metrics(labelWidth: labelWidth, cellWidth: cell, totalX: labelWidth + CGFloat(n) * cell + separator,
                       totalWidth: hasTotals ? cell * 1.25 : 0, columns: n)
    }

    private var height: CGFloat {
        headerHeight + CGFloat(rows.count) * rowHeight + (showsScale ? scaleHeight : 0)
    }

    private func hit(_ location: CGPoint, _ m: Metrics) -> (row: Int, column: Int)? {
        let r = Int((location.y - headerHeight) / rowHeight)
        guard location.y >= headerHeight, rows.indices.contains(r) else { return nil }
        if hasTotals, location.x >= m.totalX, location.x <= m.totalX + m.totalWidth { return (r, -1) }
        let c = Int((location.x - m.labelWidth) / m.cellWidth)
        guard location.x >= m.labelWidth, c < m.columns else { return nil }
        return (r, c)
    }

    private func value(_ hit: (row: Int, column: Int)) -> Double? {
        hit.column < 0 ? rows[hit.row].total : (rows[hit.row].cells.indices.contains(hit.column) ? rows[hit.row].cells[hit.column] : nil)
    }

    // MARK: Body

    public var body: some View {
        let isEmpty = rows.isEmpty || columns.isEmpty
        GeometryReader { proxy in
            let m = metrics(width: proxy.size.width)
            let hovered = active(m)
            Canvas { context, size in draw(&context, m, size: size, hovered: hovered) }
                .chartTooltip(at: hovered.flatMap { h in value(h) == nil ? nil : anchor(h, m) }, gap: 8, vertical: .above) {
                    if let hovered, let v = value(hovered) {
                        ChartTooltip(
                            title: hovered.column < 0 ? "\(rows[hovered.row].label) · \(totalTitle ?? "Total")" : "\(columns[hovered.column]) \(rows[hovered.row].label)",
                            rows: [.init(id: "v", glyph: v > 0 ? "▲" : v < 0 ? "▼" : "–", name: title, value: format.value(v), isEmphasized: true)])
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
                    guard let onSelect, let h = hit(location, m), h.column >= 0, value(h) != nil else { return }
                    onSelect(rows[h.row].id, h.column)
                }
        }
        .frame(height: isEmpty ? 120 : height)
        .chartState(isEmpty: isEmpty, isLoading: isLoading, message: emptyMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
    }

    private func active(_ m: Metrics) -> (row: Int, column: Int)? {
        if let pinned, let r = rows.firstIndex(where: { $0.id == pinned.row }) { return (r, pinned.column) }
        return hoverLocation.flatMap { hit($0, m) }
    }

    private func cellRect(_ h: (row: Int, column: Int), _ m: Metrics) -> CGRect {
        let y = headerHeight + CGFloat(h.row) * rowHeight
        if h.column < 0 { return CGRect(x: m.totalX, y: y, width: m.totalWidth, height: rowHeight).insetBy(dx: gap / 2, dy: gap / 2) }
        return CGRect(x: m.x(h.column), y: y, width: m.cellWidth, height: rowHeight).insetBy(dx: gap / 2, dy: gap / 2)
    }

    private func anchor(_ h: (row: Int, column: Int), _ m: Metrics) -> CGPoint {
        let rect = cellRect(h, m)
        return CGPoint(x: rect.midX, y: rect.minY)
    }

    private var accessibilitySummary: String {
        rows.prefix(30).map { row in
            let cells = zip(columns, row.cells).compactMap { name, v in v.map { "\(name) \(format.value($0))" } }.joined(separator: ", ")
            return "\(row.label): " + (row.total.map { "\(totalTitle ?? "total") \(format.value($0)); " } ?? "") + cells
        }.joined(separator: ". ")
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ m: Metrics, size: CGSize, hovered: (row: Int, column: Int)?) {
        let chrome = ChartChrome(contrast: contrast, surface: .clear)
        let cellScale = cellScale, totalScale = totalScale
        let radius: CGFloat = min(4, m.cellWidth / 4)

        // Column headers (thinned if the cells are narrower than the labels).
        let widest = columns.map { context.textSize($0).width }.max() ?? 0
        let every = max(1, Int(((widest + 4) / m.cellWidth).rounded(.up)))
        for c in stride(from: 0, to: columns.count, by: every) {
            context.label(columns[c], at: CGPoint(x: m.x(c) + m.cellWidth / 2, y: headerHeight - 6), anchor: .bottom,
                          color: hovered?.column == c ? Color.primary : chrome.axisLabel)
        }
        if hasTotals, let totalTitle {
            context.label(totalTitle, at: CGPoint(x: m.totalX + m.totalWidth / 2, y: headerHeight - 6), anchor: .bottom,
                          font: ChartFont.axis.weight(.semibold), color: hovered?.column == -1 ? Color.primary : chrome.axisLabel)
        }

        func drawCell(_ value: Double?, rect: CGRect, scale: DivergingScale, font: Font) {
            let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            guard let value, value.isFinite else {
                context.fill(path, with: .color(Color.primary.opacity(contrast == .increased ? 0.08 : 0.035)))
                return
            }
            context.fill(path, with: .color(scale.color(for: value, scheme: colorScheme)))
            let ink = scale.ink(for: value, scheme: colorScheme)
            let text = format.compact(value)
            if context.textSize(text, font: font).width <= rect.width - 4, rect.height >= 14 {
                context.label(text, at: CGPoint(x: rect.midX, y: rect.midY), font: font, color: ink)
            } else if differentiateWithoutColor, value < 0 {
                // No room for the number: texture marks losses.
                context.overlay(.diagonal, in: path, ink: ink)
            }
        }

        for (r, row) in rows.enumerated() {
            let y = headerHeight + CGFloat(r) * rowHeight
            context.label(row.label, at: CGPoint(x: m.labelWidth - 8, y: y + rowHeight / 2), anchor: .trailing, font: ChartFont.label,
                          color: hovered?.row == r ? Color.primary : chrome.axisLabel)
            for c in 0..<m.columns {
                drawCell(row.cells.indices.contains(c) ? row.cells[c] : nil, rect: cellRect((r, c), m), scale: cellScale, font: ChartFont.axis)
            }
            if hasTotals {
                drawCell(row.total, rect: cellRect((r, -1), m), scale: totalScale, font: ChartFont.axis.weight(.semibold))
            }
        }

        if let hovered, value(hovered) != nil {
            let ring = Path(roundedRect: cellRect(hovered, m).insetBy(dx: -1, dy: -1), cornerRadius: radius + 1, style: .continuous)
            context.stroke(ring, with: .color(Color.primary), lineWidth: contrast == .increased ? 2.5 : 1.5)
        }

        // The scale: seven steps from −limit to +limit with the ends named.
        if showsScale {
            let y = headerHeight + CGFloat(rows.count) * rowHeight + 11
            let low = format.compact(-cellScale.limit), high = format.compact(cellScale.limit)
            var x = m.labelWidth + gap / 2
            let lowRect = context.label(low, at: CGPoint(x: x, y: y + 5), anchor: .leading, color: chrome.axisLabel)
            x = lowRect.maxX + 6
            let steps = 7
            for i in 0..<steps {
                let t = Double(i) / Double(steps - 1) * 2 - 1
                let rect = CGRect(x: x, y: y, width: 16, height: 10)
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous),
                             with: .color(cellScale.color(for: t == 0 ? nil : t * cellScale.limit, scheme: colorScheme)))
                x += 18
            }
            context.label(high, at: CGPoint(x: x + 4, y: y + 5), anchor: .leading, color: chrome.axisLabel)
        }
    }
}

#Preview("HeatmapGrid") {
    let rows: [HeatmapRow] = (0..<6).map { r in
        let cells: [Double?] = (0..<12).map { c in
            if r == 0, c > 7 { return nil }
            return sin(Double(r * 12 + c) * 1.7) * 0.06
        }
        return HeatmapRow(label: String(2025 - r), cells: cells, total: sin(Double(r) * 2.1) * 0.18)
    }
    HeatmapGrid(rows: rows, columns: ChartLabels.shortMonths, totalTitle: "Year")
        .frame(width: 640)
        .padding()
}
