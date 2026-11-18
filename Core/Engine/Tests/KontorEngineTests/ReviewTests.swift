import Foundation
import KontorEngine
import KontorModel
import Testing

// Independent verification. Expected values in this file are derived by hand (comments show the
// arithmetic) or with an external tool (scipy `brentq` for the IRRs), never by calling the engine.

@Suite struct ReviewHandComputedTests {
    /// A USD account and a USD stock reported in EUR, with a moving exchange rate.
    ///
    ///     1 EUR = 1.10 USD from 01-02, 1.25 USD from 03-01, 1.00 USD from 06-28
    ///     01-02  deposit 11 000 USD; buy 100 @ 50 + 10 fee = 5 010 USD
    ///     03-01  price 60; sell 40 @ 60 = 2 400 − 5 fee − 20 tax = 2 375 USD
    ///     06-28  price 55
    private func usdPortfolio() -> (ledger: Ledger, stock: UUID, interval: DayInterval) {
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-02", 1.10), ("2024-03-01", 1.25), ("2024-06-28", 1.00)])
        let account = f.account("USD", "USD"), depot = f.depot("Depot")
        let stock = f.security("Stock", "USD", prices: [("2024-01-02", 50), ("2024-03-01", 60), ("2024-06-28", 55)])
        f.add(.deposit, "2024-01-02", account: account, amount: 11_000, currency: "USD")
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 100, amount: 5_010, fees: 10,
              currency: "USD")
        f.add(.sell, "2024-03-01", account: account, depot: depot, security: stock, shares: 40, amount: 2_375, fees: 5,
              taxes: 20, currency: "USD")
        return (f.ledger, stock, DayInterval(start: d("2024-01-01"), end: d("2024-06-28")))
    }

    @Test func multiCurrencyBreakdownToTheCent() {
        let (ledger, stock, interval) = usdPortfolio()
        let report = ledger.performance(in: interval)
        let b = report.breakdown
        // deposit 11 000 / 1.10 = 10 000.00
        #expect(b.initialValue == 0 && b.deposits == 1_000_000)
        // buy: 5 010 / 1.10 = 4 554.55, fee 10 / 1.10 = 9.09 → gross cost 4 545.46 (5 000 USD)
        // sell: 2 375 / 1.25 = 1 900.00, fee 4.00, tax 16.00 → gross 1 920.00 (2 400 USD)
        // 40 % of the lot: 4 545.46 × 0.4 = 1 818.18 → realized 1 920.00 − 1 818.18 = 101.82
        #expect(b.realizedGains == 10_182)
        // … of which currency: the 400 USD gain is worth 320.00 → 101.82 − 320.00 = −218.18
        #expect(b.realizedCurrencyGains == -21_818)
        // rest of the lot: 4 545.46 − 1 818.18 = 2 727.28; 60 × 55 USD = 3 300.00 EUR → 572.72
        #expect(b.unrealizedGains == 57_272)
        // … of which currency: 3 000 USD cost is worth 3 000.00 at the end → 3 000.00 − 2 727.28
        #expect(b.unrealizedCurrencyGains == 27_272)
        #expect(b.fees == 1_309 && b.taxes == 1_600 && b.dividends == 0 && b.interest == 0)
        // cash: 8 365 USD = 8 365.00 EUR; booked at day rates 10 000 − 4 554.55 + 1 900 = 7 345.45
        #expect(b.cashCurrencyGains == 101_955)
        #expect(b.finalValue == 1_166_500 && b.roundingResidue == 0)
        expectReconciled(b)

        // Daily values: 01-02 (5 000 + 5 990 USD) / 1.10 = 4 545.45 + 5 445.45; 03-01 (3 600 + 8 365) / 1.25.
        let v = report.valuation
        #expect(v.values[1] == 999_090 && v.inflows[1] == 1_000_000)
        #expect(v.values[v.index(of: d("2024-02-29"))!] == 999_090)
        #expect(v.values[v.index(of: d("2024-03-01"))!] == 957_200)
        #expect(v.finalValue == 1_166_500 && v.totalInflows == 1_000_000 && v.totalOutflows == 0)
        // One flow on the first day only: TTWROR = 11 665 / 10 000 − 1, IRR over 178 days (scipy).
        #expect(abs(report.ttwror - 0.1665) < 1e-12)
        #expect(abs(report.irr! - 0.37135943590104437) < 1e-9)

        // Since purchase: fees 9.09 × 0.4 = 3.64 leave with the sold shares, 5.45 stay.
        let r = report.security(stock)!
        #expect(r.costBasis == 273_273 && r.marketValue == 330_000 && r.unrealizedGain == 56_727)
        #expect(r.realizedGain == 9_418) // 101.82 − 3.64 − 4.00
        #expect(r.fees == 1_309 && r.taxes == 1_600 && r.shares == Shares(60))
        #expect(r.periodCurrencyGain == 27_272 - 21_818)
        #expect(ledger.snapshot(on: interval.end).position(stock)?.costBasis.minor == 273_273)

        let trades = ledger.trades(on: interval.end)
        #expect(trades.closed.count == 1 && trades.open.count == 1)
        #expect(trades.closed[0].entryValue == 182_182 && trades.closed[0].exitValue == 191_600)
        #expect(trades.closed[0].gain == 9_418 && trades.closed[0].taxes == 1_600 && trades.closed[0].fees == 764)
        #expect(trades.open[0].entryValue == 273_273 && trades.open[0].exitValue == 330_000)

        let earnings = ledger.earnings(in: interval)
        #expect(earnings.total.fees == 1_309 && earnings.total.taxes == 1_600)
    }

    @Test func reportingInTheAccountCurrencyHasNoCurrencyEffects() {
        let (_, stock, interval) = usdPortfolio()
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-02", 1.10), ("2024-03-01", 1.25), ("2024-06-28", 1.00)])
        let account = f.account("USD", "USD"), depot = f.depot("Depot")
        let same = f.security("Stock", "USD", prices: [("2024-01-02", 50), ("2024-03-01", 60), ("2024-06-28", 55)])
        f.add(.deposit, "2024-01-02", account: account, amount: 11_000, currency: "USD")
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: same, shares: 100, amount: 5_010, fees: 10,
              currency: "USD")
        f.add(.sell, "2024-03-01", account: account, depot: depot, security: same, shares: 40, amount: 2_375, fees: 5,
              taxes: 20, currency: "USD")
        #expect(same == stock)
        let b = Ledger(f.file, reportingCurrency: "USD").breakdown(in: interval)
        // In USD: realized 2 400 − 2 000, unrealized 3 300 − 3 000, cash 8 365.
        #expect(b.deposits == 1_100_000 && b.realizedGains == 40_000 && b.unrealizedGains == 30_000)
        #expect(b.fees == 1_500 && b.taxes == 2_000 && b.finalValue == 1_166_500)
        #expect(b.currencyGains == 0 && b.roundingResidue == 0)
        expectReconciled(b)
    }

    /// Average cost with a period that starts in the middle of the history.
    @Test func averageCostWithPeriodBasis() {
        var f = Fixture()
        f.file.settings.costMethod = .average
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [
            ("2024-01-02", 100), ("2024-01-03", 200), ("2024-01-10", 300), ("2024-01-15", 320), ("2024-01-20", 310),
        ])
        f.add(.deposit, "2024-01-01", account: account, amount: 3_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        f.add(.buy, "2024-01-03", account: account, depot: depot, security: stock, shares: 10, amount: 2_000)
        f.add(.sell, "2024-01-15", account: account, depot: depot, security: stock, shares: 5, amount: 1_600)
        let ledger = f.ledger
        let report = ledger.performance(in: DayInterval(start: d("2024-01-10"), end: d("2024-01-20")))
        let b = report.breakdown
        // Baseline 20 × 300 = 6 000. Sold 5 for 1 600 against 1 500; 15 left: 4 650 against 4 500.
        #expect(b.initialValue == 600_000 && b.realizedGains == 10_000 && b.unrealizedGains == 15_000)
        #expect(b.finalValue == 625_000 && b.roundingResidue == 0)
        expectReconciled(b)
        // Since purchase the average cost is 150: realized 1 600 − 750, 15 shares cost 2 250.
        let r = report.security(stock)!
        #expect(r.realizedGain == 85_000 && r.costBasis == 225_000 && r.unrealizedGain == 240_000)
        #expect(r.periodRealizedGain == 10_000 && r.periodUnrealizedGain == 15_000)
        // 6 000 → (4 800 + 1 600) / 6 000 on the 15th → 4 650 / 4 800 on the 20th.
        #expect(abs(r.ttwror - (6_400.0 / 6_000 * 4_650 / 4_800 - 1)) < 1e-12)
        #expect(abs(report.ttwror - (6_250.0 / 6_000 - 1)) < 1e-12)
    }

    /// buy 10 @ 100 (day 1), dividend 50 after 182 days, worth 1 100 after 365 days.
    @Test func securityReturnsWithADividend() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2023-01-02", 100), ("2024-01-02", 110)])
        f.add(.deposit, "2023-01-02", account: account, amount: 1_000)
        f.add(.buy, "2023-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        f.add(.dividend, "2023-07-03", account: account, depot: depot, security: stock, shares: 10, amount: 50)
        let report = f.ledger.performance(in: DayInterval(start: d("2023-01-01"), end: d("2024-01-02")))
        let r = report.security(stock)!
        // Position: 1 000 → (1 000 + 50) / 1 000 → 1 100 / 1 000.
        #expect(abs(r.ttwror - 0.155) < 1e-12)
        // −1 000 + 50 · v^(182/365) + 1 100 · v = 0 (scipy brentq).
        #expect(abs(r.irr! - 0.15371610941533798) < 1e-9)
        #expect(r.inflows == 100_000 && r.outflows == 5_000 && r.absolutePerformance == 15_000)
        // Portfolio: the dividend stays inside, 1 000 become 1 150 in exactly 365 days.
        #expect(abs(report.ttwror - 0.15) < 1e-12)
        #expect(abs(report.irr! - 0.15) < 1e-9)
        #expect(abs(report.ttwrorAnnualized! - (pow(1.15, 365.0 / 366) - 1)) < 1e-12)
    }

    /// −10 000 on day 0, −5 000 on day 100, +3 000 on day 200, worth 14 000 on day 400.
    @Test func portfolioIRRWithSeveralFlows() {
        var f = Fixture()
        let account = f.account("Cash")
        let start = d("2022-12-31")
        f.add(.deposit, "2022-12-31", account: account, amount: 10_000)
        f.add(.deposit, start.advanced(by: 100).iso, account: account, amount: 5_000)
        f.add(.withdrawal, start.advanced(by: 200).iso, account: account, amount: 3_000)
        f.add(.interest, start.advanced(by: 400).iso, account: account, amount: 2_000)
        let report = f.ledger.performance(in: DayInterval(start: start, end: start.advanced(by: 400)))
        #expect(report.valuation.initialValue == 1_000_000 && report.valuation.finalValue == 1_400_000)
        #expect(abs(report.irr! - 0.14815488947250882) < 1e-9)
        // All of the gain arrives on the last day on a base of 12 000.
        #expect(abs(report.ttwror - (14_000.0 / 12_000 - 1)) < 1e-12)
    }
}

