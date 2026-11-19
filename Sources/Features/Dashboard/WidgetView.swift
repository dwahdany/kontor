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
    /// The period the widget is fixed to (nil: it follows the window, or has no period).
    var pinnedPeriod: ReportingPeriod?
    /// Set when the widget overrides the window's scope.
    var scopeLabel: String?
    var scopeSymbol = "square.stack.3d.up"
    /// What the numbers cover: "Whole Portfolio", "Main Depot", … (the widget's own scope or the window's).
    var scopeTitle: String
    /// True when the widget lists the whole document although the window is narrowed to a part.
    var ignoresWindowScope = false
    /// The day a statement widget (net worth, allocation, holdings, cash, watchlist prices) is
    /// valued on — set only when that is **not today**, i.e. when the period ends in the past.
    var asOf: Day?
    /// Configured references that no longer exist (deleted depot, taxonomy, benchmark, watchlist).
    var warnings: [String] = []

    var isPartialScope: Bool { scope != .portfolio }

    /// How many days back "since the previous day" looks for the latest quote of a position
    /// (weekends, holidays, quotes that have not arrived yet).
    static let dayLookback = 7

    @MainActor
    init(_ widget: Dashboard.Widget, kind: WidgetKind, store: PortfolioStore) {
        self.kind = kind
        let today = store.today
        let file = store.file
        var query = WidgetQuery(kind: kind, today: today)
        if kind.usesCount { query.count = widget.count }
        warnings = widget.danglingReferences(in: file)

        // Scope
        scopeTitle = "Whole Portfolio"
        if kind.usesScope {
            if let override = widget.scopeOverride, let resolved = override.resolve(in: file) {
                scope = resolved
                scopeLabel = override.title(in: file)
                scopeSymbol = override.symbol
                scopeTitle = override.title(in: file)
            } else {
                scope = store.scope
                scopeTitle = store.scopeTitle
            }
        } else {
            scope = .portfolio
            ignoresWindowScope = kind.alwaysShowsWholePortfolio && !store.isWholePortfolioScope
        }

        // Period
        let dayInterval = DayInterval(start: today.advanced(by: -1), end: today)
        if kind.usesPeriod {
            if kind == .topMovers, widget.showsMoversOfTheDay {
                // The engine works out each position's latest quoted day within this window.
                interval = DayInterval(start: today.advanced(by: -Self.dayLookback), end: today)
                query.dayMode = true
                periodLabel = "1D"
                periodHelp = "Change of every position on its latest quoted day, against the day before"
                isPeriodOverridden = true
            } else {
                let period = widget.periodOverride ?? store.period
                interval = store.interval(for: period)
                periodLabel = period.shortTitle
                periodHelp = "\(period.title) (\(Fmt.interval(interval)))"
                isPeriodOverridden = widget.periodOverride != nil
                pinnedPeriod = widget.periodOverride
                // Net worth and watchlist prices are those of the period's last day — say so when that is not today.
                if kind == .netWorth || kind == .watchlist, interval.end < today { asOf = interval.end }
            }
        } else if kind.isSnapshot {
            // Statements are valued on the last day of the window's period, so they agree with the
            // net worth next to them. Every period that runs until today shares one interval, so
            // switching between such periods never recomputes them.
            let end = min(store.periodInterval.end, today)
            interval = DayInterval(start: end.advanced(by: -1), end: end)
            if end < today { asOf = end }
        } else if kind == .monthlyReturns {
            // Whole calendar years since the first transaction; `count` picks how many.
            interval = store.interval(for: .allTime)
        } else {
            // Document widgets: independent of the reporting period, so switching it never recomputes them.
            interval = dayInterval
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

    /// Day mode of Top Movers: once the data is there, the chip names the day the changes are from.
    func labelled(with data: WidgetData?, today: Day) -> WidgetRequest {
        guard query.dayMode, case .movers(let movers)? = data, let first = movers.days.first else { return self }
        var copy = self
        if movers.days.count == 1 {
            copy.periodLabel = first == today ? "Today" : Fmt.relativeDay(first, today: today)
            copy.periodHelp = "Change on \(Fmt.day(first, style: .medium)) against the day before"
        } else if let last = movers.days.last {
            copy.periodHelp = "Change of every position on its latest quoted day (\(Fmt.day(first, style: .dayMonth)) – \(Fmt.day(last, style: .dayMonth))), against the day before"
        }
        return copy
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
            let resolved = WidgetRequest(widget, kind: kind, store: store)
            let query = resolved.query
            let request = resolved.labelled(with: data.value, today: store.today)
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
                .accessibilityLabel("\(widget.displayTitle(isPartialScope: request?.isPartialScope ?? false)), widget, \(widget.clampedSpan) columns wide")
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
        Text(widget.displayTitle(isPartialScope: request?.isPartialScope ?? false))
            .font(isTile ? .subheadline.weight(.medium) : .headline)
            .foregroundStyle(isTile ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var openHelp: String {
        switch kind {
        case .consistency:
            return "Open the consistency report"
        case .some(let kind):
            guard let destination = kind.destination else { return "" }
            // The screen behind the tile shows the window's period and scope. A tile fixed to its
            // own says so, so the number found there is not mistaken for the tile's.
            var differences: [String] = []
            if let pinned = request?.pinnedPeriod, pinned != store.period {
                differences.append("period (\(store.period.shortTitle) instead of this widget's \(pinned.shortTitle))")
            }
            if let scope = request?.scopeLabel, request?.scope != store.scope {
                differences.append("scope (\(store.scopeTitle) instead of \(scope))")
            }
            if differences.isEmpty { return "Open \(destination.title)" }
            return "Open \(destination.title) — it shows the window's \(differences.joined(separator: " and "))"
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private func chips(_ request: WidgetRequest) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if !request.warnings.isEmpty {
                // A reference of this widget is gone (deleted depot, taxonomy, benchmark …): say so
                // instead of silently showing something else. The settings sheet repairs it.
                Button { editWidget() } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.warning)
                }
                .buttonStyle(.plain)
                .disabled(mode == .preview)
                .help(request.warnings.joined(separator: "\n") + (mode == .preview ? "" : "\nClick to review the widget's settings."))
                .accessibilityLabel("Warning: " + request.warnings.joined(separator: " "))
            }
            if let scope = request.scopeLabel {
                Chip(text: scope, symbol: request.scopeSymbol, isPinned: true)
                    .help("This widget always shows \(scope), whatever the window's scope is.")
                    .layoutPriority(-1)
            } else if request.ignoresWindowScope {
                Chip(text: "All", symbol: "square.stack.3d.up", isPinned: false)
                    .help("This widget always covers the whole portfolio — it does not follow the window's scope (\(store.scopeTitle)).")
                    .accessibilityLabel("Whole portfolio")
            }
            if let day = request.asOf {
                Chip(text: Fmt.day(day, style: .medium), symbol: "calendar", isPinned: false)
                    .help("Valued on \(Fmt.day(day, style: .long)), the last day of the period — not today.")
                    .accessibilityLabel("As of \(Fmt.day(day, style: .long))")
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
        let position = store.currentDashboard.widgets.firstIndex { $0.id == widget.id }
        Button("Move Earlier", systemImage: "arrow.left") { move(-1) }
            .disabled(position == nil || position == 0)
        Button("Move Later", systemImage: "arrow.right") { move(1) }
            .disabled(position == nil || position == store.currentDashboard.widgets.count - 1)
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
