import Foundation
import KontorEngine
import KontorModel
import Testing

@Suite struct InvestmentPlanTests {
    @Test func dueDatesClampAndSkipWeekends() {
        let plan = InvestmentPlan(name: "Monthly", amount: Money(100, "EUR"), start: d("2024-01-31"))
        // Feb 29 (leap year), Mar 31 is a Sunday → Monday Apr 1, Apr 30, May 31, Jun 30 is a Sunday → Jul 1.
        #expect(plan.dueDates(through: d("2024-07-01")).map(\.iso)
            == ["2024-01-31", "2024-02-29", "2024-04-01", "2024-04-30", "2024-05-31", "2024-07-01"])
        #expect(plan.dueDates(through: d("2024-06-30"), moveToWeekday: false).map(\.iso)
            == ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30", "2024-05-31", "2024-06-30"])
        #expect(plan.dueDates(through: d("2024-01-30")).isEmpty)
        #expect(plan.nextDueDate(after: d("2024-03-15")) == d("2024-04-01"))
        #expect(plan.nextDueDate(after: d("2024-04-01")) == d("2024-04-30"))
        #expect(plan.nextDueDate(after: d("2020-01-01")) == d("2024-01-31"))

        var quarterly = plan
        quarterly.intervalMonths = 3
        quarterly.start = d("2023-11-30")
        quarterly.end = d("2024-08-30")
        // Nov 30, Feb 29 (clamped), May 30, Aug 30; the next one (Nov 30) is after the end.
        #expect(quarterly.dueDates(through: d("2025-12-31")).map(\.iso)
            == ["2023-11-30", "2024-02-29", "2024-05-30", "2024-08-30"])
        #expect(quarterly.nextDueDate(after: d("2024-08-30")) == nil)

        var broken = plan
        broken.intervalMonths = 0
        #expect(broken.dueDates(through: d("2030-01-01")).isEmpty && broken.nextDueDate(after: d("2024-01-01")) == nil)
        #expect(plan.sourceTag == "plan:\(plan.id.uuidString)")
    }

    @Test func skippedDatesAreNeitherDueNorMissing() throws {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let etf = f.security("ETF", prices: [("2024-01-10", 50)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 1_000)
        var plan = InvestmentPlan(
            id: f.uuid(), name: "ETF plan", securityID: etf, depotID: depot, accountID: cash, amount: Money(100, "EUR"),
            start: d("2024-01-31"))
        // Schedule: Jan 31, Feb 29, Mar 31 (Sunday → Apr 1), Apr 30, May 31.
        // Skip February by its execution day, March by its nominal day (the Sunday) and a future one.
        plan.skippedDates = [d("2024-02-29"), d("2024-03-31"), d("2024-05-31"), d("2023-01-01")]

        #expect(plan.dueDates(through: d("2024-05-10")).map(\.iso) == ["2024-01-31", "2024-04-30"])
        #expect(plan.dueDates(through: d("2024-05-10"), includingSkipped: true).map(\.iso)
            == ["2024-01-31", "2024-02-29", "2024-04-01", "2024-04-30"])
        #expect(plan.skippedDueDates(through: d("2024-05-10")).map(\.iso) == ["2024-02-29", "2024-04-01"])
        #expect(plan.isSkipped(d("2024-02-29")) && plan.isSkipped(d("2024-04-01")) && !plan.isSkipped(d("2024-04-30")))
        #expect(!plan.isSkipped(d("2024-04-01"), moveToWeekday: false))
        // The skipped May execution is not "next".
        #expect(plan.nextDueDate(after: d("2024-05-10")) == d("2024-07-01")) // Jun 30 is a Sunday
        #expect(plan.nextDueDate(after: d("2024-02-01")) == d("2024-04-30"))

        let ledger = f.ledger
        let status = ledger.planStatus(plan, through: d("2024-05-10"))
        #expect(status.dueDates.map(\.iso) == ["2024-01-31", "2024-04-30"])
        #expect(status.missing.map(\.iso) == ["2024-01-31", "2024-04-30"])
        #expect(status.skipped.map(\.iso) == ["2024-02-29", "2024-04-01"])
        #expect(status.nextDue == d("2024-07-01"))

        let proposal = ledger.planTransactions(plan, through: d("2024-05-10"))
        #expect(proposal.transactions.map(\.date.iso) == ["2024-01-31", "2024-04-30"])

        // Skipping every open date leaves nothing to generate; un-skipping brings them back.
        plan.skippedDates = status.missing + (plan.skippedDates ?? [])
        #expect(ledger.planTransactions(plan, through: d("2024-05-10")).transactions.isEmpty)
        #expect(ledger.planStatus(plan, through: d("2024-05-10")).missing.isEmpty)
        plan.skippedDates = nil
        #expect(ledger.planStatus(plan, through: d("2024-05-10")).missing.count == 4)
        plan.skippedDates = []
        #expect(ledger.planStatus(plan, through: d("2024-05-10")).skipped.isEmpty)
    }

    @Test func generatesMissingPurchases() throws {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let etf = f.security("ETF", prices: [("2024-01-10", 49.50), ("2024-02-15", 55), ("2024-03-15", 45)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 1_000)
        let plan = InvestmentPlan(
            id: f.uuid(), name: "ETF plan", securityID: etf, depotID: depot, accountID: cash, amount: Money(100, "EUR"),
            fees: 100, start: d("2024-01-15"))
        // The March execution exists already, moved by the user to the 18th.
        f.file.transactions.append(Transaction(
            kind: .buy, date: d("2024-03-18"), accountID: cash, depotID: depot, securityID: etf, shares: Shares(2.2),
            amount: Money(100, "EUR"), fees: 100, source: "plan:\(plan.id.uuidString.lowercased())"))
        let ledger = f.ledger

        let status = ledger.planStatus(plan, through: d("2024-04-20"))
        #expect(status.dueDates.map(\.iso) == ["2024-01-15", "2024-02-15", "2024-03-15", "2024-04-15"])
        #expect(status.executions.count == 1)
        #expect(status.executions[0].due == d("2024-03-15") && status.executions[0].date == d("2024-03-18"))
        #expect(status.missing.map(\.iso) == ["2024-01-15", "2024-02-15", "2024-04-15"])
        #expect(status.nextDue == d("2024-05-15") && status.problem == nil)

        let proposal = ledger.planTransactions(plan, through: d("2024-04-20"))
        #expect(proposal.skipped.isEmpty && proposal.transactions.count == 3)
        let first = proposal.transactions[0]
        #expect(first.kind == .buy && first.date == d("2024-01-15"))
        #expect(first.accountID == cash && first.depotID == depot && first.securityID == etf)
        #expect(first.amount == Money(100, "EUR") && first.fees == 100 && first.taxes == 0)
        #expect(first.shares == Shares(2)) // (100 − 1) / 49.50
        #expect(first.source == plan.sourceTag && first.note == "ETF plan")
        #expect(proposal.transactions[1].shares == Shares(1.8)) // 99 / 55
        #expect(proposal.transactions[2].shares == Shares(2.2)) // 99 / 45
        #expect(first.id == InvestmentPlan.executionID(plan: plan.id, due: d("2024-01-15")))
        #expect(Set(proposal.transactions.map(\.id)).count == 3)

        // Pure and idempotent: the ledger is untouched; after appending nothing is missing.
        #expect(ledger.transactions.count == 2)
        var updated = f.file
        updated.transactions.append(contentsOf: proposal.transactions)
        let again = Ledger(updated).planTransactions(plan, through: d("2024-04-20"))
        #expect(again.transactions.isEmpty && again.status.missing.isEmpty && again.status.executions.count == 4)
        // The generated buys are valid bookings.
        #expect(Ledger(updated).diagnostics.isEmpty)
        #expect(Ledger(updated).snapshot(on: d("2024-04-20")).position(etf)?.shares == Shares(8.2))

        // Before the first quote there is nothing to buy at.
        var early = plan
        early.start = d("2023-12-15")
        let skipped = ledger.planTransactions(early, through: d("2024-01-20"))
        #expect(skipped.skipped.map(\.due) == [d("2023-12-15")] && skipped.skipped.map(\.reason) == [.noPrice])
        #expect(skipped.transactions.map(\.date) == [d("2024-01-15")])
    }

    @Test func foreignSecurityDepositWithdrawalAndProblems() {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let us = f.security("US ETF", "USD", prices: [("2024-01-01", 110)])
        f.rates("EUR", "USD", [("2024-01-01", 1.10)])
        let ledger = f.ledger
        let purchase = InvestmentPlan(
            name: "US", securityID: us, depotID: depot, accountID: cash, amount: Money(200, "EUR"), start: d("2024-02-01"))
        let buy = ledger.planTransactions(purchase, through: d("2024-02-10")).transactions[0]
        // 200 EUR = 220 USD = 2 shares.
        #expect(buy.shares == Shares(2) && buy.securityGross == Money(220, "USD"))

        var delivery = purchase
        delivery.accountID = nil
        #expect(ledger.planTransactions(delivery, through: d("2024-02-10")).transactions[0].kind == .deliveryIn)

        let deposit = InvestmentPlan(
            name: "Salary", kind: .deposit, accountID: cash, amount: Money(500, "EUR"), start: d("2024-01-01"),
            end: d("2024-03-31"), intervalMonths: 1)
        let deposits = ledger.planTransactions(deposit, through: d("2024-12-31")).transactions
        #expect(deposits.map(\.date.iso) == ["2024-01-01", "2024-02-01", "2024-03-01"])
        #expect(deposits.allSatisfy { $0.kind == .deposit && $0.accountID == cash && $0.amount == Money(500, "EUR") })
        var withdrawal = deposit
        withdrawal.kind = .withdrawal
        #expect(ledger.planTransactions(withdrawal, through: d("2024-01-31")).transactions[0].kind == .withdrawal)

        // Configuration problems block generation.
        func problem(_ change: (inout InvestmentPlan) -> Void, base: InvestmentPlan) -> PlanProblem? {
            var plan = base
            change(&plan)
            let proposal = ledger.planTransactions(plan, through: d("2024-12-31"))
            #expect(proposal.transactions.isEmpty)
            return proposal.status.problem
        }
        #expect(problem({ $0.intervalMonths = 0 }, base: purchase) == .invalidInterval)
        #expect(problem({ $0.amount = Money(0, "EUR") }, base: purchase) == .invalidAmount)
        #expect(problem({ $0.fees = 20_000 }, base: purchase) == .invalidAmount)
        #expect(problem({ $0.securityID = nil }, base: purchase) == .missingSecurity)
        #expect(problem({ $0.depotID = UUID() }, base: purchase) == .missingDepot)
        #expect(problem({ $0.accountID = UUID() }, base: purchase) == .missingAccount)
        #expect(problem({ $0.accountID = nil }, base: deposit) == .missingAccount)
        #expect(problem({ $0.amount = Money(100, "USD") }, base: deposit) == .currencyMismatch(expected: "EUR"))

        // No route between the plan currency and the security currency.
        var g = Fixture()
        let c2 = g.account("Cash"), d2 = g.depot("Depot")
        let jp = g.security("JP", "JPY", prices: [("2024-01-01", 1_000)])
        let plan = InvestmentPlan(name: "JP", securityID: jp, depotID: d2, accountID: c2, amount: Money(100, "EUR"), start: d("2024-02-01"))
        let result = g.ledger.planTransactions([plan], through: d("2024-02-10"))[0]
        #expect(result.transactions.isEmpty)
        #expect(result.skipped.map(\.due) == [d("2024-02-01")])
        #expect(result.skipped.map(\.reason) == [.noExchangeRate(from: "EUR", to: "JPY")])
    }
}

