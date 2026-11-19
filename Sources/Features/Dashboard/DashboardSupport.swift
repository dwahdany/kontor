import SwiftUI
import KontorUI

// MARK: - Session (per-window view state shared by the screen, its sheets, the inspector and the palette)

/// View state of the Dashboard screen of one window. It lives outside the screen so that palette
/// commands, the inspector and the feature's sheets can act on the same dashboard.
@MainActor @Observable
final class DashboardSession {
    var isEditing = false
    var selectedID: UUID?
    /// One-of-everything review dashboard (`--state dashboard=catalog`); never written to the file.
    var showsCatalog = false
    /// Restricts the review dashboard to one category (`--state category=…`).
    var catalogCategory: WidgetKind.Category?
    /// Shows chart tooltips without a pointer (`--state hover=1`).
    var pinsHover = false

    private static let sessions = NSMapTable<PortfolioStore, DashboardSession>.weakToStrongObjects()

    static func of(_ store: PortfolioStore) -> DashboardSession {
        if let session = sessions.object(forKey: store) { return session }
        let session = DashboardSession()
        sessions.setObject(session, forKey: store)
        return session
    }

    /// The dashboard on screen: the selected one, else the first, else the implicit default.
    func current(in file: PortfolioFile) -> Dashboard {
        if showsCatalog {
            var catalog = DashboardDefaults.catalog(for: file)
            if let catalogCategory { catalog.widgets.removeAll { $0.widgetKind?.category != catalogCategory } }
            return catalog
        }
        if let selectedID, let match = file.dashboards.first(where: { $0.id == selectedID }) { return match }
        return file.dashboards.first ?? DashboardDefaults.dashboard(for: file)
    }
}

// MARK: - Mutations (each one undo step)

extension PortfolioStore {
    var dashboardSession: DashboardSession { DashboardSession.of(self) }

    var currentDashboard: Dashboard { dashboardSession.current(in: file) }

    /// Edits the current dashboard as one undo step. The implicit default dashboard is written to
    /// the file by its first edit.
    func editDashboard(_ actionName: String, _ body: (inout Dashboard) -> Void) {
        guard !dashboardSession.showsCatalog else { return }
        var dashboard = currentDashboard
        body(&dashboard)
        upsertDashboard(dashboard, actionName: actionName)
        dashboardSession.selectedID = dashboard.id
    }

    func addWidget(_ kind: WidgetKind) {
        var widget = Dashboard.Widget(kind)
        if kind == .allocation, let taxonomy = file.taxonomies.first {
            widget.config[WidgetConfigKey.taxonomy] = taxonomy.id.uuidString
        }
        editDashboard("Add Widget") { $0.widgets.append(widget) }
    }

    func removeWidget(_ id: UUID) {
        editDashboard("Remove Widget") { d in d.widgets.removeAll { $0.id == id } }
    }

    func duplicateWidget(_ id: UUID) {
        editDashboard("Duplicate Widget") { d in
            guard let index = d.widgets.firstIndex(where: { $0.id == id }) else { return }
            var copy = d.widgets[index]
            copy.id = UUID()
            d.widgets.insert(copy, at: index + 1)
        }
    }

    func resizeWidget(_ id: UUID, to span: Int) {
        editDashboard("Resize Widget") { d in
            guard let index = d.widgets.firstIndex(where: { $0.id == id }) else { return }
            d.widgets[index].span = min(max(span, Dashboard.Widget.spanRange.lowerBound), Dashboard.Widget.spanRange.upperBound)
        }
    }

    /// Moves a widget by `offset` positions (clamped).
    func moveWidget(_ id: UUID, by offset: Int) {
        editDashboard("Move Widget") { d in
            guard let index = d.widgets.firstIndex(where: { $0.id == id }) else { return }
            let target = min(max(index + offset, 0), d.widgets.count - 1)
            guard target != index else { return }
            let widget = d.widgets.remove(at: index)
            d.widgets.insert(widget, at: target)
        }
    }

    /// Moves a widget to the position of another one (drag and drop).
    func moveWidget(_ id: UUID, onto targetID: UUID) {
        guard id != targetID else { return }
        editDashboard("Move Widget") { d in
            guard let from = d.widgets.firstIndex(where: { $0.id == id }),
                  let to = d.widgets.firstIndex(where: { $0.id == targetID }) else { return }
            let widget = d.widgets.remove(at: from)
            d.widgets.insert(widget, at: to)
        }
    }

    func updateWidget(_ widget: Dashboard.Widget, actionName: String = "Edit Widget") {
        editDashboard(actionName) { d in
            guard let index = d.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
            d.widgets[index] = widget
        }
    }

