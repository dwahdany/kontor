import Foundation
import KontorEngine
import KontorModel
import Testing

/// Checks the documented reconciliation identity of a breakdown.
func expectReconciled(_ b: PerformanceBreakdown, sourceLocation: SourceLocation = #_sourceLocation) {
    let sum = b.initialValue + b.deposits + b.deliveriesIn + b.transfersIn - b.withdrawals - b.deliveriesOut
        - b.transfersOut + b.realizedGains + b.unrealizedGains + b.dividends + b.interest - b.fees - b.taxes
        + b.cashCurrencyGains + b.roundingResidue
    #expect(sum == b.finalValue, sourceLocation: sourceLocation)
    #expect(b.componentSum == b.absolutePerformance, sourceLocation: sourceLocation)
    let lines = b.lines
    #expect(lines.dropLast().reduce(0) { $0 + $1.amount } == lines.last!.amount, sourceLocation: sourceLocation)
}

@Suite struct BreakdownTests {
    /// deposit 10 000; buy 50 @ 100 + 10 fees; sell 20 @ 121 − 5 fees − 15 taxes; last price 121.
    private func basic(_ method: CostMethod = .fifo) -> (ledger: Ledger, stock: UUID) {
        var f = Fixture()
        f.file.settings.costMethod = method
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100), ("2024-01-03", 110), ("2024-01-04", 121)])
        f.add(.deposit, "2024-01-01", account: account, amount: 10_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 50, amount: 5_010, fees: 10)
        f.add(.sell, "2024-01-04", account: account, depot: depot, security: stock, shares: 20, amount: 2_400, fees: 5, taxes: 15)
        return (f.ledger, stock)
    }

    @Test func wholePeriod() {
        let (ledger, stock) = basic()
        let report = ledger.performance(in: DayInterval(start: d("2023-12-31"), end: d("2024-01-05")))
        let b = report.breakdown
        #expect(b.initialValue == 0)
        #expect(b.deposits == 1_000_000)
        // Realized (gross): 20 × 121 − 20 × 100 = 420. Unrealized (gross): 30 × 121 − 30 × 100 = 630.
        #expect(b.realizedGains == 42_000)
        #expect(b.unrealizedGains == 63_000)
        #expect(b.fees == 1_500) // 10 on the buy + 5 on the sale
        #expect(b.taxes == 1_500)
        #expect(b.dividends == 0 && b.interest == 0 && b.cashCurrencyGains == 0)
        #expect(b.withdrawals == 0 && b.deliveriesIn == 0 && b.transfersIn == 0 && b.transfersOut == 0)
        // 10 000 + 420 + 630 − 15 − 15 = 11 020
        #expect(b.finalValue == 1_102_000)
        #expect(b.roundingResidue == 0)
        #expect(b.absolutePerformance == 102_000 && b.capitalGains == 105_000)
        expectReconciled(b)
        #expect(report.absolutePerformance == report.valuation.absolutePerformance)

        let r = report.security(stock)!
        #expect(r.shares == Shares(30))
        #expect(r.marketValue == 363_000 && r.initialValue == 0)
        #expect(r.costBasis == 300_600) // 5 010 × 30 / 50
        #expect(r.purchasePrice == Price(100.20))
        #expect(r.unrealizedGain == 62_400)
        #expect(abs(r.unrealizedGainFraction! - 624.0 / 3_006) < 1e-12)
        // Net proceeds 2 420 − 5 = 2 415 minus cost of 20 shares 5 010 × 20 / 50 = 2 004 → 411 (taxes separate)
        #expect(r.realizedGain == 41_100)
        #expect(r.periodRealizedGain == 42_000 && r.periodUnrealizedGain == 63_000 && r.periodCurrencyGain == 0)
        #expect(r.fees == 1_500 && r.taxes == 1_500 && r.dividends == 0 && r.lastDividend == nil)
        #expect(r.inflows == 501_000 && r.outflows == 240_000)
        #expect(r.absolutePerformance == 102_000) // 3 630 − 5 010 + 2 400 = 420 + 630 − 15 − 15
        #expect(abs(r.portfolioWeight! - 3_630.0 / 11_020) < 1e-12)
        // TTWROR of the position: 5 000 / 5 010 × 5 500 / 5 000 × (3 630 + 2 400) / 5 500 = 6 030 / 5 010
        #expect(abs(r.ttwror - (6_030.0 / 5_010 - 1)) < 1e-12)
        // IRR: −5 010 on 01-02, +2 400 on 01-04, +3 630 at the end (01-05)
        let irr = r.irr!
        let npv = -5_010 + 2_400 * pow(1 + irr, -2.0 / 365) + 3_630 * pow(1 + irr, -3.0 / 365)
        #expect(abs(npv) < 1e-6)
    }

    @Test func periodBasisStartsAtMarketValue() {
        let (ledger, stock) = basic()
        // Baseline: end of 01-03 → 50 × 110 = 5 500 securities + 4 990 cash = 10 490.
        let report = ledger.performance(in: DayInterval(start: d("2024-01-03"), end: d("2024-01-05")))
        let b = report.breakdown
        #expect(b.initialValue == 1_049_000)
        // Sold 20 for 2 420 against 20 × 110 = 2 200 → 220; remaining 30 × (121 − 110) = 330.
        #expect(b.realizedGains == 22_000)
        #expect(b.unrealizedGains == 33_000)
        #expect(b.fees == 500 && b.taxes == 1_500) // only the sale falls into the period
        #expect(b.deposits == 0)
        #expect(b.finalValue == 1_102_000 && b.roundingResidue == 0) // 10 490 + 220 + 330 − 5 − 15
        expectReconciled(b)
        // Since-purchase figures are independent of the period.
        let r = report.security(stock)!
        #expect(r.realizedGain == 41_100 && r.costBasis == 300_600 && r.initialValue == 550_000)
        #expect(r.inflows == 0 && r.outflows == 240_000)
        #expect(ledger.breakdown(in: report.interval) == b)
    }

    @Test func earningsFeesAndTaxes() {
        var f = Fixture()
        let account = f.account("Cash")
        f.add(.deposit, "2024-01-01", account: account, amount: 1_000)
        f.add(.interest, "2024-01-02", account: account, amount: 7.50, taxes: 2.50) // gross 10.00
        f.add(.interestCharge, "2024-01-03", account: account, amount: 1.25)
        f.add(.fee, "2024-01-04", account: account, amount: 3)
        f.add(.feeRefund, "2024-01-05", account: account, amount: 1)
        f.add(.tax, "2024-01-06", account: account, amount: 4)
        f.add(.taxRefund, "2024-01-07", account: account, amount: 1.50)
        f.add(.withdrawal, "2024-01-08", account: account, amount: 200)
        let b = f.ledger.breakdown(in: DayInterval(start: d("2023-12-31"), end: d("2024-01-10")))
        #expect(b.deposits == 100_000 && b.withdrawals == 20_000)
        #expect(b.interest == 875) // 10.00 − 1.25
        #expect(b.fees == 200) // 3.00 − 1.00
        #expect(b.taxes == 500) // 2.50 + 4.00 − 1.50
        // 1 000 − 200 + 8.75 − 2.00 − 5.00 = 801.75
        #expect(b.finalValue == 80_175 && b.roundingResidue == 0)
        #expect(b.earnings == 875)
        expectReconciled(b)
    }

    @Test func deliveries() {
        var f = Fixture()
        let depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 50), ("2024-01-04", 60)])
        // 10 shares delivered in, valued 500.00 + 5.00 fees; 4 delivered out at 60 (240 − 2 fees − 8 taxes = 230).
        f.add(.deliveryIn, "2024-01-02", depot: depot, security: stock, shares: 10, amount: 505, fees: 5)
        f.add(.deliveryOut, "2024-01-04", depot: depot, security: stock, shares: 4, amount: 230, fees: 2, taxes: 8)
        let report = f.ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-05")))
        let b = report.breakdown
        #expect(b.deliveriesIn == 50_500 && b.deliveriesOut == 23_000)
        #expect(b.realizedGains == 4_000) // 240 − 4 × 50
        #expect(b.unrealizedGains == 6_000) // 6 × (60 − 50)
        #expect(b.fees == 700 && b.taxes == 800)
        #expect(b.finalValue == 36_000 && b.roundingResidue == 0) // 505 − 230 + 40 + 60 − 7 − 8 = 360
        expectReconciled(b)
        #expect(report.valuation.inflows[1] == 50_500 && report.valuation.outflows[3] == 23_000)
        // TTWROR: 500 / 505 × (360 + 230) / 500 = 590 / 505
        #expect(abs(report.ttwror - (590.0 / 505 - 1)) < 1e-12)
        // Cost basis: (500 + 5) × 6 / 10 = 303; realized net: (240 − 2) − 202 = 36
        #expect(report.securities[0].costBasis == 30_300 && report.securities[0].realizedGain == 3_600)
    }
}