@Suite struct ReviewBoundaryTests {
    /// The baseline is the end of `start`: bookings dated `start` are outside, `end` is inside.
    @Test func startDayIsOutsideEndDayIsInside() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.deposit, "2024-01-02", account: account, amount: 2_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 20, amount: 2_000)
        f.add(.dividend, "2024-03-31", account: account, depot: depot, security: stock, shares: 20, amount: 10)
        f.add(.sell, "2024-03-31", account: account, depot: depot, security: stock, shares: 5, amount: 600)
        f.add(.dividend, "2024-06-30", account: account, depot: depot, security: stock, shares: 15, amount: 20)
        f.add(.sell, "2024-06-30", account: account, depot: depot, security: stock, shares: 5, amount: 700)
        f.add(.dividend, "2024-07-01", account: account, depot: depot, security: stock, shares: 10, amount: 40)
        let ledger = f.ledger
        let interval = DayInterval(start: d("2024-03-31"), end: d("2024-06-30"))

        let b = ledger.breakdown(in: interval)
        #expect(b.dividends == 2_000)
        // Baseline: 15 × 100 + cash 610. The second sale realizes 700 − 500.
        #expect(b.initialValue == 211_000 && b.realizedGains == 20_000 && b.finalValue == 233_000)
        expectReconciled(b)

        let earnings = ledger.earnings(in: interval)
        #expect(earnings.total.dividends == 2_000 && earnings.payments.map(\.day) == [d("2024-06-30")])
        #expect(earnings.months.map(\.month) == [4, 5, 6])

        let trades = ledger.trades(on: interval.end, closedAfter: interval.start)
        #expect(trades.closed.map(\.end) == [d("2024-06-30")])
        #expect(ledger.closedLots(in: interval).map(\.closed) == [d("2024-06-30")])

        let series = ledger.valuation(in: interval)
        #expect(series.initialValue == 211_000 && series.finalValue == 233_000)
        #expect(series.totalInflows == 0 && series.totalOutflows == 0)

        let analysis = Analysis(ledger: ledger, interval: interval)
        #expect(analysis.initialSnapshot.totalValue.minor == 211_000)
        #expect(analysis.snapshot.totalValue.minor == 233_000)
        #expect(analysis.trades.closed.count == 1 && analysis.earnings.total.dividends == 2_000)
    }

    /// An empty (or reversed) closed-trade range must not fall back to "everything ever closed".
    @Test func emptyTradeRangeReportsNoClosedTrades() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 20, amount: 2_000)
        f.add(.sell, "2024-02-01", account: account, depot: depot, security: stock, shares: 5, amount: 600)
        let ledger = f.ledger
        let day = d("2024-03-01")
        #expect(ledger.trades(on: day).closed.count == 1)
        #expect(ledger.trades(on: day, closedAfter: d("2024-01-31")).closed.count == 1)
        #expect(ledger.trades(on: day, closedAfter: day).closed.isEmpty)
        #expect(ledger.trades(on: day, closedAfter: d("2024-04-01")).closed.isEmpty)
        // The open position is unaffected by the range.
        #expect(ledger.trades(on: day, closedAfter: day).open.map(\.shares) == [Shares(15)])
        let analysis = Analysis(ledger: ledger, interval: DayInterval(start: day, end: day))
        #expect(analysis.trades.closed.isEmpty && analysis.trades.open.count == 1)
    }
}

