import SwiftUI
import KontorUI

/// How a widget is being shown.
enum WidgetMode: Sendable {
    /// On the dashboard: interactive, deep-links on click.
    case live
    /// On the dashboard in edit mode: content is inert, layout handles are shown.
    case editing
    /// In the gallery or the widget editor: inert, no chrome actions.
    case preview
}

/// What a widget asks the analysis layer for — resolved on the main actor from the widget's
/// configuration and the window's period and scope (cheap lookups only).
struct WidgetRequest {
    var kind: WidgetKind
    var scope: Scope
    var interval: DayInterval
    var query: WidgetQuery
    /// Short period name for the header ("YTD", "Max", "12M"); nil when the widget has no period.
    var periodLabel: String?
    var periodHelp: String?
    var isPeriodOverridden = false
    /// Set when the widget overrides the window's scope.
    var scopeLabel: String?
    var scopeSymbol = "square.stack.3d.up"

    @MainActor
    init(_ widget: Dashboard.Widget, kind: WidgetKind, store: PortfolioStore) {
        self.kind = kind
        let today = store.today
        let file = store.file
        var query = WidgetQuery(kind: kind, today: today)
        if kind.usesCount { query.count = widget.count }

        // Scope
        if kind.usesScope {
            if let override = widget.scopeOverride, let resolved = override.resolve(in: file) {
                scope = resolved
                scopeLabel = override.title(in: file)
                scopeSymbol = override.symbol
            } else {
                scope = store.scope
            }
        } else {
            scope = .portfolio
        }

        // Period
        if kind.usesPeriod {
            if kind == .topMovers, widget.showsMoversOfTheDay {
                interval = store.interval(for: .lastDays(1))
                periodLabel = "1D"
                periodHelp = "Change since the previous day"
                isPeriodOverridden = true
            } else {
                let period = widget.periodOverride ?? store.period
                interval = store.interval(for: period)
                periodLabel = period.shortTitle
                periodHelp = "\(period.title) (\(Fmt.interval(interval)))"
                isPeriodOverridden = widget.periodOverride != nil
            }
        } else {
            // Snapshot and document widgets: independent of the reporting period, so switching the
            // period never recomputes them.
            interval = DayInterval(start: today.advanced(by: -1), end: today)
            if kind == .earnings {
                periodLabel = widget.groupsEarningsByYear ? "Yearly" : "12M"
                periodHelp = widget.groupsEarningsByYear ? "Per calendar year" : "The last twelve calendar months"
            }
        }

        switch kind {
        case .allocation:
            let id = widget.uuid(WidgetConfigKey.taxonomy)
            query.taxonomy = file.taxonomies.first { $0.id == id } ?? file.taxonomies.first
        case .performanceChart:
            if widget.hidesBenchmarks {
                query.benchmarks = []
            } else if let id = widget.uuid(WidgetConfigKey.benchmark) {
                query.benchmarks = [id]
            } else {
                query.benchmarks = Array(file.settings.benchmarkSecurityIDs.prefix(3))
            }
        case .watchlist:
            let id = widget.uuid(WidgetConfigKey.watchlist)
            query.securities = (file.watchlists.first { $0.id == id } ?? file.watchlists.first)?.securityIDs ?? []
        case .upcomingPlans:
            query.plans = file.plans
        case .earnings:
            query.byYear = widget.groupsEarningsByYear
        default:
            break
        }
        self.query = query
    }
}

/// One dashboard widget: resolves its request, keeps its data up to date through the store's
/// analysis layer (last good value stays visible while recomputing) and draws tile + content.
struct WidgetView: View {
    @Environment(PortfolioStore.self) private var store
    let widget: Dashboard.Widget
    var mode: WidgetMode = .live

    @State private var data = Loadable<WidgetData>()
    @State private var width: CGFloat = 300

