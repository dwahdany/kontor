import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureEarnings

// Tests of the Earnings feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Earnings"):
//
//     KONTOR_FEATURES=Earnings swift test --scratch-path .build-earnings --filter FeatureEarningsTests
@Suite @MainActor struct EarningsFeatureTests {
    private let today = Day(year: 2026, month: 6, day: 30)

    private func demoStore() -> PortfolioStore {
        PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
    }

    private func model(_ store: PortfolioStore, kind: EarningsKind = .dividends, scope: Scope? = nil,
                       interval: DayInterval? = nil) async throws -> EarningsModel {
        let all = store.interval(for: .allTime)
        let query = EarningsModel.Query(kind: kind, today: store.today, allYears: all)
        return try await store.analyze("earnings.model", scope: scope, interval: interval ?? all, variant: query) { analysis in
            EarningsModel(analysis, query: query)
        }
    }

    @Test func moduleRegistersItsScreen() {
        #expect(EarningsFeature.module.screen == .earnings)
    }

    @Test func totalsAgreeWithTheEngineAndWithEachOther() async throws {
        let store = demoStore()
        let all = store.interval(for: .allTime)
        let report = store.ledger.earnings(in: all, scope: .portfolio)
        for kind in EarningsKind.allCases {
            let model = try await model(store, kind: kind)
            #expect(!model.isEmpty)
            #expect(model.totalValue == report.total[kind.metric])
            // Matrix: rows and columns both add up to the engine total.
            #expect(model.matrix.reduce(0) { $0 + $1.total } == model.totalValue)
            #expect(model.matrixColumnTotals.reduce(0, +) == model.totalValue)
            for row in model.matrix { #expect(row.values.reduce(0, +) == row.total) }
            // Chart: every bar width adds up to the same total, stacked or not.
            for grouping in EarningsGrouping.allCases {
                let chart = try #require(model.charts[grouping])
                let plain = chart.plain.reduce(0.0) { $0 + $1.values.reduce(0, +) }
                #expect(Int64(plain.rounded()) == model.totalValue)
                #expect(chart.amounts.reduce(0) { $0 + $1[kind.metric] } == model.totalValue)
                if let stacked = chart.bySecurity {
                    let sum = stacked.reduce(0.0) { $0 + $1.values.reduce(0, +) }
                    #expect(Int64(sum.rounded()) == model.totalValue)
                }
            }
            // By security: rows (incl. "not tied to a security") add up to the total.
            #expect(model.securities.reduce(0) { $0 + $1.amount } == model.totalValue)
        }
    }

    @Test func tilesUseCalendarWindows() async throws {
        let store = demoStore()
        let model = try await model(store)
        let ledger = store.ledger
        let ytd = ledger.earnings(in: store.interval(for: .ytd), scope: .portfolio).total.dividends
        let lastYear = ledger.earnings(in: store.interval(for: .year(2025)), scope: .portfolio).total.dividends
        #expect(model.tiles.thisYear == ytd)
        #expect(model.tiles.lastYear == lastYear)
        #expect(model.tiles.year == 2026)
        // The engine's rolling twelve-month sum at the current month is the "last 12 months" tile.
        let trailing = ledger.earnings(in: store.interval(for: .allTime), scope: .portfolio).trailingTwelveMonths(.dividends)
        #expect(model.tiles.trailing == trailing.last?.value)
        #expect(model.tiles.averagePerMonth == model.tiles.trailing / 12)
        // The current year is compared with the same days of last year in the tile and the matrix.
        let current = try #require(model.matrix.first)
        #expect(current.year == 2026)
        #expect(current.growthIsSamePeriod)
        #expect(current.growth == model.tiles.samePeriodGrowth)
        let expected = Double(model.tiles.thisYear) / Double(model.tiles.samePeriodLastYear) - 1
        #expect(abs((model.tiles.samePeriodGrowth ?? 0) - expected) < 1e-12)
    }

    @Test func tilesIgnoreTheSelectedRangeButTheTablesFollowIt() async throws {
        let store = demoStore()
        let all = try await model(store)
        let threeYears = try await model(store, interval: store.interval(for: .lastYears(3)))
        #expect(threeYears.tiles.thisYear == all.tiles.thisYear)
        #expect(threeYears.tiles.trailing == all.tiles.trailing)
        #expect(threeYears.totalValue < all.totalValue)
        #expect(threeYears.matrix.count == 4)
        // The first, cut-off year of the range is not a fair basis for the next year's growth.
        let secondYear = threeYears.matrix[threeYears.matrix.count - 2]
        #expect(secondYear.growth == nil)
        // The calendar always looks at all years.
        #expect(threeYears.calendar.expectedTotal == all.calendar.expectedTotal)
    }

    @Test func projectionRepeatsLastYearsPaymentsForTheSharesHeldToday() async throws {
        let store = demoStore()
        let model = try await model(store)
        let calendar = model.calendar
        #expect(calendar.months.count == 12)
        #expect(calendar.months.first?.detail == Fmt.month(year: 2026, month: 7, long: true))
        #expect(calendar.expected.reduce(0, +) == calendar.expectedTotal)
        #expect(calendar.expectedByCalendarMonth.reduce(0, +) == calendar.expectedTotal)
        #expect(calendar.rows.reduce(0) { $0 + $1.expectedTotal } == calendar.expectedTotal)
        #expect(calendar.expectedTotal > 0)

        // Recompute every security by hand, from the engine's bookings and today's position:
        // per payment day, gross of all bookings ÷ shares of all bookings × shares held today.
        let ledger = store.ledger
        let report = ledger.earnings(in: store.interval(for: .allTime), scope: .portfolio)
        let positions = ledger.snapshot(on: today, scope: .portfolio).positions
        let windowStart = Day(year: 2025, month: 7, day: 1)
        for row in calendar.rows {
            let shares = positions.first { $0.securityID == row.id }?.shares ?? .zero
            #expect(row.shares == shares)
            let history = report.dividendHistory(for: row.id).filter { $0.day >= windowStart && $0.day <= today }
            var expected: Int64 = 0
            for day in Set(history.map(\.day)) {
                let bookings = history.filter { $0.day == day }
                let gross = bookings.reduce(Int64(0)) { $0 + $1.gross }
                let paidFor = bookings.reduce(Int64(0)) { $0 + $1.shares.raw }
                if paidFor > 0 { expected += mulDiv(gross, shares.raw, paidFor) }
            }
            #expect(row.expectedTotal == expected)
            // Dots: a month is "recent" exactly if a payment fell into it during the last twelve months.
            for month in 0..<12 {
                #expect(row.recent[month] == history.contains { $0.day.month == month + 1 })
            }
        }

        // The demo holds Halvard Europe Dividend in two depots (241 + 40 shares), each with its own
        // dividend booking per pay date: four payments of 0.78 EUR per share in total → 219.18 EUR,
        // not once per booking (438.36 EUR, the former double count).
        let halvard = try #require(calendar.rows.first { $0.name.hasPrefix("Halvard") })
        #expect(halvard.shares == Shares(281))
        #expect(halvard.paymentsPerYear == 4)
        #expect(halvard.expectedTotal == 219_18)
        #expect(calendar.expectedTotal == 1_723_83)
    }

    // MARK: Dividend payments across depots, scopes and windows

    /// One security, bought on 2024-01-02 in each of `depots.count` depots, with dividends.
    private struct Fixture {
        var file = PortfolioFile(name: "Fixture")
        let security = Security(name: "TwoDepot AG", currency: "EUR")
        let account = Account(name: "Cash", currency: "EUR")
        var depots: [Depot] = []

        init(sharesPerDepot: [Double]) {
            file.securities = [security]
            file.accounts = [account]
            for (i, shares) in sharesPerDepot.enumerated() {
                let depot = Depot(name: "Depot \(i + 1)", referenceAccountID: account.id)
                depots.append(depot)
                file.transactions.append(Transaction(
                    kind: .buy, date: Day(year: 2024, month: 1, day: 2), accountID: account.id, depotID: depot.id,
                    securityID: security.id, shares: Shares(shares), amount: Money(shares * 10, "EUR")))
            }
            file.depots = depots
            file.transactions.insert(Transaction(
                kind: .deposit, date: Day(year: 2024, month: 1, day: 1), accountID: account.id, amount: Money(100_000, "EUR")), at: 0)
        }

        /// A dividend booking of `perShare` EUR for the depot's shares; `statesShares: false`
        /// leaves the share count out, as imported bookings often do.
        mutating func pay(_ day: Day, depot index: Int, shares: Double, perShare: Double, statesShares: Bool = true) {
            file.transactions.append(Transaction(
                kind: .dividend, date: day, accountID: account.id, depotID: depots[index].id, securityID: security.id,
                shares: statesShares ? Shares(shares) : .zero, amount: Money(shares * perShare, "EUR")))
        }
    }

    @Test func aSecurityInTwoDepotsIsProjectedOnce() async throws {
        for statesShares in [true, false] {
            var fixture = Fixture(sharesPerDepot: [50, 50])
            for day in [Day(year: 2025, month: 11, day: 14), Day(year: 2026, month: 5, day: 15)] {
                fixture.pay(day, depot: 0, shares: 50, perShare: 1, statesShares: statesShares)
                fixture.pay(day, depot: 1, shares: 50, perShare: 1, statesShares: statesShares)
            }
            let store = PortfolioStore(file: fixture.file, today: today)
            let model = try await model(store)
            // 100 shares × 1.00 EUR × two payments a year = 200.00 EUR (not 400.00 EUR).
            #expect(model.calendar.expectedTotal == 200_00)
            let row = try #require(model.calendar.rows.first)
            #expect(row.paymentsPerYear == 2)
            #expect(row.shares == Shares(100))
            // The two bookings of a day are one payment of 100.00 EUR at 1.00 EUR per share.
            let security = try #require(model.securities.first)
            #expect(security.count == 2)
            #expect(security.lastGross == 100_00)
            #expect(security.lastDay == Day(year: 2026, month: 5, day: 15))
            #expect(security.perShare == Price(1))
            #expect(model.paymentCount == 2)

            // One depot alone: its own 50 shares.
            let depot = try await self.model(store, scope: .depot(fixture.depots[1].id))
            #expect(depot.calendar.expectedTotal == 100_00)
            #expect(depot.securities.first?.lastGross == 50_00)
        }
    }

    @Test func bookingsOfOneDayAreOnePaymentEverywhere() async throws {
        // Demo: Halvard Europe Dividend pays into two depots; on 2026-04-15 it paid 48.20 + 8.00 EUR.
        let store = demoStore()
        let model = try await model(store)
        let row = try #require(model.securities.first { $0.name.hasPrefix("Halvard") })
        #expect(row.lastDay == Day(year: 2026, month: 4, day: 15))
        #expect(row.lastGross == 56_20)
        let bookings = store.ledger.earnings(in: store.interval(for: .allTime), scope: .portfolio).dividendHistory(for: row.id)
        let days = Set(bookings.map(\.day))
        #expect(days.count < bookings.count)
        #expect(row.count == days.count)
        #expect(row.perShare == Price(minor: 56_20, per: Shares(281)))
        // The inspector tells the same story.
        let inspector = try await store.analyze("earnings.inspector", interval: store.interval(for: .allTime), variant: row.id) { analysis in
            EarningsInspector.Model(analysis, securityID: row.id)
        }
        #expect(inspector.count == row.count)
        #expect(inspector.last?.gross == 56_20)
        #expect(inspector.total == row.amount)
        #expect(inspector.perYear.reduce(0, +) == inspector.total)
        // And in an account scope: what arrived on that account.
        let payment = try #require(bookings.last)
        let account = try await store.analyze("earnings.inspector", scope: .account(payment.accountID), interval: store.interval(for: .allTime), variant: row.id) { analysis in
            EarningsInspector.Model(analysis, securityID: row.id)
        }
        #expect(!account.isEmpty)
        #expect(account.total == bookings.filter { $0.accountID == payment.accountID }.reduce(0) { $0 + $1.gross })
    }

    @Test func projectionFollowsTheSharesHeldToday() async throws {
        var fixture = Fixture(sharesPerDepot: [100])
        fixture.pay(Day(year: 2025, month: 9, day: 10), depot: 0, shares: 100, perShare: 2)
        // 40 more shares since the payment.
        fixture.file.transactions.append(Transaction(
            kind: .buy, date: Day(year: 2026, month: 2, day: 3), accountID: fixture.account.id, depotID: fixture.depots[0].id,
            securityID: fixture.security.id, shares: Shares(40), amount: Money(400, "EUR")))
        let store = PortfolioStore(file: fixture.file, today: today)
        let model = try await model(store)
        #expect(model.calendar.expectedTotal == 280_00)
        // September 2026 is the third of the twelve months after June 30.
        #expect(model.calendar.expected[2] == 280_00)
    }

    @Test func aWeightedScopeProjectsItsPart() async throws {
        var fixture = Fixture(sharesPerDepot: [100])
        fixture.pay(Day(year: 2025, month: 9, day: 10), depot: 0, shares: 100, perShare: 2)
        let store = PortfolioStore(file: fixture.file, today: today)
        let scope = Scope.weighted(securities: [fixture.security.id: 6_500], accounts: [:])
        let model = try await model(store, scope: scope)
        // 65 % of the security: 65 % of what was paid and 65 % of what is expected.
        #expect(model.tiles.trailing == 130_00)
        #expect(model.calendar.expectedTotal == 130_00)
        #expect(model.securities.first?.lastGross == 130_00)
        // The amount per share is the security's, whatever the scope's weight.
        #expect(model.securities.first?.perShare == Price(2))
    }

    @Test func theTrailingWindowIsTwelveMonthsOnAnyDay() async throws {
        // Pays on the 12th of March, June, September and December.
        var fixture = Fixture(sharesPerDepot: [100])
        var day = Day(year: 2024, month: 3, day: 12)
        while day <= Day(year: 2026, month: 6, day: 30) {
            fixture.pay(day, depot: 0, shares: 100, perShare: 1)
            day = day.addingMonths(3)
        }
        // June 5: this June's payment is still to come, last June's is 51 weeks back.
        let june5 = Day(year: 2026, month: 6, day: 5)
        let early = try await model(PortfolioStore(file: fixture.file, today: june5))
        #expect(early.tiles.trailingInterval == DayInterval(start: Day(year: 2025, month: 6, day: 5), end: june5))
        #expect(early.tiles.trailing == 400_00)
        #expect(early.tiles.averagePerMonth == 400_00 / 12)
        #expect(early.calendar.basisInterval == early.tiles.trailingInterval)
        #expect(early.calendar.interval == DayInterval(start: june5, end: Day(year: 2027, month: 6, day: 5)))
        #expect(early.calendar.rows.first?.paymentsPerYear == 4)
        #expect(early.calendar.expectedTotal == 400_00)
        // June 6, 2026 … June 5, 2027 touches thirteen calendar months; the payment expected on
        // June 12, 2026 is in the first one.
        #expect(early.calendar.months.count == 13)
        #expect(early.calendar.expected.first == 100_00)
        #expect(early.calendar.expected.last == 0)
        #expect(early.calendar.expectedByCalendarMonth[5] == 100_00)
        #expect(early.calendar.rows.first?.recent[5] == true)

        // June 30: the same four payments, now in twelve whole months.
        let late = try await model(PortfolioStore(file: fixture.file, today: today))
        #expect(late.tiles.trailing == 400_00)
        #expect(late.calendar.months.count == 12)
        #expect(late.calendar.expectedTotal == 400_00)
        #expect(late.calendar.expected.last == 100_00)
    }

    // MARK: Account scope

    @Test func anAccountScopeShowsWhatWasBookedOnTheAccount() async throws {
        let store = demoStore()
        let all = store.interval(for: .allTime)
        let portfolio = store.ledger.earnings(in: all, scope: .portfolio)
        #expect(portfolio.byAccount.contains { $0.amounts.dividends > 0 })
        for booked in portfolio.byAccount {
            let scope = Scope.account(booked.accountID)
            for kind in EarningsKind.allCases {
                let model = try await model(store, kind: kind, scope: scope)
                #expect(model.isAccountScope)
                #expect(!model.isEmpty)
                // The same amounts the Accounts view of the whole portfolio attributes to it …
                #expect(model.total == booked.amounts)
                #expect(model.totalValue == booked.amounts[kind.metric])
                // … spread exactly over months, bars and securities.
                #expect(model.matrix.reduce(0) { $0 + $1.total } == model.totalValue)
                #expect(model.matrixColumnTotals.reduce(0, +) == model.totalValue)
                #expect(model.securities.reduce(0) { $0 + $1.amount } == model.totalValue)
                for grouping in EarningsGrouping.allCases {
                    let chart = try #require(model.charts[grouping])
                    #expect(chart.amounts.reduce(0) { $0 + $1[kind.metric] } == model.totalValue)
                }
                #expect(model.accounts.map(\.id) == [booked.accountID])
            }
            // Dividend payments and the calendar follow the account, too.
            let newestFirst = [KeyPathComparator(\PaymentRow.day, order: .reverse)]
            let query = PaymentsModel.Query(filter: "", months: nil, securityID: nil, sortOrder: newestFirst)
            let payments = try await store.analyze("earnings.payments", scope: scope, interval: all, variant: query) { PaymentsModel($0, query: query) }
            #expect(payments.gross == booked.amounts.dividends)
            #expect(payments.rows.allSatisfy { $0.accountID == booked.accountID })
            let dividends = try await model(store, scope: scope)
            #expect((dividends.calendar.expectedTotal > 0) == (dividends.tiles.trailing > 0))
        }
        // Every dividend arrives on exactly one account: the accounts' projections add up to the portfolio's.
        var expected: Int64 = 0
        for account in store.file.accounts {
            expected += try await model(store, scope: .account(account.id)).calendar.expectedTotal
        }
        let whole = try await model(store).calendar.expectedTotal
        #expect(abs(expected - whole) <= Int64(store.file.securities.count))

        // An account nothing was ever booked on is empty.
        var file = SampleData.demoPortfolio(today: today)
        let unused = Account(name: "Unused", currency: "EUR")
        file.accounts.append(unused)
        let empty = try await model(PortfolioStore(file: file, today: today), scope: .account(unused.id))
        #expect(empty.isEmpty)
    }

    // MARK: Missing exchange rates

    @Test func bookingsWithoutAnExchangeRateAreReported() async throws {
        var fixture = Fixture(sharesPerDepot: [100])
        fixture.pay(Day(year: 2026, month: 3, day: 10), depot: 0, shares: 100, perShare: 1)
        let usd = Account(name: "USD Cash", currency: "USD")
        fixture.file.accounts.append(usd)
        // 20 USD and 5,000 JPY of dividends, and no exchange rate for either.
        let lost = Transaction(kind: .dividend, date: Day(year: 2026, month: 4, day: 10), accountID: usd.id, depotID: fixture.depots[0].id,
                               securityID: fixture.security.id, shares: Shares(100), amount: Money(20, "USD"))
        let yen = Account(name: "JPY Cash", currency: "JPY")
        fixture.file.accounts.append(yen)
        let lostToo = Transaction(kind: .interest, date: Day(year: 2026, month: 4, day: 11), accountID: yen.id, amount: Money(5_000, "JPY"))
        // A fee long before the interval and a deposit: neither is reported.
        let old = Transaction(kind: .fee, date: Day(year: 2024, month: 2, day: 1), accountID: usd.id, amount: Money(1, "USD"))
        let deposit = Transaction(kind: .deposit, date: Day(year: 2026, month: 4, day: 1), accountID: usd.id, amount: Money(500, "USD"))
        fixture.file.transactions += [lost, lostToo, old, deposit]
        let store = PortfolioStore(file: fixture.file, today: today)

        let model = try await model(store, interval: store.interval(for: .ytd))
        #expect(model.tiles.thisYear == 100_00)   // the engine counts the USD dividend as zero
        #expect(model.unconverted.transactionIDs == [lost.id, lostToo.id])
        #expect(model.unconverted.currencies == ["JPY", "USD"])
        #expect(model.unconverted.message(reportingCurrency: "EUR").hasPrefix("2 bookings in JPY, USD are missing"))
        // All years: the old fee as well.
        #expect(try await self.model(store).unconverted.count == 3)
        // The scope decides: the EUR account has no such booking, the USD account has one this year.
        #expect(try await self.model(store, scope: .account(fixture.account.id)).unconverted.isEmpty)
        #expect(try await self.model(store, scope: .account(usd.id), interval: store.interval(for: .ytd)).unconverted.transactionIDs == [lost.id])

        // The payment list marks the row instead of showing 0.00.
        let query = PaymentsModel.Query(filter: "", months: nil, securityID: nil, sortOrder: [KeyPathComparator(\PaymentRow.day)])
        let payments = try await store.analyze("earnings.payments", interval: store.interval(for: .ytd), variant: query) { PaymentsModel($0, query: query) }
        #expect(payments.rows.map(\.isConverted) == [true, false])
        #expect(payments.unconverted.transactionIDs == [lost.id])
        let table = EarningsExport.payments(payments.rows, currency: "EUR", numbers: .plain)
        #expect(table.rows[1][5] == "" && table.rows[0][5] == "100")

        // With a rate nothing is reported.
        #expect(try await self.model(demoStore()).unconverted.isEmpty)
    }

    // MARK: Rules

    @Test func growthNeedsTwoPositiveAmounts() {
        #expect(EarningsRules.growth(150, over: 100) == 0.5)
        #expect(EarningsRules.growth(50, over: 100) == -0.5)
        #expect(EarningsRules.growth(100, over: 0) == nil)
        // A sign change (tax refunds, a net loss) has no growth rate.
        #expect(EarningsRules.growth(-254, over: 1) == nil)
        #expect(EarningsRules.growth(100, over: -35) == nil)
        #expect(EarningsRules.growth(-10, over: -20) == nil)
        // 82.00 against 0.10 is "+81,900 %": true and useless.
        #expect(EarningsRules.growth(82_00, over: 10) == nil)
        #expect(EarningsRules.growth(1_100, over: 100) == 10)
    }

    @Test func sharesOfATotalNeedPartsOfOneSign() async throws {
        #expect(EarningsRules.sharesAreMeaningful([10, 20, 0]))
        #expect(EarningsRules.sharesAreMeaningful([-10, -20]))
        #expect(!EarningsRules.sharesAreMeaningful([10, -20]))
        #expect(!EarningsRules.sharesAreMeaningful([Int64]()))
        #expect(!EarningsRules.sharesAreMeaningful([0, 0]))

        // Demo: dividends are all positive; taxes contain refunds that are not tied to a security.
        let store = demoStore()
        let dividends = try await model(store)
        #expect(dividends.securitySharesAreMeaningful && dividends.matrixSharesAreMeaningful && dividends.accountSharesAreMeaningful)
        #expect(dividends.showsDividendColumns)
        let taxes = try await model(store, kind: .taxes)
        #expect(taxes.securities.contains { $0.amount < 0 })
        #expect(!taxes.securitySharesAreMeaningful)
        #expect(!taxes.showsDividendColumns)
        // No growth rate against a year with a net refund or after one.
        for (index, row) in taxes.matrix.enumerated() where row.growth != nil && !row.growthIsSamePeriod {
            #expect(row.total > 0)
            #expect(taxes.matrix[index + 1].total > 0)
            #expect((row.growth ?? 0) <= EarningsRules.largestGrowth)
        }
        let table = EarningsExport.securities(taxes, rows: taxes.securities, numbers: .plain)
        #expect(table.rows.allSatisfy { $0[3] == "" })
    }

    @Test func aSelectionNeverOutlivesItsRows() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(EarningsRules.visible([a, b], in: [b, c]) == [b])
        #expect(EarningsRules.visible([a], in: [b, c]).isEmpty)
        #expect(EarningsRules.visible(Set<UUID>(), in: [a]).isEmpty)
    }