@Suite struct ReviewCostBasisTests {
    /// FIFO sells the oldest shares first — also when they arrived by a depot transfer after newer
    /// shares had been bought in the target depot.
    @Test func transferredLotsQueueByAcquisitionDay() {
        var f = Fixture()
        let account = f.account("Cash"), a = f.depot("A"), b = f.depot("B")
        let stock = f.security("Stock", prices: [("2020-01-02", 100), ("2022-01-03", 200), ("2023-06-01", 300)])
        f.add(.buy, "2020-01-02", account: account, depot: a, security: stock, shares: 10, amount: 1_000)
        f.add(.buy, "2021-01-04", account: account, depot: b, security: stock, shares: 10, amount: 1_500)
        f.add(.buy, "2022-01-03", account: account, depot: b, security: stock, shares: 10, amount: 2_000)
        // 6 shares of the 2020 lot move to B, where a 2021 and a 2022 lot already wait.
        f.add(.securityTransfer, "2023-01-02", depot: a, security: stock, shares: 6, amount: 1_200, counterDepot: b)
        f.add(.sell, "2023-06-01", account: account, depot: b, security: stock, shares: 10, amount: 3_000)
        let ledger = f.ledger

        let before = ledger.openLots(on: d("2023-01-02")).filter { $0.depotID == b }
        #expect(before.map(\.acquired) == [d("2020-01-02"), d("2021-01-04"), d("2022-01-03")])
        #expect(before.map(\.cost) == [60_000, 150_000, 200_000])

        // The sale takes the 6 shares from 2020 (600) and 4 of the 2021 lot (600): gain 3 000 − 1 200.
        let closed = ledger.closedLots()
        #expect(closed.map(\.opened) == [d("2020-01-02"), d("2021-01-04")])
        #expect(closed.map(\.shares) == [Shares(6), Shares(4)])
        #expect(closed.reduce(0) { $0 + $1.gain } == 180_000)
        let trade = ledger.trades(on: d("2023-06-30")).closed[0]
        #expect(trade.opened == d("2020-01-02") && trade.gain == 180_000 && trade.lots.count == 2)

        let after = ledger.openLots(on: d("2023-06-30"))
        #expect(after.filter { $0.depotID == b }.map(\.acquired) == [d("2021-01-04"), d("2022-01-03")])
        #expect(after.filter { $0.depotID == b }.map(\.cost) == [90_000, 200_000])
        #expect(after.filter { $0.depotID == a }.map(\.cost) == [40_000])
        expectReconciled(ledger.breakdown(in: DayInterval(start: d("2019-12-31"), end: d("2023-06-30"))))
    }

