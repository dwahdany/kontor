import Foundation
import KontorEngine
import KontorModel
import Testing

@Suite struct TradeTests {
    /// Two purchases, one partial sale: FIFO consumes the first lot and half of the second.
    private func twoBuysOneSale(method: CostMethod = .fifo) -> (Fixture, security: UUID, depot: UUID, sale: UUID) {
        var f = Fixture()
        f.file.settings.costMethod = method
        let account = f.account("Cash"), depot = f.depot("Depot")
        let s = f.security("ACME", prices: [("2024-01-10", 100), ("2024-06-10", 150), ("2024-06-30", 160)])
        f.add(.deposit, "2024-01-02", account: account, amount: 10_000)
        f.add(.buy, "2024-01-10", account: account, depot: depot, security: s, shares: 10, amount: 1_005, fees: 5)
        f.add(.buy, "2024-02-10", account: account, depot: depot, security: s, shares: 10, amount: 1_205, fees: 5)
        let sale = f.add(
            .sell, "2024-06-10", account: account, depot: depot, security: s, shares: 15, amount: 2_220, fees: 10, taxes: 20)
        return (f, s, depot, sale)
    }

    @Test func fifoClosedAndOpenTrade() {
        let (f, s, depot, sale) = twoBuysOneSale()
        let report = f.ledger.trades(on: d("2024-06-30"))
        #expect(report.closed.count == 1)
        let t = report.closed[0]
        #expect(t.securityID == s && t.depotID == depot && t.closingTransactionID == sale)
        #expect(!t.isOpen && !t.isShort)
        #expect(t.shares == Shares(15))
        #expect(t.opened == d("2024-01-10") && t.end == d("2024-06-10"))
        #expect(t.holdingDays == 152)
        // Entry: 10 × 100 + 5 fees, plus 5 × 120 + 2.50 fees.
        #expect(t.entryValue == minor(1_607.50))
        // Exit: 15 × 150 − 10 fees.
        #expect(t.exitValue == minor(2_240))
        #expect(t.fees == minor(17.50))
        #expect(t.taxes == minor(20))
        #expect(t.gain == minor(632.50))
        #expect(t.gainAfterTaxes == minor(612.50))
        #expect(abs(t.returnFraction! - 632.5 / 1_607.5) < 1e-12)
        #expect(t.lots.count == 2)
        #expect(t.lots.map(\.opened) == [d("2024-01-10"), d("2024-02-10")])
        #expect(t.lots.map(\.shares) == [Shares(10), Shares(5)])
        #expect(t.lots.map(\.entryValue) == [minor(1_005), minor(602.50)])
        #expect(t.irr! > 0.9) // +39 % in about five months

        #expect(report.open.count == 1)
        let o = report.open[0]
        #expect(o.isOpen && o.closingTransactionID == nil)
        #expect(o.shares == Shares(5))
        #expect(o.opened == d("2024-02-10") && o.end == d("2024-06-30"))
        #expect(o.entryValue == minor(602.50))
        #expect(o.exitValue == minor(800)) // 5 × 160
        #expect(o.gain == minor(197.50))
        #expect(o.fees == minor(2.50))

        #expect(report.statistics.count == 1)
        #expect(report.statistics.winRate == 1)
        #expect(report.statistics.profitFactor == nil)
        #expect(report.statistics.totalGain == minor(632.50))
        #expect(report.statistics.averageHoldingDays == 152)
        #expect(report.trades(for: s).count == 2)
    }

    @Test func averageMethodPoolsLots() {
        let (f, _, _, _) = twoBuysOneSale(method: .average)
        let report = f.ledger.trades(on: d("2024-06-30"))
        let t = report.closed[0]
        // Pool: 20 shares, cost 2 200 + 10 fees. 15 of 20 → 1 650 + 7.50.
        #expect(t.entryValue == minor(1_657.50))
        #expect(t.exitValue == minor(2_240))
        #expect(t.gain == minor(582.50))
        #expect(t.opened == d("2024-01-10"))
        #expect(report.open[0].entryValue == minor(552.50))
        // Both methods realize the same total once everything is counted.
        #expect(t.entryValue + report.open[0].entryValue == minor(2_210))
    }

