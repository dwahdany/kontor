import Foundation
import KontorEngine
import KontorModel
import Testing

/// Hand-computed single-currency scenario used by several tests:
///
///     2024-01-01  deposit 10 000.00
///     2024-01-02  buy 50 @ 100.00 + 10.00 fees            → pays 5 010.00
///     2024-01-04  sell 20 @ 121.00 − 5.00 fees − 15.00 tax → receives 2 400.00
///     quotes: 01-02 100, 01-03 110, 01-04 121
private struct BasicScenario {
    var fixture = Fixture()
    let account: UUID, depot: UUID, stock: UUID
    let interval = DayInterval(start: d("2023-12-31"), end: d("2024-01-05"))

    init(costMethod: CostMethod = .fifo) {
        fixture.file.settings.costMethod = costMethod
        account = fixture.account("Cash")
        depot = fixture.depot("Depot")
        stock = fixture.security("Stock", prices: [("2024-01-02", 100), ("2024-01-03", 110), ("2024-01-04", 121)])
        fixture.add(.deposit, "2024-01-01", account: account, amount: 10_000)
        fixture.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 50, amount: 5_010, fees: 10)
        fixture.add(.sell, "2024-01-04", account: account, depot: depot, security: stock, shares: 20, amount: 2_400, fees: 5, taxes: 15)
    }
    var ledger: Ledger { fixture.ledger }
}

@Suite struct SnapshotTests {
    @Test func positionsCashAndTotals() {
        let s = BasicScenario()
        let ledger = s.ledger

        // Before anything happened.
        #expect(ledger.snapshot(on: d("2023-12-31")).totalValue.minor == 0)

        // 01-02: cash 10 000 − 5 010 = 4 990; position 50 × 100 = 5 000; total 9 990.
        let day2 = ledger.snapshot(on: d("2024-01-02"))
        #expect(day2.cash(s.account)?.balance == Money(4_990, "EUR"))
        #expect(day2.cashValue == Money(4_990, "EUR"))
        #expect(day2.securitiesValue == Money(5_000, "EUR"))
        #expect(day2.totalValue == Money(9_990, "EUR"))
        let p2 = day2.position(s.stock)!
        #expect(p2.shares == Shares(50))
        #expect(p2.price == Price(100) && p2.priceDay == d("2024-01-02"))
        #expect(p2.costBasis == Money(5_010, "EUR")) // fees are part of the cost basis
        #expect(p2.unrealizedGain == Money(-10, "EUR"))
        #expect(p2.purchasePrice == Price(100.20)) // 5 010 / 50
        #expect(p2.holdings.count == 1 && p2.holdings[0].depotID == s.depot && p2.holdings[0].value == p2.value)

        // 01-03: 50 × 110 = 5 500 → total 10 490.
        #expect(ledger.snapshot(on: d("2024-01-03")).totalValue == Money(10_490, "EUR"))

        // 01-04: cash 4 990 + 2 400 = 7 390; position 30 × 121 = 3 630; total 11 020.
        // Remaining cost basis: 5 010 × 30 / 50 = 3 006.
        let day4 = ledger.snapshot(on: d("2024-01-04"))
        #expect(day4.totalValue == Money(11_020, "EUR"))
        #expect(day4.position(s.stock)?.costBasis == Money(3_006, "EUR"))
        #expect(day4.position(s.stock)?.unrealizedGain == Money(624, "EUR"))
        #expect(day4.costBasis == Money(3_006, "EUR"))
        #expect(abs(day4.share(of: day4.position(s.stock)!)! - 3_630.0 / 11_020.0) < 1e-12)

        // Weekend / later: the last known price (01-04) keeps being used.
        let later = ledger.snapshot(on: d("2024-03-01"))
        #expect(later.totalValue == Money(11_020, "EUR"))
        #expect(later.position(s.stock)?.priceDay == d("2024-01-04"))
    }

    @Test func zeroPositionsAreOmitted() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100)])
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        f.add(.sell, "2024-01-03", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        let snapshot = f.ledger.snapshot(on: d("2024-01-03"))
        #expect(snapshot.positions.isEmpty)
        #expect(snapshot.cash.count == 1) // accounts are always listed
        #expect(snapshot.totalValue.minor == 0)
    }
}