    /// Thousands of lots in one holding (a daily savings plan) that are sold in one go.
    @Test func liquidatingManyLotsIsLinear() {
        var file = PortfolioFile(name: "Many lots")
        let account = Account(name: "Cash", currency: "EUR"), depot = Depot(name: "Depot")
        let start = d("2000-01-01")
        let count = 6_000
        let stock = Security(name: "Coin", currency: "EUR", prices: PriceSeries([PricePoint(day: start, price: Price(10))]))
        file.accounts = [account]
        file.depots = [depot]
        file.securities = [stock]
        for i in 0..<count {
            file.transactions.append(Transaction(
                kind: .buy, date: start.advanced(by: i), accountID: account.id, depotID: depot.id, securityID: stock.id,
                shares: Shares(1), amount: Money(10, "EUR")))
        }
        let end = start.advanced(by: count)
        file.transactions.append(Transaction(
            kind: .sell, date: end, accountID: account.id, depotID: depot.id, securityID: stock.id,
            shares: Shares(Double(count)), amount: Money(Double(count) * 11, "EUR")))
        let ledger = Ledger(file)
        var gain: Int64 = 0
        let ms = bestMilliseconds(runs: 3) {
            gain = ledger.breakdown(in: DayInterval(start: start.advanced(by: -1), end: end)).realizedGains
        }
        #expect(gain == Int64(count) * 100)
        #expect(ledger.closedLots().count == count && ledger.openLots(on: end).isEmpty)
        #if !DEBUG
        #expect(ms < 15, "replay of \(count) lots took \(ms) ms")
        #endif
    }

    /// Whatever the cost method and the order of lots: realized + unrealized gains since purchase
    /// equal what was received minus what was paid plus what is still there.
    @Test(arguments: [1, 3, 5, 7, 9, 11, 13, 15] as [UInt64])
    func gainsAreConservedSincePurchase(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = false
        o.allowShort = seed % 4 == 3
        o.costMethod = seed % 8 >= 4 ? .average : .fifo
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let end = o.start.advanced(by: o.days - 1)
        let records = ledger.securityPerformance(in: DayInterval(start: o.start.advanced(by: -1), end: end))
        for security in file.securities {
            var received: Int64 = 0, paid: Int64 = 0, shares: Int64 = 0
            for t in file.transactions where t.securityID == security.id {
                switch t.kind {
                case .buy, .deliveryIn:
                    paid += t.amount.minor - t.taxes // fees are part of the cost, taxes are not
                    shares += t.shares.raw
                case .sell, .deliveryOut:
                    received += t.amount.minor + t.taxes // after fees, before taxes
                    shares -= t.shares.raw
                default: break
                }
            }
            // Positions are valued per depot (each rounded to a cent).
            let price = security.prices.price(on: end)!
            let value = file.depots.reduce(Int64(0)) { sum, depot in
                let held = file.transactions.filter { $0.securityID == security.id }
                    .reduce(Int64(0)) { $0 + $1.sharesEffect(on: depot.id).raw }
                return sum + price.value(of: Shares(raw: held))
            }
            let record = records.first { $0.securityID == security.id }
            #expect((record?.shares.raw ?? 0) == shares)
            #expect((record?.marketValue ?? 0) == value)
            #expect((record?.realizedGain ?? 0) + (record?.unrealizedGain ?? 0) == received - paid + value,
                    "seed \(seed) \(security.name)")
        }
    }
}

/// Values and flows recomputed from nothing but the model API (`cashEffect`, `sharesEffect`,
/// `PriceSeries.price(on:)`, `ExchangeRateSeries.rate(on:)`) — no engine index involved.
@Suite struct ReviewIndependentValuationTests {
    @Test(arguments: [2, 4, 6, 8, 10] as [UInt64])
    func valuesAndFlowsMatchABruteForceModelWalk(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = true
        o.allowShort = seed % 4 == 0
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let eurUsd = file.exchangeRates[0]
        func toEUR(_ minor: Int64, _ currency: String, _ day: Day) -> Double {
            currency == "EUR" ? Double(minor) : Double(minor) / eurUsd.rate(on: day)!
        }
        let interval = DayInterval(start: o.start.advanced(by: -1), end: o.start.advanced(by: o.days - 1))
        let series = ledger.valuation(in: interval)

        for offset in stride(from: 3, to: o.days, by: 53) {
            let day = o.start.advanced(by: offset)
            var total = 0.0
            var items = 0
            for account in file.accounts {
                let balance = file.transactions.filter { $0.date <= day }.reduce(Int64(0)) { $0 + $1.cashEffect(on: account.id) }
                total += toEUR(balance, account.currency, day)
                items += 1
            }
            for security in file.securities {
                for depot in file.depots {
                    let shares = file.transactions.filter { $0.date <= day && $0.securityID == security.id }
                        .reduce(Int64(0)) { $0 + $1.sharesEffect(on: depot.id).raw }
                    guard shares != 0 else { continue }
                    total += toEUR(security.prices.price(on: day)!.value(of: Shares(raw: shares)), security.currency, day)
                    items += 1
                }
            }
            let engine = series.values[series.index(of: day)!]
            // The engine rounds every position and balance to a cent after conversion.
            #expect(abs(Double(engine) - total) <= Double(items) * 0.5 + 0.01, "seed \(seed) \(day)")
        }

        // External flows of the whole portfolio: deposits and inbound deliveries in, withdrawals and
        // outbound deliveries out, each converted at its day's rate.
        var inflows = 0.0, outflows = 0.0, flowCount = 0
        for t in file.transactions where interval.contains(t.date) {
            switch t.kind {
            case .deposit, .deliveryIn: inflows += toEUR(t.amount.minor, t.amount.currency, t.date).rounded()
            case .withdrawal, .deliveryOut: outflows += toEUR(t.amount.minor, t.amount.currency, t.date).rounded()
            default: continue
            }
            flowCount += 1
        }
        #expect(flowCount > 20)
        #expect(Double(series.totalInflows) == inflows && Double(series.totalOutflows) == outflows)

        // TTWROR recomputed from the definition on the engine's own daily values and flows.
        var factor = 1.0
        for i in 1..<series.count {
            let base = Double(series.values[i - 1] + series.inflows[i])
            if series.values[i - 1] >= 0, base > 0 { factor *= max(Double(series.values[i] + series.outflows[i]) / base, 0) }
        }
        #expect(abs(series.returns().total - (factor - 1)) < 1e-9 * max(1, abs(factor)))
    }
}

