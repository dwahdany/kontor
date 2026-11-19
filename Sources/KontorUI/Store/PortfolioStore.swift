import Foundation
import KontorModel
import KontorEngine
import KontorMarketData
import Observation
import Synchronization

/// A thread-safe mirror of a store's current file.
///
/// The document layer needs the file while saving, on a background thread, at a moment when the
/// main thread is blocked waiting for that very save. The store therefore publishes every new file
/// here; `PortfolioFile` is a copy-on-write value type, so keeping the mirror costs nothing.
public final class FileSnapshot: Sendable {
    private let storage: Mutex<PortfolioFile>

    public init(_ file: PortfolioFile) { storage = Mutex(file) }

    /// The file as of the store's latest change. Safe to call from any thread, never blocks on the main actor.
    public var current: PortfolioFile { storage.withLock { $0 } }

    func set(_ file: PortfolioFile) { storage.withLock { $0 = file } }
}

/// The single source of truth of one open portfolio window: the document (`file`), derived lookup
/// caches, the reporting period and all transient UI state (navigation, sheets, toasts, activity).
///
/// Features obtain it from the environment and derive their models through the shared analysis
/// cache, which recomputes off the main actor whenever `revision`, the scope or the period change:
///
/// ```swift
/// @Environment(PortfolioStore.self) private var store
/// @State private var model = Loadable<HoldingsModel>()
///
/// var body: some View {
///     Content(model: model.value)
///         .analysisTask($model, id: "holdings.model") { analysis in HoldingsModel(analysis) }
/// }
/// ```
///
/// All changes go through ``mutate(_:undoable:_:)`` (or the CRUD conveniences built on it), which
/// bumps `revision`, registers undo and marks the document as edited.
@MainActor
@Observable
public final class PortfolioStore {
    // MARK: Document

    /// The open document. Read-only: change it with ``mutate(_:undoable:_:)``.
    public private(set) var file: PortfolioFile

    /// Increases by one on every change of `file` (including undo/redo and reloads). Use it as the
    /// identity of everything derived from the file.
    public private(set) var revision: Int = 0

    /// Always holds the current `file`; readable from any thread (used by the document while saving).
    public nonisolated let snapshot: FileSnapshot