    @Test func singleLotIRREqualsAnnualizedReturn() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let s = f.security("ACME", prices: [("2023-01-01", 100)])
        f.add(.buy, "2023-01-01", account: account, depot: depot, security: s, shares: 10, amount: 1_000)
        f.add(.sell, "2024-01-01", account: account, depot: depot, security: s, shares: 10, amount: 1_100)
        let t = f.ledger.trades(on: d("2024-12-31")).closed[0]
        #expect(t.holdingDays == 365)
        #expect(abs(t.irr! - 0.10) < 1e-9)
        #expect(abs(t.annualizedReturn! - 0.10) < 1e-12)
        #expect(abs(t.returnFraction! - 0.10) < 1e-12)
    }

    @Test func transferredLotsKeepAcquisitionDay() {
        var f = Fixture()
        let account = f.account("Cash"), a = f.depot("A"), b = f.depot("B")
        let s = f.security("ACME", prices: [("2024-01-10", 100), ("2024-03-01", 130), ("2024-06-10", 150)])
        f.add(.buy, "2024-01-10", account: account, depot: a, security: s, shares: 10, amount: 1_010, fees: 10)
        f.add(.securityTransfer, "2024-03-01", depot: a, security: s, shares: 10, amount: 1_300, counterDepot: b)
        f.add(.sell, "2024-06-10", account: account, depot: b, security: s, shares: 4, amount: 600)
        let report = f.ledger.trades(on: d("2024-06-30"))
        let t = report.closed[0]
        #expect(t.depotID == b)
        #expect(t.opened == d("2024-01-10"))
        #expect(t.entryValue == minor(404)) // 4/10 of 1 010: the transfer does not re-base the cost
        #expect(t.gain == minor(196))
        #expect(report.open.count == 1)
        #expect(report.open[0].depotID == b && report.open[0].opened == d("2024-01-10"))
        #expect(report.open[0].shares == Shares(6))
    }

    @Test func shortTradeAndStatistics() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let s = f.security("ACME", prices: [("2024-01-01", 100)])
        let w = f.security("Winner", prices: [("2024-01-01", 10)])
        let l = f.security("Loser", prices: [("2024-01-01", 10)])
        // Short: sell 5 @ 100, cover @ 80 with 2 fees.
        f.add(.sell, "2024-01-10", account: account, depot: depot, security: s, shares: 5, amount: 500)
        f.add(.buy, "2024-02-09", account: account, depot: depot, security: s, shares: 5, amount: 402, fees: 2)
        // A winner (+300 in 20 days) and a loser (−100 in 50 days).
        f.add(.buy, "2024-03-01", account: account, depot: depot, security: w, shares: 100, amount: 1_000)
        f.add(.sell, "2024-03-21", account: account, depot: depot, security: w, shares: 100, amount: 1_300)
        f.add(.buy, "2024-03-01", account: account, depot: depot, security: l, shares: 100, amount: 1_000)
        f.add(.sell, "2024-04-20", account: account, depot: depot, security: l, shares: 100, amount: 900)
        let report = f.ledger.trades(on: d("2024-12-31"))
        #expect(report.open.isEmpty)
        #expect(report.closed.count == 3)
        let short = report.closed[0]
        #expect(short.isShort)
        #expect(short.entryValue == minor(500) && short.exitValue == minor(402))
        #expect(short.gain == minor(98) && short.fees == minor(2))
        #expect(short.holdingDays == 30)
        #expect(short.irr! > 0)

        let stats = report.statistics
        #expect(stats.count == 3 && stats.winners == 2 && stats.losers == 1)
        #expect(abs(stats.winRate! - 2.0 / 3.0) < 1e-12)
        #expect(stats.grossProfit == minor(398) && stats.grossLoss == minor(100))
        #expect(stats.totalGain == minor(298))
        #expect(stats.averageGain == Double(minor(199)))
        #expect(stats.averageLoss == Double(minor(100)))
        #expect(abs(stats.profitFactor! - 3.98) < 1e-12)
        #expect(abs(stats.averageHoldingDays! - 100.0 / 3.0) < 1e-12)
        #expect(abs(stats.averageReturn! - (0.196 + 0.3 - 0.1) / 3) < 1e-12)

        // Only trades closed after the given day.
        let late = f.ledger.trades(on: d("2024-12-31"), closedAfter: d("2024-03-31"))
        #expect(late.closed.map(\.securityID) == [l])
        #expect(TradeStatistics([]).winRate == nil)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func closedTradeGainsEqualRealizedGains(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0
        o.allowShort = seed % 3 == 0
        o.costMethod = seed % 2 == 1 ? .average : .fifo
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let interval = DayInterval(start: o.start.advanced(by: -1), end: o.start.advanced(by: o.days))
        let scopes: [(scope: Scope, crossesDepots: Bool)] = [
            (.portfolio, false), (.depot(file.depots[0].id), true), (.security(file.securities[1].id), false),
        ]
        for (scope, crossesDepots) in scopes {
            let report = ledger.performance(in: interval, scope: scope)
            let trades = ledger.trades(on: interval.end, scope: scope)
            // Net of fees: the per-security realized gains. Gross: the breakdown line.
            #expect(trades.closed.reduce(0) { $0 + $1.gain } == report.securities.reduce(0) { $0 + $1.realizedGain })
            if !crossesDepots { // transfers out of a depot scope realize the period gain without a trade
                #expect(trades.closed.reduce(0) { $0 + $1.gain + $1.fees } == report.breakdown.realizedGains)
            }
            // Open trades are the snapshot's positions.
            let snapshot = ledger.snapshot(on: interval.end, scope: scope)
            #expect(trades.open.reduce(0) { $0 + ($1.isShort ? -$1.exitValue : $1.exitValue) } == snapshot.securitiesValue.minor)
            #expect(trades.open.filter { !$0.isShort }.reduce(0) { $0 + $1.entryValue }
                - trades.open.filter(\.isShort).reduce(0) { $0 + $1.entryValue }
                == snapshot.costBasis.minor)
            for t in trades.closed + trades.open {
                #expect(t.shares.raw > 0)
                #expect(t.lots.reduce(0) { $0 + $1.shares.raw } == t.shares.raw)
                #expect(t.lots.reduce(0) { $0 + $1.entryValue } == t.entryValue)
                #expect(t.opened <= t.end)
            }
        }
    }
}

