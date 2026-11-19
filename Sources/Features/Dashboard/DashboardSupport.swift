import SwiftUI
import KontorUI

// MARK: - Session (per-window view state shared by the screen, its sheets, the inspector and the palette)

/// View state of the Dashboard screen of one window. It lives outside the screen so that palette
/// commands, the inspector and the feature's sheets can act on the same dashboard.
@MainActor @Observable
final class DashboardSession {
    /// Edit mode. Enter by setting it; leave through `PortfolioStore.finishDashboardEditing(commitName:)`
    /// so a typed dashboard name is committed or discarded — never left behind.
    var isEditing = false
    /// The dashboard on screen. Switch through `PortfolioStore.selectDashboard(_:)`.
    var selectedID: UUID?
    /// The name being typed in the edit bar, and the dashboard it belongs to. Nil while the field
    /// shows the stored name. A draft never outlives edit mode or its dashboard.
    var nameDraft: (dashboard: UUID, text: String)?
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
    /// the file by its first edit — its first *real* edit: an action that changes nothing (moving
    /// the first widget earlier, choosing the width it already has) must not save it, or it would
    /// leave an undo step that does nothing and a document marked as edited.
    func editDashboard(_ actionName: String, _ body: (inout Dashboard) -> Void) {
        guard !dashboardSession.showsCatalog else { return }
        let before = currentDashboard
        var dashboard = before
        body(&dashboard)
        guard dashboard != before else { return }
        upsertDashboard(dashboard, actionName: actionName)
        dashboardSession.selectedID = dashboard.id
    }

    // MARK: Edit mode and the name field

    /// The text of the name field: the draft being typed, else the stored name.
    var dashboardNameText: String {
        let dashboard = currentDashboard
        if let draft = dashboardSession.nameDraft, draft.dashboard == dashboard.id { return draft.text }
        return dashboard.name
    }

    func setDashboardNameDraft(_ text: String) {
        let dashboard = currentDashboard
        dashboardSession.nameDraft = text == dashboard.name ? nil : (dashboard.id, text)
    }

    /// Renames the current dashboard to the typed name (if it is a real, different name) and
    /// forgets the draft, so the field shows the stored name again — also after an empty input.
    func commitDashboardName() {
        let session = dashboardSession
        guard let draft = session.nameDraft else { return }
        session.nameDraft = nil
        if draft.dashboard == currentDashboard.id { renameDashboard(draft.text) }
    }

    /// The one way out of edit mode — toolbar, edit bar, inspector, palette, Esc. Layout changes
    /// are saved as they are made; this decides about the name being typed: every "Done" commits
    /// it, Esc discards it.
    func finishDashboardEditing(commitName: Bool = true) {
        if commitName { commitDashboardName() }
        dashboardSession.nameDraft = nil
        dashboardSession.isEditing = false
    }

    func toggleDashboardEditing() {
        if dashboardSession.isEditing { finishDashboardEditing() } else { dashboardSession.isEditing = true }
    }

    /// Shows another dashboard. A name typed for the one on screen is committed first.
    func selectDashboard(_ id: UUID) {
        let session = dashboardSession
        if session.selectedID != id || session.showsCatalog { commitDashboardName() }
        session.showsCatalog = false
        session.selectedID = id
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

    /// Replaces the widgets with the default layout. Undoable, so it does not ask — but it says
    /// what happened and how to get the old layout back. A dashboard that already is the default
    /// layout is left alone.
    func resetDashboardToDefault() {
        guard !dashboardSession.showsCatalog else { return }
        let widgets = DashboardDefaults.widgets(for: file)
        func layout(_ widgets: [Dashboard.Widget]) -> [Dashboard.Widget] {
            widgets.map { Dashboard.Widget(id: DashboardDefaults.implicitID, kind: $0.kind, title: $0.title, span: $0.span, config: $0.config) }
        }
        let current = currentDashboard
        guard layout(current.widgets) != layout(widgets) else { return }
        let hadWidgets = !current.widgets.isEmpty
        editDashboard("Reset Dashboard") { $0.widgets = widgets }
        if hadWidgets { toast("“\(current.name)” reset to the default layout", message: "Undo (⌘Z) brings your layout back.") }
    }

    func newDashboard() {
        commitDashboardName()
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
        commitDashboardName()
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
        dashboardSession.nameDraft = nil
        deleteDashboard(current.id)
        toast("Dashboard “\(current.name)” deleted", message: "Undo (⌘Z) brings it back.")
        dashboardSession.selectedID = file.dashboards.indices.contains(index) ? file.dashboards[index].id : file.dashboards.last?.id
    }

    /// Whether the current dashboard can move by `offset` positions in the switcher.
    func canMoveCurrentDashboard(by offset: Int) -> Bool {
        guard let index = file.dashboards.firstIndex(where: { $0.id == currentDashboard.id }) else { return false }
        return offset != 0 && file.dashboards.indices.contains(index + offset)
    }

    /// Moves the current dashboard left (−1) or right (+1) in the switcher.
    func moveCurrentDashboard(by offset: Int) {
        guard canMoveCurrentDashboard(by: offset) else { return }
        let id = currentDashboard.id
        mutate("Move Dashboard") { file in
            guard let index = file.dashboards.firstIndex(where: { $0.id == id }) else { return }
            let dashboard = file.dashboards.remove(at: index)
            file.dashboards.insert(dashboard, at: index + offset)
        }
        dashboardSession.selectedID = id
    }
}

// MARK: - Grid layout

/// The dashboard grid: four columns (two below 1040 pt, one below 460 pt), widgets flow left to
/// right in file order and occupy `span` columns.
///
/// * **No holes across:** a row that cannot take the next widget stretches to the full width —
///   also a single tile in front of a full-width chart.
/// * **Fewer holes down:** widgets of a row share the row's height. Two neighbouring key-figure
///   tiles that share a row with something tall (a chart, a list) are stacked in one column
///   instead of each being stretched to the height of the chart.
struct DashboardGridLayout: Layout {
    var spacing: CGFloat = DS.Spacing.l