    @Test func rowsSignatureFollowsTheVisiblePayments() async throws {
        let store = demoStore()
        let all = store.interval(for: .allTime)
        func payments(_ filter: String, order: SortOrder = .reverse) async throws -> PaymentsModel {
            let query = PaymentsModel.Query(filter: filter, months: nil, securityID: nil, sortOrder: [KeyPathComparator(\PaymentRow.day, order: order)])
            return try await store.analyze("earnings.payments", interval: all, variant: query) { PaymentsModel($0, query: query) }
        }
        let everything = try await payments("")
        let filtered = try await payments("halvard")
        #expect(filtered.rows.count < everything.rows.count && !filtered.rows.isEmpty)
        #expect(filtered.rowsSignature != everything.rowsSignature)
        // Sorting keeps the rows: the selection may stay.
        #expect(try await payments("", order: .forward).rowsSignature == everything.rowsSignature)
        // What a stale selection would have deleted: only the rows still listed remain actionable.
        let hidden = try #require(everything.rows.first { row in !filtered.rows.contains { $0.id == row.id } })
        let shown = try #require(filtered.rows.first)
        #expect(EarningsRules.visible([hidden.id, shown.id], in: filtered.rows.map(\.id)) == [shown.id])
    }

    @Test func barsMapToMonths() {
        Fmt.setLocale(Locale(identifier: "en_US"))
        #expect(EarningsRules.months(ofBar: "2025-05") == (2025 * 12 + 4)...(2025 * 12 + 4))
        #expect(EarningsRules.months(ofBar: "2025-Q2") == (2025 * 12 + 3)...(2025 * 12 + 5))
        #expect(EarningsRules.months(ofBar: "2025") == (2025 * 12)...(2025 * 12 + 11))
        #expect(EarningsRules.months(ofBar: "2025-13") == nil)
        #expect(EarningsRules.months(ofBar: "2025-Q5") == nil)
        #expect(EarningsRules.months(ofBar: "other") == nil)
        #expect(EarningsRules.title(ofMonths: (2025 * 12 + 3)...(2025 * 12 + 5)) == "Q2 2025")
        #expect(EarningsRules.title(ofMonths: (2025 * 12)...(2025 * 12 + 11)) == "2025")
        #expect(EarningsRules.title(ofMonths: (2025 * 12 + 4)...(2025 * 12 + 4)) == Fmt.month(year: 2025, month: 5, long: true))
    }