    var body: some View {
        if let kind = widget.widgetKind {
            let request = WidgetRequest(widget, kind: kind, store: store)
            let query = request.query
            WidgetChrome(widget: widget, kind: kind, request: request, mode: mode, open: openAction(kind, request)) {
                Group {
                    if let value = data.value {
                        WidgetContent(widget: widget, kind: kind, request: request, data: value, width: width,
                                      isRefreshing: data.isRefreshing, mode: mode)
                    } else {
                        Color.clear.frame(height: placeholderHeight(kind))
                    }
                }
                .loadingOverlay(data.isInitialLoad)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .analysisTask($data, id: "dashboard.widget", scope: request.scope, interval: request.interval, variant: query) { analysis in
                WidgetData.compute(query, analysis)
            }
        } else {
            UnsupportedWidgetTile(widget: widget, mode: mode)
        }
    }

    private func placeholderHeight(_ kind: WidgetKind) -> CGFloat {
        switch kind.shape {
        case .tile: 52
        case .chart: 240
        case .list: 150
        }
    }

    private func openAction(_ kind: WidgetKind, _ request: WidgetRequest) -> (() -> Void)? {
        guard mode == .live else { return nil }
        switch kind {
        case .consistency:
            return { store.present(.consistencyReport) }
        case .allocation:
            let taxonomy = request.query.taxonomy?.id
            return { if let taxonomy { store.navigate(to: .taxonomy(taxonomy)) } else { store.navigate(to: .allocation) } }
        default:
            guard let screen = kind.destination else { return nil }
            return { store.navigate(to: screen) }
        }
    }
}

// MARK: - Chrome

/// The card around a widget: title (a link to the screen behind it), help, period/scope chips, and
/// the layout handles in edit mode.
struct WidgetChrome<Content: View>: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let widget: Dashboard.Widget
    let kind: WidgetKind?
    let request: WidgetRequest?
    let mode: WidgetMode
    let open: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var isHovered = false
    @State private var isDropTarget = false
    @FocusState private var isFocused: Bool