@Suite struct ReviewRebalancingTests {
    /// Three classes A / B / C holding 600 / 300 / 100 in cash accounts, targets 50 / 30 / 20 %.
    private func threeClasses() -> (ledger: Ledger, taxonomy: Taxonomy, accounts: [UUID]) {
        var f = Fixture()
        let a = f.account("A"), b = f.account("B"), c = f.account("C")
        f.add(.deposit, "2024-01-02", account: a, amount: 600)
        f.add(.deposit, "2024-01-02", account: b, amount: 300)
        f.add(.deposit, "2024-01-02", account: c, amount: 100)
        let taxonomy = Taxonomy(name: "T", root: [
            Classification(name: "A", targetWeight: 5_000, assignments: [.init(accountID: a)]),
            Classification(name: "B", targetWeight: 3_000, assignments: [.init(accountID: b)]),
            Classification(name: "C", targetWeight: 2_000, assignments: [.init(accountID: c)]),
        ])
        return (f.ledger, taxonomy, [a, b, c])
    }

    private func amounts(_ p: RebalancingProposal, _ accounts: [UUID]) -> [Int64] {
        accounts.map { id in p.orders.first { $0.vehicle == .account(id) }?.amount ?? 0 }
    }

    @Test func waterFillingLevels() {
        let (ledger, taxonomy, accounts) = threeClasses()
        let day = d("2024-02-01")
        func propose(_ cash: Int64, _ mode: RebalancingOptions.Mode) -> RebalancingProposal {
            ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: cash, mode: mode))
        }
        // Value / target: A 12, B 10, C 5. 100 lift C from 5 to 10 — exactly B's level.
        #expect(amounts(propose(10_000, .noSales), accounts) == [0, 0, 10_000])
        // 150: B and C meet at (300 + 100 + 150) / 50 = 11 → B 330, C 220.
        #expect(amounts(propose(15_000, .noSales), accounts) == [0, 3_000, 12_000])
        // 200 reach the targets of 1 200 exactly: 600 / 360 / 240.
        #expect(amounts(propose(20_000, .noSales), accounts) == [0, 6_000, 14_000])
        // 800: everyone is on target afterwards (1 800 → 900 / 540 / 360).
        #expect(amounts(propose(80_000, .noSales), accounts) == [30_000, 24_000, 26_000])
        // Withdraw 150 without buying: A comes down to B's level with 100, then A and B share
        // (900 − 150) / 80 = 9.375 → A 468.75, B 281.25.
        #expect(amounts(propose(-15_000, .noSales), accounts) == [-13_125, -1_875, 0])
        // Buy and sell: straight to the targets.
        #expect(amounts(propose(0, .buyAndSell), accounts) == [-10_000, 0, 10_000])
        #expect(amounts(propose(20_000, .buyAndSell), accounts) == [0, 6_000, 14_000])
        #expect(amounts(propose(-50_000, .buyAndSell), accounts) == [-35_000, -15_000, 0])
        for cash in [10_000, 15_000, 20_000, 80_000, -15_000] as [Int64] {
            let p = propose(cash, .noSales)
            #expect(p.residualCash == 0 && p.valueAfter == 100_000 + cash)
            #expect(p.orders.allSatisfy { ($0.amount > 0) == (cash > 0) })
        }
    }

    /// A quote of 0.00000001 and a large order must saturate, not trap.
    @Test func extremePricesDoNotTrap() {
        var file = PortfolioFile(name: "Dust")
        let account = Account(name: "Cash", currency: "EUR"), depot = Depot(name: "Depot")
        let day = d("2024-01-02")
        let coin = Security(name: "Dust", currency: "EUR", prices: PriceSeries([PricePoint(day: day, price: Price(raw: 1))]))
        file.accounts = [account]
        file.depots = [depot]
        file.securities = [coin]
        file.transactions = [Transaction(
            kind: .deliveryIn, date: day, depotID: depot.id, securityID: coin.id, shares: Shares(1_000_000),
            amount: Money(minor: 1, currency: "EUR"))]
        let taxonomy = Taxonomy(name: "T", root: [
            Classification(name: "All", targetWeight: 10_000, assignments: [.init(securityID: coin.id)]),
        ])
        let ledger = Ledger(file)
        for whole in [false, true] {
            let p = ledger.rebalancing(
                for: taxonomy, on: day, options: RebalancingOptions(cash: 100_000_000_000, wholeShares: whole))
            #expect(p.orders.count == 1 && p.orders[0].amount == 100_000_000_000 && p.residualCash == 0)
            #expect(p.orders[0].shares == Shares(raw: .max))
        }
    }
}

