import Foundation
import Testing
import KontorModel
import KontorEngine
import KontorMarketData
import KontorSampleData
@testable import KontorUI

private let fixedToday = Day(year: 2026, month: 6, day: 30)

/// Counts how often a computation really ran.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
private func demoStore() -> PortfolioStore {
    PortfolioStore(file: SampleData.demoPortfolio(today: fixedToday), today: fixedToday)
}

@Suite @MainActor struct AnalysisCacheTests {
    @Test func missThenHit() async throws {
        let store = demoStore()
        let runs = Counter()
        let work: @Sendable (Ledger) -> Int = { ledger in
            runs.increment()
            return ledger.transactions.count
        }
        let first = try await store.compute("count", work)
        let second = try await store.compute("count", work)
        #expect(first == store.file.transactions.count && second == first)
        #expect(runs.count == 1)
        let stats = store.analysisCache.statistics
        #expect(stats.misses == 1 && stats.hits == 1 && stats.computed == 1 && stats.ledgersBuilt == 1)

        // Another key — or the same key with another result type — is a different entry.
        _ = try await store.compute("other", work)
        let asString = try await store.compute("count") { ledger in String(ledger.transactions.count) }
        #expect(asString == String(first))
        #expect(runs.count == 2)
        #expect(store.analysisCache.statistics.misses == 3)
        #expect(store.analysisCache.statistics.ledgersBuilt == 1) // one ledger for all of them
        #expect(!store.isBusy)
    }