@Suite struct ValuationSeriesTests {
    @Test func dailyValuesAndFlows() {
        let s = BasicScenario()
        let series = s.ledger.valuation(in: s.interval)
        // Index:           12-31  01-01    01-02    01-03    01-04    01-05
        #expect(series.values == [0, 1_000_000, 999_000, 1_049_000, 1_102_000, 1_102_000])
        #expect(series.cashValues == [0, 1_000_000, 499_000, 499_000, 739_000, 739_000])
        #expect(series.inflows == [0, 1_000_000, 0, 0, 0, 0]) // only the deposit is external
        #expect(series.outflows == [0, 0, 0, 0, 0, 0])
        #expect(series.count == 6)
        #expect(series.day(at: 2) == d("2024-01-02") && series.index(of: d("2024-01-04")) == 4)
        #expect(series.index(of: d("2024-01-06")) == nil)
        #expect(series.absolutePerformance == 102_000) // 11 020 − 0 − 10 000
        #expect(series.securitiesValue(at: 4) == 363_000)
        #expect(series.investedCapital() == [0, 1_000_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000])
    }

    @Test func transactionsOnTheStartDayBelongToTheBaseline() {
        let s = BasicScenario()
        // Baseline at the end of 01-02 (value 9 990): the deposit and the buy are not flows.
        let series = s.ledger.valuation(in: DayInterval(start: d("2024-01-02"), end: d("2024-01-04")))
        #expect(series.values == [999_000, 1_049_000, 1_102_000])
        #expect(series.totalInflows == 0 && series.totalOutflows == 0)
        #expect(series.investedCapital() == [999_000, 999_000, 999_000])
        #expect(series.investedCapital(includingInitialValue: false) == [0, 0, 0])
        // Flow-free interval: TTWROR = 11 020 / 9 990 − 1
        #expect(abs(series.returns().total - (11_020.0 / 9_990.0 - 1)) < 1e-12)
    }