@Suite struct ReviewPlanTests {
    @Test(arguments: [1, 2, 3, 12], [true, false])
    func nextDueDateAgreesWithDueDates(months: Int, moveToWeekday: Bool) {
        for startISO in ["2023-01-31", "2024-02-29", "2023-12-30", "2023-07-01"] {
            let start = d(startISO)
            for end in [nil, start.advanced(by: 400)] as [Day?] {
                let plan = InvestmentPlan(
                    name: "P", amount: Money(100, "EUR"), start: start, end: end, intervalMonths: months)
                let horizon = start.advanced(by: 900)
                let all = plan.dueDates(through: horizon, moveToWeekday: moveToWeekday)
                #expect(zip(all, all.dropFirst()).allSatisfy { $0 < $1 })
                #expect(all.first == (moveToWeekday && start.isWeekend ? start.advanced(by: 8 - start.weekday) : start))
                if moveToWeekday { #expect(all.allSatisfy { !$0.isWeekend }) }
                if let end { #expect(all.allSatisfy { $0 <= end.advanced(by: 2) }) }
                // Nominal dates keep the start's day of month wherever the month is long enough.
                if !moveToWeekday {
                    for (k, due) in all.enumerated() {
                        let expected = start.addingMonths(k * months)
                        #expect(due == expected)
                        #expect(due.dayOfMonth == min(start.dayOfMonth, Day.daysInMonth(year: due.year, month: due.month)))
                    }
                }
                for offset in stride(from: -5, to: 800, by: 3) {
                    let day = start.advanced(by: offset)
                    #expect(plan.dueDates(through: day, moveToWeekday: moveToWeekday) == all.filter { $0 <= day })
                    let next = plan.nextDueDate(after: day, moveToWeekday: moveToWeekday)
                    if let expected = all.first(where: { $0 > day }) {
                        #expect(next == expected, "\(startISO) every \(months) after \(day)")
                    } else if end != nil {
                        #expect(next == nil)
                    }
                }
            }
        }
    }

    @Test func absurdIntervalsDoNotTrap() {
        let start = d("2024-01-15")
        for months in [Int.max, Int.max / 2, 1_000_000, 0, -3, Int.min] {
            let plan = InvestmentPlan(name: "P", amount: Money(100, "EUR"), start: start, intervalMonths: months)
            let dates = plan.dueDates(through: start.advanced(by: 400), moveToWeekday: false)
            #expect(dates == (months > 0 ? [start] : []))
            let next = plan.nextDueDate(after: start, moveToWeekday: false)
            #expect(months > 0 ? next == d("2124-01-15") : next == nil)
        }
    }
}

@Suite struct ReviewSameMomentTests {
    /// Bookings of one day without a time of day have no natural order (ids decide). A sale that
    /// happens to sort before the purchase it sells must not be reported as a short sale.
    @Test func untimedSaleBeforePurchaseIsNotAShortSale() {
        for method in [CostMethod.fifo, .average] {
            var f = Fixture()
            f.file.settings.costMethod = method
            let account = f.account("Cash"), depot = f.depot("Depot"), other = f.depot("Other")
            let stock = f.security("Stock", prices: [("2024-01-02", 100)])
            f.add(.deposit, "2024-01-02", account: account, amount: 5_000)
            // Ids ascend in creation order: the sale and the transfer sort before the purchase.
            let sale = f.add(.sell, "2024-01-02", account: account, depot: depot, security: stock, shares: 4, amount: 440)
            f.add(.securityTransfer, "2024-01-02", depot: depot, security: stock, shares: 3, amount: 300, counterDepot: other)
            f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
            let ledger = f.ledger
            let day = d("2024-01-03")

            #expect(ledger.transactions.map(\.id) == f.file.transactions.sorted(by: Transaction.chronological).map(\.id))
            let snapshot = ledger.snapshot(on: day)
            #expect(!snapshot.diagnostics.contains { if case .shortPosition = $0 { return true } else { return false } })
            #expect(snapshot.position(stock)?.shares == Shares(6) && snapshot.position(stock)?.costBasis.minor == 60_000)
            let trades = ledger.trades(on: day)
            #expect(trades.closed.count == 1)
            #expect(trades.closed[0].isShort == false && trades.closed[0].closingTransactionID == sale)
            #expect(trades.closed[0].gain == 4_000 && trades.closed[0].entryValue == 40_000)
            #expect(trades.open.allSatisfy { !$0.isShort })
            #expect(ledger.openLots(on: day).map(\.shares).sorted() == [Shares(3), Shares(3)])
            let report = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: day))
            #expect(report.breakdown.realizedGains == 4_000 && report.breakdown.roundingResidue == 0)
            #expect(report.valuation.values == [0, 504_000, 504_000])
            expectReconciled(report.breakdown)
            #expect(ledger.consistencyIssues(options: .init(today: day)).isEmpty)
        }
    }

    /// The order is only touched where a sale would otherwise overdraw the position: selling
    /// everything and buying back on the same day still realizes the whole gain.
    @Test func sellAllThenRebuyKeepsItsOrder() {
        for method in [CostMethod.fifo, .average] {
            var f = Fixture()
            f.file.settings.costMethod = method
            let account = f.account("Cash"), depot = f.depot("Depot")
            let stock = f.security("Stock", prices: [("2023-01-02", 50), ("2024-01-02", 100)])
            f.add(.buy, "2023-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 500)
            f.add(.sell, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
            f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
            let ledger = f.ledger
            let closed = ledger.closedLots()
            #expect(closed.count == 1 && closed[0].gain == 50_000 && closed[0].opened == d("2023-01-02"))
            #expect(ledger.snapshot(on: d("2024-01-02")).position(stock)?.costBasis.minor == 100_000)
        }
    }

    /// A time of day is respected: a timed sale before a timed purchase really is a short sale.
    @Test func timedOrderIsRespected() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 5, amount: 450, minute: 900)
        f.add(.sell, "2024-01-02", account: account, depot: depot, security: stock, shares: 5, amount: 500, minute: 600)
        let trades = f.ledger.trades(on: d("2024-01-03"))
        #expect(trades.closed.count == 1 && trades.closed[0].isShort && trades.closed[0].gain == 5_000)
    }
}