@Suite struct ConsistencyTests {
    @Test func cleanFileHasNoIssues() {
        var f = Fixture()
        let cash = f.account("Cash"), usd = f.account("USD", "USD"), depot = f.depot("Depot")
        let s = f.security("ACME", "USD", prices: [("2024-01-01", 10), ("2024-06-28", 12)])
        f.rates("EUR", "USD", [("2024-01-01", 1.1)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 5_000)
        f.add(.cashTransfer, "2024-01-03", account: cash, amount: 1_000, counterAccount: usd, counterAmount: Money(1_100, "USD"))
        f.add(.buy, "2024-01-04", account: usd, depot: depot, security: s, shares: 100, amount: 1_005, fees: 5, currency: "USD")
        f.add(.dividend, "2024-03-01", account: usd, depot: depot, security: s, shares: 100, amount: 20, currency: "USD")
        #expect(ConsistencyChecker.check(f.file, options: .init(today: d("2024-06-30"))).isEmpty)
    }

    @Test func everyKindOfIssueIsReported() {
        var f = Fixture()
        let cash = f.account("Cash"), usd = f.account("USD", "USD"), yen = f.account("Yen", "JPY"), depot = f.depot("Depot")
        let other = f.depot("Other")
        let held = f.security("Held", prices: [("2024-01-01", 10), ("2024-02-01", 11)])
        let unquoted = f.security("Unquoted")
        let ghost = UUID()
        f.rates("EUR", "USD", [("2024-01-01", 1.1)])

        f.add(.deposit, "2024-01-02", account: cash, amount: 1_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: held, shares: 10, amount: 100)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: unquoted, shares: 1, amount: 50)
        // Sells more than held → negative shares from Feb 1; a same-day buy does not hide Mar 1.
        let oversell = f.add(.sell, "2024-02-01", account: cash, depot: other, security: held, shares: 5, amount: 55)
        // Overdraws the account on Feb 10.
        f.add(.withdrawal, "2024-02-10", account: cash, amount: 5_000)
        let noAccount = f.add(.deposit, "2024-03-01", amount: 10)
        let unknownSecurity = f.add(.dividend, "2024-03-02", account: cash, security: ghost, amount: 5)
        let wrongCurrency = f.add(.deposit, "2024-03-03", account: usd, amount: 10, currency: "EUR")
        let noShares = f.add(.buy, "2024-03-04", account: cash, depot: depot, security: held, amount: 10)
        let noCounter = f.add(.cashTransfer, "2024-03-05", account: cash, amount: 10, counterAccount: usd)
        let selfTransfer = f.add(.securityTransfer, "2024-03-06", depot: depot, security: held, shares: 1, amount: 10, counterDepot: depot)
        let greedy = f.add(.buy, "2024-03-07", account: cash, depot: depot, security: held, shares: 1, amount: 10, fees: 8, taxes: 8)
        let dup1 = f.add(.fee, "2024-03-08", account: cash, amount: 2.5)
        let dup2 = f.add(.fee, "2024-03-08", account: cash, amount: 2.5)
        let grossMismatch = f.add(
            .buy, "2024-03-09", account: cash, depot: depot, security: held, shares: 1, amount: 11,
            securityGross: Money(12, "USD"))
        var negative = Transaction(kind: .fee, date: d("2024-03-10"), accountID: cash, amount: Money(-1, "EUR"))
        negative.id = f.uuid()
        f.file.transactions.append(negative)

        let issues = ConsistencyChecker.check(f.file, options: .init(today: d("2024-06-30"), staleAfterDays: 10))
        func find(_ kind: ConsistencyIssue.Kind, _ detail: String? = nil) -> [ConsistencyIssue] {
            issues.filter { $0.kind == kind && (detail == nil || $0.detail == detail) }
        }

        let shares = find(.negativeShares)
        #expect(shares.count == 1)
        #expect(shares[0].severity == .error && shares[0].day == d("2024-02-01"))
        #expect(shares[0].securityID == held && shares[0].depotID == other)
        #expect(shares[0].message.contains("Other") && shares[0].message.contains("Held"))
        _ = oversell

        let overdrawn = find(.negativeCashBalance)
        #expect(overdrawn.count == 1 && overdrawn[0].severity == .warning)
        #expect(overdrawn[0].accountID == cash && overdrawn[0].day == d("2024-02-10"))

        #expect(find(.missingField, "account").map(\.transactionIDs) == [[noAccount]])
        #expect(find(.missingField, "shares").map(\.transactionIDs) == [[noShares]])
        #expect(find(.missingField, "counterAmount").map(\.transactionIDs) == [[noCounter]])
        #expect(find(.unknownReference, "security").map(\.transactionIDs) == [[unknownSecurity]])
        #expect(find(.unknownReference)[0].severity == .error)
        let mismatches = find(.currencyMismatch)
        #expect(Set(mismatches.map(\.transactionIDs)) == [[wrongCurrency], [grossMismatch]])
        #expect(find(.currencyMismatch, "amount")[0].severity == .error)
        #expect(find(.currencyMismatch, "securityGross")[0].severity == .warning)
        #expect(find(.invalidValue, "target depot").map(\.transactionIDs) == [[selfTransfer]])
        #expect(find(.invalidValue, "fees").map(\.transactionIDs) == [[greedy]])
        #expect(find(.invalidValue, "fees")[0].severity == .warning)
        #expect(find(.invalidValue, "amount").map(\.transactionIDs) == [[negative.id]])
        #expect(find(.duplicateTransactions).map(\.transactionIDs) == [[dup1, dup2]])

        #expect(find(.securityWithoutPrices).map(\.securityID) == [unquoted])
        let stale = find(.stalePrices)
        #expect(stale.map(\.securityID) == [held] && stale[0].day == d("2024-02-01"))
        let rates = find(.missingExchangeRate)
        #expect(rates.count == 1 && rates[0].detail == "JPY→EUR" && rates[0].accountID == yen)

        // Sorted by severity, ids unique, kinds complete.
        #expect(issues.map(\.severity) == issues.map(\.severity).sorted(by: >))
        #expect(Set(issues.map(\.id)).count == issues.count)
        #expect(Set(issues.map(\.kind)) == Set(ConsistencyIssue.Kind.allCases))

        // With fresh quotes nothing is stale; retired securities are never stale.
        let fresh = ConsistencyChecker.check(f.file, options: .init(today: d("2024-02-05")))
        #expect(!fresh.contains { $0.kind == .stalePrices })
        f.file.securities[0].isRetired = true
        #expect(!Ledger(f.file).consistencyIssues(options: .init(today: d("2024-06-30"))).contains { $0.kind == .stalePrices })
    }