    @Test func concurrentRequestsShareOneComputation() async throws {
        let store = demoStore()
        let runs = Counter()
        let work: @Sendable (Ledger) -> Int = { _ in
            runs.increment()
            Thread.sleep(forTimeInterval: 0.15)
            return 42
        }
        async let a = store.compute("slow", work)
        async let b = store.compute("slow", work)
        async let c = store.compute("slow", work)
        // While they are pending the store is busy (the screenshot mode waits on this).
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.isBusy)
        let results = try await [a, b, c]
        #expect(results == [42, 42, 42])
        #expect(runs.count == 1)
        let stats = store.analysisCache.statistics
        #expect(stats.misses == 1 && stats.joins == 2 && stats.computed == 1)
        #expect(!store.isBusy && store.analysisCache.inFlightCount == 0)
    }

    @Test func documentChangeInvalidatesAndCancelsStaleWork() async throws {
        let store = demoStore()
        let runs = Counter()
        _ = try await store.compute("count") { ledger in
            runs.increment()
            return ledger.transactions.count
        }

        // Work in flight for the old revision …
        let stale = Task { try await store.compute("slow") { _ in
            Thread.sleep(forTimeInterval: 0.25)
            return "old"
        } }
        try await Task.sleep(for: .milliseconds(60))

        // … then the document changes.
        let before = store.file.transactions.count
        store.mutate("Remove") { $0.transactions.removeLast() }
        let fresh = try await store.compute("count") { ledger in
            runs.increment()
            return ledger.transactions.count
        }
        #expect(fresh == before - 1)
        #expect(runs.count == 2) // recomputed, not served from the old revision

        // The stale request does not deliver a value computed from the old document.
        await #expect(throws: CancellationError.self) { try await stale.value }
        let stats = store.analysisCache.statistics
        #expect(stats.invalidations == 1)
        #expect(stats.ledgersBuilt == 2)

        // Undo restores the content but is a new revision: recomputed again, then cached.
        let cachedBefore = store.analysisCache.statistics.hits
        _ = try await store.compute("count") { ledger in ledger.transactions.count }
        #expect(store.analysisCache.statistics.hits == cachedBefore + 1)
        #expect(!store.isBusy)
    }

    @Test func cancelledRequestDoesNotStartItsWork() async throws {
        // A file big enough that building the ledger takes a moment: the work is still queued
        // behind it when the only requester goes away.
        let file = SampleData.stressPortfolio(securities: 40, years: 10, transactions: 20_000)
        let store = PortfolioStore(file: file, today: SampleData.stressEndDay)
        let runs = Counter()
        let task = Task { try await store.compute("never") { _ in
            runs.increment()
            return 1
        } }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Give the detached work a chance to (wrongly) run.
        _ = await store.ledgerOffMain()
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.count == 0)
        #expect(store.analysisCache.statistics.cancelled == 1)
        #expect(store.analysisCache.inFlightCount == 0)

        // A later request for the same key computes normally.
        #expect(try await store.compute("never") { _ in runs.increment(); return 1 } == 1)
        #expect(runs.count == 1 && !store.isBusy)
    }

    @Test func oneWaiterLeavingDoesNotCancelTheOthers() async throws {
        let store = demoStore()
        let runs = Counter()
        let work: @Sendable (Ledger) -> Int = { _ in
            runs.increment()
            Thread.sleep(forTimeInterval: 0.15)
            return 7
        }
        let leaving = Task { try await store.compute("shared", work) }
        let staying = Task { try await store.compute("shared", work) }
        try await Task.sleep(for: .milliseconds(40))
        leaving.cancel()
        #expect(try await staying.value == 7)
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(runs.count == 1)
    }

    @Test func synchronousLedgerIsSharedWithTheAsyncLayer() async throws {
        let store = demoStore()
        let ledger = store.ledger
        #expect(ledger.transactions.count == store.file.transactions.count)
        _ = store.ledger
        _ = try await store.compute("x") { $0.securities.count }
        _ = await store.ledgerOffMain()
        #expect(store.analysisCache.statistics.ledgersBuilt == 1)

        store.mutate("Rename") { $0.name = "Changed" }
        #expect(store.ledger.name == "Changed")
        #expect(store.analysisCache.statistics.ledgersBuilt == 2)
    }

    @Test func analyzeSharesTheFacadePerScopeAndInterval() async throws {
        let store = demoStore()
        store.period = .lastYears(1)
        let first = try await store.analyze("a.total") { analysis in (ObjectIdentifier(analysis), analysis.snapshot.totalValue.minor) }
        let second = try await store.analyze("b.ttwror") { analysis in (ObjectIdentifier(analysis), analysis.interval) }
        #expect(first.0 == second.0) // the same Analysis object → shared intermediates
        #expect(second.1 == store.periodInterval)
        #expect(first.1 > 0)

        // The result matches a direct engine call.
        let direct = Ledger(store.file).snapshot(on: fixedToday).totalValue.minor
        #expect(first.1 == direct)

        // Another period or scope → another facade and another cache entry.
        store.period = .ytd
        let ytd = try await store.analyze("a.total") { analysis in (ObjectIdentifier(analysis), analysis.interval) }
        #expect(ytd.0 != first.0 && ytd.1 == store.periodInterval)
        let depot = store.file.depots[0].id
        store.scopeSelection = .depot(depot)
        let scoped = try await store.analyze("a.total") { analysis in analysis.snapshot.totalValue.minor }
        #expect(scoped == Ledger(store.file).snapshot(on: fixedToday, scope: .depot(depot)).totalValue.minor)
        #expect(scoped < first.1)

        // Variants are part of the key.
        let runs = Counter()
        for variant in [1, 2, 1] {
            _ = try await store.analyze("v", variant: variant) { _ in runs.increment(); return variant }
        }
        #expect(runs.count == 2)

        // store.analysis(...) hands out the shared facade.
        let facade = await store.analysis()
        let again = try await store.analyze("identity") { ObjectIdentifier($0) }
        #expect(ObjectIdentifier(facade) == again)
    }

    @Test func leastRecentlyUsedEntriesAreEvicted() async throws {
        let cache = AnalysisCache(capacity: 2)
        let file = SampleData.starterPortfolio(name: "x", baseCurrency: "EUR")
        let runs = Counter()
        func get(_ key: String) async throws -> String {
            try await cache.value(revision: 1, file: file, key: key) { _ in runs.increment(); return key }
        }
        _ = try await get("a")
        _ = try await get("b")
        _ = try await get("a") // a is now the most recent
        _ = try await get("c") // evicts b
        #expect(runs.count == 3)
        _ = try await get("a")
        #expect(runs.count == 3)
        _ = try await get("b")
        #expect(runs.count == 4)

        // Errors thrown by the work are passed on and not cached.
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await cache.value(revision: 1, file: file, key: "boom") { _ -> Int in throw Boom() } }
        #expect(try await cache.value(revision: 1, file: file, key: "boom") { _ in 5 } == 5)
        #expect(cache.inFlightCount == 0)

        // A request from an older revision never poisons a newer cache.
        _ = try await cache.value(revision: 2, file: file, key: "a") { _ in "new" }
        await #expect(throws: CancellationError.self) { try await cache.value(revision: 1, file: file, key: "a") { _ in "old" } }
        #expect(try await cache.value(revision: 2, file: file, key: "a") { _ in "recomputed" } == "new")
    }

    @Test func consistencyCheckRunsThroughTheCache() async throws {
        let store = demoStore()
        let issues = try await store.consistencyIssues()
        #expect(!issues.contains { $0.severity == .error }) // the demo portfolio is clean
        _ = try await store.consistencyIssues()
        #expect(store.analysisCache.statistics.hits == 1)
        let settled = await store.waitUntilSettled(quietPeriod: .milliseconds(30), timeout: .seconds(2))
        #expect(settled != nil)
    }
}

