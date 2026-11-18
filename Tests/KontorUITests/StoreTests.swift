import Foundation
import Testing
import KontorModel
@testable import KontorUI

@MainActor
private func makeStore() -> (PortfolioStore, UndoManager, ids: (security: UUID, account: UUID, depot: UUID)) {
    let account = Account(name: "Cash", currency: "EUR")
    let depot = Depot(name: "Broker", referenceAccountID: account.id)
    let security = Security(name: "World ETF", currency: "EUR", isin: "IE00B4L5Y983", ticker: "IWDA")
    let other = Security(name: "Bond ETF", currency: "EUR")
    let d = Day(year: 2024, month: 1, day: 2)
    var file = PortfolioFile(name: "Test")
    file.accounts = [account]
    file.depots = [depot]
    file.securities = [security, other]
    file.transactions = [
        Transaction(kind: .deposit, date: d, accountID: account.id, amount: Money(minor: 1_000_00, currency: "EUR")),
        Transaction(kind: .buy, date: d.advanced(by: 1), accountID: account.id, depotID: depot.id, securityID: security.id, shares: Shares(10), amount: Money(minor: 500_00, currency: "EUR")),
        Transaction(kind: .buy, date: d.advanced(by: 2), accountID: account.id, depotID: depot.id, securityID: other.id, shares: Shares(5), amount: Money(minor: 100_00, currency: "EUR")),
    ]
    file.plans = [InvestmentPlan(name: "Monthly", securityID: security.id, depotID: depot.id, accountID: account.id, amount: Money(minor: 100_00, currency: "EUR"), start: d)]
    file.watchlists = [Watchlist(name: "Watch", securityIDs: [security.id, other.id])]
    file.taxonomies = [Taxonomy(name: "Assets", root: [
        Classification(name: "Equity", children: [
            Classification(name: "Global", assignments: [.init(securityID: security.id)]),
        ]),
        Classification(name: "Bonds", assignments: [.init(securityID: other.id)]),
        Classification(name: "Cash", assignments: [.init(accountID: account.id)]),
    ])]
    file.settings.benchmarkSecurityIDs = [security.id]
    let store = PortfolioStore(file: file, today: Day(year: 2024, month: 6, day: 1))
    let undo = UndoManager()
    undo.groupsByEvent = false
    store.undoManager = undo
    return (store, undo, (security.id, account.id, depot.id))
}

@MainActor
private func grouped(_ undo: UndoManager, _ body: () -> Void) {
    undo.beginUndoGrouping()
    body()
    undo.endUndoGrouping()
}

@MainActor
@Suite struct StoreMutation {
    @Test func mutateBumpsRevisionAndRegistersUndo() {
        let (store, undo, _) = makeStore()
        let original = store.file
        #expect(store.revision == 0)
        grouped(undo) { store.rename("Renamed") }
        #expect(store.revision == 1)
        #expect(store.file.name == "Renamed")
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Rename Portfolio")

        undo.undo()
        #expect(store.file == original)
        #expect(store.revision == 2)
        #expect(undo.canRedo)
        #expect(undo.redoActionName == "Rename Portfolio")

        undo.redo()
        #expect(store.file.name == "Renamed")
        #expect(store.revision == 3)
        #expect(undo.canUndo)
    }

    @Test func noOpMutationIsFree() {
        let (store, undo, _) = makeStore()
        // No undo group is open: registering an undo step here would raise.
        let changed = store.mutate("Nothing") { file in
            file.name = file.name
            file.transactions.sort { $0.id.uuidString < $1.id.uuidString }
            file.transactions.sort(by: Transaction.chronological)
        }
        #expect(!changed)
        #expect(store.revision == 0)
        #expect(!undo.canUndo)
    }

    @Test func nonUndoableChangeNotifiesDocument() {
        let (store, undo, ids) = makeStore()
        var notified = 0
        store.onNonUndoableChange = { notified += 1 }
        store.updateSecurity(ids.security, actionName: "Update Quotes", undoable: false) {
            $0.prices.set(Price(101), on: Day(year: 2024, month: 5, day: 31))
        }
        #expect(notified == 1)
        #expect(!undo.canUndo)
        #expect(store.revision == 1)
        #expect(store.security(ids.security)?.prices.count == 1)
    }