    @Test func paymentsFilterSortAndAddUp() async throws {
        let store = demoStore()
        let all = store.interval(for: .allTime)
        let newestFirst = [KeyPathComparator(\PaymentRow.day, order: .reverse)]
        let everything = PaymentsModel.Query(filter: "", months: nil, securityID: nil, sortOrder: newestFirst)
        let payments = try await store.analyze("earnings.payments", interval: all, variant: everything) { PaymentsModel($0, query: everything) }
        let report = store.ledger.earnings(in: all, scope: .portfolio)
        #expect(payments.rows.count == report.payments.count)
        #expect(payments.gross == report.total.dividends)
        #expect(payments.rows.first!.day >= payments.rows.last!.day)
        #expect(payments.rows.allSatisfy { store.transaction($0.id)?.kind == .dividend })

        let october = PaymentsModel.Query(filter: "", months: (2025 * 12 + 9)...(2025 * 12 + 9), securityID: nil, sortOrder: newestFirst)
        let filtered = try await store.analyze("earnings.payments", interval: all, variant: october) { PaymentsModel($0, query: october) }
        #expect(!filtered.rows.isEmpty)
        #expect(filtered.rows.allSatisfy { $0.day.year == 2025 && $0.day.month == 10 })
        #expect(filtered.totalCount == report.payments.count)
        let month = try #require(report.months.first { $0.year == 2025 && $0.month == 10 })
        #expect(filtered.gross == month.amounts.dividends)

        // A quarter or a year of a chart bar.
        let quarter = PaymentsModel.Query(filter: "", months: EarningsRules.months(ofBar: "2025-Q4"), securityID: nil, sortOrder: newestFirst)
        let fourth = try await store.analyze("earnings.payments", interval: all, variant: quarter) { PaymentsModel($0, query: quarter) }
        let sum = report.months.filter { $0.year == 2025 && $0.month >= 10 }.reduce(Int64(0)) { $0 + $1.amounts.dividends }
        #expect(fourth.gross == sum)
    }

