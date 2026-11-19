import SwiftUI
import KontorUI

// MARK: - Scaled live preview

/// A real widget, computed from the open portfolio, drawn at its natural size and scaled to fit —
/// used by the gallery and by the widget editor. Inert (no clicks, no hover).
struct WidgetPreview: View {
    let widget: Dashboard.Widget
    var maxSize = CGSize(width: 300, height: 150)

    var body: some View {
        let kind = widget.widgetKind
        let natural = CGSize(width: widget.clampedSpan >= 2 ? 520 : 264, height: kind?.nominalHeight ?? 112)
        let scale = min(1, maxSize.width / natural.width, maxSize.height / natural.height)
        WidgetView(widget: widget, mode: .preview)
            .frame(width: natural.width, height: natural.height, alignment: .top)
            .scaleEffect(scale)
            .frame(width: natural.width * scale, height: natural.height * scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Gallery

/// "Add Widget": the catalogue with live previews. Adding keeps the sheet open, so several widgets
/// can be added in one go; each addition is its own undo step.
struct WidgetGallerySheet: View {
    @Environment(PortfolioStore.self) private var store
    let payload: [String: String]

    @State private var category: WidgetKind.Category?
    @State private var search = ""
    @State private var addedCount = 0
    @FocusState private var searchFocused: Bool

    private var kinds: [WidgetKind] {
        let filter = QuickFilter(search)
        return WidgetKind.allCases.filter { kind in
            (category == nil || kind.category == category) && filter.matches(kind.title, kind.summary, kind.category.rawValue)
        }
    }

    var body: some View {
        let dashboard = store.currentDashboard
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Add Widget").font(.title2.weight(.semibold))
                    Text("Previews show your own data. Widgets are added to “\(dashboard.name)”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search widgets", text: $search, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($searchFocused)
            }
            .padding(DS.Spacing.l)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                ScrollView {
                    if kinds.isEmpty {
                        EmptyState("No Matching Widgets", symbol: "magnifyingglass", message: "Try another search term or category.")
                            .frame(minHeight: 300)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top),
                                            GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top)], spacing: DS.Spacing.l) {
                            ForEach(kinds) { kind in
                                GalleryCard(kind: kind, count: dashboard.widgets.filter { $0.kind == kind.rawValue }.count) {
                                    store.addWidget(kind)
                                    addedCount += 1
                                }
                            }
                        }
                        .padding(DS.Spacing.l)
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            HStack {
                Text(addedCount == 0 ? "Each widget can later get its own title, period and scope."
                     : "\(Fmt.integer(addedCount)) \(addedCount == 1 ? "widget" : "widgets") added — arrange them in edit mode.")
                    .font(.callout).foregroundStyle(.secondary).numeric()
                Spacer()
                Button("Done") {
                    if addedCount > 0 { store.dashboardSession.isEditing = true }
                    store.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 920, height: 660)
        .onAppear {
            if let raw = payload["category"] {
                category = WidgetKind.Category.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
            }
        }
        .onExitCommand { store.dismissSheet() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            categoryRow(nil, title: "All Widgets", symbol: "square.grid.2x2", count: WidgetKind.allCases.count)
            ForEach(WidgetKind.Category.allCases) { item in
                categoryRow(item, title: item.rawValue, symbol: item.symbol, count: WidgetKind.allCases.filter { $0.category == item }.count)
            }
            Spacer()
        }
        .padding(DS.Spacing.s)
        .frame(width: 180)
    }

    private func categoryRow(_ value: WidgetKind.Category?, title: String, symbol: String, count: Int) -> some View {
        let isSelected = category == value
        return Button { category = value } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                Text(title)
                Spacer()
                Text(Fmt.integer(count)).numeric().foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GalleryCard: View {
    let kind: WidgetKind
    let count: Int
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            WidgetPreview(widget: Dashboard.Widget(id: Self.previewID, kind: kind.rawValue, span: min(kind.defaultSpan, 2)),
                          maxSize: CGSize(width: 310, height: 150))
                .frame(maxWidth: .infinity)
                .frame(height: 174)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: kind.symbol).foregroundStyle(.secondary).imageScale(.small)
                        Text(kind.title).font(.headline)
                        if count > 0 {
                            Label(count == 1 ? "Added" : "\(count)×", systemImage: "checkmark")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .accessibilityLabel("\(count) on this dashboard")
                        }
                    }
                    Text(kind.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Spacing.s)
                Button("Add", systemImage: "plus", action: add)
                    .labelStyle(.titleAndIcon)
                    .help("Add “\(kind.title)” to the dashboard")
            }
        }
    }

    /// Previews of one kind share an id so SwiftUI keeps their state while filtering.
    private static let previewID = UUID(uuidString: "D0A5B0A2-0000-4000-8000-00000000F001")!
}

// MARK: - Widget settings

/// Title, width, period/scope overrides and the kind's own options, with a live preview. Applied
/// as one undo step on "Done".
struct WidgetEditorSheet: View {
    @Environment(PortfolioStore.self) private var store
    let payload: [String: String]
    @State private var draft: Dashboard.Widget?