@Suite struct CostBasisTests {
    /// buy 10 @ 100, buy 10 @ 200, sell 5 @ 300 (no fees).
    private func ledger(_ method: CostMethod) -> (Ledger, UUID) {
        var f = Fixture()
        f.file.settings.costMethod = method
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100), ("2024-01-03", 200), ("2024-01-04", 300)])
        f.add(.deposit, "2024-01-01", account: account, amount: 10_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        f.add(.buy, "2024-01-03", account: account, depot: depot, security: stock, shares: 10, amount: 2_000)
        f.add(.sell, "2024-01-04", account: account, depot: depot, security: stock, shares: 5, amount: 1_500)
        return (f.ledger, stock)
    }
    let interval = DayInterval(start: d("2023-12-31"), end: d("2024-01-05"))

    @Test func fifo() {
        let (ledger, stock) = ledger(.fifo)
        let r = ledger.performance(in: interval).security(stock)!
        #expect(r.realizedGain == 100_000) // 1 500 − 5 × 100
        #expect(r.costBasis == 250_000) // 5 × 100 + 10 × 200
        #expect(r.unrealizedGain == 200_000) // 15 × 300 − 2 500
        let lots = ledger.openLots(on: d("2024-01-05"))
        #expect(lots.map(\.shares) == [Shares(5), Shares(10)])
        #expect(lots.map(\.cost) == [50_000, 200_000])
        #expect(lots.map(\.acquired) == [d("2024-01-02"), d("2024-01-03")])
        let closed = ledger.closedLots()
        #expect(closed.count == 1)
        #expect(closed[0].shares == Shares(5) && closed[0].opened == d("2024-01-02") && closed[0].closed == d("2024-01-04"))
        #expect(closed[0].cost == 50_000 && closed[0].proceeds == 150_000 && closed[0].gain == 100_000)
        #expect(closed[0].holdingDays == 2 && !closed[0].isShort)
        #expect(ledger.closedLots(in: DayInterval(start: d("2024-01-04"), end: d("2024-01-05"))).isEmpty)
    }

    @Test func movingAverage() {
        let (ledger, stock) = ledger(.average)
        let report = ledger.performance(in: interval)
        let r = report.security(stock)!
        // Average cost 3 000 / 20 = 150 → sold 5 for 1 500 against 750.
        #expect(r.realizedGain == 75_000)
        #expect(r.costBasis == 225_000)
        #expect(r.unrealizedGain == 225_000)
        #expect(r.purchasePrice == Price(150))
        let lots = ledger.openLots(on: d("2024-01-05"))
        #expect(lots.count == 1 && lots[0].shares == Shares(15) && lots[0].cost == 225_000)
        #expect(lots[0].acquired == d("2024-01-02"))
        // The method shifts gains between realized and unrealized but never changes the total.
        #expect(report.breakdown.capitalGains == 300_000)
        #expect(report.breakdown.realizedGains == 75_000 && report.breakdown.unrealizedGains == 225_000)
        expectReconciled(report.breakdown)
        #expect(ledger.snapshot(on: d("2024-01-05")).position(stock)?.costBasis.minor == 225_000)
    }

    @Test func partialSalesSplitCostAndFeesWithoutLosingACent() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 40)])
        // 3 shares for 100.00 + 1.00 fees. Each share is then sold for 40.00.
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 3, amount: 101, fees: 1)
        f.add(.sell, "2024-01-03", account: account, depot: depot, security: stock, shares: 1, amount: 40)
        f.add(.sell, "2024-01-04", account: account, depot: depot, security: stock, shares: 1, amount: 40)
        f.add(.sell, "2024-01-05", account: account, depot: depot, security: stock, shares: 1, amount: 40)
        let ledger = f.ledger
        // 1st: cost 100.00 / 3 = 33.33, fees 0.33 → gain 40 − 33.66 = 6.34; left 66.67 + 0.67
        // 2nd: cost 66.67 / 2 = 33.34 (half up), fees 0.34 → gain 6.32; left 33.33 + 0.33
        // 3rd: the remainder 33.66 → gain 6.34. Total 19.00 = 120 − 101 exactly.
        let closed = ledger.closedLots()
        #expect(closed.map(\.gain) == [634, 632, 634])
        #expect(closed.map(\.cost) == [3_366, 3_368, 3_366])
        #expect(closed.map(\.fees) == [33, 34, 33])
        #expect(ledger.snapshot(on: d("2024-01-03")).position(stock)?.costBasis.minor == 6_734)
        #expect(ledger.snapshot(on: d("2024-01-04")).position(stock)?.costBasis.minor == 3_366)
        #expect(ledger.openLots(on: d("2024-01-05")).isEmpty)
        let r = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-05"))).securities[0]
        #expect(r.realizedGain == 1_900)
    }

    @Test func securityTransferKeepsCostAndAcquisitionDate() {
        var f = Fixture()
        let account = f.account("Cash")
        let depotA = f.depot("A"), depotB = f.depot("B")
        let stock = f.security("Stock", prices: [("2024-01-02", 100), ("2024-01-05", 120), ("2024-01-08", 130)])
        f.add(.deposit, "2024-01-02", account: account, amount: 1_010)
        f.add(.buy, "2024-01-02", account: account, depot: depotA, security: stock, shares: 10, amount: 1_010, fees: 10)
        f.add(.securityTransfer, "2024-01-05", depot: depotA, security: stock, shares: 4, amount: 480, counterDepot: depotB)
        f.add(.sell, "2024-01-08", account: account, depot: depotB, security: stock, shares: 4, amount: 520)
        let ledger = f.ledger

        // Lots move with cost 1 010 × 4 / 10 = 404 and the original purchase day.
        let lots = ledger.openLots(on: d("2024-01-05"))
        #expect(lots.count == 2)
        let a = lots.first { $0.depotID == depotA }!, b = lots.first { $0.depotID == depotB }!
        #expect(a.shares == Shares(6) && a.cost == 60_600 && a.fees == 600 && a.acquired == d("2024-01-02"))
        #expect(b.shares == Shares(4) && b.cost == 40_400 && b.fees == 400 && b.acquired == d("2024-01-02"))

        let snapshot = ledger.snapshot(on: d("2024-01-05"))
        let position = snapshot.position(stock)!
        #expect(position.shares == Shares(10) && position.value.minor == 120_000 && position.costBasis.minor == 101_000)
        #expect(position.holdings.map(\.value.minor).sorted() == [48_000, 72_000])
        #expect(position.holdings.map(\.costBasis.minor).sorted() == [40_400, 60_600])

        // Whole portfolio: a transfer is neither a flow nor a realization.
        let interval = DayInterval(start: d("2024-01-01"), end: d("2024-01-06"))
        let whole = ledger.breakdown(in: interval)
        #expect(whole.deposits == 101_000 && whole.fees == 1_000 && whole.realizedGains == 0)
        #expect(whole.unrealizedGains == 20_000 && whole.finalValue == 120_000 && whole.roundingResidue == 0)
        expectReconciled(whole)

        // Depot B alone: 4 shares arrive at market value 480 (inflow), no gain so far.
        let seriesB = ledger.valuation(in: interval, scope: .depot(depotB))
        #expect(seriesB.values == [0, 0, 0, 0, 48_000, 48_000])
        #expect(seriesB.inflows == [0, 0, 0, 0, 48_000, 0])
        #expect(seriesB.returns().total == 0)
        let bB = ledger.breakdown(in: interval, scope: .depot(depotB))
        #expect(bB.transfersIn == 48_000 && bB.capitalGains == 0 && bB.finalValue == 48_000 && bB.roundingResidue == 0)
        expectReconciled(bB)

        // Depot A alone: buys are inflows (1 010), the transfer is an outflow at market value (480).
        let seriesA = ledger.valuation(in: interval, scope: .depot(depotA))
        #expect(seriesA.values == [0, 100_000, 100_000, 100_000, 72_000, 72_000])
        #expect(seriesA.inflows == [0, 101_000, 0, 0, 0, 0])
        #expect(seriesA.outflows == [0, 0, 0, 0, 48_000, 0])
        // TTWROR: 1 000 / 1 010 × (720 + 480) / 1 000 = 1 200 / 1 010
        #expect(abs(seriesA.returns().total - (1_200.0 / 1_010 - 1)) < 1e-12)
        let bA = ledger.breakdown(in: interval, scope: .depot(depotA))
        // The 4 shares left at 480 against 400 → 80 realized within this scope; 6 × 20 = 120 unrealized.
        #expect(bA.transfersIn == 101_000 && bA.transfersOut == 48_000 && bA.fees == 1_000)
        #expect(bA.realizedGains == 8_000 && bA.unrealizedGains == 12_000)
        #expect(bA.finalValue == 72_000 && bA.roundingResidue == 0) // 1 010 − 480 + 80 + 120 − 10
        expectReconciled(bA)

        // Selling out of depot B later: the closed lot still knows its original purchase.
        let closed = ledger.closedLots()
        #expect(closed.count == 1 && closed[0].depotID == depotB)
        #expect(closed[0].opened == d("2024-01-02") && closed[0].closed == d("2024-01-08"))
        #expect(closed[0].cost == 40_400 && closed[0].proceeds == 52_000 && closed[0].gain == 11_600)
    }

    @Test func sellEverythingThenRebuy() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [
            ("2024-01-02", 100), ("2024-01-03", 120), ("2024-01-04", 115), ("2024-01-05", 110), ("2024-01-06", 121),
        ])
        f.add(.deposit, "2024-01-01", account: account, amount: 5_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        f.add(.sell, "2024-01-03", account: account, depot: depot, security: stock, shares: 10, amount: 1_200)
        f.add(.buy, "2024-01-05", account: account, depot: depot, security: stock, shares: 5, amount: 550)
        let ledger = f.ledger
        let interval = DayInterval(start: d("2023-12-31"), end: d("2024-01-06"))
        let report = ledger.performance(in: interval)
        // Cash: 5 000, 4 000, 5 200, 5 200, 4 650, 4 650; securities: 0, 1 000, 0, 0, 550, 605.
        #expect(report.valuation.values == [0, 500_000, 500_000, 520_000, 520_000, 520_000, 525_500])
        #expect(abs(report.ttwror - 0.051) < 1e-12)
        let r = report.security(stock)!
        // Position: 01-02 1 000 / 1 000; 01-03 (0 + 1 200) / 1 000 = 1.2; 01-04 not invested;
        // 01-05 550 / 550; 01-06 605 / 550 = 1.1 → 1.2 × 1.1 − 1 = 32 %
        #expect(abs(r.ttwror - 0.32) < 1e-12)
        #expect(r.realizedGain == 20_000 && r.costBasis == 55_000 && r.unrealizedGain == 5_500 && r.shares == Shares(5))
        #expect(r.inflows == 155_000 && r.outflows == 120_000)
        let lots = ledger.openLots(on: d("2024-01-06"))
        #expect(lots.count == 1 && lots[0].acquired == d("2024-01-05") && lots[0].cost == 55_000)
        #expect(ledger.snapshot(on: d("2024-01-04")).positions.isEmpty)
        #expect(report.breakdown.realizedGains == 20_000 && report.breakdown.unrealizedGains == 5_500)
        #expect(report.breakdown.roundingResidue == 0)
        expectReconciled(report.breakdown)
    }

    @Test func sameDayBuyAndSell() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.deposit, "2024-01-01", account: account, amount: 1_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000, minute: 600)
        f.add(.sell, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_010, minute: 900)
        let ledger = f.ledger
        let interval = DayInterval(start: d("2023-12-31"), end: d("2024-01-03"))
        let report = ledger.performance(in: interval)
        #expect(report.valuation.values == [0, 100_000, 101_000, 101_000])
        #expect(abs(report.ttwror - 0.01) < 1e-12)
        let r = report.security(stock)!
        // The position never shows up in an end-of-day value, yet: (0 + 1 010) / (0 + 1 000) − 1 = 1 %
        #expect(abs(r.ttwror - 0.01) < 1e-12)
        #expect(r.realizedGain == 1_000 && r.shares == .zero && r.marketValue == 0 && r.costBasis == 0)
        #expect(r.purchasePrice == nil && r.unrealizedGainFraction == nil)
        let scoped = ledger.valuation(in: interval, scope: .security(stock))
        #expect(scoped.values == [0, 0, 0, 0] && scoped.inflows[2] == 100_000 && scoped.outflows[2] == 101_000)
        #expect(abs(scoped.returns().total - 0.01) < 1e-12)
        #expect(ledger.snapshot(on: d("2024-01-02")).positions.isEmpty)
    }

    @Test func overselling() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100), ("2024-01-03", 90)])
        // Sell 5 shares that are not held (short), cover them a day later 10.00 cheaper.
        f.add(.sell, "2024-01-02", account: account, depot: depot, security: stock, shares: 5, amount: 500)
        f.add(.buy, "2024-01-03", account: account, depot: depot, security: stock, shares: 5, amount: 450)
        let ledger = f.ledger
        let short = ledger.snapshot(on: d("2024-01-02"))
        #expect(short.position(stock)?.shares == Shares(-5))
        #expect(short.position(stock)?.value.minor == -50_000)
        #expect(short.totalValue.minor == 0)
        #expect(short.diagnostics.contains(.shortPosition(securityID: stock, depotID: depot, day: d("2024-01-02"))))
        let report = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-04")))
        #expect(report.valuation.values == [0, 0, 5_000, 5_000])
        #expect(report.breakdown.realizedGains == 5_000 && report.breakdown.finalValue == 5_000)
        #expect(report.breakdown.roundingResidue == 0)
        expectReconciled(report.breakdown)
        let closed = ledger.closedLots()
        #expect(closed.count == 1 && closed[0].isShort && closed[0].cost == 45_000 && closed[0].proceeds == 50_000)
        #expect(ledger.openLots(on: d("2024-01-04")).isEmpty)
        #expect(report.returns.daily.allSatisfy { $0.isFinite })
    }
}