    @Test func throwingBodyLeavesFileUntouched() {
        struct Boom: Error {}
        let (store, _, _) = makeStore()
        let before = store.file
        #expect(throws: Boom.self) {
            try store.mutate("Fail") { file in
                file.name = "half-done"
                throw Boom()
            }
        }
        #expect(store.file == before)
        #expect(store.revision == 0)
    }

    @Test func lookupsFollowRevisions() {
        let (store, undo, ids) = makeStore()
        #expect(store.security(ids.security)?.name == "World ETF")
        #expect(store.account(ids.account)?.name == "Cash")
        #expect(store.depot(ids.depot)?.name == "Broker")
        #expect(store.security(UUID()) == nil)
        #expect(store.security(nil) == nil)
        #expect(store.transactions(forSecurity: ids.security).count == 1)
        #expect(store.transactions(forAccount: ids.account).count == 3)
        #expect(store.transactions(forDepot: ids.depot).count == 2)
        #expect(store.inception == Day(year: 2024, month: 1, day: 2))

        let extra = Transaction(kind: .dividend, date: Day(year: 2023, month: 12, day: 1), accountID: ids.account, securityID: ids.security, amount: Money(minor: 5_00, currency: "EUR"))
        grouped(undo) { store.addTransaction(extra) }
        #expect(store.transaction(extra.id) == extra)
        #expect(store.transactions(forSecurity: ids.security).count == 2)
        #expect(store.inception == Day(year: 2023, month: 12, day: 1))
        undo.undo()
        #expect(store.transaction(extra.id) == nil)
        #expect(store.inception == Day(year: 2024, month: 1, day: 2))
    }

    @Test func transactionCRUD() {
        let (store, undo, ids) = makeStore()
        var t = store.file.transactions[1]
        t.note = "edited"
        grouped(undo) { store.updateTransaction(t) }
        #expect(store.transaction(t.id)?.note == "edited")
        #expect(undo.undoActionName == "Edit Transaction")
        grouped(undo) { store.deleteTransactions(Set(store.file.transactions.map(\.id))) }
        #expect(store.file.transactions.isEmpty)
        #expect(undo.undoActionName == "Delete Transactions")
        undo.undo()
        #expect(store.file.transactions.count == 3)
        _ = ids
    }

    @Test func deletingSecurityCascades() {
        let (store, undo, ids) = makeStore()
        let usage = store.usage(ofSecurities: [ids.security])
        #expect(usage == EntityUsage(transactions: 1, plans: 1, classifications: 1, watchlists: 1, depots: 0))
        #expect(usage.summary == "1 transaction, 1 plan, 1 classification, 1 watchlist")
        let before = store.file

        grouped(undo) { store.deleteSecurities([ids.security]) }
        #expect(store.file.securities.map(\.name) == ["Bond ETF"])
        #expect(store.file.transactions.count == 2)
        #expect(store.file.plans.isEmpty)
        #expect(store.file.watchlists[0].securityIDs.count == 1)
        #expect(store.file.settings.benchmarkSecurityIDs.isEmpty)
        #expect(store.file.taxonomies[0].root[0].children[0].assignments.isEmpty)
        #expect(store.file.taxonomies[0].root[1].assignments.count == 1)
        #expect(ConsistencyChecker.check(store.file).isEmpty)

        undo.undo()
        #expect(store.file == before)
    }

    @Test func deletingAccountCascades() {
        let (store, undo, ids) = makeStore()
        #expect(store.usage(ofAccounts: [ids.account]) == EntityUsage(transactions: 3, plans: 1, classifications: 1, watchlists: 0, depots: 1))
        grouped(undo) { store.deleteAccounts([ids.account]) }
        #expect(store.file.accounts.isEmpty)
        #expect(store.file.transactions.isEmpty)
        #expect(store.file.depots[0].referenceAccountID == nil)
        #expect(store.file.taxonomies[0].root[2].assignments.isEmpty)
        #expect(ConsistencyChecker.check(store.file).isEmpty)
    }

    @Test func deletingDepotCascades() {
        let (store, undo, ids) = makeStore()
        #expect(store.usage(ofDepots: [ids.depot]).transactions == 2)
        grouped(undo) { store.deleteDepots([ids.depot]) }
        #expect(store.file.depots.isEmpty)
        #expect(store.file.transactions.count == 1)
        #expect(store.file.plans.isEmpty)
    }

    @Test func confirmedDeleteAsksOnlyWhenReferenced() {
        let (store, undo, ids) = makeStore()
        let unused = Security(name: "Unused", currency: "USD")
        grouped(undo) { store.addSecurity(unused) }
        grouped(undo) { store.confirmDeleteSecurities([unused.id]) }
        #expect(store.confirmation == nil)
        #expect(store.security(unused.id) == nil)

        store.confirmDeleteSecurities([ids.security])
        #expect(store.security(ids.security) != nil)
        let request = try! #require(store.confirmation)
        #expect(request.title == "Delete “World ETF”?")
        grouped(undo) { request.action() }
        #expect(store.security(ids.security) == nil)
    }

    @Test func upserts() {
        let (store, undo, _) = makeStore()
        var list = Watchlist(name: "New")
        grouped(undo) { store.upsertWatchlist(list) }
        #expect(store.file.watchlists.count == 2)
        list.name = "Renamed"
        grouped(undo) { store.upsertWatchlist(list) }
        #expect(store.file.watchlists.count == 2)
        #expect(store.file.watchlists[1].name == "Renamed")
        grouped(undo) { store.updateSettings { $0.costMethod = .average } }
        #expect(store.file.settings.costMethod == .average)
    }
}

