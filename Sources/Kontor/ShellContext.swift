import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KontorModel
import KontorUI
import KontorMarketData

/// App-wide coordination between scenes that SwiftUI gives no direct channel for: which portfolio
/// window is frontmost, and work queued for the next document window (import a file after creating
/// a document for it).
@MainActor
final class ShellContext {
    static let shared = ShellContext()

    let registry = FeatureCatalog.makeRegistry()

    /// The store of the most recently key portfolio window.
    private(set) weak var frontStore: PortfolioStore?
    private var openStores: [ObjectIdentifier: WeakStore] = [:]
    private struct WeakStore { weak var store: PortfolioStore? }

    /// An import to start as soon as the next document window appears.
    private var pendingImport: URL?

    var hasOpenDocuments: Bool { openStores.values.contains { $0.store != nil } }

    func windowAppeared(_ store: PortfolioStore) {
        openStores[ObjectIdentifier(store)] = WeakStore(store: store)
        if frontStore == nil { frontStore = store }
        if let url = pendingImport {
            pendingImport = nil
            store.present(.importFile(url))
        }
    }

    func windowDisappeared(_ store: PortfolioStore) {
        openStores[ObjectIdentifier(store)] = nil
        if frontStore === store { frontStore = openStores.values.compactMap(\.store).first }
    }

    func windowBecameKey(_ store: PortfolioStore) { frontStore = store }

    /// Routes a file the app was asked to open as an *import source* (Portfolio Performance XML,
    /// CSV): into the frontmost portfolio if there is one, otherwise into a new document.
    func importFile(_ url: URL) {
        if let store = frontStore {
            store.present(.importFile(url))
            NSApp.activate()
        } else {
            // No portfolio window yet. During launch, restored documents may still be on their way:
            // give them a moment to claim the import before creating a new document for it.
            pendingImport = url
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, self.pendingImport == url else { return }
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }

    /// Queues an import for the document that is about to be created.
    func queueImport(_ url: URL) { pendingImport = url }

    /// Shows an open panel restricted to importable files.
    func chooseImportFile(message: String = "Choose a file to import") -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UTType.importable
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// One updater for the whole app: its HTTP stack throttles per host, so all windows share it.
    private lazy var quoteUpdater = QuoteUpdater()

    /// Connects a store to the app: the import-file panel and KontorMarketData's quote updater.
    ///
    /// - Parameter network: `false` in the headless screenshot mode — no updater is installed, so
    ///   nothing can touch the network there.
    func installServices(on store: PortfolioStore, network: Bool = true) {
        store.services.chooseImportFile = { [weak self] store in
            guard let url = self?.chooseImportFile() else { return }
            store.present(.importFile(url))
        }
        store.quoteUpdater = network ? quoteUpdater : nil
    }

    /// Settings ▸ Market Data ▸ "Update quotes when a portfolio opens" (on by default). Quiet: it
    /// only reports through toasts, and does nothing if no security has an automatic feed.
    func autoUpdateQuotesIfEnabled(_ store: PortfolioStore) {
        let enabled = UserDefaults.standard.object(forKey: AppPreferences.Key.autoUpdateQuotes) as? Bool ?? true
        guard enabled, !store.isUpdatingQuotes, store.hasAutomaticQuoteFeeds else { return }
        store.updateQuotes(interactive: false)
    }

    /// Settings ▸ Market Data ▸ "Keep updating while the app is running".
    var isPeriodicUpdateEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferences.Key.periodicUpdate)
            && (UserDefaults.standard.object(forKey: AppPreferences.Key.autoUpdateQuotes) as? Bool ?? true)
    }

    /// Export as a pretty-printed, diff-friendly JSON copy — the shell's built-in export; richer
    /// formats (Portfolio Performance XML, CSV) come with the Import feature's export sheet.
    static func exportJSON(_ store: PortfolioStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (store.file.name.isEmpty ? "Portfolio" : store.file.name) + ".json"
        panel.message = "Export a readable JSON copy of this portfolio"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.file.encoded(pretty: true).write(to: url, options: .atomic)
            store.toast("Exported “\(url.lastPathComponent)”", style: .success)
        } catch {
            store.toast("Export failed", message: error.localizedDescription, style: .error)
        }
    }
}

/// Application delegate: handles files that are *import sources* rather than documents, and keeps
/// AppKit from opening an untitled document at launch (the welcome window is shown instead).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            if url.pathExtension.lowercased() == PortfolioFile.fileExtension || type?.conforms(to: .kontorPortfolio) == true {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } else {
                ShellContext.shared.importFile(url)
            }
        }
    }
}

/// Reports the hosting `NSWindow` (and when it becomes key) to SwiftUI code.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    var onBecomeKey: () -> Void = {}

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onWindow = onWindow
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onWindow = onWindow
        view.onBecomeKey = onBecomeKey
    }

    final class TrackingView: NSView {
        var onWindow: (NSWindow) -> Void = { _ in }
        var onBecomeKey: () -> Void = {}
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindow(window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBecomeKey() }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // Leaving the window (or being torn down): stop observing it.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
