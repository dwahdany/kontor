import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureAccounts

// Tests of the Accounts feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Accounts"):
//
//     KONTOR_FEATURES=Accounts swift test --scratch-path .build-accounts --filter FeatureAccountsTests
@Suite @MainActor struct AccountsFeatureTests {
    let today = Day(year: 2026, month: 6, day: 30)

    private func demoStore() -> PortfolioStore {
        PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
    }

    private func overview(_ store: PortfolioStore) async throws -> AccountsOverview {
        let today = store.today
        return try await store.analyze("accounts.overview", scope: .portfolio, variant: today) { AccountsOverview($0, today: today) }
    }

    private func accountDetail(_ store: PortfolioStore, _ id: UUID) async throws -> AccountDetailModel {
        let today = store.today
        return try await store.analyze("accounts.account-detail", scope: .account(id), variant: today) { analysis in
            guard let detail = AccountDetailModel(analysis, account: id, today: today) else { throw MissingEntity() }
            return detail
        }
    }

    @Test func moduleRegistersItsScreen() {
        #expect(AccountsFeature.module.screen == .accounts)
    }

    // MARK: Overview

    @Test func overviewTotalsAddUp() async throws {
        let store = demoStore()
        let model = try await overview(store)
        #expect(model.accounts.count == 3)
        #expect(model.depots.count == 2)
        #expect(model.accounts.reduce(0) { $0 + $1.value.minor } == model.cashTotal.minor)
        #expect(model.depots.reduce(0) { $0 + $1.value.minor } == model.depotTotal.minor)
        #expect(model.cashTotal.minor + model.depotTotal.minor == model.netWorth.minor)
        // The same numbers as the engine's snapshot.
        let snapshot = store.ledger.snapshot(on: today)
        #expect(model.netWorth == snapshot.totalValue)
        for row in model.accounts {
            #expect(row.balance == snapshot.cash(row.id)?.balance)
            #expect(row.sparkline.last == Double(row.balance.minor))
            #expect(row.sparkline.count == 53)
        }
        #expect(model.depots.reduce(0) { $0 + $1.positionCount } >= snapshot.positions.count)
        #expect(model.hasForeignCurrency)
    }

    @Test func stackedChartSumsToThePortfolioValuation() async throws {
        let store = demoStore()
        let model = try await overview(store)
        let valuation = store.ledger.valuation(in: store.periodInterval)
        #expect(model.chart.series.count == 5)
        #expect(model.chart.days.first == store.periodInterval.start)
        #expect(model.chart.days.last == store.periodInterval.end)
        for (index, day) in model.chart.days.enumerated() {
            let expected = valuation.values[valuation.index(of: day)!]
            #expect(Int64(model.chart.total(at: index)) == expected)
        }
    }

    @Test func depotPerformanceMatchesTheEngine() async throws {
        let store = demoStore()
        let model = try await overview(store)
        for row in model.depots {
            let report = store.ledger.performance(in: store.periodInterval, scope: .depot(row.id))
            #expect(row.ttwror == report.ttwror)
            #expect(row.gain.minor == report.valuation.absolutePerformance)
        }
    }

    @Test func foldingKeepsTheTotal() {
        let series = (0..<12).map { StackedAreaData.Series(id: "\($0)", name: "S\($0)", values: [Double($0), Double($0 * 2)]) }
        let folded = StackedAreaData.folded(series)
        #expect(folded.count == StackedAreaData.maxSeries)
        #expect(folded.last?.name == "Other")
        #expect(folded.reduce(0) { $0 + $1.values[1] } == series.reduce(0) { $0 + $1.values[1] })
    }

    @Test func sampledIndicesKeepBothEnds() {
        #expect(sampledIndices(count: 5, maxPoints: 10) == [0, 1, 2, 3, 4])
        let sampled = sampledIndices(count: 9132, maxPoints: 360)
        #expect(sampled.first == 0)
        #expect(sampled.last == 9131)
        #expect(sampled.count <= 360)
        #expect(sampled == sampled.sorted())
    }