@MainActor
@Suite struct StoreNavigationAndState {
    @Test func historyBackForward() {
        let (store, _, ids) = makeStore()
        #expect(store.route == Route(.dashboard))
        #expect(!store.canGoBack)
        store.navigate(to: .holdings)
        store.navigate(to: .security(ids.security))
        store.navigate(to: .security(ids.security)) // same route: no history entry
        #expect(store.backStack.count == 2)
        store.goBack()
        #expect(store.route == Route(.holdings))
        #expect(store.canGoForward)
        store.goForward()
        #expect(store.route == .security(ids.security))
        store.goBack()
        store.navigate(to: .trades)
        #expect(!store.canGoForward)
    }

    @Test func focusIsDroppedWhenEntityDisappears() {
        let (store, undo, ids) = makeStore()
        store.navigate(to: .security(ids.security))
        store.navigate(to: .holdings)
        grouped(undo) { store.deleteSecurities([ids.security]) }
        store.goBack()
        #expect(store.route == Route(.securities))
        store.setFocus(.account(ids.account))
        #expect(store.route.focus == .account(ids.account))
        #expect(store.backStack.count == 1)
    }

    @Test func sheetQueue() {
        let (store, _, _) = makeStore()
        store.present(.newSecurity)
        store.present(.newAccount)
        store.present(.newAccount)
        #expect(store.sheet == .newSecurity)
        store.dismissSheet()
        #expect(store.sheet == .newAccount)
        store.dismissSheet()
        #expect(store.sheet == nil)
    }

    @Test func activityAndBusy() async {
        let (store, _, _) = makeStore()
        #expect(!store.isBusy)
        store.beginActivity("Updating quotes", total: 14)
        store.updateActivity(completed: 3)
        #expect(store.activity?.statusText == "Updating quotes 3/14")
        #expect(store.activity?.fraction == 3.0 / 14)
        #expect(store.isBusy)
        store.endActivity()
        #expect(!store.isBusy)
        let value = await store.whileBusy { () -> Int in
            #expect(store.isBusy)
            return 42
        }
        #expect(value == 42)
        #expect(!store.isBusy)
        await store.waitUntilSettled(quietPeriod: .milliseconds(30), timeout: .seconds(2))
    }

    @Test func toastsExpire() async throws {
        let (store, _, _) = makeStore()
        store.show(Toast("Saved", style: .success, duration: 0.05))
        #expect(store.toasts.count == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.toasts.isEmpty)
    }

    @Test func periodInterval() {
        let (store, _, _) = makeStore()
        store.period = .allTime
        #expect(store.periodInterval == Day(year: 2024, month: 1, day: 1)...Day(year: 2024, month: 6, day: 1))
        #expect(store.baseCurrency == "EUR")
    }
}

