import SwiftUI
import KontorModel
import KontorUI

/// The landing screen: a user-configurable grid of widgets stored in `PortfolioFile.dashboards`.
///
/// Every widget derives its numbers through the store's analysis layer (off the main actor, cached
/// per scope × interval, last good value kept while recomputing), follows the window's period and
/// scope unless its configuration overrides them, and deep-links to the screen behind it.
///
/// **Launch state** (`--state key=value`, read once on appear):
///
/// | key | values | effect |
/// |---|---|---|
/// | `edit` | `1` | edit mode (layout handles, dashboard bar) |
/// | `gallery` | `1` | presents the widget gallery sheet (same as `--sheet custom:dashboard.gallery`) |
/// | `category` | `overview` `performance` `risk` `positions` `income` `activity` | gallery category; with `dashboard=catalog`: only that category's widgets |
/// | `configure` | widget index (0-based) or UUID | presents that widget's settings sheet (same as `--sheet custom:dashboard.widget?widget=<index or uuid>`) |
/// | `dashboard` | dashboard name, index (0-based) or `catalog` | selects a dashboard; `catalog` shows one of every widget kind (never saved) |
/// | `hover` | `1` | pins the chart tooltips so they show without a pointer |
///
/// Period, scope and inspector come from `--period`, `--scope` and `--inspector`.
public struct DashboardScreen: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("dashboard.selected") private var storedSelection = ""
    @State private var nameDraft = ""
    @State private var didAppear = false

    public init() {}

    public var body: some View {
        let session = store.dashboardSession
        let dashboard = session.current(in: store.file)
        // A file without transactions has nothing to chart: show how to get started instead.
        let showsOnboarding = store.file.transactions.isEmpty && !session.isEditing && !session.showsCatalog
        Group {
            if showsOnboarding {
                OnboardingView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        if session.isEditing {
                            editBar(dashboard)
                        } else {
                            header(dashboard)
                        }
                        if dashboard.widgets.isEmpty {
                            emptyDashboard
                        } else {
                            grid(dashboard, isEditing: session.isEditing)
                        }
                    }
                    .screenPadding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbar(dashboard) }
        .onAppear { appear() }
        .onChange(of: session.selectedID) { _, id in storedSelection = id?.uuidString ?? "" }
        .onChange(of: dashboard.id, initial: true) { _, _ in nameDraft = dashboard.name }
        .onChange(of: dashboard.name) { _, name in nameDraft = name }
        .onExitCommand { if session.isEditing { session.isEditing = false } }
    }

    // MARK: Grid

    private func grid(_ dashboard: Dashboard, isEditing: Bool) -> some View {
        DashboardGridLayout {
            ForEach(dashboard.widgets) { widget in
                WidgetView(widget: widget, mode: isEditing ? .editing : .live)
                    .dashboardSpan(widget.clampedSpan)
            }
        }
        .animation(DS.Motion.standard(reduceMotion), value: dashboard.widgets.map(\.id))
        .animation(DS.Motion.standard(reduceMotion), value: dashboard.widgets.map(\.span))
    }

    private var emptyDashboard: some View {
        EmptyState("This Dashboard Is Empty", symbol: "square.grid.2x2",
                   message: "Add widgets from the gallery, or start from the default layout.") {
            Button("Add Widget…") { presentGallery() }.buttonStyle(.borderedProminent)
            Button("Use Default Layout") { store.resetDashboardToDefault() }
        }
        .frame(minHeight: 360)
    }

    // MARK: Header

    private func header(_ dashboard: Dashboard) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            if store.file.dashboards.count > 1, !store.dashboardSession.showsCatalog {
                Picker("Dashboard", selection: Binding(get: { dashboard.id }, set: { store.dashboardSession.selectedID = $0 })) {
                    ForEach(store.file.dashboards) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Text(dashboard.name.isEmpty ? "Dashboard" : dashboard.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: DS.Spacing.m)
            HStack(spacing: DS.Spacing.xs) {
                Text("\(store.scopeTitle) · \(Fmt.interval(store.periodInterval))")
                    .numeric()
                HelpButton(.reportingPeriod)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func editBar(_ dashboard: Dashboard) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            TextField("Dashboard Name", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { store.renameDashboard(nameDraft) }
                .disabled(store.dashboardSession.showsCatalog)
                .accessibilityLabel("Dashboard name")
            // The hint gives way first when the window is narrow.
            ViewThatFits(in: .horizontal) {
                Text("Drag widgets to reorder · − + to resize").fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer(minLength: DS.Spacing.s)
            Button("Add Widget…", systemImage: "plus") { presentGallery() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                .help("Add a widget from the gallery (⌥⇧⌘N)")
            Button("Reset to Default") { withAnimation(DS.Motion.standard(reduceMotion)) { store.resetDashboardToDefault() } }
                .help("Replace this dashboard's widgets with the default layout (undoable)")
            Button("Done") { finishEditing() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ dashboard: Dashboard) -> some ToolbarContent {
        ToolbarItem { ScopePicker() }
        ToolbarItem {
            Menu {
                if !store.file.dashboards.isEmpty {
                    Section("Dashboards") {
                        ForEach(store.file.dashboards) { item in
                            Toggle(item.name.isEmpty ? "Untitled" : item.name, isOn: Binding(
                                get: { item.id == dashboard.id },
                                set: { if $0 { store.dashboardSession.showsCatalog = false; store.dashboardSession.selectedID = item.id } }))
                        }
                    }
                }
                Section {
                    Button("New Dashboard", systemImage: "plus") { store.newDashboard() }
                    Button("Duplicate “\(dashboard.name)”", systemImage: "plus.square.on.square") { store.duplicateDashboard() }
                    Button("Delete “\(dashboard.name)”", systemImage: "trash", role: .destructive) { store.deleteCurrentDashboard() }
                        .disabled(!store.file.dashboards.contains { $0.id == dashboard.id })
                }
                Section {
                    Button(store.dashboardSession.isEditing ? "Finish Editing" : "Edit Dashboard", systemImage: "square.and.pencil") { toggleEditing() }
                    Button("Add Widget…", systemImage: "rectangle.badge.plus") { presentGallery() }
                    Button("Reset to Default", systemImage: "arrow.counterclockwise") { store.resetDashboardToDefault() }
                }
            } label: {
                Label("Dashboard", systemImage: "rectangle.3.group")
            }
            .help("Dashboards: switch, add, duplicate, edit")
        }
        ToolbarItem {
            Button(store.dashboardSession.isEditing ? "Done" : "Edit", systemImage: store.dashboardSession.isEditing ? "checkmark" : "square.and.pencil") {
                toggleEditing()
            }
            .keyboardShortcut("e", modifiers: .command)
            .help(store.dashboardSession.isEditing ? "Finish editing the dashboard (⌘E)" : "Edit the dashboard: add, remove, move and resize widgets (⌘E)")
        }
    }

    // MARK: Actions

    private func toggleEditing() {
        if store.dashboardSession.isEditing { finishEditing() } else { store.dashboardSession.isEditing = true }
    }

    private func finishEditing() {
        store.renameDashboard(nameDraft)
        store.dashboardSession.isEditing = false
    }

    private func presentGallery() {
        store.present(.custom(id: DashboardFeature.gallerySheetID))
    }

    private func appear() {
        let session = store.dashboardSession
        guard !didAppear else { return }
        didAppear = true
        if session.selectedID == nil, let id = UUID(uuidString: storedSelection) { session.selectedID = id }

        // Launch state (--state key=value)
        if let value = store.launchValue("dashboard") {
            if value == "catalog" {
                session.showsCatalog = true
                session.catalogCategory = store.launchValue("category").flatMap { raw in
                    WidgetKind.Category.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
                }
            } else if let index = Int(value), store.file.dashboards.indices.contains(index) {
                session.selectedID = store.file.dashboards[index].id
            } else if let match = store.file.dashboards.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
                session.selectedID = match.id
            }
        }
        if store.launchValue("edit") == "1" { session.isEditing = true }
        if store.launchValue("hover") == "1" { session.pinsHover = true }
        if store.launchValue("gallery") == "1" {
            var payload: [String: String] = [:]
            if let category = store.launchValue("category") { payload["category"] = category }
            store.present(.custom(id: DashboardFeature.gallerySheetID, payload: payload))
        }
        if let widget = store.launchValue("configure") {
            store.present(.custom(id: DashboardFeature.widgetSheetID, payload: ["widget": widget]))
        }
    }
}

// MARK: - Onboarding (file without transactions)

/// What a new portfolio shows instead of a dashboard full of dashes: the next step, spelled out.
struct OnboardingView: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        let file = store.file
        let checklist = WidgetData.Checklist(hasAccount: !file.accounts.isEmpty, hasSecurity: !file.securities.isEmpty,
                                             hasTransaction: false, hasImport: false)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(file.name.isEmpty ? "Welcome to Your Portfolio" : "Welcome to \(file.name)")
                        .font(.largeTitle.weight(.semibold))
                    Text("Your dashboard — net worth, returns, allocation, dividends — is calculated from your transactions. A few steps and it comes to life.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Card("Getting Started", symbol: "checklist") {
                    GettingStartedList(checklist: checklist)
                } accessory: {
                    Text("\(checklist.doneCount) of 4 done").font(.callout).foregroundStyle(.secondary).numeric()
                }
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    Image(systemName: "lightbulb").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Kontor measures returns in two ways — time-weighted (how well your investments did) and money-weighted (how well your money did).")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DS.Spacing.xs) {
                            Text("What is the difference?")
                            HelpButton(.ttwrorVersusIRR)
                            Spacer()
                            Button("Customize Dashboard…") { store.dashboardSession.isEditing = true }
                                .buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(DS.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
    }
}
