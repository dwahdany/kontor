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
    }

    /// Review finding: the Interest tile showed gross amounts in the reporting currency. The tiles
    /// now show what was booked on the account, in its own currency, and reconcile with the statement.
    @Test func accountIncomeIsWhatTheStatementShows() async throws {
        let store = demoStore()
        let interval = store.periodInterval
        let earnings = store.ledger.earnings(in: interval)
        var sawWithheldTax = false, sawForeign = false
        for account in store.file.accounts {
            let model = try await accountDetail(store, account.id)
            let income = model.income
            // Net figures are exactly the statement's credits and debits of the period.
            let rows = Statement(store.ledger, account: account.id, interval: interval, filter: QuickFilter("")).rows
            #expect(income.interestNet == rows.filter { $0.kind == .interest || $0.kind == .interestCharge }.reduce(0) { $0 + $1.amount })
            #expect(income.dividendsReceived == rows.filter { $0.kind == .dividend }.reduce(0) { $0 + $1.amount })
            #expect(income.interestGross >= income.interestReceived)
            #expect(income.dividendsGross >= income.dividendsReceived)
            if income.interestWithheld > 0 || income.dividendsWithheld > 0 { sawWithheldTax = true }
            // Gross figures are the engine's definitions: equal to its report where no conversion is involved.
            let booked = earnings.byAccount.first { $0.accountID == account.id }?.amounts ?? EarningsAmounts()
            if account.currency == store.baseCurrency {
                #expect(income.interestGross == booked.interest)
                #expect(income.interestCharges == booked.interestCharges)
                #expect(income.dividendsGross == booked.dividends)
                #expect(income.fees == booked.fees)
                #expect(income.taxes == booked.taxes)
            } else {
                sawForeign = true
                // Own currency, not the converted reporting-currency amount.
                if booked.dividends != 0 { #expect(income.dividendsGross != booked.dividends) }
            }
        }
        #expect(sawWithheldTax)
        #expect(sawForeign)
    }

    @Test func incomeFootnotesSayWhatWasWithheld() {
        let id = UUID()
        let day = Day(year: 2026, month: 3, day: 1)
        let interval = DayInterval(start: Day(year: 2025, month: 12, day: 31), end: today)
        func eur(_ minor: Int64) -> Money { Money(minor: minor, currency: "EUR") }
        var income = AccountIncome([
            Transaction(kind: .interest, date: day, accountID: id, amount: eur(7_500), taxes: 2_500),
            Transaction(kind: .interestCharge, date: day, accountID: id, amount: eur(500)),
            Transaction(kind: .interest, date: interval.start, accountID: id, amount: eur(99_999)),     // baseline day: not in the period
            Transaction(kind: .interest, date: day, accountID: UUID(), amount: eur(99_999)),            // another account
        ], account: id, in: interval)
        #expect(income.interestNet == 7_000)
        #expect(income.interestGross == 10_000)
        #expect(income.taxes == 2_500)
        #expect(income.interestFootnote(currency: "EUR").hasPrefix("gross "))
        #expect(income.interestFootnote(currency: "EUR").hasSuffix(" tax"))
        income = AccountIncome([Transaction(kind: .dividend, date: day, accountID: id, amount: eur(4_000), taxes: 1_000)], account: id, in: interval)
        #expect(income.dividendsReceived == 4_000)
        #expect(income.dividendsGross == 5_000)
        #expect(income.interestFootnote(currency: "EUR").hasSuffix("net dividends"))
        income = AccountIncome([Transaction(kind: .taxRefund, date: day, accountID: id, amount: eur(300))], account: id, in: interval)
        #expect(income.taxes == -300)
        #expect(income.feesFootnote(currency: "EUR").hasSuffix("taxes refunded"))
        #expect(AccountIncome().interestFootnote(currency: "EUR") == "credited to this account")
    }

    /// Review finding: the statement ignored the reporting period and had no opening / closing balance.
    @Test func statementOfAPeriodRunsFromOpeningToClosingBalance() {
        let store = demoStore()
        let account = store.file.accounts[0]
        let transactions = store.ledger.transactions(forAccount: account.id)
        let interval = store.interval(for: .year(2025))
        let statement = Statement(store.ledger, account: account.id, interval: interval, filter: QuickFilter(""))
        #expect(!statement.rows.isEmpty)
        #expect(statement.rows.count < transactions.count)
        #expect(statement.rows.allSatisfy { interval.contains($0.date) })
        #expect(statement.rangeCount == statement.rows.count)
        #expect(statement.totalCount == transactions.count)
        #expect(statement.opening == CashBalances.balance(transactions, account: account.id, on: interval.start))
        #expect(statement.closing == CashBalances.balance(transactions, account: account.id, on: interval.end))
        #expect(statement.opening + statement.rows.reduce(0) { $0 + $1.amount } == statement.closing)
        #expect(statement.rows.last?.balance == statement.closing)
        #expect(statement.ids == Set(statement.rows.map(\.id)))

        // A quick filter narrows the rows, not the balances the period runs between.
        let filtered = Statement(store.ledger, account: account.id, interval: interval, filter: QuickFilter("dividend"))
        #expect(filtered.rows.count < statement.rows.count)
        #expect(filtered.rangeCount == statement.rangeCount)
        #expect(filtered.opening == statement.opening)
        #expect(filtered.closing == statement.closing)

        // Copying the whole period gives a statement framed by both balances, in booking order …
        var sorted = statement
        sorted.rows.reverse()
        let lines = sorted.tsv(only: [], currency: account.currency).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.count == statement.rows.count + 3)
        #expect(lines[1][0] == Substring(interval.start.iso))
        #expect(lines[1][1] == "Opening balance")
        #expect(lines[2][0] == Substring(statement.rows[0].date.iso))
        #expect(lines.last?[1] == "Closing balance")
        #expect(lines.last?[0] == Substring(interval.end.iso))
        // … a selection or a filtered list is copied as listed, without the frame.
        let two = Set(statement.rows.prefix(2).map(\.id))
        #expect(statement.tsv(only: two, currency: account.currency).split(separator: "\n").count == 3)
        #expect(!filtered.tsv(only: [], currency: account.currency).contains("Opening balance"))

        // "All" is the complete ledger from a zero balance.
        let all = Statement(store.ledger, account: account.id, interval: nil, filter: QuickFilter(""))
        #expect(all.rows.count == transactions.count)
        #expect(all.opening == 0)
        #expect(all.interval == nil)

        // A period without bookings still knows both balances.
        let early = DayInterval(start: transactions[0].date.advanced(by: -40), end: transactions[0].date.advanced(by: -10))
        let nothing = Statement(store.ledger, account: account.id, interval: early, filter: QuickFilter(""))
        #expect(nothing.rows.isEmpty && nothing.rangeCount == 0 && nothing.totalCount == transactions.count)
        #expect(nothing.opening == 0 && nothing.closing == 0)
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

    // MARK: Review findings

    /// A file with the corner cases the demo portfolio hides: a dividend booked without a depot
    /// (as Portfolio Performance does), a security without quotes, an account without an exchange
    /// rate, a second depot that never held anything.
    private struct EdgeFile {
        var file = PortfolioFile(name: "Edge")
        let giro = Account(name: "Giro", currency: "EUR")
        let franken = Account(name: "Franken", currency: "CHF")
        let brokerA = Depot(name: "Broker A")
        let brokerB = Depot(name: "Broker B")
        var priced: Security
        var unlisted = Security(name: "Unlisted GmbH", currency: "EUR")
        var dividendID = UUID()

        init(today: Day) {
            priced = Security(name: "Priced AG", currency: "EUR", prices: PriceSeries([
                PricePoint(day: today.advanced(by: -300), price: Price(100)),
                PricePoint(day: today.advanced(by: -40), price: Price(120)),
            ]))
            func eur(_ value: Double) -> Money { Money(value, "EUR") }
            file.accounts = [giro, franken]
            file.depots = [brokerA, brokerB]
            file.securities = [priced, unlisted]
            file.transactions = [
                Transaction(kind: .deposit, date: today.advanced(by: -300), accountID: giro.id, amount: eur(10_000)),
                Transaction(kind: .deposit, date: today.advanced(by: -300), accountID: franken.id, amount: Money(5_950, "CHF")),
                Transaction(kind: .buy, date: today.advanced(by: -290), accountID: giro.id, depotID: brokerA.id, securityID: priced.id,
                            shares: Shares(10), amount: eur(1_000)),
                Transaction(kind: .buy, date: today.advanced(by: -200), accountID: giro.id, depotID: brokerA.id, securityID: unlisted.id,
                            shares: Shares(10), amount: eur(1_000)),
                // Portfolio Performance style: on the account only, no depot.
                Transaction(id: dividendID, kind: .dividend, date: today.advanced(by: -100), accountID: giro.id, securityID: priced.id,
                            shares: Shares(10), amount: eur(40), taxes: 1_000),
            ]
        }
    }

    @Test func tooltipStaysBesideTheCrosshair() {
        // Right of the crosshair while there is room …
        #expect(TooltipPlacement.leading(anchorX: 100, width: 200, container: 800) == 112)
        #expect(TooltipPlacement.leading(anchorX: 400, width: 200, container: 800) == 412)
        // … flipped to its left near the trailing edge (this is where it used to stick to x = 0) …
        #expect(TooltipPlacement.leading(anchorX: 790, width: 200, container: 800) == 578)
        #expect(TooltipPlacement.leading(anchorX: 800, width: 200, container: 800) == 588)
        // … and never outside the chart, even when it is wider than either side.
        #expect(TooltipPlacement.leading(anchorX: 150, width: 200, container: 300) == 0)
        #expect(TooltipPlacement.leading(anchorX: 10, width: 400, container: 300) == 0)
        for x in stride(from: CGFloat(0), through: 800, by: 25) {
            let left = TooltipPlacement.leading(anchorX: x, width: 210, container: 800)
            #expect(left >= 0 && left + 210 <= 800)
            #expect(left == x + 12 || left + 210 == x - 12 || left == 0)
        }
    }

    @Test func depotLedgerListsDividendsBookedWithoutADepot() async throws {
        let edge = EdgeFile(today: today)
        let store = PortfolioStore(file: edge.file, today: today)
        let ledger = store.ledger
        // The engine's own list does not have it …
        #expect(!ledger.transactions(forDepot: edge.brokerA.id).contains { $0.id == edge.dividendID })
        // … but the depot's figures do, so its transaction list must as well.
        let all = DepotLedger(ledger, depot: edge.brokerA.id, interval: nil, filter: QuickFilter(""))
        let dividend = try #require(all.rows.first { $0.id == edge.dividendID })
        #expect(dividend.isAttributed)
        #expect(all.attributedCount == 1)
        #expect(all.rows.count == 3 && all.totalCount == 3)
        #expect(all.rows.map(\.date) == all.rows.map(\.date).sorted())
        #expect(all.rows.map(\.order) == [0, 1, 2])
        #expect(all.rows.filter { !$0.isAttributed }.map(\.id) == ledger.transactions(forDepot: edge.brokerA.id).map(\.id))
        // The listed dividends explain the depot's dividend figure.
        let interval = DayInterval(start: today.advanced(by: -400), end: today)
        let breakdown = ledger.breakdown(in: interval, scope: .depot(edge.brokerA.id))
        let listed = ledger.transactions.filter { t in all.rows.contains { $0.id == t.id && $0.kind == .dividend } }
        #expect(listed.reduce(0) { $0 + $1.grossMinor } == breakdown.dividends)
        #expect(breakdown.dividends == 5_000)
        #expect(all.tsv(only: []).contains("Dividend (attributed)"))
        // A depot that never held the security gets nothing.
        let other = DepotLedger(ledger, depot: edge.brokerB.id, interval: nil, filter: QuickFilter(""))
        #expect(other.rows.isEmpty && other.attributedCount == 0)

        // Period and quick filter.
        let recent = DepotLedger(ledger, depot: edge.brokerA.id, interval: DayInterval(start: today.advanced(by: -150), end: today), filter: QuickFilter(""))
        #expect(recent.rows.map(\.id) == [edge.dividendID])
        #expect(recent.rangeCount == 1 && recent.totalCount == 3)
        let filtered = DepotLedger(ledger, depot: edge.brokerA.id, interval: nil, filter: QuickFilter("unlisted"))
        #expect(filtered.rows.count == 1 && filtered.rangeCount == 3)

        // The demo books its dividends with a depot: nothing is attributed, nothing is listed twice.
        let demo = demoStore()
        for depot in demo.file.depots {
            let rows = DepotLedger(demo.ledger, depot: depot.id, interval: nil, filter: QuickFilter(""))
            #expect(rows.attributedCount == 0)
            #expect(rows.rows.map(\.id) == demo.ledger.transactions(forDepot: depot.id).map(\.id))
            #expect(rows.ids.count == rows.rows.count)
        }
    }

    @Test func totalsSayWhatTheyLeaveOut() async throws {
        let edge = EdgeFile(today: today)
        let model = try await overview(PortfolioStore(file: edge.file, today: today))
        let franken = try #require(model.accounts.first { $0.id == edge.franken.id })
        #expect(!franken.isValued)
        #expect(model.gaps.balances == [Money(5_950, "CHF")])
        #expect(model.gaps.hasCashGap && !model.gaps.hasSecuritiesGap)
        let note = try #require(model.gaps.cashNote)
        #expect(note.contains("CHF") && note.contains("no exchange rate"))
        #expect(model.gaps.note == note)
        #expect(model.gaps.securitiesNote == nil)
        // The clipboard does not claim a value of 0 for it.
        let line = try #require(model.tsv.split(separator: "\n").first { $0.contains("Franken") })
        #expect(line.split(separator: "\t", omittingEmptySubsequences: false).last == "")
        let giro = try #require(model.tsv.split(separator: "\n").first { $0.contains("Giro") })
        #expect(giro.split(separator: "\t", omittingEmptySubsequences: false).last != "")

        // Several unvalued accounts add up per currency; an empty unvalued account is no gap.
        let gaps = ValuationGaps(balances: [Money(100, "CHF"), Money(50, "CHF"), Money(1, "AUD")], positions: 2)
        #expect(gaps.balances == [Money(1, "AUD"), Money(150, "CHF")])
        #expect(gaps.note?.contains("2 positions") == true)
        #expect(ValuationGaps().isEmpty && ValuationGaps().note == nil)

        let demo = try await overview(demoStore())
        #expect(demo.gaps.isEmpty)
        #expect(demo.depots.allSatisfy { $0.unvaluedPositions == 0 })
        #expect(demo.accounts.allSatisfy { $0.firstActivity != nil && $0.firstActivity! <= $0.lastActivity! })
    }

    @Test func positionsWithoutQuotesAreFlagged() async throws {
        let edge = EdgeFile(today: today)
        let store = PortfolioStore(file: edge.file, today: today)
        let today = today
        let id = edge.brokerA.id
        let model = try await store.analyze("accounts.depot-detail", scope: .depot(id), variant: today) { analysis in
            guard let detail = DepotDetailModel(analysis, depot: id, today: today) else { throw MissingEntity() }
            return detail
        }
        let unlisted = try #require(model.positions.first { $0.id == edge.unlisted.id })
        #expect(unlisted.pricing == .derived)
        #expect(unlisted.value == 100_000)                       // the purchase price, not a market price
        #expect(unlisted.priceWarning(on: today)?.contains("No quotes") == true)
        #expect(unlisted.staleDays(on: today) == nil)            // derived, not stale
        let priced = try #require(model.positions.first { $0.id == edge.priced.id })
        #expect(priced.pricing == .quoted)
        #expect(priced.priceDay == today.advanced(by: -40))
        #expect(priced.staleDays(on: today) == 40)
        #expect(priced.priceWarning(on: today)?.hasPrefix("Last quote from") == true)
        #expect(priced.staleDays(on: today.advanced(by: -35)) == nil)
        #expect(model.valuationWarning == "1 position at transaction price")
        #expect(model.today == today)

        // The demo has current quotes for everything it holds.
        let demo = demoStore()
        let depot = demo.file.depots[0].id
        let detail = try await demo.analyze("accounts.depot-detail", scope: .depot(depot), variant: today) { analysis in
            guard let detail = DepotDetailModel(analysis, depot: depot, today: today) else { throw MissingEntity() }
            return detail
        }
        #expect(detail.valuationWarning == nil)
        #expect(detail.positions.allSatisfy { $0.pricing == .quoted && $0.priceWarning(on: today) == nil })
    }

    /// Review finding: Delete could remove rows that a quick filter had hidden.
    @Test func actionsOnlyTouchTheListedPartOfASelection() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(TableSelection.effective([a, b, c], visible: [c, d]) == [c])
        #expect(TableSelection.effective([a, b], visible: [c, d]).isEmpty)
        #expect(TableSelection.effective([a], visible: [a, b, c, d]) == [a])
        #expect(TableSelection.effective(Set<UUID>(), visible: [a]).isEmpty)
        #expect(TableSelection.effective([a, b, c, d], visible: [b]) == [b])

        // End to end on the model: select three rows, filter them away — nothing is left to delete.
        let store = demoStore()
        let account = store.file.accounts[0].id
        let all = Statement(store.ledger, account: account, interval: nil, filter: QuickFilter(""))
        let deposits = Set(all.rows.filter { $0.kind == .deposit }.prefix(3).map(\.id))
        #expect(deposits.count == 3)
        let filtered = Statement(store.ledger, account: account, interval: nil, filter: QuickFilter("dividend"))
        #expect(TableSelection.effective(deposits, visible: filtered.ids).isEmpty)
        #expect(all.stamp != filtered.stamp)
    }

    @Test func showTransactionsOpensExactlyThatEntity() {
        let store = demoStore()
        let account = store.file.accounts[1].id, depot = store.file.depots[1].id
        #expect(AccountsActions.transactionsRoute(.account(account)) == Route(.transactions, focus: .account(account)))
        AccountsActions.showTransactions(.depot(depot), in: store)
        #expect(store.route.screen == .transactions)
        #expect(store.route.depotID == depot)
        AccountsActions.showTransactions(.account(account), in: store)
        #expect(store.route == Route(.transactions, focus: .account(account)))
    }

    @Test func chartsStepAsideInShortWindows() {
        // 1440×900 window: header ≈ 190, charts ≈ 250, table gets what is left.
        #expect(DetailLayout.showsCharts(available: 848, fixed: 280, charts: 266, minTable: 240))
        // 1000×700 window: charts would leave about 100 pt for the table — they go.
        #expect(!DetailLayout.showsCharts(available: 648, fixed: 280, charts: 266, minTable: 240))
        #expect(DetailLayout.showsCharts(available: 786, fixed: 280, charts: 266, minTable: 240))
        #expect(!DetailLayout.showsCharts(available: 785, fixed: 280, charts: 266, minTable: 240))
    }

    @Test func overviewKeysActOnVisibleRowsOnly() {
        let a = AccountsEntity.account(UUID()), b = AccountsEntity.account(UUID()), hidden = AccountsEntity.depot(UUID())
        let visible = [a, b]
        // A highlight in a collapsed group is no target for Return or Delete.
        #expect(OverviewNavigation.resolved(hidden, visible: visible) == nil)
        #expect(OverviewNavigation.resolved(a, visible: visible) == a)
        #expect(OverviewNavigation.resolved(nil, visible: visible) == nil)
        #expect(OverviewNavigation.moved(nil, by: 1, visible: visible) == a)
        #expect(OverviewNavigation.moved(nil, by: -1, visible: visible) == b)
        #expect(OverviewNavigation.moved(a, by: 1, visible: visible) == b)
        #expect(OverviewNavigation.moved(b, by: 1, visible: visible) == b)
        #expect(OverviewNavigation.moved(a, by: -1, visible: visible) == a)
        #expect(OverviewNavigation.moved(hidden, by: 1, visible: visible) == a)
        #expect(OverviewNavigation.moved(a, by: 1, visible: []) == nil)
        let file = SampleData.demoPortfolio(today: today)
        #expect(AccountsOverviewView.launchHighlight("last", in: file) == .depot(file.depots[1].id))
        #expect(AccountsOverviewView.launchHighlight("savings account", in: file) == .account(file.accounts[1].id))
    }

    @Test func paletteHasNoCommandsForADeletedEntity() {
        let store = demoStore()
        let depot = store.file.depots[1].id
        store.navigate(to: .depot(depot))
        #expect(AccountsFeature.commands(store).contains { $0.id == "accounts.show-transactions" })
        store.deleteDepots([depot])
        // Whether or not the store has already dropped the stale focus, nothing refers to the ghost.
        let commands = AccountsFeature.commands(store)
        #expect(commands.map(\.id) == ["accounts.transfer", "accounts.copy-balances"])
        #expect(!AccountsActions.exists(.depot(depot), in: store))

        // The transfer command does not prefill an account that is gone either.
        let account = Account(name: "Temp", currency: "EUR")
        store.addAccount(account)
        store.navigate(to: .account(account.id))
        store.deleteAccounts([account.id])
        AccountsFeature.commands(store).first { $0.id == "accounts.transfer" }?.action()
        #expect(store.sheet == .newTransaction(TransactionPrefill(kind: .cashTransfer, date: today, accountID: nil)))
    }

    @Test func currencyIsLockedByTransactionsAndByPlans() {
        let id = UUID()
        let plan = InvestmentPlan(name: "Save", kind: .deposit, accountID: id, amount: Money(100, "EUR"), start: today)
        let other = InvestmentPlan(name: "Other", kind: .deposit, accountID: UUID(), amount: Money(100, "EUR"), start: today)
        #expect(AccountCurrencyLock.evaluate(account: id, bookedTransactions: 0, plans: [other]) == .open)
        #expect(AccountCurrencyLock.evaluate(account: id, bookedTransactions: 0, plans: [plan, other]) == .plans(1))
        #expect(AccountCurrencyLock.evaluate(account: id, bookedTransactions: 4, plans: [plan]) == .transactions(4))
        #expect(!AccountCurrencyLock.open.isLocked)
        #expect(AccountCurrencyLock.plans(1).isLocked)
        #expect(AccountCurrencyLock.plans(1).explanation(currency: "EUR").contains("investment plan"))
        #expect(AccountCurrencyLock.open.explanation(currency: "EUR").contains("investment plan"))

        // Through the store: a fresh account with a plan but no transactions.
        var file = PortfolioFile(name: "Plans")
        let account = Account(name: "Cash", currency: "EUR")
        file.accounts = [account]
        let store = PortfolioStore(file: file, today: today)
        #expect(AccountEditor.currencyLock(account.id, in: store) == .open)
        store.addPlan(InvestmentPlan(name: "Save", kind: .deposit, accountID: account.id, amount: Money(100, "EUR"), start: today))
        #expect(AccountEditor.currencyLock(account.id, in: store) == .plans(1))
    }

    @Test func referencesMatchTheStoresUsage() {
        let store = demoStore()
        for account in store.file.accounts {
            let usage = store.usage(ofAccounts: [account.id])
            let references = EntityReferences.account(account.id, in: store.file)
            #expect(references.plans == usage.plans)
            #expect(references.classifications == usage.classifications)
            #expect(references.depots.count == usage.depots)
        }
        for depot in store.file.depots {
            #expect(EntityReferences.depot(depot.id, in: store.file).plans == store.usage(ofDepots: [depot.id]).plans)
        }
        #expect(store.file.accounts.contains { !EntityReferences.account($0.id, in: store.file).depots.isEmpty })
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
