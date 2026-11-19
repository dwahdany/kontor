import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import KontorModel
import KontorEngine
import KontorMarketData
import KontorInterchange
import KontorUI
import KontorSampleData
#if canImport(FeatureTransactions)
import FeatureTransactions
#endif
#if canImport(FeatureAccounts)
import FeatureAccounts
#endif
#if canImport(FeatureSecurities)
import FeatureSecurities
#endif
#if canImport(FeaturePlans)
import FeaturePlans
#endif
#if canImport(FeatureAllocation)
import FeatureAllocation
#endif
#if canImport(FeatureImport)
import FeatureImport
#endif

/// `Kontor --selftest` — an end-to-end test of the real app objects, in-process and invisible.
///
/// Nothing is clicked. Instead the run drives the same code the UI drives: the editors' models and
/// save paths (through the hooks each feature exposes as `<Feature>SelfTest`), the store with a
/// real undo manager, the document's read and write paths, the importers, the plan generator, the
/// rebalancing model, a quote update against a stub HTTP client — and it hosts the real
/// `MainWindowView` in a window below the desktop picture (the technique of the screenshot mode)
/// and walks every screen, sub-view, period, scope, deep link and sheet, so that anything that
/// only fails when a view is actually mounted (a missing environment object, a layout exception,
/// "Modifying state during view update") surfaces. Finally everything the process logged is
/// searched for runtime warnings.
///
///     Kontor --selftest [--verbose] [--quick] [--today YYYY-MM-DD] [--fixtures <dir>] [--only <phase>]
///
/// One line per step (`ok` / `FAIL`), a summary, exit status 0 or 1. See `Scripts/selftest.sh`.
@MainActor
enum SelfTest {
    struct Options {
        var verbose = false
        /// Skips the stress portfolio and the slow parts of the tours.
        var quick = false
        var today = Day(iso: "2026-06-30")!
        /// A directory with `.xml` (Portfolio Performance) and `.csv` files to import as well.
        var fixtures: String?
        /// Run a single phase: scenario, documents, import, tours.
        var only: String?
        /// Tours only: restrict to these portfolios (starter, demo, stress) …
        var portfolios: Set<String>?
        /// … and to these parts (screens, periods, links, sheets, layers, edits).
        var parts: Set<String>?

        init(arguments: [String]) throws {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--selftest": break
                case "--verbose", "-v": verbose = true
                case "--quick": quick = true
                case "--today":
                    guard let day = iterator.next().flatMap({ Day(iso: $0) }) else { throw ScreenshotOptions.ArgumentError(description: "--today expects YYYY-MM-DD") }
                    today = day
                case "--fixtures":
                    guard let path = iterator.next() else { throw ScreenshotOptions.ArgumentError(description: "--fixtures expects a directory") }
                    fixtures = path
                case "--only":
                    guard let phase = iterator.next(), ["scenario", "documents", "import", "tours"].contains(phase) else {
                        throw ScreenshotOptions.ArgumentError(description: "--only expects scenario, documents, import or tours")
                    }
                    only = phase
                case "--portfolio":
                    guard let value = iterator.next() else { throw ScreenshotOptions.ArgumentError(description: "--portfolio expects starter, demo or stress") }
                    portfolios = Set(value.split(separator: ",").map(String.init))
                case "--parts":
                    guard let value = iterator.next() else { throw ScreenshotOptions.ArgumentError(description: "--parts expects screens, periods, links, sheets, layers, edits") }
                    parts = Set(value.split(separator: ",").map(String.init))
                default:
                    throw ScreenshotOptions.ArgumentError(description: "unknown argument \(argument)")
                }
            }
        }
    }

    static func run(_ options: Options) -> Never {
        let capture = LogCapture()
        capture.start()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(options: options, capture: capture)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        let options: Options
        let capture: LogCapture
        init(options: Options, capture: LogCapture) {
            self.options = options
            self.capture = capture
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                let run = SelfTestRun(options: options, capture: capture)
                await run.execute()
                exit(run.failures == 0 ? 0 : 1)
            }
        }
    }
}

// MARK: - Log capture

/// Collects what the process writes to standard error (AppKit and SwiftUI diagnostics end up
/// there) and, at the end, what it logged through the unified logging system.
final class LogCapture: @unchecked Sendable {
    private var originalStderr: Int32 = -1
    private let path = NSTemporaryDirectory() + "kontor-selftest-\(ProcessInfo.processInfo.processIdentifier).stderr"
    private let started = Date()

    /// Messages that mean a bug in the app, wherever they come from.
    static let patterns: [(needle: String, meaning: String)] = [
        ("Modifying state during view update", "state modified during a view update"),
        ("Publishing changes from within view updates", "publishing changes from within view updates"),
        ("AttributeGraph: cycle", "AttributeGraph cycle"),
        ("reentrant operation in its NSTableView delegate", "NSTableView re-entrancy"),
        ("Unable to simultaneously satisfy constraints", "conflicting layout constraints"),
        ("tried to update multiple times per frame", "value updated multiple times per frame"),
        ("No Observable object of type", "missing environment object"),
        ("Invalid frame dimension", "invalid frame dimension"),
        ("laid out reentrantly", "re-entrant layout"),
        ("It's not legal to call -layoutSubtreeIfNeeded", "layout requested during layout"),
        ("NSInternalInconsistencyException", "exception logged"),
        ("uncaught exception", "exception logged"),
        ("Exception raised", "exception logged"),
        ("*** Assertion failure", "assertion failure logged"),
        ("is not on the main thread", "main-thread violation"),
        ("Fatal error:", "fatal error"),
    ]

    func start() {
        fflush(stderr)
        originalStderr = dup(STDERR_FILENO)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let file = fopen(path, "w") else { return }
        dup2(fileno(file), STDERR_FILENO)
        fclose(file)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    /// Everything written to standard error since `start()`; standard error is restored.
    func finish() -> String {
        fflush(stderr)
        if originalStderr >= 0 {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            originalStderr = -1
        }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return text
    }

    /// Messages this process sent to the unified log since `start()` (SwiftUI reports its runtime
    /// issues there as faults).
    func unifiedLog() -> [(date: Date, text: String)] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: started)
        guard let entries = try? store.getEntries(at: position) else { return [] }
        return entries.compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return (log.date, "[\(log.subsystem)] \(log.composedMessage)")
        }
    }

    /// Messages that are a consequence of how the self-test hosts the views, not of the app.
    static let expected = [
        // The self-test hosts MainWindowView in a plain NSWindow; scene storage is inert there.
        "SceneStorage is only for use with SwiftUI App Lifecycle",
        // SwiftUI resizes a sheet's window from inside its own layout pass when the sheet's content
        // changes height (the transaction editor goes from its loading placeholder to the form).
        // AppKit logs this once per process; the backtrace has no frame of the app.
        "It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out",
    ]

    /// The time stamp NSLog puts in front of a line written to standard error.
    static func date(ofStderrLine line: String) -> Date? {
        guard line.count > 23 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: String(line.prefix(23)))
    }
}

// MARK: - The run

@MainActor
final class SelfTestRun {
    let options: SelfTest.Options
    let capture: LogCapture
    private(set) var failures = 0
    private var passed = 0
    /// When each step ran, to attribute log messages to the step that caused them.
    private var spans: [(name: String, start: Date, end: Date)] = []
    private let registry = ShellContext.shared.registry
    private let clock = ContinuousClock()