    @Test func intradayOrderDoesNotCauseFalseAlarms() {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let s = f.security("ACME", prices: [("2024-01-01", 10)])
        // Recorded sale first, purchase and deposit later the same day: fine at the end of the day.
        f.add(.sell, "2024-01-05", account: cash, depot: depot, security: s, shares: 5, amount: 50)
        f.add(.buy, "2024-01-05", account: cash, depot: depot, security: s, shares: 5, amount: 50)
        f.add(.withdrawal, "2024-01-06", account: cash, amount: 20)
        f.add(.deposit, "2024-01-06", account: cash, amount: 20)
        #expect(ConsistencyChecker.check(f.file, options: .init(today: d("2024-01-07"))).isEmpty)
    }
}

@Suite struct ReturnAnalyticsTests {
    @Test func heatmap() {
        // 2023-11-30 baseline; +1 % on the first day of each month Dec 2023 … Mar 2024.
        let interval = DayInterval(start: d("2023-11-30"), end: d("2024-03-15"))
        var daily = [Double](repeating: 0, count: interval.dayCount + 1)
        for (i, iso) in ["2023-12-01", "2024-01-01", "2024-02-01", "2024-03-01"].enumerated() {
            daily[interval.start.distance(to: d(iso))] = 0.01 * Double(i + 1)
        }
        let map = ReturnSeries(interval: interval, daily: daily).heatmap()
        #expect(map.rows.map(\.year) == [2023, 2024])
        #expect(abs(map.rows[0].months[11]! - 0.01) < 1e-12 && map.rows[0].months[0] == nil)
        #expect(abs(map.rows[0].total - 0.01) < 1e-12)
        #expect(abs(map.rows[1].months[0]! - 0.02) < 1e-12 && abs(map.rows[1].months[2]! - 0.04) < 1e-12)
        #expect(map.rows[1].months[3] == nil)
        #expect(abs(map.rows[1].total - (1.02 * 1.03 * 1.04 - 1)) < 1e-12)
        #expect(abs(map.value(year: 2024, month: 2)! - 0.03) < 1e-12)
        #expect(map.value(year: 2022, month: 1) == nil && map.value(year: 2024, month: 13) == nil)
        #expect(abs(map.monthlyRange!.lowerBound - 0.01) < 1e-12 && abs(map.monthlyRange!.upperBound - 0.04) < 1e-12)
        #expect(ReturnSeries(interval: DayInterval(start: d("2024-01-01"), end: d("2024-01-01")), daily: [0]).heatmap().rows.isEmpty)
    }