@Suite struct EarningsTests {
    @Test func handComputedScenario() {
        var f = Fixture()
        let cash = f.account("Cash"), savings = f.account("Savings"), depot = f.depot("Depot")
        let s = f.security("ACME", prices: [("2023-01-01", 50), ("2024-01-15", 40)])
        f.add(.deposit, "2023-01-02", account: cash, amount: 50_000)
        f.add(.buy, "2023-01-05", account: cash, depot: depot, security: s, shares: 100, amount: 5_003, fees: 3)
        f.add(.dividend, "2023-07-15", account: cash, depot: depot, security: s, shares: 100, amount: 60, taxes: 20)
        f.add(.dividend, "2024-01-15", account: cash, depot: depot, security: s, shares: 100, amount: 75, taxes: 25)
        f.add(.interest, "2024-02-10", account: savings, amount: 7.5, taxes: 2.5)
        f.add(.fee, "2024-03-05", account: cash, amount: 5)
        f.add(.feeRefund, "2024-03-20", account: cash, amount: 1)
        f.add(.interestCharge, "2024-04-01", account: cash, amount: 2)
        f.add(.tax, "2024-05-01", account: cash, security: s, amount: 4)
        f.add(.taxRefund, "2024-05-02", account: cash, amount: 1.5)
        f.add(.dividend, "2024-07-15", account: cash, security: s, amount: 90, taxes: 30) // no share count
        let ledger = f.ledger
        let interval = DayInterval(start: d("2022-12-31"), end: d("2024-12-31"))
        let e = ledger.earnings(in: interval)

        #expect(e.total.dividends == minor(300))
        #expect(e.total.interest == minor(10))
        #expect(e.total.interestCharges == minor(2))
        #expect(e.total.fees == minor(7))
        #expect(e.total.taxes == minor(80))
        #expect(e.total.earnings == minor(308))
        #expect(e.total.costs == minor(87))
        #expect(e.total.net == minor(221))
        #expect(e.total[.dividends] == minor(300) && e.total[.net] == minor(221))

        // Months: contiguous January 2023 … December 2024.
        #expect(e.months.count == 24)
        #expect(e.months[0].year == 2023 && e.months[0].month == 1)
        #expect(e.months[0].amounts.fees == minor(3))
        #expect(e.months[6].amounts.dividends == minor(80) && e.months[6].amounts.taxes == minor(20))
        #expect(e.months[12].amounts.dividends == minor(100))
        #expect(e.months[14].amounts.fees == minor(4))
        #expect(e.months[23].amounts.isZero)

        // Year × month matrix.
        #expect(e.years.map(\.year) == [2023, 2024])
        #expect(e.years[1].values(.dividends) == [10_000, 0, 0, 0, 0, 0, 12_000, 0, 0, 0, 0, 0])
        #expect(e.years[0].total.dividends == minor(80))
        #expect(e.years[1].total.dividends == minor(220))
        #expect(e.years[1].total.taxes == minor(25 + 2.5 + 4 - 1.5 + 30))

        // Quarters.
        #expect(e.quarters.count == 8)
        #expect(e.quarters[4].year == 2024 && e.quarters[4].quarter == 1)
        #expect(e.quarters[4].amounts.dividends == minor(100))
        #expect(e.quarters[4].amounts.interest == minor(10))
        #expect(e.quarters[4].amounts.fees == minor(4))
        #expect(e.quarters[5].amounts.interestCharges == minor(2))
        #expect(e.quarters[5].amounts.taxes == minor(2.5))

        // By security / account.
        #expect(e.bySecurity.count == 1)
        #expect(e.bySecurity[0].securityID == s && e.bySecurity[0].dividendCount == 3)
        #expect(e.bySecurity[0].amounts.dividends == minor(300))
        #expect(e.bySecurity[0].amounts.fees == minor(3))
        #expect(e.bySecurity[0].amounts.taxes == minor(79))
        #expect(e.withoutSecurity.interest == minor(10) && e.withoutSecurity.fees == minor(4))
        #expect(e.withoutSecurity.taxes == minor(1))
        #expect(e.bySecurity[0].amounts + e.withoutSecurity == e.total)
        #expect(e.byAccount.map(\.accountID) == [cash, savings])
        #expect(e.byAccount[1].amounts.interest == minor(10) && e.byAccount[1].amounts.taxes == minor(2.5))
        #expect(e.byAccount[0].amounts + e.byAccount[1].amounts == e.total)

        // Trailing twelve months and year over year.
        let ttm = e.trailingTwelveMonths(.dividends)
        #expect(ttm.count == 24)
        #expect(ttm[6].value == minor(80) && !ttm[6].isComplete)
        #expect(ttm[11].value == minor(80) && ttm[11].isComplete)
        #expect(ttm[12].value == minor(180))
        #expect(ttm[18].value == minor(220)) // July 2023 has dropped out
        #expect(ttm[23].value == minor(220))
        let yoy = e.yearOverYear(.dividends)
        #expect(yoy[0].growth == nil)
        #expect(abs(yoy[1].growth! - 1.75) < 1e-12)

        // Dividend history with per-share amount and yield.
        let history = e.dividendHistory(for: s)
        #expect(history.count == 3)
        #expect(history[0].day == d("2023-07-15") && history[0].gross == minor(80) && history[0].net == minor(60))
        #expect(history[0].perShare == Price(0.8))
        #expect(abs(history[0].yield! - 80.0 / 5_000) < 1e-12)
        #expect(history[1].perShare == Price(1.0))
        #expect(abs(history[1].yield! - 100.0 / 4_000) < 1e-12)
        // The third payment has no share count: the held position (100) is used.
        #expect(history[2].shares == Shares(100))
        #expect(history[2].perShare == Price(1.2))
        #expect(history[2].accountID == cash)

        // A sub-interval only sees its own bookings; the start day belongs to the baseline.
        let y2024 = ledger.earnings(in: DayInterval(start: d("2024-01-15"), end: d("2024-12-31")))
        #expect(y2024.total.dividends == minor(120))
        #expect(y2024.months.first!.month == 1 && y2024.months.count == 12)
    }