    // MARK: Account detail

    @Test func accountDetailReconciles() async throws {
        let store = demoStore()
        let today = today
        for account in store.file.accounts {
            let id = account.id
            let model = try await accountDetail(store, id)
            let snapshot = store.ledger.snapshot(on: today)
            #expect(model.balance == snapshot.cash(id)?.balance)
            #expect(model.value == snapshot.cash(id)?.value)
            #expect(model.balances.count == store.periodInterval.dayCount + 1)
            #expect(model.balances.last == model.balance.minor)
            #expect(model.periodChange == model.moneyIn - model.moneyOut)
            #expect(model.months.reduce(0) { $0 + $1.moneyIn } == model.moneyIn)
            #expect(model.months.reduce(0) { $0 + $1.moneyOut } == model.moneyOut)
            // For an account in the reporting currency the own-currency balance IS the engine's valuation.
            if account.currency == store.baseCurrency {
                #expect(model.balances == store.ledger.valuation(in: store.periodInterval, scope: .account(id)).values)
            }
        }
        // Interest and fees booked on all accounts add up to the portfolio's earnings report.
        let earnings = store.ledger.earnings(in: store.periodInterval)
        var interest: Int64 = 0, fees: Int64 = 0
        for account in store.file.accounts {
            let id = account.id
            let model = try await accountDetail(store, id)
            interest += model.interest
            fees += model.fees
        }
        #expect(interest == earnings.byAccount.reduce(0) { $0 + $1.amounts.interest - $1.amounts.interestCharges })
        #expect(fees == earnings.byAccount.reduce(0) { $0 + $1.amounts.fees })
        #expect(interest > 0)
    }

    @Test func statementRunsToTheCurrentBalance() async throws {
        let store = demoStore()
        let snapshot = store.ledger.snapshot(on: today)
        for account in store.file.accounts {
            let rows = StatementRow.rows(store.ledger, account: account.id, filter: QuickFilter(""))
            #expect(rows.count == store.transactions(forAccount: account.id).count)
            #expect(rows.last?.balance == snapshot.cash(account.id)?.balance.minor)
            #expect(rows.reduce(0) { $0 + $1.amount } == rows.last?.balance)
            #expect(rows.map(\.order) == Array(rows.indices))
        }
        let settlement = store.file.accounts[0], savings = store.file.accounts[1]
        let transfers = StatementRow.rows(store.ledger, account: savings.id, filter: QuickFilter("transfer"))
        #expect(!transfers.isEmpty)
        #expect(transfers.allSatisfy { $0.kind == .cashTransfer })
        #expect(transfers.contains { $0.counterpart == "From \(settlement.name)" && $0.amount > 0 })
        // Filtering never changes a row's running balance.
        let all = Dictionary(uniqueKeysWithValues: StatementRow.rows(store.ledger, account: savings.id, filter: QuickFilter("")).map { ($0.id, $0.balance) })
        #expect(transfers.allSatisfy { all[$0.id] == $0.balance })
    }

    // MARK: Depot detail