@Suite struct Consistency {
    @Test func detectsStructuralProblems() {
        let account = Account(name: "USD Cash", currency: "USD")
        var file = PortfolioFile()
        file.accounts = [account]
        let d = Day(year: 2024, month: 1, day: 1)
        file.transactions = [
            Transaction(kind: .deposit, date: d, accountID: account.id, amount: Money(minor: 100, currency: "EUR")),
            Transaction(kind: .buy, date: d, accountID: account.id, depotID: UUID(), securityID: UUID(), shares: Shares(1), amount: Money(minor: 100, currency: "USD")),
            Transaction(kind: .cashTransfer, date: d, accountID: account.id, counterAccountID: account.id, amount: Money(minor: 100, currency: "USD")),
            Transaction(kind: .withdrawal, date: d, amount: Money(minor: -5, currency: "USD")),
        ]
        let messages = ConsistencyChecker.check(file).map(\.message)
        #expect(messages.contains { $0.contains("is in EUR but account “USD Cash” is in USD") })
        #expect(messages.contains { $0.contains("no valid depot") })
        #expect(messages.contains { $0.contains("no valid security") })
        #expect(messages.contains { $0.contains("same source and target account") })
        #expect(messages.contains { $0.contains("negative magnitude") })
        #expect(messages.contains { $0.contains("no valid cash account") })
        #expect(ConsistencyChecker.check(PortfolioFile()).isEmpty)
    }
}

@Suite struct Fuzzy {
    @Test func subsequenceMatching() {
        #expect(FuzzyMatcher.match("hld", in: "Holdings") != nil)
        #expect(FuzzyMatcher.match("xyz", in: "Holdings") == nil)
        #expect(FuzzyMatcher.match("holdingsx", in: "Holdings") == nil)
        #expect(FuzzyMatcher.match("", in: "Anything")?.score == 0)
        #expect(FuzzyMatcher.match("zur", in: "Zürich")?.positions == [0, 1, 2])
        #expect(FuzzyMatcher.match("NT", in: "New Transaction")?.positions == [0, 4])
    }

    @Test func ranking() {
        let items = ["Household", "Holdings", "Threshold", "Update Quotes", "Old Holdings Report"]
        let ranked = FuzzyMatcher.rank(items, query: "hold") { [$0] }.map(\.item)
        #expect(ranked.first == "Holdings")
        // Tight matches only: "Household"/"Threshold" contain "hold" mid-word (scattered start).
        #expect(ranked == ["Holdings", "Old Holdings Report"])
        // Without any tight match, scattered ones are still offered.
        #expect(FuzzyMatcher.rank(items, query: "hsh") { [$0] }.map(\.item) == ["Household", "Threshold"])
        #expect(FuzzyMatcher.match("hold", in: "Holdings")?.isTight == true)
        #expect(FuzzyMatcher.match("hold", in: "Threshold")?.isTight == false)

        // Word-start matches beat scattered ones.
        let acronym = FuzzyMatcher.rank(["Annual Turnover", "New Transaction", "Internet"], query: "nt") { [$0] }.map(\.item)
        #expect(acronym.first == "New Transaction")

        // Exact match wins over a longer prefix match.
        #expect(FuzzyMatcher.rank(["Trades Report", "Trades"], query: "trades") { [$0] }.first?.item == "Trades")

        // Secondary keys (ticker) are searched too; empty query keeps order.
        struct S { let name: String; let ticker: String }
        let securities = [S(name: "Vanguard All-World", ticker: "VWCE"), S(name: "Apple", ticker: "AAPL")]
        #expect(FuzzyMatcher.rank(securities, query: "aapl") { [$0.name, $0.ticker] }.first?.item.name == "Apple")
        #expect(FuzzyMatcher.rank(items, query: " ", limit: 2) { [$0] }.map(\.item) == ["Household", "Holdings"])
    }

    @Test func sparklineReduction() {
        let values = (0..<10_000).map { Double($0 % 100) }
        let reduced = Sparkline.reduced(values, maxBuckets: 50)
        #expect(reduced.count == 100)
        #expect(reduced.first == values.first)
        #expect(reduced.last == values.last)
        #expect(reduced.max() == 99)
        #expect(Sparkline.reduced([1, .nan, 3], maxBuckets: 50) == [1, 3])
        let pts = Sparkline.points([1, 2, 3], in: CGSize(width: 100, height: 20), inset: 1)
        #expect(pts.count == 3)
        #expect(pts[0].y > pts[2].y)
        #expect(Sparkline.points([5], in: CGSize(width: 100, height: 20), inset: 1).isEmpty)
    }
}