    @Test func foreignDividendConvertsAtPaymentDay() {
        var f = Fixture()
        let usd = f.account("USD", "USD"), depot = f.depot("Depot")
        let s = f.security("US Corp", "USD", prices: [("2024-01-01", 100)])
        f.rates("EUR", "USD", [("2024-01-01", 1.25), ("2024-06-01", 1.0)])
        f.add(.deliveryIn, "2024-01-02", depot: depot, security: s, shares: 10, amount: 1_000, currency: "USD")
        f.add(.dividend, "2024-03-01", account: usd, depot: depot, security: s, shares: 10, amount: 85, taxes: 15, currency: "USD")
        f.add(.dividend, "2024-07-01", account: usd, depot: depot, security: s, shares: 10, amount: 85, taxes: 15, currency: "USD")
        let e = f.ledger.earnings(in: DayInterval(start: d("2023-12-31"), end: d("2024-12-31")))
        #expect(e.currency == "EUR")
        #expect(e.payments.map(\.gross) == [minor(80), minor(100)])
        #expect(e.payments.map(\.taxes) == [minor(12), minor(15)])
        #expect(e.total.dividends == minor(180))
        // Yield is currency-neutral: 100 USD on 1 000 USD.
        #expect(abs(e.payments[0].yield! - 0.1) < 1e-12)
        #expect(e.payments[0].perShare == Price(8))
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func totalsEqualBreakdownLines(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        var weights: [UUID: Int] = [:]
        for (i, s) in file.securities.enumerated() where i % 2 == 0 { weights[s.id] = [10_000, 3_333, 5_000][i / 2 % 3] }
        let scopes: [Scope] = [
            .portfolio, .depot(file.depots[0].id, account: file.accounts[0].id), .account(file.accounts[1].id),
            .security(file.securities[0].id), .weighted(securities: weights, accounts: [file.accounts[0].id: 2_500]),
        ]
        let intervals = [
            DayInterval(start: o.start.advanced(by: -1), end: o.start.advanced(by: o.days)),
            DayInterval(start: o.start.advanced(by: 200), end: o.start.advanced(by: 590)),
        ]
        for scope in scopes {
            for interval in intervals {
                let b = ledger.breakdown(in: interval, scope: scope)
                let e = ledger.earnings(in: interval, scope: scope)
                #expect(e.total.dividends == b.dividends)
                #expect(e.total.interest - e.total.interestCharges == b.interest)
                #expect(e.total.fees == b.fees)
                #expect(e.total.taxes == b.taxes)
                // Every aggregation adds up to the same total.
                #expect(e.months.reduce(EarningsAmounts()) { $0 + $1.amounts } == e.total)
                #expect(e.quarters.reduce(EarningsAmounts()) { $0 + $1.amounts } == e.total)
                #expect(e.years.reduce(EarningsAmounts()) { $0 + $1.total } == e.total)
                #expect(e.bySecurity.reduce(e.withoutSecurity) { $0 + $1.amounts } == e.total)
                #expect(e.payments.reduce(0) { $0 + $1.gross } == e.total.dividends)
                #expect(e.trailingTwelveMonths(.net).last?.value
                    == e.months.suffix(12).reduce(0) { $0 + $1.amounts.net })
            }
        }
    }
}
