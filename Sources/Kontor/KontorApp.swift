import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KontorModel
import KontorUI

/// The app: a document scene for `.kontor` portfolios, the welcome window and Settings.
struct KontorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppPreferences.Key.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some Scene {
        Window("Welcome to Kontor", id: WelcomeScene.id) {
            WelcomeScene()
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearance) { _, new in applyAppearance(new) }
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

    private func applyAppearance(_ raw: String) {
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
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
                let file = PortfolioFile(name: name, settings: Settings(baseCurrency: currency))
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
                let file = DemoPortfolio.make()
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

/// One portfolio window: binds the document's store to the window (undo manager, change tracking,
/// state restoration) and shows `MainWindowView`.
struct DocumentWindow: View {
    @ObservedObject var document: KontorDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismissWindow) private var dismissWindow
    @SceneStorage("route") private var storedRoute = AppScreen.dashboard.rawValue
    @SceneStorage("period") private var storedPeriod = ""
    @SceneStorage("inspector") private var storedInspector = false
    @State private var window: NSWindow?

    var body: some View {
        let store = document.store
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
                ShellContext.shared.autoUpdateQuotesIfEnabled(store)
            }
            .onDisappear { ShellContext.shared.windowDisappeared(store) }
            .onChange(of: undoManager, initial: true) { _, manager in store.undoManager = manager }
            .onChange(of: window) { _, window in trackChanges(of: store, in: window) }
            .onChange(of: store.route) { _, route in storedRoute = route.stringValue }
            .onChange(of: store.period) { _, period in storedPeriod = Self.encode(period) }
            .onChange(of: store.isInspectorPresented) { _, shown in storedInspector = shown }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in store.today = .today }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if store.today != .today { store.today = .today }
            }
    }

    /// Changes that bypass undo (e.g. quote updates) must still mark the document as edited.
    private func trackChanges(of store: PortfolioStore, in window: NSWindow?) {
        store.onNonUndoableChange = { [weak window] in
            (window?.windowController?.document as? NSDocument)?.updateChangeCount(.changeDone)
        }
    }

    private func restoreState(into store: PortfolioStore) {
        if let route = Route(string: storedRoute) { store.restore(route: route) }
        if let period = Self.decodePeriod(storedPeriod) { store.period = period }
        store.isInspectorPresented = storedInspector
    }

    private static func encode(_ period: ReportingPeriod) -> String {
        (try? JSONEncoder().encode(period)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func decodePeriod(_ string: String) -> ReportingPeriod? {
        guard !string.isEmpty else { return nil }
        return try? JSONDecoder().decode(ReportingPeriod.self, from: Data(string.utf8))
    }
}
