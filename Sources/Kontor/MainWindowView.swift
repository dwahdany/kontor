import SwiftUI
import AppKit
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
                // Files dropped anywhere on the screen area: a Kontor portfolio opens as a document, anything
                // else (Portfolio Performance XML, CSV) goes to the importer. Screens with their own drop
                // targets (Import, Allocation, Dashboard) take precedence inside their areas.
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty else { return false }
                    for url in files {
                        if url.pathExtension.lowercased() == PortfolioFile.fileExtension {
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                                if let error { NSApp.presentError(error) }
                            }
                        } else {
                            store.present(.importFile(url))
                        }
                    }
                    return true
                }
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
            PeriodPicker(store: store)
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

/// "Update Quotes": starts an update (⌘R), shows inline progress and turns into "Cancel" while one
/// runs, and carries the results popover (failures per security) of the last update.
private struct QuoteUpdateButton: View {
    @Bindable var store: PortfolioStore

    var body: some View {
        Button {
            if store.isUpdatingQuotes {
                store.cancelQuoteUpdate()
            } else if NSEvent.modifierFlags.contains(.option), store.lastQuoteUpdate != nil {
                store.isQuoteReportPresented = true
            } else {
                store.updateQuotes()
            }
        } label: {
            if store.isUpdatingQuotes, let activity = store.activity {
                Label {
                    Text(activity.statusText)
                } icon: {
                    if let fraction = activity.fraction {
                        ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else if store.lastQuoteUpdate?.hasFailures == true {
                Label("Update Quotes", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
            } else {
                Label("Update Quotes", systemImage: "arrow.trianglehead.2.clockwise")
            }
        }
        .help(help)
        .accessibilityLabel(store.isUpdatingQuotes ? "Cancel quote update" : "Update quotes")
        .contextMenu {
            Button("Update Quotes") { store.updateQuotes() }.disabled(store.isUpdatingQuotes)
            Button("Cancel Update") { store.cancelQuoteUpdate() }.disabled(!store.isUpdatingQuotes)
            Divider()
            Button("Show Last Update…") { store.isQuoteReportPresented = true }.disabled(store.lastQuoteUpdate == nil)
        }
        .popover(isPresented: $store.isQuoteReportPresented, arrowEdge: .bottom) {
            if let report = store.lastQuoteUpdate {
                QuoteReportView(report: report)
                    .environment(store)
            }
        }
    }

    private var help: String {
        if store.isUpdatingQuotes { return "\(store.activity?.statusText ?? "Updating quotes") — click to cancel" }
        if let report = store.lastQuoteUpdate, report.hasFailures {
            return "Update Quotes (⌘R) — \(report.failures.count) feed\(report.failures.count == 1 ? "" : "s") failed last time; right-click for details"
        }
        return "Update Quotes (⌘R)"
    }
}

/// The results of a quote update: what arrived, and which feeds failed and why. Each failure
/// links to its security so the feed can be fixed.
struct QuoteReportView: View {
    @Environment(PortfolioStore.self) private var store
    let report: QuoteUpdateReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                Image(systemName: report.hasFailures ? "exclamationmark.triangle.fill" : report.wasCancelled ? "stop.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(report.hasFailures ? DS.Colors.warning : report.wasCancelled ? Color.secondary : DS.Colors.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(headline).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .numeric()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.l)

            if report.hasFailures {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(report.failures) { failure in
                            failureRow(failure)
                            if failure.id != report.failures.last?.id { Divider().padding(.leading, DS.Spacing.l) }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            if !report.unsupportedCurrencies.isEmpty {
                Divider()
                Text("No exchange rates are available for \(report.unsupportedCurrencies.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.s)
            }
            Divider()
            HStack {
                if report.hasFailures {
                    Button("Retry Failed") {
                        store.isQuoteReportPresented = false
                        store.updateQuotes(only: Set(report.failures.compactMap(\.securityID)))
                    }
                    .disabled(store.isUpdatingQuotes || report.failures.allSatisfy { $0.securityID == nil })
                }
                Spacer()
                Button("Done") { store.isQuoteReportPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.m)
        }
        .frame(width: 420)
    }

    private func failureRow(_ failure: QuoteUpdateReport.Failure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(failure.name).font(.body.weight(.medium)).lineLimit(1)
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: DS.Spacing.s)
            if let id = failure.securityID, store.security(id) != nil {
                Button("Show") {
                    store.isQuoteReportPresented = false
                    store.navigate(to: .security(id))
                }
                .buttonStyle(.link)
                .accessibilityLabel("Show \(failure.name)")
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private var headline: String {
        if report.hasFailures {
            let count = report.failures.count
            return count == 1 ? "1 feed could not be updated" : "\(count) feeds could not be updated"
        }
        if report.wasCancelled { return "Update canceled" }
        return report.hasNewData ? "Quotes updated" : "Quotes are up to date"
    }

    private var detail: String {
        "\(report.summary) · \(Fmt.relativeDay(Day(date: report.finishedAt), today: store.today)), \(report.finishedAt.formatted(date: .omitted, time: .shortened))"
    }
}