/// "The engine never traps on bad data": damaged files run through every public entry point.
@Suite struct ReviewGarbageTests {
    static func damaged(seed: UInt64) -> PortfolioFile {
        var o = RandomPortfolioOptions(seed: seed)
        o.days = 400
        o.transactions = 250
        o.allowShort = true
        o.costMethod = seed % 2 == 0 ? .average : .fifo
        var file = makeRandomPortfolio(o)
        var rng = SplitMix64(seed: seed &* 7_919 &+ 13)
        let kinds = Transaction.Kind.allCases
        for i in file.transactions.indices where rng.chance(0.35) {
            var t = file.transactions[i]
            switch rng.int(0...15) {
            case 0: t.kind = kinds[rng.int(0...(kinds.count - 1))]
            case 1: t.accountID = rng.chance(0.5) ? nil : UUID()
            case 2: t.depotID = rng.chance(0.5) ? nil : UUID()
            case 3: t.securityID = rng.chance(0.5) ? nil : UUID()
            case 4: t.shares = Shares(raw: -t.shares.raw - 1)
            case 5: t.shares = .zero
            case 6: t.amount.minor = -t.amount.minor
            case 7: t.amount = Money(minor: 0, currency: t.amount.currency)
            case 8: t.fees = t.amount.minor * 3 + 5
            case 9: t.taxes = -17
            case 10: t.amount.currency = ["XXX", "", "USD", "JPY"][rng.int(0...3)]
            case 11:
                t.kind = .cashTransfer
                t.counterAccountID = rng.chance(0.5) ? t.accountID : file.accounts[rng.int(0...(file.accounts.count - 1))].id
                t.counterAmount = rng.chance(0.5) ? Money(minor: Int64(rng.int(-500...90_000)), currency: "CHF") : nil
            case 12:
                t.kind = .securityTransfer
                t.counterDepotID = rng.chance(0.5) ? t.depotID : file.depots[rng.int(0...1)].id
            case 13: t.minuteOfDay = [-5, 0, 1_439, 100_000, Int.max][rng.int(0...4)]
            case 14: t.id = file.transactions[rng.int(0...(file.transactions.count - 1))].id
            default: t.securityGross = Money(minor: Int64(rng.int(-100...100_000)), currency: ["USD", "EUR", "GBP"][rng.int(0...2)])
            }
            file.transactions[i] = t
        }
        // Securities without quotes, in an unconvertible currency, and a damaged rate series.
        file.securities[0].prices = PriceSeries()
        file.securities[1].currency = "GBP"
        file.securities.append(file.securities[2]) // duplicate id
        file.accounts.append(Account(name: "Yen", currency: "JPY"))
        file.exchangeRates.append(ExchangeRateSeries(base: "EUR", quote: "CHF", days: [5, 3, 3], rates: [0, -.infinity, .nan]))
        file.exchangeRates.append(ExchangeRateSeries(base: "EUR", quote: "EUR", days: [1], rates: [2]))
        return file
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] as [UInt64])
    func everyEntryPointSurvivesDamagedFiles(seed: UInt64) {
        let file = Self.damaged(seed: seed)
        let ledger = Ledger(file, reportingCurrency: seed % 5 == 0 ? "USD" : nil)
        let start = Day(year: 2015, month: 1, day: 1)
        let weights = Dictionary(file.securities.prefix(5).enumerated().map { ($1.id, [0, -4, 3_333, 10_000, 99_999][$0]) }) { a, _ in a }
        let scopes: [Scope] = [
            .portfolio, .depot(file.depots[0].id, account: file.accounts[0].id), .account(file.accounts[2].id),
            .security(file.securities[0].id), .security(file.securities[2].id, depot: file.depots[1].id),
            .security(UUID()), .subset(depots: [UUID()], accounts: []),
            .weighted(securities: weights, accounts: [file.accounts[1].id: 5_000, UUID(): 10_000]),
        ]
        let intervals = [
            DayInterval(start: start.advanced(by: -40), end: start.advanced(by: 450)),
            DayInterval(start: start.advanced(by: 120), end: start.advanced(by: 240)),
            DayInterval(start: start.advanced(by: 200), end: start.advanced(by: 200)),
            DayInterval(start: start.advanced(by: 900), end: start.advanced(by: 600)),
        ]
        var taxonomy = Taxonomy(name: "T")
        var rng = SplitMix64(seed: seed)
        for i in 0..<4 {
            var node = Classification(name: "C\(i)", targetWeight: [nil, 5_000, -100, 20_000][i])
            for s in file.securities where rng.chance(0.4) {
                node.assignments.append(.init(securityID: s.id, weight: [10_000, 2_500, -5, 70_000, 0][rng.int(0...4)]))
            }
            node.assignments.append(.init(accountID: file.accounts[i % file.accounts.count].id, weight: 6_000))
            node.assignments.append(.init()) // names nothing
            node.children = [Classification(name: "Child", targetWeight: i % 2 == 0 ? 10_000 : nil,
                                            assignments: [.init(securityID: file.securities[i].id, weight: 5_000)])]
            taxonomy.root.append(node)
        }

        for scope in scopes {
            for interval in intervals {
                let report = ledger.performance(in: interval, scope: scope)
                expectReconciled(report.breakdown)
                #expect(report.breakdown.initialValue == report.valuation.initialValue)
                #expect(report.breakdown.finalValue == report.valuation.finalValue)
                #expect(report.returns.daily.allSatisfy { $0.isFinite && $0 >= -1 })
                #expect(report.securities.allSatisfy { $0.ttwror.isFinite && ($0.irr?.isFinite ?? true) })
                #expect(report.valuation.finalValue == ledger.snapshot(on: interval.end, scope: scope).totalValue.minor)

                let analysis = Analysis(ledger: ledger, scope: scope, interval: interval)
                #expect(analysis.breakdown == report.breakdown)
                _ = (analysis.snapshot, analysis.initialSnapshot, analysis.risk, analysis.heatmap, analysis.drawdowns)
                _ = (analysis.trades, analysis.investedCapital, analysis.report, analysis.diagnostics)
                _ = analysis.rollingReturns(windowDays: 30, annualized: true)
                _ = analysis.benchmark(securityID: file.securities[1].id)
                let earnings = analysis.earnings
                #expect(earnings.total.dividends == report.breakdown.dividends)
                #expect(earnings.total.interest - earnings.total.interestCharges == report.breakdown.interest)
                #expect(earnings.total.fees == report.breakdown.fees && earnings.total.taxes == report.breakdown.taxes)
                _ = (earnings.quarters, earnings.years, earnings.trailingTwelveMonths(.net), earnings.yearOverYear(.dividends))

                let allocation = analysis.allocation(for: taxonomy)
                #expect(allocation.totalValue == analysis.snapshot.totalValue.minor)
                for cash in [0, 123_456, -98_765] as [Int64] {
                    for mode in RebalancingOptions.Mode.allCases {
                        for whole in [false, true] {
                            let p = allocation.rebalancing(RebalancingOptions(cash: cash, mode: mode, wholeShares: whole))
                            #expect(p.orders.reduce(0) { $0 + $1.amount } + p.residualCash == cash)
                        }
                    }
                }
            }
            _ = ledger.openLots(on: start.advanced(by: 300), scope: scope)
            _ = ledger.closedLots(scope: scope)
        }
        _ = ledger.classificationPerformance(of: taxonomy, in: intervals[1])
        _ = ledger.consistencyIssues(options: .init(today: start.advanced(by: 380)))
        _ = ConsistencyChecker.check(file)
        for kind in InvestmentPlan.Kind.allCases {
            let plan = InvestmentPlan(
                name: "P", kind: kind, securityID: file.securities[Int(seed) % 3].id, depotID: file.depots[0].id,
                accountID: seed % 2 == 0 ? file.accounts[0].id : nil, amount: Money(100, seed % 3 == 0 ? "USD" : "EUR"),
                fees: 150, start: start.advanced(by: 3), intervalMonths: 1)
            let proposal = ledger.planTransactions(plan, through: start.advanced(by: 400))
            _ = Ledger(PortfolioFile(
                settings: file.settings, securities: file.securities, accounts: file.accounts, depots: file.depots,
                transactions: file.transactions + proposal.transactions, exchangeRates: file.exchangeRates))
        }
        if let split = StockSplit(securityID: file.securities[3].id, day: start.advanced(by: 100), ratio: "7:3"),
           let adjusted = file.applying(split) {
            _ = Ledger(adjusted).snapshot(on: start.advanced(by: 399))
        }
    }
}