    init(options: SelfTest.Options, capture: LogCapture) {
        self.options = options
        self.capture = capture
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Reporting

    private func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private func heading(_ title: String) { emit("\n== \(title)") }

    /// Runs one step; a thrown error is a failure of that step only.
    @discardableResult
    private func step(_ name: String, _ body: () async throws -> String?) async -> Bool {
        let start = clock.now
        let began = Date()
        defer { spans.append((name, began, Date())) }
        if options.verbose { emit("…    \(name)") }
        do {
            let detail = try await body()
            passed += 1
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            var line = "ok   \(name)"
            if let detail, !detail.isEmpty { line += " — \(detail)" }
            if options.verbose || seconds >= 5 { line += String(format: " (%.1f s)", seconds) }
            emit(line)
            return true
        } catch {
            failures += 1
            let message = (error as? Failure)?.description ?? (error as? SelfTestFailure)?.description ?? "\(error)"
            emit("FAIL \(name) — \(message)")
            return false
        }
    }

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message()) }
    }

    private func enabled(_ phase: String) -> Bool { options.only == nil || options.only == phase }

    // MARK: Entry point

    func execute() async {
        emit("Kontor self-test — today \(options.today.iso), features: \(FeatureCatalog.linkedFeatures.joined(separator: ", "))")
        if enabled("scenario") { await scenario() }
        if enabled("documents") { await documents() }
        if enabled("import") { await imports() }
        if enabled("tours") {
            func wanted(_ name: String) -> Bool { options.portfolios?.contains(name) ?? true }
            if wanted("starter") { await tour("starter", file: SampleData.starterPortfolio(name: "Starter", baseCurrency: "EUR"), depth: .full) }
            if wanted("demo") { await tour("demo", file: SampleData.demoPortfolio(today: options.today), depth: options.quick ? .light : .full) }
            if let scenarioFile, wanted("scenario") { await tour("scenario", file: scenarioFile, depth: .light) }
            if !options.quick || options.portfolios?.contains("stress") == true, wanted("stress") {
                await tour("stress", file: SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000, endingOn: options.today), depth: .light)
            }
        }
        await scanLogs()
        emit("\n\(failures == 0 ? "PASS" : "FAIL") — \(passed) steps passed, \(failures) failed")
    }

    // MARK: - Phase 1: a portfolio built from nothing

    private func makeStore(_ file: PortfolioFile, explicitUndoGroups: Bool = false) -> (PortfolioStore, UndoManager) {
        let store = PortfolioStore(file: file, today: options.today)
        ShellContext.shared.installServices(on: store, network: false)
        let undoManager = UndoManager()
        // The scenario closes one undo group per step itself; there is no event loop to do it.
        if explicitUndoGroups { undoManager.groupsByEvent = false }
        store.undoManager = undoManager
        return (store, undoManager)
    }

    private func scenario() async {
        heading("Scenario: starter portfolio → accounts, securities, all 15 transaction kinds → engine")
        #if canImport(FeatureTransactions) && canImport(FeatureAccounts) && canImport(FeatureSecurities)
        let (store, undoManager) = makeStore(SampleData.starterPortfolio(name: "Self-Test", baseCurrency: "EUR"), explicitUndoGroups: true)
        var history: [PortfolioFile] = [store.file]
        var names: [String] = ["starter"]

        /// One user action = one undo group; remembers the file after it.
        func action(_ name: String, _ body: () async throws -> String?) async -> Bool {
            await step(name) {
                undoManager.beginUndoGrouping()
                defer { undoManager.endUndoGrouping() }
                let before = store.file
                let detail = try await body()
                if store.file != before {
                    history.append(store.file)
                    names.append(name)
                }
                return detail
            }
        }

        var eur = UUID(), usd = UUID(), depotA = UUID(), depotB = UUID(), equity = UUID(), foreign = UUID()
        let ready = await step("starter document has a cash account, a depot and taxonomies") {
            guard let account = store.file.accounts.first, let depot = store.file.depots.first else { throw Failure("the starter has no account or depot") }
            eur = account.id
            depotA = depot.id
            try expect(account.currency == "EUR", "starter account is \(account.currency)")
            try expect(depot.referenceAccountID == account.id, "the starter depot does not settle against the starter account")
            try expect(!store.file.taxonomies.isEmpty, "the starter has no taxonomies")
            return "\(store.file.taxonomies.count) taxonomies"
        }
        guard ready else { return }

        _ = await action("add a USD cash account (account editor)") {
            usd = try AccountsSelfTest.addAccount(name: "  Dollar Account ", currency: "USD", in: store)
            try expect(store.account(usd)?.name == "Dollar Account", "the name was not trimmed")
            return nil
        }
        _ = await action("add a second depot (depot editor)") {
            depotB = try AccountsSelfTest.addDepot(name: "Second Depot", referenceAccountID: eur, in: store)
            return nil
        }
        _ = await action("rename an account (account editor, edit)") {
            try AccountsSelfTest.renameAccount(eur, to: "Euro Account", in: store)
            return nil
        }
        _ = await action("add a security in EUR (security editor)") {
            equity = try SecuritiesSelfTest.addSecurity(
                name: "Selftest Equity", currency: "EUR", isin: "de000selftest1", ticker: "SELF.DE",
                feed: QuoteFeed(provider: YahooProvider.id, symbol: "SELF.DE"), in: store)
            try expect(store.security(equity)?.isin == "DE000SELFTEST1", "the ISIN was not normalised")
            return nil
        }
        _ = await action("add a security in USD (security editor)") {
            foreign = try SecuritiesSelfTest.addSecurity(
                name: "Selftest US", currency: "USD", ticker: "SELFUS", feed: QuoteFeed(provider: YahooProvider.id, symbol: "SELFUS"), in: store)
            return nil
        }
        _ = await action("edit a security: note and benchmark flag (security editor, edit)") {
            try SecuritiesSelfTest.edit(equity, note: "edited by the self-test", isBenchmark: true, in: store)
            return nil
        }

        // The ledger: every kind once, typed the way the editor's fields take it.
        typealias Entry = TransactionsSelfTest.Entry
        var day = options.today.advanced(by: -200)
        func next() -> Day {
            day = day.advanced(by: 3)
            return day
        }
        var expectedCash: [UUID: Int64] = [:]
        var expectedShares: [String: Int64] = [:]
        func key(_ security: UUID, _ depot: UUID) -> String { "\(security)/\(depot)" }
        let bookings: [(String, Entry, [(UUID, Int64)], [(UUID, UUID, Int64)])] = [
            ("deposit", Entry(.deposit, date: next(), accountID: eur, amount: 5_000_000), [(eur, 5_000_000)], []),
            ("deposit (USD)", Entry(.deposit, date: next(), accountID: usd, amount: 1_000_000), [(usd, 1_000_000)], []),
            ("buy", Entry(.buy, date: next(), securityID: equity, depotID: depotA, shares: Shares(100), price: Price(50), fees: 990),
             [(eur, -500_990)], [(equity, depotA, 100)]),
            ("buy in a foreign currency (USD security, EUR account, typed rate)",
             Entry(.buy, date: next(), securityID: foreign, depotID: depotA, shares: Shares(20), price: Price(150), fees: 500, rate: 0.9),
             [(eur, -270_500)], [(foreign, depotA, 20)]),
            ("deliveryIn", Entry(.deliveryIn, date: next(), securityID: equity, depotID: depotA, shares: Shares(10), price: Price(48)),
             [], [(equity, depotA, 10)]),
            ("sell", Entry(.sell, date: next(), securityID: equity, depotID: depotA, shares: Shares(30), price: Price(55), fees: 990, taxes: 1_200),
             [(eur, 162_810)], [(equity, depotA, -30)]),
            ("deliveryOut", Entry(.deliveryOut, date: next(), securityID: equity, depotID: depotA, shares: Shares(5), price: Price(52)),
             [], [(equity, depotA, -5)]),
            ("dividend", Entry(.dividend, date: next(), securityID: equity, accountID: eur, amount: 8_000, taxes: 2_000), [(eur, 6_000)], []),
            ("interest", Entry(.interest, date: next(), accountID: eur, amount: 1_234), [(eur, 1_234)], []),
            ("interestCharge", Entry(.interestCharge, date: next(), accountID: eur, amount: 321), [(eur, -321)], []),
            ("fee", Entry(.fee, date: next(), accountID: eur, amount: 500), [(eur, -500)], []),
            ("feeRefund", Entry(.feeRefund, date: next(), accountID: eur, amount: 100), [(eur, 100)], []),
            ("tax", Entry(.tax, date: next(), accountID: eur, amount: 700), [(eur, -700)], []),
            ("taxRefund", Entry(.taxRefund, date: next(), accountID: eur, amount: 200), [(eur, 200)], []),
            ("cashTransfer across currencies (EUR → USD)",
             Entry(.cashTransfer, date: next(), accountID: eur, counterAccountID: usd, amount: 100_000, counterAmount: 108_000),
             [(eur, -100_000), (usd, 108_000)], []),
            ("securityTransfer", Entry(.securityTransfer, date: next(), securityID: equity, depotID: depotA, counterDepotID: depotB, shares: Shares(20)),
             [], [(equity, depotA, -20), (equity, depotB, 20)]),
            ("withdrawal", Entry(.withdrawal, date: next(), accountID: eur, amount: 50_000), [(eur, -50_000)], []),
        ]
        var recordedKinds = Set<Transaction.Kind>()
        var recorded: [Transaction] = []
        for (name, entry, cash, shares) in bookings {
            let ok = await action("record \(name) (transaction editor)") {
                let transaction = try await TransactionsSelfTest.record(entry, in: store)
                try expect(transaction.kind == entry.kind, "stored as \(transaction.kind.rawValue)")
                recorded.append(transaction)
                return "\(Fmt.money(transaction.amount))" + (transaction.shares.isZero ? "" : ", \(Fmt.shares(transaction.shares)) shares")
            }
            if ok {
                recordedKinds.insert(entry.kind)
                for (account, delta) in cash { expectedCash[account, default: 0] += delta }
                for (security, depot, delta) in shares { expectedShares[key(security, depot), default: 0] += delta * Int64(Scale.shares) }
            }
        }
        await step("all 15 transaction kinds were recorded") {
            let missing = Transaction.Kind.allCases.filter { !recordedKinds.contains($0) }
            try expect(missing.isEmpty, "missing: \(missing.map(\.rawValue).joined(separator: ", "))")
            return "\(store.file.transactions.count) transactions"
        }
        await step("foreign-currency buy stores both currencies") {
            guard let buy = recorded.first(where: { $0.kind == .buy && $0.securityID == foreign }) else { throw Failure("not recorded") }
            try expect(buy.amount == Money(minor: 270_500, currency: "EUR"), "amount is \(buy.amount)")
            try expect(buy.securityGross == Money(minor: 300_000, currency: "USD"), "security gross is \(String(describing: buy.securityGross))")
            return nil
        }
        await step("cross-currency transfer stores the arrived amount") {
            guard let transfer = recorded.first(where: { $0.kind == .cashTransfer }) else { throw Failure("not recorded") }
            try expect(transfer.counterAmount == Money(minor: 108_000, currency: "USD"), "counter amount is \(String(describing: transfer.counterAmount))")
            return nil
        }
        await step("engine: cash balances match what was typed") {
            let snapshot = try await store.compute("selftest.snapshot.\(store.revision)") { [today = options.today] ledger in ledger.snapshot(on: today) }
            for (account, expected) in expectedCash {
                let balance = snapshot.cash(account)?.balance.minor
                try expect(balance == expected, "\(store.account(account)?.name ?? "?"): engine \(balance.map(String.init) ?? "nil"), expected \(expected)")
            }
            return expectedCash.map { "\(store.account($0.key)?.currency ?? "?") \(Fmt.number(Double($0.value) / 100, decimals: 2))" }.sorted().joined(separator: ", ")
        }
        await step("engine: positions per depot match what was typed") {
            let snapshot = try await store.compute("selftest.snapshot.\(store.revision)") { [today = options.today] ledger in ledger.snapshot(on: today) }
            for (name, expected) in expectedShares {
                let parts = name.split(separator: "/").compactMap { UUID(uuidString: String($0)) }
                let held = snapshot.position(parts[0])?.holdings.first { $0.depotID == parts[1] }?.shares.raw ?? 0
                try expect(held == expected, "\(store.security(parts[0])?.name ?? "?") in \(store.depot(parts[1])?.name ?? "?"): engine \(held), expected \(expected)")
            }
            return snapshot.positions.map { "\(store.security($0.securityID)?.name ?? "?") \(Fmt.shares($0.shares))" }.joined(separator: ", ")
        }
        await step("consistency check: no errors (apart from the exchange rate that has not been downloaded yet)") {
            let issues = try await store.consistencyIssues()
            let serious = issues.filter { $0.severity == .error && $0.kind != .missingExchangeRate }
            try expect(serious.isEmpty, serious.prefix(3).map(\.message).joined(separator: " / "))
            return issues.isEmpty ? nil : "\(issues.count) non-error findings (\(Set(issues.map(\.kind.rawValue)).sorted().joined(separator: ", ")))"
        }
        await step("every recorded entry survives “open in the editor, save unchanged”") {
            let unstable = await TransactionsSelfTest.unstableRoundTrips(in: store)
            try expect(unstable.isEmpty, unstable.compactMap { store.transaction($0)?.kind.rawValue }.joined(separator: ", ") + " would change")
            return nil
        }
        _ = await action("edit a transaction's note (transaction editor, edit)") {
            guard let first = recorded.first else { throw Failure("nothing recorded") }
            let edited = try await TransactionsSelfTest.editNote(of: first.id, to: "opening deposit", in: store)
            try expect(store.transaction(first.id)?.note == "opening deposit" && edited.amount == first.amount, "the note was not stored")
            return nil
        }

        // Plans.
        #if canImport(FeaturePlans)
        _ = await action("add a savings plan that started four months ago (plan editor)") {
            let start = options.today.startOfMonth.addingMonths(-4)
            let id = try PlansSelfTest.addSavingsPlan(securityID: equity, amount: 20_000, start: start, in: store)
            return store.plan(id)?.name
        }
        _ = await action("generate due plan transactions (Generate sheet)") {
            let before = store.file.transactions.count
            let outcome = try await PlansSelfTest.generateDue(in: store)
            try expect(outcome.created > 0, "nothing was created (\(outcome.proposed) proposed)")
            try expect(store.file.transactions.count == before + outcome.created, "the ledger grew by \(store.file.transactions.count - before), not \(outcome.created)")
            return "\(outcome.created) created of \(outcome.proposed) proposed"
        }
        #endif

        // Quotes from a stub server, through the real providers, parsers and the store's update flow.
        _ = await action("quote update against a stub HTTP client") {
            let http = StubHTTPClient()
            StubMarket.install(on: http, today: options.today)
            store.quoteUpdater = QuoteUpdater(http: http)
            defer { store.quoteUpdater = nil }
            guard let task = store.updateQuotes() else { throw Failure("no update was started (nothing to do?)") }
            guard let report = await task.value else { throw Failure("the update returned no report") }
            try expect(!report.hasFailures, report.failures.map { "\($0.name): \($0.message)" }.joined(separator: " / "))
            try expect(report.newPrices > 0, "no prices arrived")
            try expect(report.newRates > 0, "no exchange rates arrived")
            try expect(store.security(equity)?.prices.lastDay != nil && store.security(foreign)?.prices.lastDay != nil, "a security has no prices")
            try expect(!store.isUpdatingQuotes && store.activity == nil, "the store still reports an update in progress")
            return "\(report.summary); \(http.requests.count) requests"
        }
        await step("a second quote update finds nothing and leaves the document untouched") {
            let http = StubHTTPClient()
            StubMarket.install(on: http, today: options.today)
            store.quoteUpdater = QuoteUpdater(http: http)
            defer { store.quoteUpdater = nil }
            let before = store.file, revision = store.revision
            if let task = store.updateQuotes(interactive: false) { _ = await task.value }
            try expect(store.file == before && store.revision == revision, "the file changed although nothing new arrived")
            return nil
        }
        await step("engine: the foreign position is valued once rates exist") {
            let snapshot = try await store.compute("selftest.snapshot.\(store.revision)") { [today = options.today] ledger in ledger.snapshot(on: today) }
            guard let position = snapshot.position(foreign) else { throw Failure("no position") }
            try expect(position.isValued && position.value.minor > 0, "valued at \(position.value)")
            try expect(snapshot.cash(usd)?.isValued == true, "the USD account is not valued")
            return "net worth \(Fmt.money(snapshot.totalValue))"
        }

        // Rebalancing.
        #if canImport(FeatureAllocation)
        var taxonomyID: UUID?
        _ = await action("set targets and assign both securities (taxonomy edit)") {
            guard let taxonomy = store.file.taxonomies.first(where: { $0.root.count >= 2 }) else { throw Failure("no taxonomy with two classifications") }
            taxonomyID = taxonomy.id
            try AllocationSelfTest.setEqualTargets(taxonomyID: taxonomy.id, assigning: [equity, foreign], in: store)
            return taxonomy.name
        }
        _ = await action("rebalancing proposal → create transactions (review sheet)") {
            guard let taxonomyID else { throw Failure("no taxonomy") }
            let before = store.file.transactions.count
            let outcome = try await AllocationSelfTest.rebalance(taxonomyID: taxonomyID, investing: 1_000_000, in: store)
            try expect(outcome.created > 0, "the proposal produced no transactions (\(outcome.orders) orders, \(outcome.drafts) drafts)")
            try expect(store.file.transactions.count == before + outcome.created, "the ledger did not grow by \(outcome.created)")
            if let a = outcome.driftBefore, let b = outcome.driftAfter { try expect(b <= a + 1e-9, "drift grew from \(a) to \(b)") }
            return "\(outcome.created) transactions; largest drift \(outcome.driftBefore.map { Fmt.percent($0, decimals: 2) } ?? "–") → \(outcome.driftAfter.map { Fmt.percent($0, decimals: 2) } ?? "–")"
        }
        await step("engine: consistency check still has no errors") {
            let serious = try await store.consistencyIssues().filter { $0.severity == .error }
            try expect(serious.isEmpty, serious.prefix(3).map(\.message).joined(separator: " / "))
            return nil
        }
        #endif

        // Undo everything, redo everything.
        let final = store.file
        await step("undo every step back to the starter (\(history.count - 1) steps), file equal at each") {
            for index in stride(from: history.count - 1, to: 0, by: -1) {
                try expect(undoManager.canUndo, "nothing to undo before “\(names[index])”")
                undoManager.undo()
                try expect(store.file == history[index - 1], "after undoing “\(names[index])” the file differs from the state before it")
                try expect(store.snapshot.current == store.file, "the document mirror is out of date after undo")
            }
            try expect(!undoManager.canUndo, "undo steps remain after reaching the starter")
            return nil
        }
        await step("redo every step, file equal at each") {
            for index in 1..<history.count {
                try expect(undoManager.canRedo, "nothing to redo for “\(names[index])”")
                undoManager.redo()
                try expect(store.file == history[index], "after redoing “\(names[index])” the file differs")
            }
            try expect(store.file == final, "the final file differs")
            return nil
        }
        await step("route focus is dropped when its entity is deleted and restored state stays valid") {
            guard let id = store.file.transactions.last?.id else { throw Failure("no transactions") }
            store.navigate(to: .transaction(id))
            undoManager.beginUndoGrouping()
            store.deleteTransaction(id)
            undoManager.endUndoGrouping()
            try expect(store.route.focus == nil, "the focus still names the deleted transaction")
            undoManager.undo()
            try expect(store.transaction(id) != nil, "undo did not bring the transaction back")
            return nil
        }
        scenarioFile = store.file
        #else
        emit("skipped: needs the Transactions, Accounts and Securities features")
        #endif
    }

    /// The portfolio the scenario built; the document phase and a tour use it.
    private var scenarioFile: PortfolioFile?

    // MARK: - Phase 2: documents

    private func documents() async {
        heading("Documents: write path, read path, save without the main thread")
        let files: [(String, PortfolioFile)] = [
            ("scenario", scenarioFile ?? SampleData.starterPortfolio(name: "Starter", baseCurrency: "EUR")),
            ("demo", SampleData.demoPortfolio(today: options.today)),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kontor-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, file) in files {
            await step("\(name): save through the document's write path, reopen through its read path, compare") {
                let url = directory.appendingPathComponent("\(name).kontor")
                let data = try KontorDocument.write(file)
                try data.write(to: url, options: .atomic)
                let reopened = try KontorDocument.read(Data(contentsOf: url))
                try expect(reopened.file == file, "the reopened file differs from the one saved")
                try expect(reopened.repairs.isEmpty, "the reader repaired something: \(reopened.repairs.summary)")
                try expect(try KontorDocument.write(reopened.file) == data, "saving the reopened file is not byte-identical")
                return "\(Fmt.integer(data.count)) bytes"
            }
        }
        await step("the document's snapshot is taken on a background thread while the main thread waits") {
            // What AppKit does on every save and autosave. Hopping to the main thread here would
            // deadlock; the watchdog turns that into a failure.
            let document = KontorDocument(file: files[0].1)
            let store = document.store
            store.mutate("Edit") { $0.name = "Snapshot Test" }
            guard let snapshot = Self.snapshotWhileMainThreadWaits(document) else {
                throw Failure("snapshot() did not return while the main thread was blocked (deadlock)")
            }
            try expect(snapshot.name == "Snapshot Test", "the snapshot does not contain the latest edit")
            return nil
        }
        await step("files that are not portfolios are refused") {
            for text in ["{}", "{\"name\":\"left-pad\",\"version\":\"1.0.0\"}", "{\"formatVersion\":1,\"transactions\":null}",
                         "{\"formatVersion\":1,\"Transactions\":[]}", "{\"formatVersion\":0,\"transactions\":[]}", "[]", ""] {
                let opened = (try? KontorDocument.read(Data(text.utf8))) != nil
                try expect(!opened, "“\(text)” opened as a portfolio")
            }
            try expect((try? KontorDocument.read(Data("{\"formatVersion\":1}".utf8))) != nil, "a minimal valid document was refused")
            return nil
        }
        await step("a file with a zero exchange rate opens repaired and can be saved after a quote update") {
            var file = SampleData.starterPortfolio(name: "Rates", baseCurrency: "USD")
            file.exchangeRates = [ExchangeRateSeries(base: "EUR", quote: "USD", days: [20_000, 20_001], rates: [1.1, 0])]
            file.accounts.append(Account(name: "Euro", currency: "EUR"))
            // As it would arrive from disk (the encoder accepts 0).
            let opened = try KontorDocument.read(try file.encoded())
            try expect(opened.repairs.droppedRates == 1, "dropped \(opened.repairs.droppedRates) rates")
            var updated = opened.file
            ExchangeRates.refreshCrossRates(in: &updated)
            _ = try KontorDocument.write(updated)
            // And a file that got a non-finite number at runtime is still saved.
            var broken = file
            broken.exchangeRates[0].rates = [1.1, .infinity]
            broken.settings.riskFreeRate = .nan
            let data = try KontorDocument.write(broken)
            try expect(try KontorDocument.read(data).file.exchangeRates[0].rates == [1.1], "the non-finite rate was written")
            return nil
        }
        await step("undo depth is bounded by the size of the document") {
            let small = PortfolioStore.undoLevels(for: files[1].1)
            let large = PortfolioStore.undoLevels(for: SampleData.stressPortfolio(securities: 5, years: 2, transactions: 50_000, endingOn: options.today))
            try expect(small == 100, "demo portfolio keeps \(small) levels")
            try expect(large >= 10 && large < 30, "a 50,000-transaction portfolio keeps \(large) levels")
            let (store, undoManager) = makeStore(files[1].1)
            try expect(undoManager.levelsOfUndo == small, "the undo manager was not configured (\(undoManager.levelsOfUndo))")
            _ = store
            return "\(small) levels for the demo, \(large) for 50,000 transactions"
        }
    }

    /// Blocks the calling (main) thread like AppKit does during a save, and takes the document's
    /// snapshot on a background thread meanwhile. nil if that does not finish (a deadlock).
    private nonisolated static func snapshotWhileMainThreadWaits(_ document: KontorDocument) -> PortfolioFile? {
        let box = SnapshotBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.set(try? document.snapshot(contentType: .kontorPortfolio))
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { return nil }
        return box.value
    }

    // MARK: - Phase 3: import and export

    private func imports() async {
        heading("Import and export")
        #if canImport(FeatureImport)
        let demo = SampleData.demoPortfolio(today: options.today)
        await step("Portfolio Performance XML (exported from the demo) → Import into This Portfolio") {
            let export = PortfolioPerformanceExporter.export(demo)
            let (store, undoManager) = makeStore(SampleData.starterPortfolio(name: "Imported", baseCurrency: "EUR"))
            let outcome = try await ImportSelfTest.importPortfolioPerformance(export.data, fileName: "demo.xml", in: store)
            try expect(store.file.transactions.count == demo.transactions.count, "\(store.file.transactions.count) transactions, the demo has \(demo.transactions.count)")
            try expect(store.file.securities.count == demo.securities.count, "\(store.file.securities.count) securities, the demo has \(demo.securities.count)")
            try await compareBalances(store.file, demo, label: "imported")
            undoManager.undo()
            try expect(store.file.transactions.isEmpty, "undo did not take the import back")
            return "\(outcome.transactions) transactions, \(outcome.securities) securities, \(outcome.detail)"
        }
        await step("Portfolio Performance XML → Merge into a portfolio that already has data (twice)") {
            var half = demo
            half.transactions = Array(demo.transactions.prefix(demo.transactions.count / 2))
            let export = PortfolioPerformanceExporter.export(demo)
            let (store, _) = makeStore(half)
            let outcome = try await ImportSelfTest.importPortfolioPerformance(export.data, fileName: "demo.xml", in: store)
            try expect(store.file.transactions.count == demo.transactions.count, "\(store.file.transactions.count) transactions after merging, the demo has \(demo.transactions.count)")
            try expect(store.file.securities.count == demo.securities.count, "\(store.file.securities.count) securities after merging")
            return outcome.detail
        }
        await step("CSV (exported from the demo) → wizard with automatic mapping → Import; second import adds nothing") {
            let data = CSVExporter.data(CSVExporter.transactions(demo))
            var empty = SampleData.starterPortfolio(name: "CSV", baseCurrency: demo.settings.baseCurrency)
            empty.accounts = []
            empty.depots = []
            let (store, undoManager) = makeStore(empty)
            let outcome = try await ImportSelfTest.importCSV(data, fileName: "transactions.csv", in: store)
            try expect(outcome.transactions == demo.transactions.count, "\(outcome.transactions) of \(demo.transactions.count) transactions were imported")
            try await compareBalances(store.file, demo, label: "imported")
            undoManager.undo()
            try expect(store.file.transactions.isEmpty, "undo did not take the import back")
            return "\(outcome.transactions) transactions, \(outcome.securities) securities"
        }
        await step("CSV export → import reproduces the ledger (kinds, dates, accounts, depots, amounts)") {
            let result = ImportSelfTest.csvRoundTrip(demo)
            try expect(result.imported == result.exported, "\(result.imported) of \(result.exported) transactions came back")
            try expect(result.differing == 0, "\(result.differing) transactions differ, e.g. \(result.firstDifference ?? "?")")
            return "\(result.exported) transactions"
        }
        if let scenarioFile {
            await step("the scenario portfolio survives Portfolio Performance export → import") {
                let export = PortfolioPerformanceExporter.export(scenarioFile)
                let imported = try PortfolioPerformanceImporter.read(export.data, name: scenarioFile.name)
                try expect(imported.file.transactions.count == scenarioFile.transactions.count, "\(imported.file.transactions.count) of \(scenarioFile.transactions.count) transactions")
                try await compareBalances(imported.file, scenarioFile, label: "re-imported")
                return nil
            }
        }
        if let path = options.fixtures {
            let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let urls = ((try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []).sorted().map { directory.appendingPathComponent($0) }
            let xml = urls.filter { ["xml", "portfolio"].contains($0.pathExtension.lowercased()) }
            if xml.isEmpty { emit("note: no .xml fixtures under \(directory.path)") }
            for url in xml {
                await step("fixture \(url.lastPathComponent): import, analyse") {
                    let data = try Data(contentsOf: url)
                    let (store, _) = makeStore(SampleData.starterPortfolio(name: "Fixture", baseCurrency: "EUR"))
                    do {
                        let outcome = try await ImportSelfTest.importPortfolioPerformance(data, fileName: url.lastPathComponent, in: store)
                        // The engine must cope with whatever came in.
                        let today = options.today
                        let figures = try await store.compute("selftest.fixture.\(url.lastPathComponent)") { ledger in
                            let snapshot = ledger.snapshot(on: today)
                            let shorts = ledger.trades(on: today).closed.count { $0.isShort }
                            return (snapshot.totalValue, snapshot.costBasis, shorts)
                        }
                        return "\(outcome.transactions) transactions, \(outcome.securities) securities, \(outcome.warnings) warnings, value \(Fmt.money(figures.0)), cost basis \(Fmt.money(figures.1)), \(figures.2) short trades"
                    } catch let failure as SelfTestFailure where failure.description.contains("was not recognised") {
                        // Encrypted, binary or deliberately broken fixtures are refused with advice: fine.
                        return "refused (not a readable Portfolio Performance XML)"
                    }
                }
            }
        }
        #else
        emit("skipped: needs the Import feature")
        #endif
    }

    /// Cash balances per account name and shares per security name must agree between two files.
    private func compareBalances(_ a: PortfolioFile, _ b: PortfolioFile, label: String) async throws {
        let today = options.today
        let (left, right) = await Task.detached { (Self.balanceFigures(a, on: today), Self.balanceFigures(b, on: today)) }.value
        let differing = Set(left.keys).union(right.keys).filter { left[$0] != right[$0] }.sorted()
        try expect(differing.isEmpty, "\(label) balances differ for \(differing.prefix(4).joined(separator: ", "))")
    }

    private nonisolated static func balanceFigures(_ file: PortfolioFile, on today: Day) -> [String: Int64] {
        let snapshot = Ledger(file).snapshot(on: today)
        var result: [String: Int64] = [:]
        for cash in snapshot.cash { result["cash:" + (file.accounts.first { $0.id == cash.accountID }?.name ?? "?"), default: 0] += cash.balance.minor }
        for position in snapshot.positions { result["shares:" + (file.securities.first { $0.id == position.securityID }?.name ?? "?"), default: 0] += position.shares.raw }
        return result.filter { $0.value != 0 }
    }

    // MARK: - Phase 4: the hosted UI

    enum Depth { case full, light }

    /// Launch-state variants per screen (`--state` keys the screens document): every sub-view.
    private static let variants: [AppScreen: [[String: String]]] = [
        .dashboard: [[:], ["edit": "1"]],
        .holdings: [[:], ["view": "treemap"], ["view": "concentration"], ["group": "depot", "closed": "on"], ["group": "taxonomy", "collapse": "all"], ["select": "first", "cash": "off"]],
        .performance: [[:], ["tab": "returns", "chart": "value"], ["tab": "risk", "chart": "drawdown", "distribution": "monthly"], ["tab": "securities"], ["tab": "calculation", "line": "dividends"]],
        .allocation: [[:], ["view": "sunburst"], ["view": "treemap"], ["view": "bars"], ["tab": "edit", "pool": "all"], ["tab": "rebalancing", "cash": "5000"], ["tab": "rebalancing", "mode": "orders", "cash": "-2500", "whole": "off"]],
        .earnings: [[:], ["view": "matrix"], ["view": "securities", "metric": "net"], ["view": "accounts", "metric": "interest"], ["view": "payments"], ["view": "calendar"], ["metric": "fees", "group": "year", "range": "period"]],
        .trades: [[:], ["tab": "open", "chart": "distribution"], ["tab": "years"], ["tab": "closed", "chart": "cumulative", "selection": "first"], ["tab": "closed", "chart": "holding", "outcome": "losers"]],
        .securities: [["security": "first"], ["security": "first", "tab": "transactions"], ["security": "first", "tab": "prices"], ["security": "first", "tab": "events"], ["security": "first", "tab": "source"], ["security": "first", "tab": "notes"], ["selection": "multi"], ["selection": "none", "filter": "held"]],
        .transactions: [[:], ["filter": "trades"], ["filter": "issues"], ["dates": "period", "sort": "amount:desc"], ["selection": "3"]],
        .accounts: [[:], ["account": "first"], ["depot": "first"], ["depot": "first", "tab": "transactions", "range": "all"], ["retired": "shown"]],
        .plans: [[:], ["tab": "projection"], ["tab": "projection", "start": "zero", "years": "30", "include": "all"], ["plan": "last"]],
        .import: [[:], ["drop": "on"]],
    ]

    private func tour(_ label: String, file: PortfolioFile, depth: Depth) async {
        heading("Hosted UI: \(label) portfolio (\(Fmt.integer(file.transactions.count)) transactions, \(Fmt.integer(file.securities.count)) securities)")
        let (store, _) = makeStore(file)
        let window = HiddenWindow(content: MainWindowView(store: store, registry: registry), title: file.name.isEmpty ? label : file.name)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(300))

        /// Waits until the screen has its data and forces a layout and display pass.
        func settle(_ what: String) async throws {
            guard await store.waitUntilSettled(quietPeriod: .milliseconds(120), timeout: .seconds(90)) != nil else {
                throw Failure("\(what) did not settle within 90 s")
            }
            window.flush()
        }
        func show(_ route: Route, state: [String: String] = [:]) async throws {
            store.launchState = state
            // Leaving and re-entering recreates the screen, so that it reads its launch state again.
            if store.route.screen == route.screen {
                store.navigate(to: route.screen == .import ? .dashboard : .import)
                try await settle("leaving \(route.screen.rawValue)")
            }
            store.navigate(to: route)
            try await settle(route.stringValue)
            store.launchState = [:]
        }

        func part(_ name: String) -> Bool { options.parts?.contains(name) ?? true }

        // Every screen, every documented sub-view.
        let rounds = depth == .full ? (Self.variants.values.map(\.count).max() ?? 1) : 2
        for round in 0..<(part("screens") ? rounds : 0) {
            for screen in AppScreen.allCases {
                guard let variant = Self.variants[screen].flatMap({ round < $0.count ? $0[round] : nil }) else { continue }
                let description = variant.isEmpty ? "default" : variant.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                await step("\(label) ▸ \(screen.title) (\(description))") {
                    store.isInspectorPresented = round % 2 == 1
                    try await show(Route(screen), state: variant)
                    return nil
                }
            }
        }
        store.isInspectorPresented = false

        // Reporting period and scope on every screen.
        let depot = file.depots.first?.id, account = file.accounts.first?.id
        let classification: ScopeSelection? = file.taxonomies.lazy.compactMap { taxonomy in
            taxonomy.flattened.first { !$0.classification.assignments.isEmpty }.map { .classification(taxonomy: taxonomy.id, id: $0.classification.id) }
        }.first
        let periods: [ReportingPeriod] = depth == .full
            ? [.ytd, .allTime, .monthToDate, .year(options.today.year - 1), .custom(from: options.today.advanced(by: -45), to: options.today.advanced(by: -10)), .lastYears(1)]
            : [.allTime, .lastYears(1)]
        var scopes: [ScopeSelection] = []
        if let depot { scopes.append(.depot(depot)) }
        if depth == .full, let account { scopes.append(.account(account)) }
        if depth == .full, let classification { scopes.append(classification) }
        scopes.append(.portfolio)
        for screen in AppScreen.allCases where part("periods") {
            await step("\(label) ▸ \(screen.title): \(periods.count) periods, \(scopes.count) scopes") {
                try await show(Route(screen))
                for period in periods {
                    store.period = period
                    try await settle("\(screen.rawValue) with period \(period.code)")
                }
                for scope in scopes {
                    store.scopeSelection = scope
                    try await settle("\(screen.rawValue) with scope \(scope.stringValue)")
                }
                return nil
            }
        }

        // Deep links, with the inspector following.
        var routes: [Route] = []
        if let security = file.securities.first?.id {
            routes += [.security(security), Route(.performance, focus: .security(security)), Route(.trades, focus: .security(security)),
                       Route(.transactions, focus: .security(security)), Route(.holdings, focus: .security(security)), Route(.earnings, focus: .security(security))]
        }
        if let account { routes += [.account(account), Route(.transactions, focus: .account(account)), Route(.holdings, focus: .account(account))] }
        if let depot { routes += [.depot(depot), Route(.transactions, focus: .depot(depot))] }
        if let transaction = file.transactions.last?.id { routes += [.transaction(transaction), Route(.trades, focus: .transaction(transaction))] }
        if let plan = file.plans.first?.id { routes.append(.plan(plan)) }
        if let taxonomy = file.taxonomies.first {
            routes.append(.taxonomy(taxonomy.id))
            if let node = taxonomy.flattened.first { routes.append(.classification(taxonomy: taxonomy.id, id: node.classification.id)) }
        }
        if !part("links") { routes = [] }
        store.isInspectorPresented = true
        for route in routes {
            await step("\(label) ▸ deep link \(Self.describe(route)) with the inspector open") {
                store.navigate(to: route)
                try await settle(route.stringValue)
                try expect(store.route == route, "\(route.stringValue) was rewritten to \(store.route.stringValue)")
                return nil
            }
        }
        if !routes.isEmpty {
            await step("\(label) ▸ back through the history and forward again") {
                var steps = 0
                while store.canGoBack {
                    store.goBack()
                    steps += 1
                    if depth == .full { try await settle("back to \(store.route.stringValue)") }
                }
                while store.canGoForward {
                    store.goForward()
                    if depth == .full { try await settle("forward to \(store.route.stringValue)") }
                }
                try await settle("history")
                return "\(steps) entries"
            }
        }
        store.isInspectorPresented = false

        // Every sheet request.
        try? await show(Route(.dashboard))
        for (name, request, mustAppear) in sheetRequests(for: file, depth: depth) where part("sheets") {
            await step("\(label) ▸ sheet \(name)") {
                store.present(request)
                let appeared = await window.waitForSheet(present: true, timeout: 6)
                if !appeared {
                    let dismissedItself = store.sheet == nil
                    if store.sheet != nil { store.dismissSheet() }
                    if mustAppear || !dismissedItself { throw Failure("the sheet was not presented") }
                    return "closed itself (nothing to show for this portfolio)"
                }
                try await settle("sheet \(name)")
                try? await Task.sleep(for: .milliseconds(150))
                window.flush()
                if store.sheet != nil { store.dismissSheet() }
                guard await window.waitForSheet(present: false, timeout: 6) else { throw Failure("the sheet did not close") }
                try expect(store.sheet == nil, "another sheet was queued behind it: \(String(describing: store.sheet))")
                return nil
            }
        }

        // The floating layers of the shell.
        if part("layers") { await step("\(label) ▸ command palette, quote report, toast, confirmation") {
            store.openCommandPalette(query: "div")
            try await settle("palette")
            try? await Task.sleep(for: .milliseconds(200))
            let commands = registry.commands(for: store)
            try expect(file.transactions.isEmpty || !commands.isEmpty, "no feature contributed palette commands")
            store.isCommandPalettePresented = false
            store.presentQuoteReport(QuoteUpdateReport(targetCount: 3, newPrices: 4, failures: [.init(securityID: file.securities.first?.id, name: "Example", message: "The symbol was not found.")]))
            try? await Task.sleep(for: .milliseconds(400))
            store.isQuoteReportPresented = false
            store.toast("Self-test", message: "A toast", style: .success)
            store.confirm(ConfirmationRequest(title: "Delete?", message: "A confirmation.") {})
            try? await Task.sleep(for: .milliseconds(500))
            store.confirmation = nil
            try? await Task.sleep(for: .milliseconds(400))
            window.flush()
            return "\(commands.count) palette commands"
        } }

        // Editing while screens are mounted: every screen must follow a document change and an undo.
        if depth == .full, let account, part("edits") {
            await step("\(label) ▸ every screen follows an edit and its undo") {
                for screen in AppScreen.allCases {
                    try await show(Route(screen))
                    let currency = store.account(account)?.currency ?? "EUR"
                    store.addTransaction(Transaction(kind: .deposit, date: options.today, accountID: account, amount: Money(minor: 12_300, currency: currency), note: "self-test"))
                    try await settle("\(screen.rawValue) after an edit")
                    store.undoManager?.undo()
                    try await settle("\(screen.rawValue) after undo")
                }
                try expect(store.file == file, "the file differs after edit + undo on every screen")
                return nil
            }
        }
    }

    /// "securities/security", "transactions/account" — a route without its ids.
    private static func describe(_ route: Route) -> String {
        let focus = route.stringValue.split(separator: "/").dropFirst().first.map { String($0.prefix { $0 != ":" }) }
        return route.screen.rawValue + (focus.map { "/" + $0 } ?? "")
    }

    private func sheetRequests(for file: PortfolioFile, depth: Depth) -> [(String, SheetRequest, Bool)] {
        var result: [(String, SheetRequest, Bool)] = []
        result.append(("portfolio-settings", .portfolioSettings, true))
        let kinds = depth == .full ? Transaction.Kind.allCases : [.buy, .dividend, .cashTransfer]
        for kind in kinds { result.append(("new-transaction:\(kind.rawValue)", .newTransaction(TransactionPrefill(kind: kind)), true)) }
        var seen = Set<Transaction.Kind>()
        for transaction in file.transactions where seen.insert(transaction.kind).inserted && (depth == .full || seen.count <= 3) {
            result.append(("edit-transaction (\(transaction.kind.rawValue))", .editTransaction(transaction.id), true))
        }
        result.append(("new-security", .newSecurity, true))
        if let id = file.securities.first?.id { result.append(("edit-security", .editSecurity(id), true)) }
        result.append(("new-account", .newAccount, true))
        if let id = file.accounts.first?.id { result.append(("edit-account", .editAccount(id), true)) }
        result.append(("new-depot", .newDepot, true))
        if let id = file.depots.first?.id { result.append(("edit-depot", .editDepot(id), true)) }
        for kind in InvestmentPlan.Kind.allCases { result.append(("new-plan (\(kind.rawValue))", .newPlan(PlanPrefill(kind: kind)), true)) }
        if let id = file.plans.first?.id { result.append(("edit-plan", .editPlan(id), true)) }
        result.append(("import", .importFile(nil), true))
        result.append(("export", .export, true))
        result.append(("export:transactions", .export(ExportRequest(.transactions())), true))
        result.append(("export:securities", .export(ExportRequest(.securities)), true))
        if let id = file.securities.first?.id { result.append(("export:quotes", .export(ExportRequest(.quotes(securityID: id))), true)) }
        result.append(("consistency", .consistencyReport, true))
        // Feature-private sheets; some have nothing to show for an empty portfolio and close themselves.
        result.append(("custom:dashboard.gallery", .custom(id: "dashboard.gallery"), false))
        result.append(("custom:dashboard.widget", .custom(id: "dashboard.widget", payload: ["widget": "first"]), false))
        result.append(("custom:plans.generate", .custom(id: "plans.generate"), false))
        result.append(("custom:import.export", .custom(id: "import.export"), false))
        result.append(("custom:import.file", .custom(id: "import.file"), false))
        result.append(("custom:transactions.change-date", .custom(id: "transactions.change-date", payload: ["count": "3"]), false))
        if let id = file.securities.first?.id {
            result.append(("custom:securities.split", .custom(id: "securities.split", payload: ["security": id.uuidString, "ratio": "2:1"]), false))
        }
        if let taxonomy = file.taxonomies.first {
            result.append(("custom:allocation.rebalance-review", .custom(id: "allocation.rebalance-review", payload: ["taxonomy": taxonomy.id.uuidString, "amount": "500000"]), false))
            if let id = file.securities.first?.id {
                result.append(("custom:allocation.split", .custom(id: "allocation.split", payload: ["taxonomy": taxonomy.id.uuidString, "vehicle": "s:\(id.uuidString)"]), false))
            }
        }
        return result
    }

    // MARK: - Logs

    private func scanLogs() async {
        heading("Runtime warnings")
        // Give late log messages a moment to arrive.
        try? await Task.sleep(for: .milliseconds(300))
        let stderrText = capture.finish()
        let stderrLines = stderrText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let unified = capture.unifiedLog()
        var entries: [(date: Date?, text: String)] = stderrLines.map { (LogCapture.date(ofStderrLine: $0), $0) }
        entries += unified.map { ($0.date, $0.text) }
        let spans = spans
        await step("nothing the app logged is a runtime warning (\(stderrLines.count) stderr lines, \(unified.count) log entries)") {
            var found: [String: (count: Int, example: String, steps: [String])] = [:]
            for entry in entries {
                guard !LogCapture.expected.contains(where: { entry.text.contains($0) }),
                      let pattern = LogCapture.patterns.first(where: { entry.text.localizedCaseInsensitiveContains($0.needle) }) else { continue }
                var record = found[pattern.meaning] ?? (0, entry.text, [])
                record.count += 1
                if let date = entry.date {
                    // The step that was running, or the one that had just finished.
                    let name = spans.last { $0.start <= date && date <= $0.end.addingTimeInterval(0.25) }?.name ?? spans.last { $0.end <= date }?.name
                    if let name, !record.steps.contains(name), record.steps.count < 12 { record.steps.append(name) }
                }
                found[pattern.meaning] = record
            }
            if !found.isEmpty {
                let text = found.sorted { $0.key < $1.key }.map {
                    "\($0.value.count)× \($0.key) — e.g. “\($0.value.example.prefix(260))”\n       during: " + ($0.value.steps.isEmpty ? "?" : $0.value.steps.joined(separator: " | "))
                }.joined(separator: "\n     ")
                throw Failure("\n     " + text)
            }
            return nil
        }
        if options.verbose || failures > 0 {
            let other = stderrLines.filter { line in !LogCapture.patterns.contains { line.localizedCaseInsensitiveContains($0.needle) } }
            if !other.isEmpty {
                emit("other stderr output (\(other.count) lines, first 40):")
                for line in Array(Set(other)).sorted().prefix(40) { emit("     \(line.prefix(300))") }
            }
        }
    }
}