    func renameDashboard(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentDashboard.name else { return }
        editDashboard("Rename Dashboard") { $0.name = trimmed }
    }

    func resetDashboardToDefault() {
        let widgets = DashboardDefaults.widgets(for: file)
        editDashboard("Reset Dashboard") { $0.widgets = widgets }
    }

    func newDashboard() {
        let current = currentDashboard
        let session = dashboardSession
        let new = Dashboard(name: DashboardDefaults.uniqueName("New Dashboard", in: file),
                            widgets: [.init(.netWorth), .init(.ttwror), .init(.irr), .init(.absoluteGain)])
        mutate("New Dashboard") { file in
            // Keep the implicit default: without it, adding a second dashboard would replace it.
            if file.dashboards.isEmpty { file.dashboards.append(current) }
            file.dashboards.append(new)
        }
        session.showsCatalog = false
        session.selectedID = new.id
        session.isEditing = true
    }

    func duplicateDashboard() {
        let current = currentDashboard
        var copy = current
        copy.id = UUID()
        copy.name = DashboardDefaults.uniqueName("\(current.name) Copy", in: file)
        copy.widgets = copy.widgets.map { var w = $0; w.id = UUID(); return w }
        mutate("Duplicate Dashboard") { file in
            if file.dashboards.isEmpty { file.dashboards.append(current) }
            let index = file.dashboards.firstIndex { $0.id == current.id } ?? file.dashboards.count - 1
            file.dashboards.insert(copy, at: index + 1)
        }
        dashboardSession.showsCatalog = false
        dashboardSession.selectedID = copy.id
    }

    func deleteCurrentDashboard() {
        let current = currentDashboard
        guard let index = file.dashboards.firstIndex(where: { $0.id == current.id }) else { return }
        deleteDashboard(current.id)
        dashboardSession.selectedID = file.dashboards.indices.contains(index) ? file.dashboards[index].id : file.dashboards.last?.id
    }
}

// MARK: - Grid layout

/// The dashboard grid: four columns (two below 1040 pt, one below 460 pt), widgets flow left to
/// right in file order and occupy `span` columns. Widgets of a row share the row's height; a row
/// that cannot take the next widget stretches to the full width so there are no holes.
struct DashboardGridLayout: Layout {
    var spacing: CGFloat = DS.Spacing.l

    struct Span: LayoutValueKey {
        static let defaultValue = 1
    }

    struct Cache {
        var width: CGFloat = -1
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    static func columnCount(for width: CGFloat) -> Int {
        width >= 1040 ? 4 : width >= 460 ? 2 : 1
    }

    /// Spans as laid out: in two columns every widget wider than one column takes the full row.
    static func effectiveSpan(_ span: Int, columns: Int) -> Int {
        switch columns {
        case 4: min(max(span, 1), 4)
        case 2: span >= 2 ? 2 : 1
        default: 1
        }
    }

    /// Groups spans into rows (indices into the input).
    static func rows(spans: [Int], columns: Int) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used = 0
        for (index, span) in spans.enumerated() {
            let span = effectiveSpan(span, columns: columns)
            if used + span > columns, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(index)
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 960
        layout(width: width, subviews: subviews, cache: &cache, force: true)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        layout(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() where index < cache.frames.count {
            let frame = cache.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// Measuring always recomputes (widget heights change when their data arrives); placing reuses
    /// the measurement of the same width.
    private func layout(width: CGFloat, subviews: Subviews, cache: inout Cache, force: Bool = false) {
        guard force || cache.width != width || cache.frames.count != subviews.count else { return }
        let columns = Self.columnCount(for: width)
        let spans = subviews.map { Self.effectiveSpan($0[Span.self], columns: columns) }
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        for row in Self.rows(spans: spans, columns: columns) {
            let used = row.reduce(0) { $0 + spans[$1] }
            // Rows that are at least half full stretch to the full width; a lone small tile does not.
            let stretches = columns == 4 && used < columns && used * 2 >= columns
            let unit = stretches ? (width - spacing * CGFloat(row.count - 1)) / CGFloat(used) : columnWidth
            var x: CGFloat = 0
            var height: CGFloat = 0
            for index in row {
                let span = CGFloat(spans[index])
                let itemWidth = stretches ? unit * span : columnWidth * span + spacing * (span - 1)
                frames[index] = CGRect(x: x, y: y, width: itemWidth, height: 0)
                height = max(height, subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height)
                x += itemWidth + spacing
            }
            for index in row { frames[index].size.height = height }
            y += height + spacing
        }
        cache = Cache(width: width, frames: frames, height: max(0, y - spacing))
    }
}

extension View {
    func dashboardSpan(_ span: Int) -> some View { layoutValue(key: DashboardGridLayout.Span.self, value: span) }
}