    @Test func rollingReturns() {
        // Level doubles on day 3 and halves on day 6.
        let interval = DayInterval(start: d("2024-01-01"), end: d("2024-01-09"))
        let series = ReturnSeries(interval: interval, levels: [100, 100, 100, 200, 200, 200, 100, 100, 100])
        let rolling = series.rollingReturns(windowDays: 3)
        #expect(rolling.values.count == 9 && rolling.windowDays == 3 && !rolling.isAnnualized)
        #expect(rolling.values[0] == nil && rolling.values[2] == nil)
        let expected: [Double] = [1, 1, 1, -0.5, -0.5, -0.5]
        for (i, e) in expected.enumerated() { #expect(abs(rolling.values[i + 3]! - e) < 1e-12) }
        #expect(rolling.best == 1 && rolling.worst == -0.5)
        #expect(abs(rolling.average! - 0.25) < 1e-12 && rolling.positiveShare == 0.5)
        #expect(rolling.day(at: 3) == d("2024-01-04"))
        #expect(rolling.chartPoints(maxPoints: 100).map(\.day).first == d("2024-01-04"))
        #expect(rolling.chartPoints(maxPoints: 100).count == 6)

        let annual = series.rollingReturns(windowDays: 365, annualized: true)
        #expect(annual.values.allSatisfy { $0 == nil } && annual.best == nil && annual.positiveShare == nil)
        let flat = ReturnSeries(interval: DayInterval(start: d("2023-01-01"), end: d("2025-01-01")),
                                levels: (0...731).map { 100 * pow(1.1, Double($0) / 365) })
        let yearly = flat.rollingReturns(windowDays: 730, annualized: true)
        #expect(abs(yearly.values[731]! - 0.1) < 1e-9)
    }

    @Test func ledgerConvenienceMatchesSeries() {
        let file = makeRandomPortfolio(RandomPortfolioOptions(seed: 11))
        let ledger = Ledger(file)
        let interval = DayInterval(start: d("2015-03-01"), end: d("2016-12-31"))
        let returns = ledger.valuation(in: interval).returns()
        let map = ledger.returnHeatmap(in: interval)
        #expect(map == returns.heatmap())
        #expect(map.rows.map(\.year) == [2015, 2016])
        let months = returns.monthlyReturns()
        #expect(map.rows.flatMap { $0.months.compactMap { $0 } } == months.map(\.value))
        #expect(map.rows.map(\.total) == returns.yearlyReturns().map(\.value))
        let rolling = ledger.rollingReturns(in: interval, windowDays: 90)
        let i = 300
        #expect(abs(rolling.values[i]! - ((1 + returns.cumulative[i]) / (1 + returns.cumulative[i - 90]) - 1)) < 1e-12)
    }
}

@Suite struct StockSplitTests {
    @Test func parsing() {
        let id = UUID()
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), ratio: "2:1")?.newShares == 2)
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), ratio: " 1 : 10 ")?.oldShares == 10)
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), ratio: "3:2")?.ratio == "3:2")
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), ratio: "0:1") == nil)
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), ratio: "2") == nil)
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), ratio: "a:b") == nil)
        #expect(StockSplit(securityID: id, day: d("2024-06-10"), newShares: 1, oldShares: -1) == nil)
    }

    @Test func splitAdjustsHistoryAndKeepsValues() throws {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        // Unadjusted history: 400 before the 4:1 split, 100 after.
        let s = f.security("ACME", prices: [("2024-01-02", 400), ("2024-03-01", 420), ("2024-06-10", 105), ("2024-07-01", 110)])
        let o = f.security("Other", prices: [("2024-01-02", 10)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 20_000)
        let before = f.add(.buy, "2024-01-02", account: cash, depot: depot, security: s, shares: 10, amount: 4_000)
        let dividend = f.add(.dividend, "2024-03-01", account: cash, depot: depot, security: s, shares: 10, amount: 30)
        let after = f.add(.buy, "2024-06-10", account: cash, depot: depot, security: s, shares: 4, amount: 420)
        let unrelated = f.add(.buy, "2024-01-02", account: cash, depot: depot, security: o, shares: 10, amount: 100)
        // Until the split is applied the data is inconsistent: 14 shares.
        let split = try #require(StockSplit(securityID: s, day: d("2024-06-10"), ratio: "4:1"))
        #expect(!split.isRecorded(in: f.file.securities[0]))

        let result = split.apply(to: f.file.securities[0], transactions: f.file.transactions)
        #expect(result.adjustedPriceCount == 2)
        #expect(result.security.prices.map(\.price) == [Price(100), Price(105), Price(105), Price(110)])
        #expect(result.adjustedTransactionIDs == [before, dividend])
        let byID = Dictionary(uniqueKeysWithValues: result.transactions.map { ($0.id, $0) })
        #expect(byID[before]?.shares == Shares(40) && byID[before]?.amount == Money(4_000, "EUR"))
        #expect(byID[dividend]?.shares == Shares(40))
        #expect(byID[after]?.shares == Shares(4))
        #expect(byID[unrelated]?.shares == Shares(10))
        #expect(result.transactions.map(\.id) == f.file.transactions.map(\.id))
        #expect(result.event.kind == .split && result.event.detail == "4:1" && result.event.day == d("2024-06-10"))
        #expect(result.security.events == [result.event])
        #expect(split.isRecorded(in: result.security))
        // An equivalent ratio counts as recorded as well.
        #expect(StockSplit(securityID: s, day: d("2024-06-10"), ratio: "8:2")!.isRecorded(in: result.security))

        // File-level convenience; values before the split day are unchanged, afterwards consistent.
        let adjusted = try #require(f.file.applying(split))
        let old = f.ledger, new = Ledger(adjusted)
        for day in ["2024-01-31", "2024-03-15", "2024-06-09"] {
            #expect(new.snapshot(on: d(day)).totalValue == old.snapshot(on: d(day)).totalValue)
        }
        #expect(new.snapshot(on: d("2024-07-01")).position(s)?.shares == Shares(44))
        #expect(new.snapshot(on: d("2024-07-01")).position(s)?.value == Money(4_840, "EUR"))
        // The price history no longer shows a 75 % crash.
        let returns = new.benchmark(securityID: s, in: DayInterval(start: d("2024-01-02"), end: d("2024-07-01")))!
        #expect(abs(returns.total - 0.1) < 1e-12)
        #expect(f.file.applying(StockSplit(securityID: UUID(), day: d("2024-06-10"), ratio: "2:1")!) == nil)

        // Reverse split 1:10.
        let reverse = StockSplit(securityID: o, day: d("2024-02-01"), newShares: 1, oldShares: 10)!
        let merged = reverse.apply(to: f.file.securities[1], transactions: f.file.transactions)
        #expect(merged.security.prices.map(\.price) == [Price(100)])
        #expect(merged.transactions.first { $0.id == unrelated }?.shares == Shares(1))
    }
}