/// Carries a value out of a background closure.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PortfolioFile?
    var value: PortfolioFile? { lock.withLock { stored } }
    func set(_ file: PortfolioFile?) { lock.withLock { stored = file } }
}

// MARK: - Hidden window

/// A real window that hosts real views but is never seen: it sits below the desktop picture, is
/// never key and the process is never activated (the same technique as the screenshot mode).
@MainActor
final class HiddenWindow {
    let window: NSWindow

    init(content: some View, title: String, size: CGSize = CGSize(width: 1280, height: 800)) {
        let window = ShotWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.animationBehavior = .none
        window.toolbarStyle = .unified
        let host = NSHostingController(rootView: AnyView(content))
        host.sceneBridgingOptions = .all
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: visible.minX + 20, y: max(visible.minY, visible.maxY - window.frame.height - 20)))
        }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.orderBack(nil)
        self.window = window
    }

    /// Forces pending layout and drawing, so that layout problems happen now and not later.
    func flush() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        window.attachedSheet?.layoutIfNeeded()
        window.attachedSheet?.displayIfNeeded()
        CATransaction.flush()
    }

    func waitForSheet(present: Bool, timeout: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while (window.attachedSheet != nil) != present {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
    }
}

// MARK: - Stub market data

/// Canned answers of Yahoo Finance and the ECB for the self-test's stub HTTP client: generated for
/// whatever range is requested, so the real providers and parsers run without a network.
enum StubMarket {
    static func install(on http: StubHTTPClient, today: Day) {
        http.on("/v8/finance/chart/") { request in
            let url = request.url
            let symbol = url.lastPathComponent
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let from = items.first { $0.name == "period1" }?.value.flatMap(Int64.init) ?? Int64(today.rawValue - 30) * 86_400
            let to = min(items.first { $0.name == "period2" }?.value.flatMap(Int64.init) ?? Int64(today.rawValue + 1) * 86_400, Int64(today.rawValue + 1) * 86_400)
            var timestamps: [Int64] = []
            var closes: [Double] = []
            var day = Int32(from / 86_400) + 1
            let base = symbol == "SELFUS" ? 150.0 : 50.0
            while Int64(day) * 86_400 < to, day <= today.rawValue {
                if !Day(rawValue: day).isWeekend {
                    timestamps.append(Int64(day) * 86_400 + 16 * 3_600)
                    closes.append(((base * (1 + 0.1 * sin(Double(day) / 9))) * 100).rounded() / 100)
                }
                day += 1
            }
            let currency = symbol == "SELFUS" ? "USD" : "EUR"
            let numbers = closes.map { String($0) }.joined(separator: ",")
            let body = """
            {"chart":{"result":[{"meta":{"currency":"\(currency)","symbol":"\(symbol)","exchangeName":"STB","instrumentType":"EQUITY",\
            "gmtoffset":0,"timezone":"UTC","exchangeTimezoneName":"UTC","regularMarketPrice":\(closes.last ?? base),"dataGranularity":"1d"},\
            "timestamp":[\(timestamps.map(String.init).joined(separator: ","))],\
            "indicators":{"quote":[{"close":[\(numbers)],"open":[\(numbers)],"high":[\(numbers)],"low":[\(numbers)]}],"adjclose":[{"adjclose":[\(numbers)]}]}}],"error":null}}
            """
            return HTTPResponse(status: 200, body: Data(body.utf8))
        }
        // One generated history serves the daily, 90-day and full ECB files.
        var cubes = ""
        var day = today
        var written = 0
        while written < 400 {
            if !day.isWeekend {
                let usd = 1.08 + 0.02 * sin(Double(day.rawValue) / 20)
                cubes += "<Cube time='\(day.iso)'><Cube currency='USD' rate='\(String(format: "%.4f", usd))'/><Cube currency='GBP' rate='0.8500'/><Cube currency='CHF' rate='0.9500'/></Cube>\n"
                written += 1
            }
            day = day.advanced(by: -1)
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
        <gesmes:subject>Reference rates</gesmes:subject><gesmes:Sender><gesmes:name>European Central Bank</gesmes:name></gesmes:Sender>
        <Cube>
        \(cubes)</Cube>
        </gesmes:Envelope>
        """
        http.on("eurofxref", text: xml)
    }
}
