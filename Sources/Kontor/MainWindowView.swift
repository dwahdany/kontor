import SwiftUI
import KontorModel
import KontorUI

/// The content of a portfolio window: sidebar, the selected feature screen, inspector, toolbar and
/// the floating layers (command palette, toasts, sheets). Used by both the document scene and the
/// headless screenshot mode, so what reviewers capture is exactly what users see.
struct MainWindowView: View {
    @Bindable var store: PortfolioStore
    let registry: FeatureRegistry

    @AppStorage(AppPreferences.Key.gainStyle) private var gainStyleRaw = GainStyle.regionDefault.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 300)
        } detail: {
            registry.content(for: store.route.screen)
                .id(store.route.screen)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSubtitle(store.route.screen.title)
                .inspector(isPresented: $store.isInspectorPresented) {
                    InspectorView(registry: registry)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
                }
                .toolbar { MainToolbar(store: store) }
        }
        .overlay(alignment: .bottom) { ToastOverlay() }
        .overlay { CommandPaletteLayer(registry: registry) }
        .sheet(item: sheetBinding) { request in
            SheetHost(request: request, registry: registry)
                .environment(store)
                .environment(\.gainStyle, gainStyle)
        }
        .alert(
            store.confirmation?.title ?? "",
            isPresented: Binding(get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }),
            presenting: store.confirmation
        ) { request in
            Button(request.confirmTitle, role: request.isDestructive ? .destructive : nil) { request.action() }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .environment(store)
        .environment(\.featureRegistry, registry)
        .environment(\.gainStyle, gainStyle)
        .focusedSceneValue(\.portfolioStore, store)
        .animation(DS.Motion.standard(reduceMotion), value: store.isCommandPalettePresented)
    }

    private var gainStyle: GainStyle { GainStyle(rawValue: gainStyleRaw) ?? .greenUp }

    private var sheetBinding: Binding<SheetRequest?> {
        Binding(get: { store.sheet }, set: { if $0 == nil { store.dismissSheet() } })
    }
}

extension FocusedValues {
    /// The store of the focused portfolio window — how menu commands reach the active document.
    @Entry var portfolioStore: PortfolioStore? = nil
}

/// The unified window toolbar: history, reporting period, quotes, "+", search.
struct MainToolbar: ToolbarContent {
    @Bindable var store: PortfolioStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .help("Back (⌘[)")
            Button {
                store.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .help("Forward (⌘])")
        }

        ToolbarItem(placement: .primaryAction) {
            PeriodPicker()
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            QuoteUpdateButton(store: store)
            Menu {
                Button("New Transaction", systemImage: "list.bullet.rectangle") { store.present(.newTransaction) }
                Button("New Security", systemImage: "building.columns") { store.present(.newSecurity) }
                Button("New Account", systemImage: "creditcard") { store.present(.newAccount) }
                Button("New Depot", systemImage: "briefcase") { store.present(.newDepot) }
                Button("New Plan", systemImage: "calendar.badge.clock") { store.present(.newPlan) }
                Divider()
                Button("Import…", systemImage: "square.and.arrow.down") { store.services.chooseImportFile?(store) }
            } label: {
                Label("New Transaction", systemImage: "plus")
            } primaryAction: {
                store.present(.newTransaction)
            }
            .help("New Transaction (⇧⌘N) — hold for more")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isCommandPalettePresented = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search and commands (⌘K)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// "Update Quotes" with inline progress while a background activity runs.
private struct QuoteUpdateButton: View {
    let store: PortfolioStore

    var body: some View {
        Button {
            ShellContext.shared.updateQuotes(store)
        } label: {
            if let activity = store.activity {
                Label {
                    Text(activity.statusText)
                } icon: {
                    if let fraction = activity.fraction {
                        ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Label("Update Quotes", systemImage: "arrow.trianglehead.2.clockwise")
            }
        }
        .disabled(store.activity != nil)
        .help(store.activity?.statusText ?? "Update Quotes (⌘R)")
    }
}