    @Test func depotDetailMatchesTheEngine() async throws {
        let store = demoStore()
        let today = today
        let id = store.file.depots[0].id
        let model = try await store.analyze("accounts.depot-detail", scope: .depot(id), variant: today) { analysis in
            guard let detail = DepotDetailModel(analysis, depot: id, today: today) else { throw MissingEntity() }
            return detail
        }
        let snapshot = store.ledger.snapshot(on: today, scope: .depot(id))
        #expect(model.positions.count == snapshot.positions.count)
        #expect(model.positions.reduce(0) { $0 + $1.value } == model.marketValue.minor)
        #expect(abs(model.positions.reduce(0) { $0 + $1.weight } - 1) < 1e-9)
        #expect(model.positions.map(\.value) == model.positions.map(\.value).sorted(by: >))
        let report = store.ledger.performance(in: store.periodInterval, scope: .depot(id))
        #expect(model.ttwror == report.ttwror)
        #expect(model.irr == report.irr)
        #expect(model.absolutePerformance.minor == report.valuation.absolutePerformance)
        #expect(model.invested.count == store.periodInterval.dayCount + 1)

        let rows = DepotTransactionRow.rows(store.ledger, depot: id, filter: QuickFilter(""))
        #expect(rows.count == store.transactions(forDepot: id).count)
        // Share movements of the statement add up to today's positions.
        var shares = [String: Int64]()
        for row in rows { shares[row.security, default: 0] += row.shares.raw }
        for position in model.positions { #expect(shares[position.name] == position.shares.raw) }
    }

    // MARK: Launch state

    @Test func launchStateFindsEntities() {
        let file = SampleData.demoPortfolio(today: today)
        #expect(AccountsScreen.launchFocus(["account": "first"], in: file) == .account(file.accounts[0].id))
        #expect(AccountsScreen.launchFocus(["account": "savings account"], in: file) == .account(file.accounts[1].id))
        #expect(AccountsScreen.launchFocus(["depot": "Kids Depot"], in: file) == .depot(file.depots[1].id))
        #expect(AccountsScreen.launchFocus(["depot": "nope"], in: file) == nil)
        #expect(AccountsScreen.launchFocus([:], in: file) == nil)
        let interval = DayInterval(start: Day(year: 2025, month: 6, day: 30), end: today)
        #expect(AccountsScreen.launchHover(["hover": "last"], interval: interval) == today)
        #expect(AccountsScreen.launchHover(["hover": "2026-03-16"], interval: interval) == Day(year: 2026, month: 3, day: 16))
        #expect(AccountsScreen.launchHover([:], interval: interval) == nil)
    }

    // MARK: Actions

    @Test func retireAndReactivateAreUndoableSteps() {
        let store = demoStore()
        let id = store.file.accounts[2].id
        AccountsActions.setRetired(true, .account(id), in: store)
        #expect(store.account(id)?.isRetired == true)
        AccountsActions.setRetired(true, .account(id), in: store)       // no-op: no second revision
        let revision = store.revision
        AccountsActions.setRetired(false, .account(id), in: store)
        #expect(store.account(id)?.isRetired == false)
        #expect(store.revision == revision + 1)
    }

    @Test func reorderMovesWithinActiveAndRetiredGroups() {
        let store = demoStore()
        let ids = store.file.accounts.map(\.id)
        #expect(!AccountsActions.canMove(.account(ids[0]), by: -1, in: store.file))
        #expect(AccountsActions.canMove(.account(ids[0]), by: 1, in: store.file))
        AccountsActions.move(.account(ids[0]), by: 1, in: store)
        #expect(store.file.accounts.map(\.id) == [ids[1], ids[0], ids[2]])
        // A retired account in the middle is skipped: active accounts swap around it.
        AccountsActions.setRetired(true, .account(ids[0]), in: store)
        #expect(AccountsActions.canMove(.account(ids[1]), by: 1, in: store.file))
        AccountsActions.move(.account(ids[1]), by: 1, in: store)
        #expect(store.file.accounts.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(!AccountsActions.canMove(.account(ids[0]), by: 1, in: store.file))
        let depots = store.file.depots.map(\.id)
        AccountsActions.move(.depot(depots[1]), by: -1, in: store)
        #expect(store.file.depots.map(\.id) == [depots[1], depots[0]])
    }

    @Test func deletionImpactNamesEverythingThatGoes() throws {
        let store = demoStore()
        let account = store.file.accounts[0]
        let usage = store.usage(ofAccounts: [account.id])
        let impact = try #require(AccountsActions.deletionImpact(.account(account.id), in: store))
        #expect(!impact.isFree)
        #expect(impact.title == "Delete “\(account.name)”?")
        #expect(impact.message.contains("\(Fmt.integer(usage.transactions)) transactions"))
        #expect(impact.message.contains("1 depot loses its reference account"))
        #expect(impact.message.contains("undo"))

        // Used entity: asks first, nothing is deleted yet.
        AccountsActions.delete(.account(account.id), in: store)
        #expect(store.account(account.id) != nil)
        #expect(store.confirmation != nil)
        store.confirmation?.action()
        #expect(store.account(account.id) == nil)
        #expect(store.file.transactions.allSatisfy { $0.accountID != account.id && $0.counterAccountID != account.id })
        #expect(store.file.depots[0].referenceAccountID == nil)

        // Unused entity: deleted right away, no dialog.
        store.confirmation = nil
        let empty = Depot(name: "Empty")
        store.addDepot(empty)
        #expect(AccountsActions.deletionImpact(.depot(empty.id), in: store)?.isFree == true)
        AccountsActions.delete(.depot(empty.id), in: store)
        #expect(store.depot(empty.id) == nil)
        #expect(store.confirmation == nil)
    }

    @Test func quickActionsPrefillTheTransaction() {
        let store = demoStore()
        let depot = store.file.depots[0]
        AccountsActions.record(.buy, depot: depot.id, in: store)
        #expect(store.sheet == .newTransaction(TransactionPrefill(kind: .buy, date: today, accountID: depot.referenceAccountID, depotID: depot.id)))
        store.dismissSheet()
        AccountsActions.record(.deposit, account: store.file.accounts[1].id, in: store)
        #expect(store.sheet == .newTransaction(TransactionPrefill(kind: .deposit, date: today, accountID: store.file.accounts[1].id)))
    }

    @Test func paletteOffersContextActions() {
        let store = demoStore()
        var commands = AccountsFeature.commands(store)
        #expect(commands.map(\.id) == ["accounts.transfer", "accounts.copy-balances"])
        store.navigate(to: .depot(store.file.depots[0].id))
        commands = AccountsFeature.commands(store)
        #expect(commands.contains { $0.id == "accounts.record.buy" })
        #expect(commands.contains { $0.id == "accounts.retire" })
        #expect(commands.contains { $0.id == "accounts.delete" })
        #expect(Set(commands.map(\.id)).count == commands.count)
    }

    // MARK: Edge cases

    @Test func emptyAndSingleEntityFiles() async throws {
        let empty = PortfolioStore(file: PortfolioFile(name: "Empty"), today: today)
        let none = try await overview(empty)
        #expect(none.isEmpty)
        #expect(none.chart.isEmpty)
        #expect(none.netWorth.minor == 0)

        var file = PortfolioFile(name: "One")
        let account = Account(name: "Cash", currency: "EUR")
        file.accounts = [account]
        file.transactions = [Transaction(kind: .deposit, date: today.advanced(by: -10), accountID: account.id, amount: Money(minor: 100_000, currency: "EUR"))]
        let one = try await overview(PortfolioStore(file: file, today: today))
        #expect(one.accounts.count == 1)
        #expect(one.accounts[0].balance.minor == 100_000)
        #expect(one.accounts[0].lastActivity == today.advanced(by: -10))
        #expect(one.netWorth.minor == 100_000)
        #expect(one.chart.series.count == 1)
        #expect(!one.hasForeignCurrency)
    }

    @Test func stressPortfolioStaysFast() async throws {
        let file = SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000, endingOn: today)
        let store = PortfolioStore(file: file, today: today)
        let clock = ContinuousClock()
        let start = clock.now
        let model = try await overview(store)
        let id = file.accounts[0].id
        let rows = try await store.compute("test.statement") { ledger in StatementRow.rows(ledger, account: id, filter: QuickFilter("")) }
        let elapsed = clock.now - start
        #expect(model.accounts.count == 2)
        #expect(rows.count > 1_000)
        #expect(model.cashTotal.minor + model.depotTotal.minor == model.netWorth.minor)
        // Debug build, off the main actor; generous bound that still catches accidental quadratic work.
        #expect(elapsed < .seconds(20))
    }
}