    private var isTile: Bool { kind?.shape == .tile }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: isTile ? DS.Spacing.s : DS.Spacing.m) {
            header
            content
                .allowsHitTesting(mode == .live)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

        switch mode {
        case .preview:
            card
        case .live:
            if isTile, let open {
                // A key figure is one target: the whole tile opens the screen behind it.
                card
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(isHovered ? 0.45 : 0), lineWidth: 1)
                    }
                    .onTapGesture(perform: open)
                    .onHover { isHovered = $0 }
                    .contextMenu { menu }
            } else {
                card
                    .onHover { isHovered = $0 }
                    .contextMenu { menu }
            }
        case .editing:
            card
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isDropTarget || isFocused ? 1 : 0.35),
                                      style: StrokeStyle(lineWidth: isDropTarget || isFocused ? 2 : 1, dash: isDropTarget || isFocused ? [] : [5, 4]))
                }
                .overlay(alignment: .topTrailing) { handles.offset(x: -DS.Spacing.s, y: -DS.Spacing.m) }
                .contextMenu { menu }
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in keyPress(press) }
                .draggable(widget.id.uuidString) {
                    Label(widget.displayTitle, systemImage: kind?.symbol ?? "questionmark.square.dashed")
                        .padding(DS.Spacing.m)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)), id != widget.id else { return false }
                    withAnimation(DS.Motion.standard(reduceMotion)) { store.moveWidget(id, onto: widget.id) }
                    return true
                } isTargeted: { isDropTarget = $0 }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(widget.displayTitle), widget, \(widget.clampedSpan) columns wide")
                .accessibilityHint("Option-arrow keys move it, plus and minus resize it, Delete removes it, Return opens its settings.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.xs) {
            if let open {
                Button(action: open) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        titleText
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .opacity(isHovered ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(openHelp)
                .accessibilityHint(openHelp)
            } else {
                titleText
            }
            if let topic = kind?.helpTopic, mode != .preview {
                HelpButton(topic)
            }
            Spacer(minLength: DS.Spacing.s)
            if let request {
                chips(request)
            }
        }
        // One height for every header, with or without chips, so the values of neighbouring tiles line up.
        .frame(height: 20)
    }

    private var titleText: some View {
        Text(widget.displayTitle)
            .font(isTile ? .subheadline.weight(.medium) : .headline)
            .foregroundStyle(isTile ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var openHelp: String {
        switch kind {
        case .consistency: "Open the consistency report"
        case .some(let kind): kind.destination.map { "Open \($0.title)" } ?? ""
        case nil: ""
        }
    }

    @ViewBuilder
    private func chips(_ request: WidgetRequest) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if let scope = request.scopeLabel {
                Chip(text: scope, symbol: request.scopeSymbol, isPinned: true)
                    .help("This widget always shows \(scope), whatever the window's scope is.")
                    .layoutPriority(-1)
            }
            if let period = request.periodLabel {
                Chip(text: period, symbol: nil, isPinned: request.isPeriodOverridden)
                    .help((request.periodHelp ?? period) + (request.isPeriodOverridden ? " — fixed for this widget" : ""))
            }
        }
    }

    // MARK: Edit mode

    private var handles: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Divider().frame(height: 12)
            Button { store.resizeWidget(widget.id, to: widget.clampedSpan - 1) } label: {
                Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(widget.clampedSpan <= 1)
            .help("Narrower")
            .accessibilityLabel("Narrower")
            Text("\(widget.clampedSpan)")
                .font(.caption.weight(.semibold))
                .numeric()
                .frame(minWidth: 10)
                .help("Width in columns")
            Button { store.resizeWidget(widget.id, to: widget.clampedSpan + 1) } label: {
                Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(widget.clampedSpan >= 4)
            .help("Wider")
            .accessibilityLabel("Wider")
            Divider().frame(height: 12)
            if kind != nil {
                Button { editWidget() } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .help("Widget settings: title, period, scope")
                .accessibilityLabel("Widget settings")
            }
            Button { remove() } label: {
                Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .help("Remove widget")
            .accessibilityLabel("Remove widget")
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, DS.Spacing.xs)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Colors.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    @ViewBuilder private var menu: some View {
        if kind != nil {
            Button("Widget Settings…", systemImage: "slider.horizontal.3") { editWidget() }
        }
        Picker("Width", systemImage: "arrow.left.and.right", selection: Binding(
            get: { widget.clampedSpan }, set: { store.resizeWidget(widget.id, to: $0) })
        ) {
            ForEach(1...4, id: \.self) { Text($0 == 1 ? "1 Column" : "\($0) Columns").tag($0) }
        }
        .pickerStyle(.menu)
        Divider()
        Button("Move Earlier", systemImage: "arrow.left") { move(-1) }
        Button("Move Later", systemImage: "arrow.right") { move(1) }
        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateWidget(widget.id) }
        Divider()
        Button("Remove Widget", systemImage: "trash", role: .destructive) { remove() }
        if mode == .live {
            Divider()
            Button("Edit Dashboard", systemImage: "square.grid.2x2") { store.dashboardSession.isEditing = true }
        }
    }

    private func editWidget() {
        store.present(.custom(id: DashboardFeature.widgetSheetID, payload: ["widget": widget.id.uuidString]))
    }

    private func remove() {
        withAnimation(DS.Motion.standard(reduceMotion)) { store.removeWidget(widget.id) }
    }

    private func move(_ offset: Int) {
        withAnimation(DS.Motion.standard(reduceMotion)) { store.moveWidget(widget.id, by: offset) }
    }

    private func keyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .delete, .deleteForward:
            remove()
        case .leftArrow where press.modifiers.contains(.option), .upArrow where press.modifiers.contains(.option):
            move(-1)
        case .rightArrow where press.modifiers.contains(.option), .downArrow where press.modifiers.contains(.option):
            move(1)
        case .return:
            guard kind != nil else { return .ignored }
            editWidget()
        default:
            switch press.characters {
            case "+", "=": store.resizeWidget(widget.id, to: widget.clampedSpan + 1)
            case "-": store.resizeWidget(widget.id, to: widget.clampedSpan - 1)
            default: return .ignored
            }
        }
        return .handled
    }
}

/// A small header label for the period or scope a widget shows. Pinned = overridden for this
/// widget (drawn on a capsule with a pin so it reads as "fixed").
private struct Chip: View {
    let text: String
    let symbol: String?
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            } else if isPinned {
                Image(systemName: "pin.fill").font(.system(size: 7)).accessibilityLabel("Fixed")
            }
            Text(text).numeric().lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, isPinned ? 6 : 0)
        .padding(.vertical, isPinned ? 2 : 0)
        .background {
            if isPinned { Capsule().fill(Color.primary.opacity(0.07)) }
        }
    }
}

/// A widget whose kind this version of the app does not know. It stays in the file untouched.
struct UnsupportedWidgetTile: View {
    let widget: Dashboard.Widget
    let mode: WidgetMode

    var body: some View {
        WidgetChrome(widget: widget, kind: nil, request: nil, mode: mode, open: nil) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label("Unsupported widget", systemImage: "questionmark.square.dashed")
                    .foregroundStyle(.secondary)
                Text("“\(widget.kind)” needs a newer version of Kontor. It is kept in your file.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }
}