    /// The document's undo manager; the shell assigns it when the window appears. Its depth is
    /// bounded (see ``undoLevels(for:)``): every step retains the collections it changed.
    @ObservationIgnored public var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = Self.undoLevels(for: file) }
    }

    /// How many undo steps to keep for `file`: 100 for everyday portfolios, fewer for very large
    /// ones, because a step keeps a copy of every collection it changed (the whole ledger for a
    /// transaction edit: about 12 MB with 50,000 transactions). At least 10.
    public nonisolated static func undoLevels(for file: PortfolioFile) -> Int {
        let bytesPerStep = max(1, file.transactions.count * MemoryLayout<Transaction>.stride)
        let budget = 192 * 1024 * 1024
        return min(100, max(10, budget / bytesPerStep))
    }

    /// Called after a change that is *not* covered by an undo registration (`undoable: false`), so
    /// the document can still be marked as edited. Installed by the shell.
    @ObservationIgnored public var onNonUndoableChange: (@MainActor () -> Void)?

    /// Services implemented outside the UI kit (quote updates, import/export).
    @ObservationIgnored public var services = PortfolioServices()

    // MARK: Reporting context

    /// "Today" as used for valuations. Refreshed by the shell at midnight / on activation; fixed in
    /// screenshot mode so that renders are reproducible.
    public var today: Day

    /// The globally selected reporting period (toolbar period picker).
    public var period: ReportingPeriod = .lastYears(1)

    /// The part of the portfolio this window looks at (see `ScopePicker`). Use ``scope`` for the
    /// engine value.
    public var scopeSelection: ScopeSelection = .portfolio

    /// Launch-time view state for the headless screenshot mode: `--state key=value` arguments end
    /// up here (empty in normal use). Screens read it once, when they appear, to open a particular
    /// tab / sub-view / selection — see ``launchValue(_:)``.
    public var launchState: [String: String] = [:]

    // MARK: Analysis

    /// The memoizing analysis layer (see ``compute(_:_:)`` and ``analyze(_:scope:interval:variant:_:)``).
    @ObservationIgnored public let analysisCache = AnalysisCache()

    // MARK: Quote updates

    /// Downloads quotes and exchange rates. Installed by the shell; `nil` disables updates (tests,
    /// headless screenshot mode — no network there).
    @ObservationIgnored public var quoteUpdater: QuoteUpdater?

    /// The outcome of the most recent quote update of this window.
    public internal(set) var lastQuoteUpdate: QuoteUpdateReport?

    /// Whether the shell shows the results popover of the last quote update.
    public var isQuoteReportPresented = false

    @ObservationIgnored var quoteUpdateTask: Task<QuoteUpdateReport?, Never>?
    /// True from the start of a quote update until its results are applied.
    public internal(set) var isUpdatingQuotes = false

    // MARK: Transient UI state

    /// The current navigation target. Change it with ``navigate(to:)``.
    public private(set) var route: Route
    public private(set) var backStack: [Route] = []
    public private(set) var forwardStack: [Route] = []

    /// The sheet currently presented by the shell (further requests queue up behind it).
    public internal(set) var sheet: SheetRequest?
    @ObservationIgnored private var queuedSheets: [SheetRequest] = []

    /// A confirmation dialog awaiting the user's decision.
    public var confirmation: ConfirmationRequest?

    /// Whether the ⌘K command palette is showing. Closing it clears `commandPaletteQuery`.
    public var isCommandPalettePresented = false {
        didSet { if !isCommandPalettePresented, !commandPaletteQuery.isEmpty { commandPaletteQuery = "" } }
    }
    /// The palette's search text. Set it before presenting to open the palette pre-filled.
    public var commandPaletteQuery = ""
    public var isInspectorPresented = false

    /// Visible toasts, oldest first.
    public private(set) var toasts: [Toast] = []

    /// The running background job, if any.
    public private(set) var activity: BackgroundActivity?

    private var busyCount = 0 {
        didSet {
            guard (oldValue == 0) != (busyCount == 0) else { return }
            let now = ContinuousClock.now
            if busyCount > 0 {
                busySince = now
            } else if let since = busySince {
                busyTime += now - since
                lastIdleAt = now
                busySince = nil
            }
        }
    }
    @ObservationIgnored private var busySince: ContinuousClock.Instant?

    /// Total time spent busy (analysis requests, `whileBusy`) so far — for timing diagnostics.
    @ObservationIgnored public private(set) var busyTime: Duration = .zero
    /// When the store last went from busy to idle; nil if it has never been busy.
    @ObservationIgnored public private(set) var lastIdleAt: ContinuousClock.Instant?

    // MARK: Caches (rebuilt lazily after each revision)

    @ObservationIgnored private var caches = Caches()

    private struct Caches {
        var securities: [UUID: Int]?
        var accounts: [UUID: Int]?
        var depots: [UUID: Int]?
        var transactions: [UUID: Int]?
        var plans: [UUID: Int]?
        var transactionsBySecurity: [UUID: [Int]]?
        var transactionsByAccount: [UUID: [Int]]?
        var transactionsByDepot: [UUID: [Int]]?
        var inception: Day??
    }

    /// - Parameter snapshot: the mirror to publish the file to; the document passes its own so
    ///   it can save without touching the main actor.
    public init(file: PortfolioFile = PortfolioFile(), today: Day = .today, route: Route = Route(.dashboard), snapshot: FileSnapshot? = nil) {
        self.file = file
        self.snapshot = snapshot ?? FileSnapshot(file)
        self.snapshot.set(file)
        self.today = today
        self.route = route
    }

    // MARK: - Mutation & undo

    /// Applies `body` to a copy of the file. If the result differs from the current file it becomes
    /// the new file, `revision` is bumped and an undo step named `actionName` is registered;
    /// otherwise nothing happens (no revision bump, no undo step, document stays clean).
    ///
    /// Snapshots are cheap: `PortfolioFile` is a value type whose arrays are shared copy-on-write, so
    /// an undo step only retains the collections that actually changed.
    ///
    /// - Parameters:
    ///   - actionName: Shown in the Edit menu ("Undo Add Transaction").
    ///   - undoable: Pass `false` for background changes such as automatic quote updates, which
    ///     dirty the document but neither add an undo step nor clear the redo stack.
    /// - Returns: `true` if the file changed.
    @discardableResult
    public func mutate(_ actionName: String, undoable: Bool = true, _ body: (inout PortfolioFile) throws -> Void) rethrows -> Bool {
        let before = file
        var working = before
        try body(&working)
        guard working != before else { return false }
        install(working)
        if undoable, let undoManager {
            registerUndo(restoring: before, actionName: actionName, in: undoManager)
        } else {
            onNonUndoableChange?()
        }
        // A deleted entity must not stay the focus (inspector, "selected" commands).
        validateRoute()
        return true
    }

    /// Replaces the whole file without registering undo — for loading, reverting and tests.
    public func replaceFile(_ newFile: PortfolioFile) {
        install(newFile)
        validateRoute()
    }

    private func install(_ newFile: PortfolioFile) {
        file = newFile
        snapshot.set(newFile)
        revision += 1
        caches = Caches()
        if let undoManager {
            let levels = Self.undoLevels(for: newFile)
            if undoManager.levelsOfUndo != levels { undoManager.levelsOfUndo = levels }
        }
    }

    /// Stops background work that belongs to this window (the shell calls it when the window closes).
    public func shutdown() {
        cancelQuoteUpdate()
    }

    private func registerUndo(restoring snapshot: PortfolioFile, actionName: String, in undoManager: UndoManager) {
        // Weak: the handler lives in the manager's own stack and must not keep it alive.
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            let current = store.file
            store.install(snapshot)
            store.validateRoute()
            // Registering during undo records the redo step (and vice versa).
            if let undoManager { store.registerUndo(restoring: current, actionName: actionName, in: undoManager) }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Lookups (O(1) after the first call per revision)

    public func security(_ id: UUID?) -> Security? {
        guard let id else { return nil }
        if caches.securities == nil { caches.securities = Self.index(file.securities) }
        return caches.securities?[id].map { file.securities[$0] }
    }

    public func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        if caches.accounts == nil { caches.accounts = Self.index(file.accounts) }
        return caches.accounts?[id].map { file.accounts[$0] }
    }

    public func depot(_ id: UUID?) -> Depot? {
        guard let id else { return nil }
        if caches.depots == nil { caches.depots = Self.index(file.depots) }
        return caches.depots?[id].map { file.depots[$0] }
    }

    public func transaction(_ id: UUID?) -> Transaction? {
        guard let id else { return nil }
        if caches.transactions == nil { caches.transactions = Self.index(file.transactions) }
        return caches.transactions?[id].map { file.transactions[$0] }
    }

    public func plan(_ id: UUID?) -> InvestmentPlan? {
        guard let id else { return nil }
        if caches.plans == nil { caches.plans = Self.index(file.plans) }
        return caches.plans?[id].map { file.plans[$0] }
    }

    /// All transactions of a security, in file order.
    public func transactions(forSecurity id: UUID) -> [Transaction] {
        if caches.transactionsBySecurity == nil {
            var map = [UUID: [Int]]()
            for (i, t) in file.transactions.enumerated() {
                if let s = t.securityID { map[s, default: []].append(i) }
            }
            caches.transactionsBySecurity = map
        }
        return (caches.transactionsBySecurity?[id] ?? []).map { file.transactions[$0] }
    }

    /// All transactions touching a cash account (as source or as transfer target), in file order.
    public func transactions(forAccount id: UUID) -> [Transaction] {
        if caches.transactionsByAccount == nil {
            var map = [UUID: [Int]]()
            for (i, t) in file.transactions.enumerated() {
                if let a = t.accountID { map[a, default: []].append(i) }
                if let c = t.counterAccountID, c != t.accountID { map[c, default: []].append(i) }
            }
            caches.transactionsByAccount = map
        }
        return (caches.transactionsByAccount?[id] ?? []).map { file.transactions[$0] }
    }

    /// All transactions touching a depot (as source or as transfer target), in file order.
    public func transactions(forDepot id: UUID) -> [Transaction] {
        if caches.transactionsByDepot == nil {
            var map = [UUID: [Int]]()
            for (i, t) in file.transactions.enumerated() {
                if let d = t.depotID { map[d, default: []].append(i) }
                if let c = t.counterDepotID, c != t.depotID { map[c, default: []].append(i) }
            }
            caches.transactionsByDepot = map
        }
        return (caches.transactionsByDepot?[id] ?? []).map { file.transactions[$0] }
    }

    /// The date of the earliest transaction, if any.
    public var inception: Day? {
        _ = revision
        if let cached = caches.inception { return cached }
        let first = file.transactions.lazy.map(\.date).min()
        caches.inception = .some(first)
        return first
    }

    /// The portfolio's reporting currency.
    public var baseCurrency: CurrencyCode { file.settings.baseCurrency }

    /// The selected period resolved against `today` and the first transaction.
    ///
    /// Engine convention: the value at the **end of `start`** is the baseline, the period covers
    /// `start + 1 … end` (`interval.firstDay … interval.end`).
    public var periodInterval: DayInterval { interval(for: period) }

    /// Any reporting period resolved against `today` and the first transaction.
    public func interval(for period: ReportingPeriod) -> DayInterval {
        period.interval(today: today, firstTransactionDay: inception)
    }

    /// A launch-state value (`--state key=value`), or nil.
    public func launchValue(_ key: String) -> String? { launchState[key] }

    /// A launch-state value converted to a `String`-backed enum, e.g.
    /// `store.launchValue("tab", as: Tab.self) ?? .overview`.
    public func launchValue<Value: RawRepresentable>(_ key: String, as type: Value.Type) -> Value? where Value.RawValue == String {
        launchState[key].flatMap { Value(rawValue: $0) }
    }

    private static func index<E: Identifiable>(_ items: [E]) -> [E.ID: Int] {
        var map = [E.ID: Int](minimumCapacity: items.count)
        for (i, item) in items.enumerated() { map[item.id] = i }
        return map
    }

    // MARK: - Navigation

    /// Navigates to `route`, pushing the current route onto the back stack.
    public func navigate(to route: Route) {
        guard route != self.route else { return }
        backStack.append(self.route)
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack.removeAll()
        self.route = route
    }

    /// Switches screens, keeping no focus.
    public func navigate(to screen: AppScreen) { navigate(to: Route(screen)) }

    /// Updates the focused entity of the current screen without adding a history entry — call this
    /// when the user changes the selection inside your screen so the inspector follows.
    public func setFocus(_ focus: Route.Focus?) {
        guard route.focus != focus else { return }
        route.focus = focus
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        route = previous
        validateRoute()
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        route = next
        validateRoute()
    }

    /// Restores a route (state restoration, `--route`) without touching history.
    public func restore(route: Route) {
        self.route = route
        validateRoute()
    }

    /// Drops a focus whose entity no longer exists (after delete/undo).
    private func validateRoute() {
        guard let focus = route.focus else { return }
        let exists: Bool
        switch focus {
        case .security(let id): exists = security(id) != nil
        case .account(let id): exists = account(id) != nil
        case .depot(let id): exists = depot(id) != nil
        case .transaction(let id): exists = transaction(id) != nil
        case .plan(let id): exists = plan(id) != nil
        case .taxonomy(let id): exists = file.taxonomies.contains { $0.id == id }
        case .classification(let taxonomy, let id):
            exists = file.taxonomies.first { $0.id == taxonomy }?.classification(id) != nil
        }
        if !exists { route.focus = nil }
    }

    // MARK: - Sheets & confirmations

    /// Asks the shell to present a sheet. If one is already up, the request is queued.
    public func present(_ request: SheetRequest) {
        if sheet == nil {
            sheet = request
        } else if sheet != request, !queuedSheets.contains(request) {
            queuedSheets.append(request)
        }
    }

    /// Dismisses the current sheet and presents the next queued one, if any.
    public func dismissSheet() {
        sheet = queuedSheets.isEmpty ? nil : queuedSheets.removeFirst()
    }

    /// Opens the command palette, optionally pre-filled with a search.
    public func openCommandPalette(query: String = "") {
        commandPaletteQuery = query
        isCommandPalettePresented = true
    }

    /// Asks the shell to show a confirmation dialog.
    public func confirm(_ request: ConfirmationRequest) { confirmation = request }

    // MARK: - Toasts

    /// Shows a transient notification. It disappears after `toast.duration` seconds.
    public func show(_ toast: Toast) {
        toasts.append(toast)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        let id = toast.id
        let duration = toast.duration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.dismissToast(id)
        }
    }

    public func toast(_ title: String, message: String? = nil, style: Toast.Style = .info) {
        show(Toast(title, message: message, style: style))
    }

    public func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: - Background activity & settling

    /// Publishes a background job ("Updating quotes"). Call ``updateActivity(completed:total:)`` as
    /// it progresses and ``endActivity()`` when done.
    public func beginActivity(_ title: String, total: Int? = nil) {
        activity = BackgroundActivity(title: title, completed: 0, total: total)
    }

    public func updateActivity(completed: Int, total: Int? = nil) {
        guard var current = activity else { return }
        current.completed = completed
        if let total { current.total = total }
        activity = current
    }

    public func endActivity() { activity = nil }

    /// True while a background activity runs, an analysis request (``compute(_:_:)``,
    /// ``analyze(_:scope:interval:variant:_:)``, `analysisTask`) is pending, or any feature is inside
    /// ``whileBusy(_:)``. The screenshot mode waits for this to turn false before capturing.
    public var isBusy: Bool { busyCount > 0 || activity != nil }

    /// Marks the store busy for the duration of `operation` — wrap asynchronous recomputation in it
    /// so loading indicators and the headless screenshot mode know when the screen has settled.
    public func whileBusy<T>(_ operation: () async throws -> T) async rethrows -> T {
        beginBusy()
        defer { endBusy() }
        return try await operation()
    }

    /// Manual variant of ``whileBusy(_:)`` for callback-style work. Balance every call with ``endBusy()``.
    public func beginBusy() { busyCount += 1 }
    public func endBusy() { busyCount = max(0, busyCount - 1) }

    /// Suspends until `isBusy` has been false for `quietPeriod`, or `timeout` elapsed.
    ///
    /// - Returns: How long it took until the store became idle (not counting the quiet period), or
    ///   nil if it never settled before the timeout.
    @discardableResult
    public func waitUntilSettled(quietPeriod: Duration = .milliseconds(250), timeout: Duration = .seconds(10)) async -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + timeout
        var quietSince: ContinuousClock.Instant? = nil
        while clock.now < deadline {
            if isBusy {
                quietSince = nil
            } else if let since = quietSince {
                if clock.now - since >= quietPeriod { return since - start }
            } else {
                quietSince = clock.now
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