    @Test func emptyAndScopedStates() async throws {
        var file = SampleData.demoPortfolio(today: today)
        file.transactions = []
        let empty = PortfolioStore(file: file, today: today)
        let model = try await model(empty)
        #expect(model.isEmpty)
        #expect(model.calendar.isEmpty)
        #expect(model.securities.isEmpty)
        #expect(model.tiles.samePeriodGrowth == nil)
    }

    @Test func csvIsQuotedNeutralizedAndMachineReadable() async throws {
        let table = EarningsTable(name: "T", header: ["Name", "Amount"], rows: [
            ["Plain", "12.5"], ["Has, comma", "-3"], ["=SUM(A1)", "1"], ["Say \"hi\"", "0.1"],
        ])
        let csv = EarningsExport.csv(table)
        #expect(csv == "Name,Amount\r\nPlain,12.5\r\n\"Has, comma\",-3\r\n'=SUM(A1),1\r\n\"Say \"\"hi\"\"\",0.1\r\n")

        // Names that merely start like a number are text: `Decimal(string:)` would read "-1x Short DAX" as −1.
        #expect(Decimal(string: "-1x Short DAX") == -1)
        let names = EarningsTable(name: "T", header: ["Name", "Amount"], rows: [
            ["-1x Short DAX", "-1"], ["+2+cmd|' /C calc'!A0", "2"], ["@SUM(1)", "0.5"], ["3M Co", "-0.25"], ["2025-05-01", "1e5"],
        ])
        #expect(EarningsExport.csv(names) == "Name,Amount\r\n'-1x Short DAX,-1\r\n'+2+cmd|' /C calc'!A0,2\r\n'@SUM(1),0.5\r\n3M Co,-0.25\r\n2025-05-01,1e5\r\n")
        for number in ["0", "-3", "12.5", "-0.25", "1234567.89"] { #expect(EarningsExport.isPlainNumber(number)) }
        for text in ["", "-", ".5", "5.", "1.2.3", "+2", "1e5", "-1x", "１２", " 1"] { #expect(!EarningsExport.isPlainNumber(text)) }

        let store = demoStore()
        let model = try await model(store)
        let matrix = EarningsExport.matrix(model, numbers: .plain)
        #expect(matrix.header.count == 16)
        #expect(matrix.rows.count == model.matrix.count + 1)
        #expect(matrix.rows.first?.first == "2017")
        #expect(matrix.rows.last?[13] == "\(Decimal(model.totalValue) / 100)")
        for view in EarningsView.allCases where view != .payments {
            let table = EarningsExport.table(for: view, model: model, grouping: .month, payments: nil)
            #expect(!table.rows.isEmpty)
            #expect(table.rows.allSatisfy { $0.count == table.header.count })
        }
    }

    @Test func formatsDerivedValuesCompactly() {
        Fmt.setLocale(Locale(identifier: "en_US"))
        #expect(EarningsFormat.perShare(Price(0.47534615), currency: "EUR") == Fmt.price(Price(0.4753), currency: "EUR"))
        #expect(EarningsFormat.perShare(nil, currency: "EUR") == Fmt.missing)
        #expect(EarningsFormat.shares(Shares(81.36014567)) == Fmt.shares(Shares(81.3601)))
        #expect(EarningsFormat.shares(Shares(75)) == "75")
    }
}