@Suite struct AnalysisFacadeTests {
    @Test(arguments: [3, 4] as [UInt64])
    func matchesTheIndividualCalls(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let interval = DayInterval(start: o.start.advanced(by: 120), end: o.start.advanced(by: 640))
        let taxonomy = AllocationTests.randomTaxonomy(file, seed: seed)
        for scope in [Scope.portfolio, .depot(file.depots[1].id, account: file.accounts[0].id)] {
            let a = Analysis(ledger: ledger, scope: scope, interval: interval)
            let report = ledger.performance(in: interval, scope: scope)
            #expect(a.currency == report.currency)
            #expect(a.valuation.values == report.valuation.values)
            #expect(a.valuation.inflows == report.valuation.inflows)
            #expect(a.returns.daily == report.returns.daily)
            #expect(a.ttwror == report.ttwror && a.ttwrorAnnualized == report.ttwrorAnnualized)
            #expect(a.irr == report.irr)
            #expect(a.breakdown == report.breakdown)
            #expect(a.absolutePerformance == report.absolutePerformance)
            #expect(a.securities == report.securities)
            #expect(a.security(file.securities[0].id) == report.security(file.securities[0].id))
            #expect(a.risk == report.risk)
            #expect(a.report.securities == report.securities && a.report.diagnostics == report.diagnostics)
            #expect(a.drawdowns == report.returns.drawdowns())
            #expect(a.investedCapital == report.valuation.investedCapital())
            #expect(a.heatmap == report.returns.heatmap())
            #expect(a.rollingReturns(windowDays: 30).values == report.returns.rollingReturns(windowDays: 30).values)

            let end = ledger.snapshot(on: interval.end, scope: scope)
            #expect(a.snapshot.positions == end.positions && a.snapshot.cash == end.cash)
            #expect(a.snapshot.totalValue == end.totalValue && a.snapshot.costBasis == end.costBasis)
            let start = ledger.snapshot(on: interval.start, scope: scope)
            #expect(a.initialSnapshot.positions == start.positions && a.initialSnapshot.totalValue == start.totalValue)
            #expect(a.initialSnapshot.totalValue.minor == a.breakdown.initialValue)

            let trades = ledger.trades(on: interval.end, closedAfter: interval.start, scope: scope)
            #expect(a.trades.closed == trades.closed && a.trades.open == trades.open)
            #expect(a.earnings.total == ledger.earnings(in: interval, scope: scope).total)
            #expect(a.earnings.total.dividends == a.breakdown.dividends)
            let allocation = ledger.allocation(for: taxonomy, on: interval.end, scope: scope)
            #expect(a.allocation(for: taxonomy).roots == allocation.roots)
            #expect(a.rebalancing(for: taxonomy).orders == allocation.rebalancing().orders)
            let benchmark = a.benchmark(securityID: file.securities[0].id)
            #expect(benchmark?.daily == ledger.benchmark(securityID: file.securities[0].id, in: interval)?.daily)
            #expect(a.benchmark(securityID: UUID()) == nil)
            #expect(a.diagnostics.count >= ledger.diagnostics.count)
        }
    }

