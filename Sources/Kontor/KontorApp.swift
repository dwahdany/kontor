import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KontorModel
import KontorUI
import KontorSampleData

/// The app: a document scene for `.kontor` portfolios, the welcome window and Settings.
struct KontorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Welcome to Kontor", id: WelcomeScene.id) {
            WelcomeScene()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        // Never let "open file" events (re)open the welcome window; the app delegate routes those.
        .handlesExternalEvents(matching: [])
        .defaultLaunchBehavior(UserDefaults.standard.object(forKey: AppPreferences.Key.showWelcomeAtLaunch) as? Bool == false ? .suppressed : .presented)
        .commandsRemoved()

        DocumentGroup(newDocument: { KontorDocument() }) { configuration in
            DocumentWindow(document: configuration.document)
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// Hosts `WelcomeView` in its window and wires it to document actions.
struct WelcomeScene: View {
    static let id = "welcome"

    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recents: [URL] = []

    var body: some View {
        WelcomeView(actions: actions, recents: recents)
            // The content runs under the (hidden) title bar; the frame is the window's content size.
            .ignoresSafeArea(.container, edges: .top)
            .frame(width: 760, height: 488)
            .task {
                // The recents list is loaded lazily by AppKit shortly after launch.
                recents = NSDocumentController.shared.recentDocumentURLs
                try? await Task.sleep(for: .milliseconds(400))
                recents = NSDocumentController.shared.recentDocumentURLs
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                recents = NSDocumentController.shared.recentDocumentURLs
            }
    }

    private var actions: WelcomeActions {
        WelcomeActions(
            newPortfolio: { name, currency in
                let file = SampleData.starterPortfolio(name: name, baseCurrency: currency)
                newDocument { KontorDocument(file: file) }
                dismissWindow(id: Self.id)
            },
            open: {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.kontorPortfolio]
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                open(url)
            },
            openDemo: {
                let file = SampleData.demoPortfolio()
                newDocument { KontorDocument(file: file) }
                dismissWindow(id: Self.id)
            },
            importPortfolioPerformance: {
                guard let url = ShellContext.shared.chooseImportFile(message: "Choose a Portfolio Performance file (.xml or .portfolio)") else { return }
                ShellContext.shared.queueImport(url)
                newDocument { KontorDocument() }
                dismissWindow(id: Self.id)
            },
            openRecent: { url in open(url) }
        )
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: Self.id)
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}

/// One portfolio window. The actual content is keyed by the document *instance*: Revert To Saved,
/// restoring a version and an external change of the file all make SwiftUI hand this view a new
/// `KontorDocument` (and with it a new store) while the view's identity stays the same. Without
/// the key, `onAppear` would not run again and the new store would have no undo manager, no change
/// tracking and no services: every later edit would silently never be saved.
struct DocumentWindow: View {
    @ObservedObject var document: KontorDocument

    var body: some View {
        DocumentContent(store: document.store, repairs: document.repairs)
            .id(ObjectIdentifier(document))
    }
}

/// Binds one store to its window (undo manager, change tracking, services, state restoration) and
/// shows `MainWindowView`. Recreated whenever the document instance changes.
private struct DocumentContent: View {
    let store: PortfolioStore
    let repairs: DocumentIO.Repairs
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismissWindow) private var dismissWindow
    @SceneStorage("route") private var storedRoute = AppScreen.dashboard.rawValue
    @SceneStorage("period") private var storedPeriod = ""
    @SceneStorage("scope") private var storedScope = ""
    @SceneStorage("inspector") private var storedInspector = false
    @State private var window: NSWindow?

    var body: some View {
        MainWindowView(store: store, registry: ShellContext.shared.registry)
            .frame(minWidth: 900, minHeight: 520)
            .background {
                WindowAccessor(onWindow: { window = $0 }, onBecomeKey: { ShellContext.shared.windowBecameKey(store) })
            }
            .onAppear {
                restoreState(into: store)
                ShellContext.shared.installServices(on: store)
                trackChanges(of: store, in: window)
                ShellContext.shared.windowAppeared(store)
                dismissWindow(id: WelcomeScene.id)
                if !repairs.isEmpty {
                    store.show(Toast("This file was repaired while opening", message: repairs.summary.prefix(1).uppercased() + repairs.summary.dropFirst() + ".", style: .warning, duration: 12))
                }
                ShellContext.shared.autoUpdateQuotesIfEnabled(store)
                DocumentSelfTest.documentWindowAppeared(store)
            }
            .onDisappear { ShellContext.shared.windowDisappeared(store) }
            .onChange(of: undoManager, initial: true) { _, manager in store.undoManager = manager }
            .onChange(of: window) { _, window in trackChanges(of: store, in: window) }
            .onChange(of: store.route) { _, route in storedRoute = route.stringValue }
            .onChange(of: store.period) { _, period in storedPeriod = period.code }
            .onChange(of: store.scopeSelection) { _, scope in storedScope = scope.stringValue }
            .task { await updateQuotesPeriodically(store) }
            .onChange(of: store.isInspectorPresented) { _, shown in storedInspector = shown }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in store.today = .today }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if store.today != .today { store.today = .today }
            }
    }

    /// Changes that bypass undo (automatic quote updates) must still mark the document as edited.
    private func trackChanges(of store: PortfolioStore, in window: NSWindow?) {
        store.onNonUndoableChange = { [weak window] in
            (window?.windowController?.document as? NSDocument)?.updateChangeCount(.changeDone)
        }
        store.services.closeDocument = { [weak window] in
            guard let document = window?.windowController?.document as? NSDocument, !document.isDocumentEdited else { return }
            document.close()
        }
    }

    private func restoreState(into store: PortfolioStore) {
        if let route = Route(string: storedRoute) { store.restore(route: route) }
        if let period = ReportingPeriod(code: storedPeriod) { store.period = period }
        if let scope = ScopeSelection(string: storedScope), scope.resolve(in: store.file) != nil { store.scopeSelection = scope }
        store.isInspectorPresented = storedInspector
    }

    /// Settings ▸ Market Data ▸ periodic updates: every 30 minutes while the window is open.
    private func updateQuotesPeriodically(_ store: PortfolioStore) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled else { return }
            if ShellContext.shared.isPeriodicUpdateEnabled, !store.isUpdatingQuotes, (store.hasAutomaticQuoteFeeds || store.needsExchangeRates) {
                store.updateQuotes(interactive: false)
            }
        }
    }
}