@Suite struct MultiCurrencyTests {
    /// Base EUR. EUR/USD = 1.10 from 01-01, 1.25 from 01-03 (USD → EUR: 0.9090…, then 0.8).
    ///     01-02  deposit 1 100.00 USD                     = 1 000.00 EUR
    ///     01-02  buy 10 @ 100 USD = 1 000.00 USD          =   909.09 EUR
    ///     01-03  quote 110 USD
    private func scenario(sell: Bool) -> (Ledger, account: UUID, stock: UUID) {
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-01", 1.10), ("2024-01-03", 1.25)])
        let account = f.account("USD cash", "USD"), depot = f.depot("Depot")
        let stock = f.security("US stock", "USD", prices: [("2024-01-02", 100), ("2024-01-03", 110)])
        f.add(.deposit, "2024-01-02", account: account, amount: 1_100, currency: "USD")
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000, currency: "USD")
        if sell {
            f.add(.sell, "2024-01-04", account: account, depot: depot, security: stock, shares: 10, amount: 1_100, currency: "USD")
        }
        return (f.ledger, account, stock)
    }

    @Test func snapshotInReportingCurrency() {
        let (ledger, account, stock) = scenario(sell: false)
        // 01-02: cash 100 USD / 1.10 = 90.91; position 1 000 USD / 1.10 = 909.09 → 1 000.00
        let day2 = ledger.snapshot(on: d("2024-01-02"))
        #expect(day2.cash(account)?.balance == Money(100, "USD"))
        #expect(day2.cash(account)?.value == Money(90.91, "EUR"))
        #expect(day2.position(stock)?.value == Money(909.09, "EUR"))
        #expect(day2.position(stock)?.valueInSecurityCurrency == Money(1_000, "USD"))
        #expect(day2.position(stock)?.costBasis == Money(909.09, "EUR")) // cost at the purchase-day rate
        #expect(day2.totalValue == Money(1_000, "EUR"))
        // 01-03: 1 100 USD × 0.8 = 880.00; 100 USD × 0.8 = 80.00 → 960.00
        let day3 = ledger.snapshot(on: d("2024-01-03"))
        #expect(day3.position(stock)?.value == Money(880, "EUR"))
        #expect(day3.position(stock)?.costBasis == Money(909.09, "EUR"))
        #expect(day3.cashValue == Money(80, "EUR"))
        #expect(day3.totalValue == Money(960, "EUR"))
        // Reporting in USD instead: no conversion at all.
        let usd = Ledger(ledgerFile(sell: false), reportingCurrency: "USD").snapshot(on: d("2024-01-03"))
        #expect(usd.totalValue == Money(1_200, "USD"))
    }

    private func ledgerFile(sell: Bool) -> PortfolioFile {
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-01", 1.10), ("2024-01-03", 1.25)])
        let account = f.account("USD cash", "USD"), depot = f.depot("Depot")
        let stock = f.security("US stock", "USD", prices: [("2024-01-02", 100), ("2024-01-03", 110)])
        f.add(.deposit, "2024-01-02", account: account, amount: 1_100, currency: "USD")
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000, currency: "USD")
        return f.file
    }

    @Test func unrealizedCurrencyGains() {
        let (ledger, _, stock) = scenario(sell: false)
        let report = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-03")))
        #expect(report.valuation.values == [0, 100_000, 96_000])
        #expect(report.valuation.inflows == [0, 100_000, 0])
        #expect(abs(report.ttwror - (-0.04)) < 1e-12)
        let b = report.breakdown
        #expect(b.deposits == 100_000)
        // Securities: 880.00 − 909.09 = −29.09, of which currency: 1 000 USD × 0.8 − 909.09 = −109.09
        // (the price gain of 100 USD × 0.8 = +80.00 makes up the rest).
        #expect(b.unrealizedGains == -2_909)
        #expect(b.unrealizedCurrencyGains == -10_909)
        // Cash: 100 USD were worth 90.91 when they arrived (1 000.00 − 909.09) and are worth 80.00 now.
        #expect(b.cashCurrencyGains == -1_091)
        #expect(b.currencyGains == -12_000)
        #expect(b.finalValue == 96_000 && b.roundingResidue == 0) // 1 000 − 29.09 − 10.91
        expectReconciled(b)
        let r = report.security(stock)!
        #expect(r.costBasis == 90_909 && r.unrealizedGain == -2_909 && r.periodCurrencyGain == -10_909)
        #expect(r.purchasePrice == Price(90.909)) // EUR per share
    }

    @Test func realizedCurrencyGains() {
        let (ledger, _, stock) = scenario(sell: true)
        // 01-04: sell 10 @ 110 USD = 1 100 USD × 0.8 = 880.00 EUR; cash 1 200 USD = 960.00 EUR
        let report = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-04")))
        let b = report.breakdown
        #expect(b.realizedGains == -2_909) // 880.00 − 909.09
        #expect(b.realizedCurrencyGains == -10_909) // −29.09 − (100 USD × 0.8)
        #expect(b.unrealizedGains == 0 && b.unrealizedCurrencyGains == 0)
        // Cash: 960.00 − (1 000.00 − 909.09 + 880.00) = −10.91
        #expect(b.cashCurrencyGains == -1_091)
        #expect(b.finalValue == 96_000 && b.roundingResidue == 0)
        expectReconciled(b)
        #expect(report.security(stock)?.realizedGain == -2_909)
    }

    @Test func foreignSecurityBoughtFromBaseCurrencyAccount() {
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-01", 1.10), ("2024-01-03", 1.25)])
        let account = f.account("EUR cash"), depot = f.depot("Depot")
        let stock = f.security("US stock", "USD", prices: [("2024-01-02", 100), ("2024-01-03", 110)])
        f.add(.deposit, "2024-01-02", account: account, amount: 1_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 909.09,
              securityGross: Money(1_000, "USD"))
        let b = f.ledger.breakdown(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-03")))
        // Cash 90.91 EUR + 1 100 USD × 0.8 = 970.91; unrealized −29.09 of which currency −109.09.
        #expect(b.finalValue == 97_091)
        #expect(b.unrealizedGains == -2_909 && b.unrealizedCurrencyGains == -10_909 && b.cashCurrencyGains == 0)
        #expect(b.roundingResidue == 0)
        expectReconciled(b)
    }

    @Test func crossCurrencyCashTransfer() {
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-01", 1.25)])
        let eur = f.account("EUR"), usd = f.account("USD", "USD")
        f.add(.deposit, "2024-01-02", account: eur, amount: 110)
        // The bank converts 110.00 EUR into 120.00 USD (fair would be 137.50): worth 96.00 EUR.
        f.add(.cashTransfer, "2024-01-03", account: eur, amount: 110, counterAccount: usd, counterAmount: Money(120, "USD"))
        let ledger = f.ledger
        let interval = DayInterval(start: d("2024-01-01"), end: d("2024-01-04"))
        let series = ledger.valuation(in: interval)
        #expect(series.values == [0, 11_000, 9_600, 9_600])
        #expect(series.totalInflows == 11_000 && series.totalOutflows == 0) // the transfer is internal
        let b = ledger.breakdown(in: interval)
        #expect(b.cashCurrencyGains == -1_400 && b.finalValue == 9_600 && b.roundingResidue == 0)
        expectReconciled(b)
        // Seen from the USD account alone, 110.00 EUR arrive and 14.00 are lost to the spread.
        let target = ledger.breakdown(in: interval, scope: .account(usd))
        #expect(target.transfersIn == 11_000 && target.cashCurrencyGains == -1_400 && target.finalValue == 9_600)
        expectReconciled(target)
        let source = ledger.breakdown(in: interval, scope: .account(eur))
        #expect(source.deposits == 11_000 && source.transfersOut == 11_000 && source.finalValue == 0)
        expectReconciled(source)
    }

    @Test func missingExchangeRateExcludesAndFlags() {
        var f = Fixture()
        let eur = f.account("EUR"), jpy = f.account("JPY", "JPY")
        f.add(.deposit, "2024-01-02", account: eur, amount: 100)
        f.add(.deposit, "2024-01-02", account: jpy, amount: 5_000, currency: "JPY")
        let ledger = f.ledger
        let missing = EngineDiagnostic.missingExchangeRate(from: "JPY", to: "EUR")
        #expect(ledger.diagnostics.contains(missing))
        let snapshot = ledger.snapshot(on: d("2024-01-03"))
        #expect(snapshot.totalValue == Money(100, "EUR"))
        #expect(snapshot.cash(jpy)?.balance == Money(5_000, "JPY"))
        #expect(snapshot.cash(jpy)?.isValued == false && snapshot.cash(jpy)?.value.minor == 0)
        #expect(snapshot.diagnostics.contains(missing))
        let report = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-03")))
        #expect(report.valuation.values == [0, 10_000, 10_000])
        #expect(report.diagnostics.contains(missing))
        #expect(report.breakdown.deposits == 10_000 && report.breakdown.roundingResidue == 0)
        expectReconciled(report.breakdown)
    }
}