    @Test func negativeCashAndUnfundedPurchases() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 100), ("2024-01-03", 110)])
        // No deposit: the account goes to −1 000.00 while the position is worth 1 000.00.
        f.add(.buy, "2024-01-02", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        let ledger = f.ledger
        let series = ledger.valuation(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-03")))
        #expect(series.values == [0, 0, 10_000])
        #expect(series.cashValues == [0, -100_000, -100_000])
        let returns = series.returns()
        // Nothing was ever invested from outside: every denominator is 0 → daily return 0, no NaN.
        #expect(returns.daily == [0, 0, 0])
        #expect(returns.total == 0)
        #expect(series.irr() == nil)
        #expect(ledger.snapshot(on: d("2024-01-02"), scope: .account(account)).totalValue.minor == -100_000)
        // The account alone: −1 000 left the scope on 01-02 (outflow), value −1 000.
        let cashOnly = ledger.valuation(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-03")), scope: .account(account))
        #expect(cashOnly.values == [0, -100_000, -100_000])
        #expect(cashOnly.outflows == [0, 100_000, 0])
        #expect(cashOnly.returns().daily.allSatisfy { $0.isFinite })
    }
}

@Suite struct ReturnTests {
    @Test func timeWeightedReturn() {
        let s = BasicScenario()
        let returns = s.ledger.valuation(in: s.interval).returns()
        // r(01-01) = 10 000 / (0 + 10 000) − 1 = 0        (inflow at the start of the day)
        // r(01-02) =  9 990 / 10 000 − 1 = −0.1 %          (the fee)
        // r(01-03) = 10 490 /  9 990 − 1
        // r(01-04) = 11 020 / 10 490 − 1
        let expected = [0, 0, 9_990.0 / 10_000 - 1, 10_490.0 / 9_990 - 1, 11_020.0 / 10_490 - 1, 0]
        for (a, b) in zip(returns.daily, expected) { #expect(abs(a - b) < 1e-14) }
        #expect(abs(returns.total - 0.102) < 1e-12) // telescopes to 11 020 / 10 000 − 1
        #expect(abs(returns.cumulative[3] - 0.049) < 1e-12)
        // Annualized over 5 days: 1.102^(365/5) − 1
        #expect(abs(returns.annualized! - (pow(1.102, 73) - 1)) / pow(1.102, 73) < 1e-12)
    }

    @Test func flowsDoNotDistortTheReturn() {
        var f = Fixture()
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-01", 100), ("2024-01-03", 110), ("2024-01-05", 99)])
        f.add(.deposit, "2024-01-01", account: account, amount: 1_000)
        f.add(.buy, "2024-01-01", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        // 01-03: price +10 % (value 1 100). Then 9 900 more are deposited and invested at 110.
        f.add(.deposit, "2024-01-04", account: account, amount: 9_900)
        f.add(.buy, "2024-01-04", account: account, depot: depot, security: stock, shares: 90, amount: 9_900)
        // 01-05: price −10 % (100 shares × 99 = 9 900). 01-06: withdraw everything after selling.
        f.add(.sell, "2024-01-06", account: account, depot: depot, security: stock, shares: 100, amount: 9_900)
        f.add(.withdrawal, "2024-01-06", account: account, amount: 9_900)
        let series = f.ledger.valuation(in: DayInterval(start: d("2023-12-31"), end: d("2024-01-07")))
        #expect(series.values == [0, 100_000, 100_000, 110_000, 1_100_000, 990_000, 0, 0])
        #expect(series.inflows == [0, 100_000, 0, 0, 990_000, 0, 0, 0])
        #expect(series.outflows == [0, 0, 0, 0, 0, 0, 990_000, 0])
        let returns = series.returns()
        // Daily: 0, 0, +10 %, 11 000 / (1 100 + 9 900) − 1 = 0, −10 %, (0 + 9 900) / 9 900 − 1 = 0, 0
        // TTWROR = 1.1 × 0.9 − 1 = −1 % although the investor lost 1 000 on 10 900 paid in.
        #expect(abs(returns.total - (-0.01)) < 1e-12)
        #expect(abs(returns.daily[6]) < 1e-15) // full liquidation: no NaN / −100 %
        #expect(returns.daily[7] == 0) // empty portfolio afterwards
        #expect(series.absolutePerformance == -100_000)
        // Money-weighted: −1 000 (day 1), −9 900 (day 4), +9 900 (day 6) → strongly negative.
        let irr = series.irr()!
        let npv = -1_000 * pow(1 + irr, -1.0 / 365) - 9_900 * pow(1 + irr, -4.0 / 365) + 9_900 * pow(1 + irr, -6.0 / 365)
        #expect(abs(npv) < 1e-6)
        #expect(irr < -0.99)
    }

    @Test func dailyReturnConvention() {
        #expect(Returns.dailyReturn(previous: 1_000, value: 1_100, inflow: 0, outflow: 0) == 1_100.0 / 1_000 - 1)
        // Inflow at the start of the day: (1 650) / (1 000 + 500) − 1 = 10 %
        #expect(abs(Returns.dailyReturn(previous: 1_000, value: 1_650, inflow: 500, outflow: 0) - 0.1) < 1e-15)
        // Outflow at the end of the day: (600 + 500) / 1 000 − 1 = 10 %
        #expect(abs(Returns.dailyReturn(previous: 1_000, value: 600, inflow: 0, outflow: 500) - 0.1) < 1e-15)
        // Same-day round trip from nothing: (0 + 1 010) / (0 + 1 000) − 1 = 1 %
        #expect(abs(Returns.dailyReturn(previous: 0, value: 0, inflow: 1_000, outflow: 1_010) - 0.01) < 1e-15)
        #expect(Returns.dailyReturn(previous: 0, value: 0, inflow: 0, outflow: 0) == 0)
        #expect(Returns.dailyReturn(previous: -500, value: -400, inflow: 0, outflow: 0) == 0) // negative base
        // Negative base topped up to barely positive: still undefined → 0, not −100 %.
        #expect(Returns.dailyReturn(previous: -4_900, value: -50, inflow: 5_000, outflow: 0) == 0)
        #expect(Returns.dailyReturn(previous: 100, value: -50, inflow: 0, outflow: 0) == -1) // capped
    }

    @Test func annualization() {
        #expect(abs(Returns.annualize(total: 0.21, days: 730)! - 0.1) < 1e-12) // 1.21^(1/2)
        #expect(abs(Returns.annualize(total: 0.1, days: 365)! - 0.1) < 1e-12)
        #expect(Returns.annualize(total: 0.1, days: 0) == nil)
        #expect(Returns.annualize(total: -1, days: 100) == -1)
    }

    @Test func internalRateOfReturn() {
        typealias CF = Returns.CashFlow
        // −1 000 today, +1 100 in a year → 10 %
        #expect(abs(Returns.irr([CF(day: 0, amount: -1_000), CF(day: 365, amount: 1_100)])! - 0.1) < 1e-10)
        // −1 000 now, −1 000 after one year, +2 310 after two: 1 000·1.1² + 1 000·1.1 = 2 310 → 10 %
        let twoStep = [CF(day: 0, amount: -1_000), CF(day: 365, amount: -1_000), CF(day: 730, amount: 2_310)]
        #expect(abs(Returns.irr(twoStep)! - 0.1) < 1e-10)
        // Loss: −1 000 → 500 after two years: (0.5)^(1/2) − 1
        #expect(abs(Returns.irr([CF(day: 10, amount: -1_000), CF(day: 740, amount: 500)])! - (0.5.squareRoot() - 1)) < 1e-10)
        // Break-even.
        #expect(Returns.irr([CF(day: 0, amount: -1_000), CF(day: 200, amount: 1_000)]) == 0)
        // Order of flows does not matter; borrowing-type flows (receive first) work too.
        #expect(abs(Returns.irr([CF(day: 365, amount: -1_100), CF(day: 0, amount: 1_000)])! - 0.1) < 1e-10)
        // Absurd: ×1000 in 20 days would be a yearly factor of 10^54.75 — outside the solver range → nil.
        #expect(Returns.irr([CF(day: 0, amount: -100), CF(day: 20, amount: 100_000)]) == nil)
        // ×2 in 60 days: 2^(365/60) − 1
        #expect(abs(Returns.irr([CF(day: 0, amount: -100), CF(day: 60, amount: 200)])! / (pow(2, 365.0 / 60) - 1) - 1) < 1e-9)
        // Near-total loss within the solvable range: 100 → 1 in two years = −90 % p.a.
        #expect(abs(Returns.irr([CF(day: 0, amount: -100), CF(day: 730, amount: 1)])! - (-0.9)) < 1e-10)

        // Undefined cases → nil instead of garbage.
        #expect(Returns.irr([]) == nil)
        #expect(Returns.irr([CF(day: 0, amount: -1_000)]) == nil)
        #expect(Returns.irr([CF(day: 0, amount: -1_000), CF(day: 365, amount: -50)]) == nil) // no sign change
        #expect(Returns.irr([CF(day: 0, amount: 1_000), CF(day: 365, amount: 50)]) == nil)
        #expect(Returns.irr([CF(day: 5, amount: -1_000), CF(day: 5, amount: 1_200)]) == nil) // no time span
        #expect(Returns.irr([CF(day: 0, amount: -1_000), CF(day: 365, amount: 0)]) == nil)
        #expect(Returns.irr([CF(day: 0, amount: -1_000), CF(day: 365, amount: .nan)]) == nil)

        // Many flows (savings plan): 120 monthly payments of 100, final value 15 000.
        var plan = (0..<120).map { CF(day: $0 * 30, amount: -100) }
        plan.append(CF(day: 3_600, amount: 15_000))
        let r = Returns.irr(plan)!
        let npv = plan.reduce(0.0) { $0 + $1.amount * pow(1 + r, -Double($1.day) / 365) }
        #expect(abs(npv) < 1e-6 && r > 0.04 && r < 0.05)
    }

    @Test func portfolioIRR() {
        let s = BasicScenario()
        // −10 000 on 01-01, +11 020 on 01-05 (4 days) → 1.102^(365/4) − 1
        let irr = s.ledger.valuation(in: s.interval).irr()!
        let expected = pow(1.102, 365.0 / 4) - 1
        #expect(abs(irr / expected - 1) < 1e-9)
    }
}