@Suite struct ReviewDepotAttributionTests {
    /// Dividends (and security fees / taxes) often carry no depot — Portfolio Performance books
    /// them on the account only. They belong to the depot that holds the security at that time,
    /// not to every depot that ever held it.
    @Test func depotlessDividendsFollowTheHolding() {
        var f = Fixture()
        let account = f.account("Cash"), a = f.depot("A"), b = f.depot("B")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.deposit, "2024-01-02", account: account, amount: 1_000)
        f.add(.buy, "2024-01-02", account: account, depot: a, security: stock, shares: 10, amount: 1_000)
        f.add(.dividend, "2024-02-01", account: account, security: stock, shares: 10, amount: 30) // held in A
        f.add(.securityTransfer, "2024-03-01", depot: a, security: stock, shares: 10, amount: 1_000, counterDepot: b)
        f.add(.dividend, "2024-04-01", account: account, security: stock, shares: 10, amount: 40) // held in B
        f.add(.fee, "2024-04-02", account: account, security: stock, amount: 3) // held in B
        f.add(.sell, "2024-05-01", account: account, depot: b, security: stock, shares: 10, amount: 1_000)
        f.add(.dividend, "2024-05-10", account: account, security: stock, shares: 10, amount: 50) // paid after the sale: B
        let ledger = f.ledger
        let interval = DayInterval(start: d("2024-01-01"), end: d("2024-06-30"))

        let whole = ledger.breakdown(in: interval)
        let inA = ledger.breakdown(in: interval, scope: .depot(a))
        let inB = ledger.breakdown(in: interval, scope: .depot(b))
        #expect(whole.dividends == 12_000 && whole.fees == 300)
        #expect(inA.dividends == 3_000 && inA.fees == 0)
        #expect(inB.dividends == 9_000 && inB.fees == 300)
        expectReconciled(inA)
        expectReconciled(inB)
        #expect(ledger.earnings(in: interval, scope: .depot(a)).total.dividends == 3_000)
        #expect(ledger.earnings(in: interval, scope: .depot(b)).payments.map(\.gross) == [4_000, 5_000])
        #expect(ledger.valuation(in: interval, scope: .depot(a)).totalOutflows == 3_000 + 100_000)
        // Security in one depot only.
        let recordA = ledger.securityPerformance(in: interval, scope: .security(stock, depot: a))
        #expect(recordA.first?.dividends == 3_000 && recordA.first?.dividendCount == 1)
        // Once the position has left depot A, later bookings no longer list the security there.
        let late = DayInterval(start: d("2024-03-15"), end: d("2024-06-30"))
        #expect(ledger.securityPerformance(in: late, scope: .depot(a)).isEmpty)
        #expect(ledger.securityPerformance(in: late, scope: .depot(b)).map(\.dividends) == [9_000])
        // The whole security is unaffected by the attribution.
        #expect(ledger.securityPerformance(in: interval, scope: .security(stock)).first?.dividends == 12_000)
    }

    /// Held in two depots at once: a depot-less dividend cannot be attributed and counts for the
    /// security as a whole (every depot scope holding it sees it).
    @Test func ambiguousDividendsCountForEveryHoldingDepot() {
        var f = Fixture()
        let account = f.account("Cash"), a = f.depot("A"), b = f.depot("B"), c = f.depot("C")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.buy, "2024-01-02", account: account, depot: a, security: stock, shares: 10, amount: 1_000)
        f.add(.buy, "2024-01-02", account: account, depot: b, security: stock, shares: 10, amount: 1_000)
        f.add(.dividend, "2024-02-01", account: account, security: stock, shares: 20, amount: 60)
        f.add(.dividend, "2024-02-02", account: account, depot: b, security: stock, shares: 10, amount: 7)
        let ledger = f.ledger
        let interval = DayInterval(start: d("2024-01-01"), end: d("2024-06-30"))
        #expect(ledger.breakdown(in: interval, scope: .depot(a)).dividends == 6_000)
        #expect(ledger.breakdown(in: interval, scope: .depot(b)).dividends == 6_700)
        #expect(ledger.breakdown(in: interval, scope: .depot(c)).dividends == 0)
        #expect(ledger.breakdown(in: interval).dividends == 6_700)
    }
}