    @Test func convenienceInitializersAndConcurrentAccess() {
        let file = makeRandomPortfolio(RandomPortfolioOptions(seed: 5))
        let today = d("2016-06-30")
        let ledger = Ledger(file)
        let a = Analysis(ledger: ledger, period: .lastYears(1), today: today)
        #expect(a.interval == DayInterval(start: d("2015-06-30"), end: today))
        #expect(a.scope == .portfolio)

        let usd = Analysis(file: file, interval: a.interval, reportingCurrency: "USD")
        #expect(usd.currency == "USD" && usd.snapshot.currency == "USD")
        #expect(usd.snapshot.totalValue.minor != a.snapshot.totalValue.minor)

        // Hammer a fresh analysis from many threads: every reader sees the same values.
        let shared = Analysis(ledger: ledger, interval: a.interval)
        let expected = ledger.performance(in: a.interval)
        let results = Collector()
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            let ok: Bool
            switch i % 4 {
            case 0: ok = shared.ttwror == expected.ttwror
            case 1: ok = shared.securities == expected.securities
            case 2: ok = shared.snapshot.totalValue.minor == expected.valuation.finalValue
            default: ok = shared.breakdown == expected.breakdown
                && Set(shared.trades.open.map(\.securityID)) == Set(shared.snapshot.positions.map(\.securityID))
            }
            results.add(ok)
        }
        #expect(results.values.count == 16 && results.values.allSatisfy { $0 })
    }
}