    struct Span: LayoutValueKey {
        static let defaultValue = 1
    }

    /// Key-figure tiles (short, fixed height) — the ones that may be stacked.
    struct IsTile: LayoutValueKey {
        static let defaultValue = false
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

    /// The columns ("slots") of one row when tiles are stacked: neighbouring one-column tiles pair
    /// up, provided the row also holds something that is not a tile. `spans` are effective spans.
    static func stackedSlots(row: [Int], spans: [Int], tiles: [Bool]) -> [[Int]] {
        func stackable(_ index: Int) -> Bool { tiles[index] && spans[index] == 1 }
        guard row.contains(where: { !tiles[$0] }) else { return row.map { [$0] } }
        var slots: [[Int]] = []
        var i = 0
        while i < row.count {
            if i + 1 < row.count, stackable(row[i]), stackable(row[i + 1]) {
                slots.append([row[i], row[i + 1]])
                i += 2
            } else {
                slots.append([row[i]])
                i += 1
            }
        }
        return slots
    }

    /// Widths of the slots of one row. A row that does not use every column stretches: its slots
    /// share the full width in proportion to their spans.
    static func slotWidths(spans: [Int], columns: Int, width: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let used = spans.reduce(0, +)
        guard used > 0 else { return [] }
        if used < columns {
            let unit = (width - spacing * CGFloat(spans.count - 1)) / CGFloat(used)
            return spans.map { unit * CGFloat($0) }
        }
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return spans.map { columnWidth * CGFloat($0) + spacing * CGFloat($0 - 1) }
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
        let tiles = subviews.map { $0[IsTile.self] }
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0

        func measure(_ slots: [[Int]]) -> (widths: [CGFloat], heights: [[CGFloat]]) {
            let widths = Self.slotWidths(spans: slots.map { spans[$0[0]] }, columns: columns, width: width, spacing: spacing)
            let heights = zip(slots, widths).map { slot, slotWidth in
                slot.map { subviews[$0].sizeThatFits(ProposedViewSize(width: slotWidth, height: nil)).height }
            }
            return (widths, heights)
        }

        for row in Self.rows(spans: spans, columns: columns) {
            var slots = row.map { [$0] }
            var measured = measure(slots)
            // Stack pairs of tiles when the row's tall widget leaves room for two of them.
            let stacked = Self.stackedSlots(row: row, spans: spans, tiles: tiles)
            if stacked.count < slots.count {
                var tileHeight: CGFloat = 0
                var tallest: CGFloat = 0
                for (index, heights) in zip(row, measured.heights) {
                    if tiles[index] { tileHeight = max(tileHeight, heights[0]) } else { tallest = max(tallest, heights[0]) }
                }
                if tallest >= (2 * tileHeight + spacing) * 0.8 {
                    slots = stacked
                    measured = measure(slots)
                }
            }
            var height: CGFloat = 0
            for members in measured.heights {
                // A stack gives each member the same share, so it needs room for its tallest one.
                let tallest: CGFloat = members.max() ?? 0
                let count = CGFloat(members.count)
                height = max(height, count * tallest + spacing * (count - 1))
            }
            var x: CGFloat = 0
            for (slot, slotWidth) in zip(slots, measured.widths) {
                let itemHeight = (height - spacing * CGFloat(slot.count - 1)) / CGFloat(slot.count)
                for (position, index) in slot.enumerated() {
                    frames[index] = CGRect(x: x, y: y + CGFloat(position) * (itemHeight + spacing), width: slotWidth, height: itemHeight)
                }
                x += slotWidth + spacing
            }
            y += height + spacing
        }
        cache = Cache(width: width, frames: frames, height: max(0, y - spacing))
    }
}

extension View {
    func dashboardSpan(_ span: Int, isTile: Bool = false) -> some View {
        layoutValue(key: DashboardGridLayout.Span.self, value: span)
            .layoutValue(key: DashboardGridLayout.IsTile.self, value: isTile)
    }
}