@Suite @MainActor struct ScopeAndRequestTests {
    @Test func scopeSelection() throws {
        let store = demoStore()
        let file = store.file
        #expect(store.scope == .portfolio && store.scopeTitle == "Whole Portfolio" && store.isWholePortfolioScope)

        let depot = file.depots[1]
        store.scopeSelection = .depot(depot.id)
        #expect(store.scope == .depot(depot.id) && store.scopeTitle == depot.name && !store.isWholePortfolioScope)

        let account = file.accounts[0]
        store.scopeSelection = .account(account.id)
        #expect(store.scope == .account(account.id) && store.scopeTitle == account.name)

        let taxonomy = file.taxonomies[0]
        let equity = try #require(taxonomy.root.first)
        store.scopeSelection = .classification(taxonomy: taxonomy.id, id: equity.id)
        #expect(store.scope == taxonomy.scope(forClassification: equity.id))
        #expect(store.scopeTitle == "\(taxonomy.name) ▸ \(equity.name)")
        if case .weighted(let securities, _) = store.scope { #expect(!securities.isEmpty) } else { Issue.record("expected a weighted scope") }

        // Something that no longer exists falls back to the whole portfolio.
        store.scopeSelection = .depot(UUID())
        #expect(store.scope == .portfolio && store.scopeTitle == "Whole Portfolio")

        // Text form (scene storage, --scope).
        let all: [ScopeSelection] = [.portfolio, .depot(depot.id), .account(account.id), .classification(taxonomy: taxonomy.id, id: equity.id)]
        for selection in all { #expect(ScopeSelection(string: selection.stringValue) == selection) }
        #expect(ScopeSelection(string: "depot:nope") == nil && ScopeSelection(string: "classification:\(UUID())") == nil)
        #expect(ScopeSelection(string: "") == .portfolio)

        // Taxonomy helpers.
        #expect(taxonomy.classification(equity.id)?.name == equity.name)
        #expect(taxonomy.flattened.first?.depth == 0)
        #expect(taxonomy.flattened.count >= taxonomy.root.count)
    }

    @Test func sheetRequestsFromText() throws {
        let file = SampleData.demoPortfolio(today: fixedToday)
        let security = file.securities[3], account = file.accounts[1], plan = file.plans[0]
        func parse(_ text: String) -> SheetRequest? { SheetRequest.parse(text, in: file) }

        #expect(parse("new-transaction") == .newTransaction)
        #expect(parse("new-transaction:dividend") == .newTransaction(TransactionPrefill(kind: .dividend)))
        #expect(parse("new-transaction:nonsense") == nil)
        let first = try #require(file.transactions.min(by: Transaction.chronological))
        #expect(parse("edit-transaction:first") == .editTransaction(first.id))
        #expect(parse("edit-transaction:\(file.transactions[5].id.uuidString)") == .editTransaction(file.transactions[5].id))
        #expect(parse("edit-transaction:\(UUID().uuidString)") == nil)
        #expect(parse("edit-transaction") == nil)
        #expect(parse("new-security") == .newSecurity && parse("edit-security:first") == .editSecurity(file.securities[0].id))
        #expect(parse("edit-security:\(security.id.uuidString)") == .editSecurity(security.id))
        #expect(parse("new-account") == .newAccount && parse("edit-account:\(account.id.uuidString)") == .editAccount(account.id))
        #expect(parse("new-depot") == .newDepot && parse("edit-depot:first") == .editDepot(file.depots[0].id))
        #expect(parse("new-plan") == .newPlan && parse("edit-plan:\(plan.id.uuidString)") == .editPlan(plan.id))
        #expect(parse("import") == .importFile(nil))
        #expect(parse("import:/tmp/some file.csv") == .importFile(URL(fileURLWithPath: "/tmp/some file.csv")))
        #expect(parse("export") == .export && parse("export:transactions") == .export(ExportRequest(.transactions())))
        #expect(parse("export:quotes:first") == .export(ExportRequest(.quotes(securityID: file.securities[0].id))))
        #expect(parse("export:everything") == nil)
        #expect(parse("portfolio-settings") == .portfolioSettings && parse("consistency") == .consistencyReport)
        #expect(parse("custom:allocation.rebalance") == .custom(id: "allocation.rebalance"))
        #expect(parse("custom:allocation.rebalance?taxonomy=abc&cash=500") == .custom(id: "allocation.rebalance", payload: ["taxonomy": "abc", "cash": "500"]))
        #expect(parse("custom:") == nil && parse("frobnicate") == nil)
        #expect(SheetRequest.parse("edit-plan:first", in: PortfolioFile()) == nil)

        // Every request has a title and a symbol for the placeholder sheet.
        for request in [parse("new-transaction"), parse("export"), parse("new-plan"), parse("custom:x")].compactMap({ $0 }) {
            #expect(!request.title.isEmpty && !request.symbol.isEmpty)
        }

        // "Duplicate": a prefill carrying everything of an existing entry.
        let buy = try #require(file.transactions.first { $0.kind == .buy && $0.fees > 0 })
        let prefill = TransactionPrefill(copying: buy, date: fixedToday)
        #expect(prefill.kind == .buy && prefill.securityID == buy.securityID && prefill.depotID == buy.depotID)
        #expect(prefill.amount == buy.amount && prefill.shares == buy.shares && prefill.fees == buy.fees && prefill.date == fixedToday)
    }

    @Test func classificationRoutesAndLaunchState() throws {
        let store = demoStore()
        let taxonomy = store.file.taxonomies[0]
        let node = try #require(taxonomy.root.first?.children.first ?? taxonomy.root.first)
        let route = Route.classification(taxonomy: taxonomy.id, id: node.id)
        #expect(route.screen == .allocation && route.taxonomyID == taxonomy.id && route.classificationID == node.id)
        #expect(Route(string: route.stringValue) == route)
        #expect(Route(string: "classification:\(taxonomy.id.uuidString)/\(node.id.uuidString)") == route)
        let onPerformance = Route(.performance, focus: route.focus)
        #expect(Route(string: onPerformance.stringValue) == onPerformance)
        #expect(Route(string: "classification:\(taxonomy.id.uuidString)") == nil)

        store.navigate(to: route)
        #expect(store.route == route)
        // A focus on a classification that disappears is dropped.
        store.mutate("Delete Taxonomy") { $0.taxonomies.removeFirst() }
        store.goBack()
        store.goForward()
        #expect(store.route.focus == nil && store.route.screen == .allocation)

        let security = store.file.securities[0].id
        store.navigate(to: .security(security))
        #expect(store.route.securityID == security && store.route.transactionID == nil)
        let transaction = store.file.transactions[0].id
        store.navigate(to: .transaction(transaction))
        #expect(store.route.screen == .transactions && store.route.transactionID == transaction)

        enum Tab: String { case overview, rebalancing }
        #expect(store.launchValue("tab") == nil && store.launchValue("tab", as: Tab.self) == nil)
        store.launchState = ["tab": "rebalancing", "selection": "x"]
        #expect(store.launchValue("tab", as: Tab.self) == .rebalancing && store.launchValue("selection") == "x")
        store.launchState["tab"] = "unknown"
        #expect(store.launchValue("tab", as: Tab.self) == nil)
    }
}

// MARK: Quote updates

private struct TestProvider: QuoteProvider {
    let descriptor = ProviderDescriptor(id: "test", name: "Test", summary: "In-memory quotes", symbol: nil)
    let delay: Duration

    func history(_ request: QuoteRequest) async throws -> QuoteHistory {
        if delay > .zero { try await Task.sleep(for: delay) }
        if request.feed.symbol == "FAIL" { throw MarketDataError.symbolNotFound(request.feed.symbol) }
        let days = [request.range.upperBound.advanced(by: -1), request.range.upperBound].filter { request.range.contains($0) }
        return QuoteHistory(points: days.enumerated().map { PricePoint(day: $1, price: Price(100 + Double($0))) }, currency: request.currency)
    }
}

/// The undo manager is only attached when a test asks for it (it needs explicit grouping).
@MainActor
private func quoteStore(delay: Duration = .zero, undoable: Bool = false) -> (PortfolioStore, UndoManager) {
    let today = Day(year: 2026, month: 6, day: 30)
    var file = PortfolioFile(name: "Quotes")
    file.securities = [
        Security(name: "Good One", currency: "EUR", feed: QuoteFeed(provider: "test", symbol: "A"), prices: PriceSeries([PricePoint(day: today.advanced(by: -10), price: Price(90))])),
        Security(name: "Good Two", currency: "EUR", feed: QuoteFeed(provider: "test", symbol: "B")),
        Security(name: "Broken", currency: "EUR", feed: QuoteFeed(provider: "test", symbol: "FAIL")),
        Security(name: "Manual", currency: "EUR", feed: .manual),
        Security(name: "No Feed", currency: "EUR"),
        Security(name: "Retired", currency: "EUR", isRetired: true, feed: QuoteFeed(provider: "test", symbol: "R")),
    ]
    let store = PortfolioStore(file: file, today: today)
    var registry = ProviderRegistry()
    registry.register(TestProvider(delay: delay))
    store.quoteUpdater = QuoteUpdater(registry: registry, rateProvider: nil, options: UpdateOptions(historyStart: .day(today.advanced(by: -5))))
    let undo = UndoManager()
    undo.groupsByEvent = false
    if undoable { store.undoManager = undo }
    return (store, undo)
}

@Suite @MainActor struct QuoteUpdateTests {
    @Test func updateAppliesAsOneUndoableStepAndReportsFailures() async throws {
        let (store, undo) = quoteStore(undoable: true)
        let before = store.file
        #expect(store.hasAutomaticQuoteFeeds)

        undo.beginUndoGrouping()
        let task = try #require(store.updateQuotes())
        #expect(store.isUpdatingQuotes && store.isBusy && store.activity?.total == 3) // manual, feed-less, retired: not requested
        #expect(store.updateQuotes() == nil) // one at a time
        let report = try #require(await task.value)
        undo.endUndoGrouping()

        #expect(!store.isUpdatingQuotes && store.activity == nil && !store.isBusy)
        #expect(report.targetCount == 3 && report.newPrices == 4 && report.changedSecurities >= 2)
        #expect(report.failures.map(\.name) == ["Broken"])
        #expect(report.failures[0].securityID == before.securities[2].id && !report.failures[0].message.isEmpty)
        #expect(store.lastQuoteUpdate == report && store.isQuoteReportPresented) // interactive + failures → popover
        #expect(store.file.securities[0].prices.count == 3 && store.file.securities[1].prices.count == 2)
        #expect(store.file.securities[3] == before.securities[3] && store.file.securities[4] == before.securities[4])
        #expect(store.file.securities[5] == before.securities[5])
        #expect(store.toasts.last?.style == .warning)

        // One undo step brings back the exact previous document.
        #expect(undo.canUndo && undo.undoActionName == "Update Quotes")
        undo.undo()
        #expect(store.file == before)
        undo.redo()
        #expect(store.file.securities[0].prices.count == 3)
    }

    @Test func quietUpdateDoesNotOpenThePopover() async throws {
        let (store, _) = quoteStore()
        let report = try #require(await store.updateQuotes(interactive: false)?.value)
        #expect(report.hasFailures && !store.isQuoteReportPresented)

        // Restricting to selected securities.
        let only = try #require(await store.updateQuotes(only: [store.file.securities[2].id])?.value)
        #expect(only.targetCount == 1 && only.failures.count == 1 && only.newPrices == 0)
    }

    @Test func nothingToDoAndNoUpdater() async {
        let (store, _) = quoteStore()
        store.mutate("Manual only") { file in
            for index in file.securities.indices { file.securities[index].feed = .manual }
        }
        #expect(!store.hasAutomaticQuoteFeeds)
        #expect(store.updateQuotes() == nil)
        #expect(store.toasts.last?.title == "Nothing to update" && !store.isUpdatingQuotes && store.activity == nil)

        // Without an updater (screenshot mode, tests) nothing can reach the network.
        let (offline, _) = quoteStore()
        offline.quoteUpdater = nil
        #expect(offline.updateQuotes() == nil && !offline.hasAutomaticQuoteFeeds)
        #expect(offline.toasts.last?.style == .warning)
        #expect(offline.updateQuotes(interactive: false) == nil && offline.toasts.count == 1)
    }

    @Test func cancellation() async throws {
        let (store, _) = quoteStore(delay: .seconds(5))
        let task = try #require(store.updateQuotes())
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let started = clock.now
        store.cancelQuoteUpdate()
        let report = try #require(await task.value)
        #expect(clock.now - started < .seconds(2)) // returns promptly, not after the 5 s download
        #expect(report.wasCancelled && report.newPrices == 0)
        #expect(!store.isUpdatingQuotes && store.activity == nil)
        #expect(store.toasts.last?.title == "Quote update canceled")
    }

    @Test func reportSummaries() {
        #expect(QuoteUpdateReport().summary == "Everything is up to date")
        #expect(QuoteUpdateReport(newPrices: 1).summary == "1 new price")
        #expect(QuoteUpdateReport(newPrices: 1_200, newRates: 6).summary == "\(Fmt.integer(1_200)) new prices, 6 new exchange rates")
        let failed = QuoteUpdateReport(failures: [.init(securityID: nil, name: "Exchange rates", message: "offline")])
        #expect(failed.summary == "No new data" && failed.hasFailures && failed.failures[0].id == "exchange-rates")
    }
}

@Suite @MainActor struct OptionalResultTests {
    /// Optional results — including nil — are values like any other (they used to look like a
    /// failed cast and never arrived).
    @Test func optionalValuesAreDeliveredAndCached() async throws {
        let store = demoStore()
        let runs = Counter()
        let none: Int? = try await store.compute("test.optional.nil") { _ in
            runs.increment()
            return Int?.none
        }
        #expect(none == nil)
        let again: Int? = try await store.compute("test.optional.nil") { _ in
            runs.increment()
            return Int?.none
        }
        #expect(again == nil)
        #expect(runs.count == 1)
        let some: Int? = try await store.compute("test.optional.some") { ledger in Optional(ledger.transactions.count) }
        #expect(some == store.file.transactions.count)
    }
}