/// Thread-safe result sink for the concurrency test.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    func add(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite struct AnalyticsEdgeCaseTests {
    @Test func emptyInputsNeverTrap() {
        let ledger = Ledger(PortfolioFile(name: "Empty"))
        let day = d("2024-06-30")
        let interval = DayInterval(start: d("2023-12-31"), end: day)
        let empty = Taxonomy(name: "Empty")

        let trades = ledger.trades(on: day)
        #expect(trades.closed.isEmpty && trades.open.isEmpty && trades.statistics.count == 0)
        #expect(trades.statistics.winRate == nil && trades.statistics.averageHoldingDays == nil)

        let earnings = ledger.earnings(in: interval)
        #expect(earnings.total.isZero && earnings.months.count == 6 && earnings.years.count == 1)
        #expect(earnings.quarters.count == 2 && earnings.bySecurity.isEmpty && earnings.payments.isEmpty)
        #expect(earnings.trailingTwelveMonths(.dividends).allSatisfy { $0.value == 0 && !$0.isComplete })
        #expect(earnings.yearOverYear(.net).map(\.growth) == [nil])
        let oneDay = ledger.earnings(in: DayInterval(start: day, end: day))
        #expect(oneDay.months.count == 1 && oneDay.total.isZero)

        let allocation = ledger.allocation(for: empty, on: day)
        #expect(allocation.totalValue == 0 && allocation.roots.isEmpty && allocation.unassigned.isEmpty)
        #expect(allocation.unassignedShare == nil)
        let proposal = allocation.rebalancing(RebalancingOptions(cash: 1_000))
        #expect(proposal.orders.isEmpty && proposal.residualCash == 1_000)
        #expect(ledger.classificationPerformance(of: empty, in: interval).isEmpty)

        #expect(ledger.consistencyIssues(options: .init(today: day)).isEmpty)
        #expect(ledger.returnHeatmap(in: interval).rows.map(\.year) == [2024])
        #expect(ledger.rollingReturns(in: interval, windowDays: 30).best == 0)

        let analysis = Analysis(ledger: ledger, interval: interval)
        #expect(analysis.snapshot.totalValue.minor == 0 && analysis.initialSnapshot.positions.isEmpty)
        #expect(analysis.ttwror == 0 && analysis.irr == nil && analysis.securities.isEmpty)
        #expect(analysis.trades.open.isEmpty && analysis.earnings.total.isZero)
        #expect(analysis.report.breakdown.absolutePerformance == 0)
        #expect(analysis.allocation(for: empty).roots.isEmpty)
    }

    @Test func weightedScopeScalesTradesAndEarnings() {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let s = f.security("ACME", prices: [("2024-01-01", 100), ("2024-06-01", 120)])
        f.add(.buy, "2024-01-02", account: cash, depot: depot, security: s, shares: 10, amount: 1_010, fees: 10)
        f.add(.dividend, "2024-03-01", account: cash, depot: depot, security: s, shares: 10, amount: 30, taxes: 10)
        f.add(.sell, "2024-06-01", account: cash, depot: depot, security: s, shares: 4, amount: 470, fees: 10)
        let ledger = f.ledger
        let half = Scope.weighted(securities: [s: 5_000], accounts: [:])
        let trades = ledger.trades(on: d("2024-06-30"), scope: half)
        #expect(trades.closed[0].shares == Shares(4)) // shares are never weighted
        #expect(trades.closed[0].entryValue == minor(202) && trades.closed[0].exitValue == minor(235))
        #expect(trades.closed[0].fees == minor(7))
        #expect(trades.open[0].entryValue == minor(303) && trades.open[0].exitValue == minor(360))
        let earnings = ledger.earnings(in: DayInterval(start: d("2023-12-31"), end: d("2024-06-30")), scope: half)
        #expect(earnings.total.dividends == minor(20) && earnings.total.taxes == minor(5) && earnings.total.fees == minor(10))
        #expect(earnings.payments[0].gross == minor(20))
        #expect(earnings.payments[0].perShare == Price(4)) // per share is not weighted
        // Out-of-scope securities produce nothing.
        let none = ledger.trades(on: d("2024-06-30"), scope: .account(cash))
        #expect(none.closed.isEmpty && none.open.isEmpty)
    }

    /// Arbitrary taxonomies (nested, partial, over-assigned, missing targets, overdrawn accounts):
    /// the bookkeeping of a proposal must hold in every mode.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] as [UInt64])
    func rebalancingBookkeepingOnArbitraryTaxonomies(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0
        o.allowShort = seed % 5 == 0
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let allocation = ledger.allocation(
            for: AllocationTests.randomTaxonomy(file, seed: seed &+ 100), on: o.start.advanced(by: 700))
        for cash: Int64 in [0, 250_000, 12_345_678, -100_000, -40_000_000] {
            for mode in RebalancingOptions.Mode.allCases {
                for whole in [false, true] {
                    let p = allocation.rebalancing(RebalancingOptions(cash: cash, mode: mode, wholeShares: whole))
                    #expect(p.totalBuys - p.totalSells + p.residualCash == cash)
                    #expect(p.orders.reduce(0) { $0 + $1.amount } == p.totalBuys - p.totalSells)
                    #expect(p.nodes.count == allocation.roots.count)
                    #expect(p.valueBefore == allocation.classifiedValue)
                    #expect(p.valueAfter == p.nodes.reduce(0) { $0 + $1.resultingValue })
                    #expect(Set(p.orders.map(\.vehicle)).count == p.orders.count)
                    if mode == .noSales {
                        for order in p.orders { #expect(cash > 0 ? order.amount > 0 : order.amount < 0) }
                        if cash == 0 { #expect(p.orders.isEmpty) }
                    }
                    if whole {
                        for order in p.orders {
                            if case .security = order.vehicle, let shares = order.shares {
                                #expect(shares.raw % Scale.shares == 0)
                            }
                        }
                    }
                    // Money that could not be placed is always explained by a warning.
                    let unplaceable = p.warnings.contains {
                        switch $0 {
                        case .noVehicles, .insufficientHoldings, .noTargets: return true
                        default: return false
                        }
                    }
                    if !whole, !unplaceable { #expect(p.residualCash == 0) }
                    // Resulting values follow from the orders: per vehicle, the effects on all
                    // classifications never exceed the order itself.
                    let moved = p.valueAfter - p.valueBefore
                    let ordered = p.totalBuys - p.totalSells
                    #expect(abs(moved) <= abs(ordered) + Int64(p.orders.count) || p.orders.contains { order in
                        p.orders.contains { ($0.amount > 0) != (order.amount > 0) }
                    })
                }
            }
        }
    }
}