@Suite struct ScopeTests {
    /// deposit 1 000; buy 10 @ 100; dividend 60 gross − 10 tax = 50; fee 5 booked on the security.
    private func scenario() -> (Ledger, account: UUID, depot: UUID, stock: UUID) {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.deposit, "2024-01-01", account: account, amount: 1_000)
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        f.add(.dividend, "2024-01-03", account: account, depot: depot, security: stock, shares: 10, amount: 50, taxes: 10)
        f.add(.fee, "2024-01-04", account: account, security: stock, amount: 5)
        return (f.ledger, account, depot, stock)
    }
    let interval = DayInterval(start: d("2023-12-31"), end: d("2024-01-05"))

    @Test func wholePortfolio() {
        let (ledger, _, _, _) = scenario()
        let report = ledger.performance(in: interval)
        #expect(report.valuation.values == [0, 100_000, 100_000, 105_000, 104_500, 104_500])
        #expect(report.valuation.inflows == [0, 100_000, 0, 0, 0, 0]) // dividends and fees are not flows
        #expect(abs(report.ttwror - 0.045) < 1e-12)
        let b = report.breakdown
        #expect(b.deposits == 100_000 && b.dividends == 6_000 && b.taxes == 1_000 && b.fees == 500)
        #expect(b.finalValue == 104_500 && b.roundingResidue == 0)
        expectReconciled(b)
    }

    @Test func singleSecurity() {
        let (ledger, _, depot, stock) = scenario()
        let series = ledger.valuation(in: interval, scope: .security(stock))
        #expect(series.values == [0, 0, 100_000, 100_000, 100_000, 100_000])
        #expect(series.cashValues.allSatisfy { $0 == 0 })
        // The buy is an inflow, the dividend an outflow, the fee an inflow that buys nothing.
        #expect(series.inflows == [0, 0, 100_000, 0, 500, 0])
        #expect(series.outflows == [0, 0, 0, 5_000, 0, 0])
        // 01-03: (1 000 + 50) / 1 000 = 1.05 (the dividend is return); 01-04: 1 000 / (1 000 + 5)
        let expected = 1.05 * 1_000 / 1_005 - 1
        #expect(abs(series.returns().total - expected) < 1e-12)

        let b = ledger.breakdown(in: interval, scope: .security(stock))
        #expect(b.transfersIn == 100_500 && b.transfersOut == 5_000)
        #expect(b.dividends == 6_000 && b.taxes == 1_000 && b.fees == 500)
        #expect(b.finalValue == 100_000 && b.roundingResidue == 0) // 1 005 − 50 + 60 − 10 − 5
        expectReconciled(b)

        // The per-security record of the portfolio report is the same view.
        let r = ledger.performance(in: interval).security(stock)!
        #expect(abs(r.ttwror - expected) < 1e-12)
        #expect(r.dividends == 6_000 && r.dividendCount == 1 && r.lastDividend == 6_000)
        #expect(r.lastDividendDay == d("2024-01-03"))
        #expect(abs(r.dividendYieldOnCost! - 0.06) < 1e-12)
        #expect(r.fees == 500 && r.taxes == 1_000 && r.inflows == 100_500 && r.outflows == 5_000)
        #expect(r.absolutePerformance == 4_500) // 60 − 10 − 5
        #expect(r.irr! > 0)

        // Restricting to the depot gives the same; another depot gives nothing.
        let inDepot = ledger.valuation(in: interval, scope: .security(stock, depot: depot))
        #expect(inDepot.values == series.values)
        let elsewhere = ledger.valuation(in: interval, scope: .security(stock, depot: UUID()))
        #expect(elsewhere.values.allSatisfy { $0 == 0 } && elsewhere.totalInflows == 0)
    }

    @Test func singleAccount() {
        let (ledger, account, _, _) = scenario()
        let series = ledger.valuation(in: interval, scope: .account(account))
        #expect(series.values == [0, 100_000, 0, 5_000, 4_500, 4_500])
        #expect(series.inflows == [0, 100_000, 0, 5_000, 0, 0]) // deposit; dividend arriving from the depot
        #expect(series.outflows == [0, 0, 100_000, 0, 500, 0]) // purchase; fee paid for the security
        let b = ledger.breakdown(in: interval, scope: .account(account))
        #expect(b.deposits == 100_000 && b.transfersIn == 5_000 && b.transfersOut == 100_500)
        #expect(b.dividends == 0 && b.fees == 0 && b.finalValue == 4_500 && b.roundingResidue == 0)
        expectReconciled(b)
    }

    @Test func depotPlusAccountEqualsPortfolio() {
        let (ledger, account, depot, _) = scenario()
        let whole = ledger.valuation(in: interval)
        let subset = ledger.valuation(in: interval, scope: .depot(depot, account: account))
        #expect(subset.values == whole.values && subset.inflows == whole.inflows && subset.outflows == whole.outflows)
        #expect(ledger.resolve(.portfolio).isWholePortfolio)
        #expect(!ledger.resolve(.depot(depot, account: account)).isWholePortfolio)
    }

    @Test func weightedScope() {
        let (ledger, account, _, stock) = scenario()
        // 50 % of the security and 25 % of the account.
        let scope = Scope.weighted(securities: [stock: 5_000], accounts: [account: 2_500])
        let snapshot = ledger.snapshot(on: d("2024-01-05"), scope: scope)
        let position = snapshot.position(stock)!
        #expect(position.weight == 5_000 && position.shares == Shares(10)) // shares are not scaled
        #expect(position.value.minor == 50_000 && position.costBasis.minor == 50_000)
        #expect(position.purchasePrice == Price(100))
        #expect(snapshot.cash(account)?.balance.minor == 4_500 && snapshot.cash(account)?.value.minor == 1_125)
        #expect(snapshot.totalValue.minor == 51_125)

        let b = ledger.breakdown(in: interval, scope: scope)
        #expect(b.deposits == 25_000) // 25 % of 1 000
        // Buy: 50 % × 1 000 enters the position, 25 % × 1 000 leaves the account → +250 net.
        // Fee: 50 % × 5 enters the position, 25 % × 5 leaves the account → +1.25 net.
        #expect(b.transfersIn == 25_125)
        // Dividend: 50 % × 50 leaves the position, 25 % × 50 reaches the account → −12.50 net.
        #expect(b.transfersOut == 1_250)
        #expect(b.dividends == 3_000 && b.taxes == 500 && b.fees == 250)
        // 250 + 251.25 − 12.50 + 30 − 5 − 2.50 = 511.25
        #expect(b.finalValue == 51_125 && b.roundingResidue == 0)
        expectReconciled(b)
        let series = ledger.valuation(in: interval, scope: scope)
        #expect(series.finalValue == 51_125)
        #expect(series.totalInflows == b.inflows && series.totalOutflows == b.outflows)

        // Scope is Codable (it is stored in dashboard widgets).
        let data = try! JSONEncoder().encode([scope, .portfolio, .security(stock), .depot(UUID())])
        #expect(try! JSONDecoder().decode([Scope].self, from: data).first == scope)
    }
}