    var body: some View {
        Group {
            if let draft, let kind = draft.widgetKind {
                editor(Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }), kind: kind)
            } else {
                EmptyState("Widget Not Found", symbol: "questionmark.square.dashed", message: "It may have been removed.") {
                    Button("Close") { store.dismissSheet() }.keyboardShortcut(.defaultAction)
                }
                .frame(width: 420, height: 240)
            }
        }
        // The draft starts from what the tile effectively shows: references to things that were
        // deleted are dropped, so every picker has a real selection and "Done" cleans the file.
        .onAppear { if draft == nil { draft = resolve()?.normalized(in: store.file) } }
        .onExitCommand { store.dismissSheet() }
    }

    private func resolve() -> Dashboard.Widget? {
        let widgets = store.currentDashboard.widgets
        guard let reference = payload["widget"] else { return widgets.first }
        if let id = UUID(uuidString: reference) { return widgets.first { $0.id == id } }
        if let index = Int(reference), widgets.indices.contains(index) { return widgets[index] }
        return reference == "first" ? widgets.first : nil
    }

    private func editor(_ widget: Binding<Dashboard.Widget>, kind: WidgetKind) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Form {
                    Section {
                        TextField("Title", text: widget.title, prompt: Text(kind.title))
                        Picker("Width in columns", selection: widget.span) {
                            ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Label(kind.title, systemImage: kind.symbol)
                    } footer: {
                        Text(kind.summary)
                    }
                    if kind.usesPeriod || kind.usesScope {
                        Section {
                            if kind.usesPeriod, !(kind == .topMovers && widget.wrappedValue.showsMoversOfTheDay) {
                                overrideRow("Period", maxControlWidth: nil, isOn: Binding(
                                    get: { widget.wrappedValue.periodOverride != nil },
                                    set: { widget.wrappedValue.periodOverride = $0 ? store.period : nil })
                                ) {
                                    PeriodPicker(selection: Binding(
                                        get: { widget.wrappedValue.periodOverride ?? store.period },
                                        set: { widget.wrappedValue.periodOverride = $0 }))
                                }
                            }
                            if kind.usesScope {
                                // Long depot / account names truncate inside the row instead of pushing it apart.
                                overrideRow("Scope", maxControlWidth: 200, isOn: Binding(
                                    get: { widget.wrappedValue.scopeOverride != nil },
                                    set: { widget.wrappedValue.scopeOverride = $0 ? store.scopeSelection : nil })
                                ) {
                                    ScopePicker(selection: Binding(
                                        get: { widget.wrappedValue.scopeOverride ?? store.scopeSelection },
                                        set: { widget.wrappedValue.scopeOverride = $0 }))
                                }
                            }
                        } header: {
                            HStack(spacing: DS.Spacing.xs) {
                                Text("Period and Scope")
                                HelpButton(kind.usesPeriod ? .reportingPeriod : .scope)
                            }
                        } footer: {
                            Text("“Window” follows the period and scope chosen in the toolbar. A fixed value stays put — for example an all-time return next to year-to-date figures.")
                        }
                    }
                    options(widget, kind: kind)
                }
                .formStyle(.grouped)
                .frame(width: 440)
                Divider()
                VStack(spacing: DS.Spacing.m) {
                    Text("Preview").font(.kontorCaption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    WidgetPreview(widget: widget.wrappedValue, maxSize: CGSize(width: 330, height: 330))
                    Spacer(minLength: 0)
                }
                .padding(DS.Spacing.l)
                .frame(width: 362)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            HStack {
                Button("Remove Widget", role: .destructive) {
                    store.removeWidget(widget.wrappedValue.id)
                    store.dismissSheet()
                }
                Spacer()
                Button("Cancel") { store.dismissSheet() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    var result = widget.wrappedValue
                    result.title = result.title.trimmingCharacters(in: .whitespaces)
                    store.updateWidget(result)
                    store.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 803, height: 600)
    }

    private func overrideRow<Control: View>(_ title: String, maxControlWidth: CGFloat?, isOn: Binding<Bool>,
                                            @ViewBuilder control: () -> Control) -> some View {
        LabeledContent(title) {
            HStack(spacing: DS.Spacing.s) {
                if isOn.wrappedValue {
                    if let maxControlWidth {
                        control().lineLimit(1).truncationMode(.middle).frame(maxWidth: maxControlWidth, alignment: .trailing)
                    } else {
                        control().fixedSize()
                    }
                }
                Picker(title, selection: isOn) {
                    Text("Window").tag(false)
                    Text("Fixed").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func options(_ widget: Binding<Dashboard.Widget>, kind: WidgetKind) -> some View {
        let file = store.file
        switch kind {
        case .allocation:
            Section("Options") {
                if file.taxonomies.isEmpty {
                    Text("Create a taxonomy on the Allocation screen first.").foregroundStyle(.secondary)
                } else {
                    Picker("Taxonomy", selection: config(widget, WidgetConfigKey.taxonomy, default: file.taxonomies[0].id.uuidString)) {
                        ForEach(file.taxonomies) { Text($0.name.isEmpty ? "Untitled Taxonomy" : $0.name).tag($0.id.uuidString) }
                    }
                }
            }
        case .performanceChart:
            Section("Options") {
                Picker(selection: config(widget, WidgetConfigKey.benchmark, default: "")) {
                    Text(file.settings.benchmarkSecurityIDs.isEmpty ? "Portfolio benchmarks (none set)" : "Portfolio benchmarks").tag("")
                    Text("None").tag("none")
                    Divider()
                    ForEach(file.securities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { security in
                        Text(security.name).tag(security.id.uuidString)
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) { Text("Compare with"); HelpButton(.benchmark) }
                }
            }
        case .topMovers:
            Section("Options") {
                Picker("Movement", selection: config(widget, WidgetConfigKey.mode, default: "period")) {
                    Text("Over the period").tag("period")
                    Text("Since the previous day").tag("day")
                }
                countStepper(widget, kind: kind)
            }
        case .earnings:
            Section("Options") {
                Picker("Bars", selection: config(widget, WidgetConfigKey.grouping, default: "month")) {
                    Text("Last 12 months").tag("month")
                    Text("Calendar years").tag("year")
                }
            }
        case .watchlist:
            Section("Options") {
                if file.watchlists.isEmpty {
                    Text("Create a watchlist on the Securities screen first.").foregroundStyle(.secondary)
                } else {
                    Picker("Watchlist", selection: config(widget, WidgetConfigKey.watchlist, default: file.watchlists[0].id.uuidString)) {
                        ForEach(file.watchlists) { Text($0.name.isEmpty ? "Untitled Watchlist" : $0.name).tag($0.id.uuidString) }
                    }
                }
            }
        default:
            if kind.usesCount {
                Section("Options") { countStepper(widget, kind: kind) }
            }
        }
    }

    private func countStepper(_ widget: Binding<Dashboard.Widget>, kind: WidgetKind) -> some View {
        Stepper(value: widget.count, in: kind.countRange) {
            LabeledContent(kind.countLabel) { Text(Fmt.integer(widget.wrappedValue.count)).numeric() }
        }
    }

    /// A config value as a picker selection; choosing the default removes the key.
    private func config(_ widget: Binding<Dashboard.Widget>, _ key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { widget.wrappedValue.config[key]?.lowercased() == defaultValue.lowercased() ? defaultValue : widget.wrappedValue.config[key] ?? defaultValue },
            set: { widget.wrappedValue.config[key] = $0 == defaultValue && key != WidgetConfigKey.taxonomy && key != WidgetConfigKey.watchlist ? nil : $0 })
    }
}

// MARK: - Inspector

/// The dashboard's layout as a list: reorder by dragging rows (or with the keyboard), resize, remove.
struct DashboardInspector: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        let dashboard = store.currentDashboard
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(dashboard.name.isEmpty ? "Dashboard" : dashboard.name).font(.headline)
                Text("\(Fmt.integer(dashboard.widgets.count)) \(dashboard.widgets.count == 1 ? "widget" : "widgets") · drag to reorder")
                    .font(.caption).foregroundStyle(.secondary).numeric()
            }
            .padding(DS.Spacing.m)
            List {
                ForEach(dashboard.widgets) { widget in
                    HStack(spacing: DS.Spacing.s) {
                        Image(systemName: widget.widgetKind?.symbol ?? "questionmark.square.dashed")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(widget.displayTitle).lineLimit(1)
                        Spacer(minLength: DS.Spacing.xs)
                        Menu {
                            Picker("Width", selection: Binding(get: { widget.clampedSpan }, set: { store.resizeWidget(widget.id, to: $0) })) {
                                ForEach(1...4, id: \.self) { Text($0 == 1 ? "1 Column" : "\($0) Columns").tag($0) }
                            }
                            .pickerStyle(.inline)
                            Divider()
                            if widget.widgetKind != nil {
                                Button("Widget Settings…") {
                                    store.present(.custom(id: DashboardFeature.widgetSheetID, payload: ["widget": widget.id.uuidString]))
                                }
                            }
                            Button("Remove Widget", role: .destructive) { store.removeWidget(widget.id) }
                        } label: {
                            Text("\(widget.clampedSpan)×").numeric().foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Width and more")
                    }
                }
                .onMove { source, destination in
                    store.editDashboard("Move Widget") { $0.widgets.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    store.editDashboard("Remove Widget") { $0.widgets.remove(atOffsets: offsets) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Add Widget…", systemImage: "plus") { store.present(.custom(id: DashboardFeature.gallerySheetID)) }
                Spacer()
                Button(store.dashboardSession.isEditing ? "Done" : "Edit") { store.toggleDashboardEditing() }
            }
            .padding(DS.Spacing.m)
        }
    }
}
