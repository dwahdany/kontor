import Foundation
import KontorEngine
import KontorModel
import Testing

/// Randomized invariants over seeded ledgers that use every transaction kind.
@Suite struct RandomizedInvariantTests {
    static let seeds: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8]

    private func options(_ seed: UInt64) -> RandomPortfolioOptions {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0 // odd seeds: EUR only (everything must reconcile to the cent)
        o.allowShort = seed % 4 >= 2
        o.costMethod = seed % 3 == 0 ? .average : .fifo
        return o
    }

    private func scopes(_ file: PortfolioFile) -> [Scope] {
        var weights: [UUID: Int] = [:]
        for (i, s) in file.securities.enumerated() where i % 2 == 0 { weights[s.id] = [10_000, 3_333, 5_000, 1][i / 2 % 4] }
        return [
            .portfolio,
            .depot(file.depots[0].id, account: file.accounts[0].id),
            .subset(depots: [file.depots[1].id], accounts: []),
            .account(file.accounts.last!.id),
            .security(file.securities[0].id),
            .security(file.securities[2].id, depot: file.depots[1].id),
            .weighted(securities: weights, accounts: [file.accounts[0].id: 2_500, file.accounts[1].id: 10_000]),
        ]
    }

    private func intervals(_ o: RandomPortfolioOptions) -> [DayInterval] {
        [
            DayInterval(start: o.start.advanced(by: -1), end: o.start.advanced(by: o.days - 1)), // everything
            DayInterval(start: o.start.advanced(by: 211), end: o.start.advanced(by: 577)), // mid-history
            DayInterval(start: o.start.advanced(by: 400), end: o.start.advanced(by: 401)), // a single day
        ]
    }

    @Test(arguments: seeds)
    func breakdownReconcilesWithValuation(seed: UInt64) {
        let o = options(seed)
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        for scope in scopes(file) {
            let exact = !o.multiCurrency && {
                if case .weighted = scope { return false }
                return true
            }()
            for interval in intervals(o) {
                let report = ledger.performance(in: interval, scope: scope)
                let b = report.breakdown
                expectReconciled(b)
                // The breakdown is computed by an independent pass; it must agree with the daily series.
                #expect(b.initialValue == report.valuation.initialValue)
                #expect(b.finalValue == report.valuation.finalValue)
                #expect(b.inflows == report.valuation.totalInflows)
                #expect(b.outflows == report.valuation.totalOutflows)
                #expect(b.deposits >= 0 && b.withdrawals >= 0 && b.transfersIn >= 0 && b.transfersOut >= 0)
                // The residue is rounding only: zero without conversions/weights, tiny otherwise.
                let transactions = ledger.transactions.filter { interval.contains($0.date) }.count
                if exact {
                    #expect(b.roundingResidue == 0, "seed \(seed) scope \(scope) \(interval)")
                    #expect(b.cashCurrencyGains == 0 && b.realizedCurrencyGains == 0 && b.unrealizedCurrencyGains == 0)
                } else {
                    #expect(abs(b.roundingResidue) <= Int64(2 * transactions + 2 * file.securities.count + 8),
                            "seed \(seed) scope \(scope) \(interval): residue \(b.roundingResidue)")
                }
                // Per security: the gain not explained by flows equals its components.
                for r in report.securities {
                    let components = r.periodRealizedGain + r.periodUnrealizedGain + r.dividends - r.fees - r.taxes
                    if exact {
                        #expect(r.absolutePerformance == components, "seed \(seed) security \(r.securityID)")
                    } else {
                        #expect(abs(r.absolutePerformance - components) <= Int64(2 * transactions + 8))
                    }
                    #expect(r.ttwror.isFinite && r.ttwror >= -1)
                    #expect(r.irr?.isFinite ?? true)
                    #expect(r.unrealizedGain == r.marketValue - r.costBasis)
                }
                #expect(report.returns.daily.allSatisfy { $0.isFinite && $0 >= -1 })
                #expect(report.irr?.isFinite ?? true)
                // Securities of the breakdown and the records tell the same story.
                #expect(report.securities.reduce(0) { $0 + $1.dividends } == b.dividends)
                #expect(report.securities.reduce(0) { $0 + $1.periodRealizedGain } == b.realizedGains)
                #expect(report.securities.reduce(0) { $0 + $1.periodUnrealizedGain } == b.unrealizedGains)
                #expect(report.securities.reduce(0) { $0 + $1.marketValue } == report.valuation.securitiesValue(at: report.valuation.count - 1))
            }
        }
    }

    @Test(arguments: seeds)
    func valuationSeriesEqualsIndependentSnapshots(seed: UInt64) {
        let o = options(seed)
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let interval = DayInterval(start: o.start.advanced(by: 100), end: o.start.advanced(by: o.days - 1))
        for scope in scopes(file) {
            let series = ledger.valuation(in: interval, scope: scope)
            var i = 0
            while i < series.count {
                let snapshot = ledger.snapshot(on: series.day(at: i), scope: scope)
                #expect(series.values[i] == snapshot.totalValue.minor, "seed \(seed) scope \(scope) day \(series.day(at: i))")
                #expect(series.cashValues[i] == snapshot.cashValue.minor)
                // Sum of position values + cash == total, at every level.
                let positions = snapshot.positions.reduce(0) { $0 + $1.value.minor }
                let cash = snapshot.cash.reduce(0) { $0 + $1.value.minor }
                #expect(positions + cash == snapshot.totalValue.minor)
                #expect(positions == snapshot.securitiesValue.minor && cash == snapshot.cashValue.minor)
                for p in snapshot.positions {
                    #expect(p.holdings.reduce(0) { $0 + $1.value.minor } == p.value.minor)
                    #expect(p.holdings.reduce(0) { $0 + $1.costBasis.minor } == p.costBasis.minor)
                    #expect(p.holdings.reduce(Int64(0)) { $0 + $1.shares.raw } == p.shares.raw)
                }
                #expect(snapshot.positions.reduce(0) { $0 + $1.costBasis.minor } == snapshot.costBasis.minor)
                i += 37
            }
            // The last day too.
            #expect(series.finalValue == ledger.snapshot(on: interval.end, scope: scope).totalValue.minor)
        }
    }

    @Test(arguments: seeds)
    func partialScopesAddUpToThePortfolio(seed: UInt64) {
        let o = options(seed)
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let interval = DayInterval(start: o.start.advanced(by: 50), end: o.start.advanced(by: o.days - 1))
        let whole = ledger.valuation(in: interval)
        var parts = file.depots.map { ledger.valuation(in: interval, scope: .subset(depots: [$0.id], accounts: [])) }
        parts += file.accounts.map { ledger.valuation(in: interval, scope: .account($0.id)) }
        for i in stride(from: 0, to: whole.count, by: 11) {
            #expect(parts.reduce(0) { $0 + $1.values[i] } == whole.values[i])
        }
        // Securities one by one add up to the securities value.
        let securities = file.securities.map { ledger.valuation(in: interval, scope: .security($0.id)) }
        for i in stride(from: 0, to: whole.count, by: 11) {
            #expect(securities.reduce(0) { $0 + $1.values[i] } == whole.securitiesValue(at: i))
        }
        // Open lots agree with positions.
        let day = interval.end
        let snapshot = ledger.snapshot(on: day)
        let lots = ledger.openLots(on: day)
        for p in snapshot.positions {
            let own = lots.filter { $0.securityID == p.securityID }
            #expect(own.reduce(Int64(0)) { $0 + $1.shares.raw } == p.shares.raw)
            #expect(own.reduce(0) { $0 + $1.cost } == p.costBasis.minor)
        }
        // Realized gains of the records equal the closed lots of the same interval.
        let closed = ledger.closedLots(in: interval)
        let records = ledger.securityPerformance(in: interval)
        for r in records {
            #expect(closed.filter { $0.securityID == r.securityID }.reduce(0) { $0 + $1.gain } == r.realizedGain)
            // A record is the single-security scope seen through the portfolio report.
            let own = securities[ledger.securityIndex(r.securityID)!]
            #expect(r.initialValue == own.initialValue && r.marketValue == own.finalValue)
            #expect(r.inflows == own.totalInflows && r.outflows == own.totalOutflows)
            #expect(abs(r.ttwror - own.returns().total) < 1e-9 * max(1, abs(r.ttwror)))
            #expect(r.marketValue == (snapshot.position(r.securityID)?.value.minor ?? 0))
            #expect(r.costBasis == (snapshot.position(r.securityID)?.costBasis.minor ?? 0))
            if let a = r.irr, let b = own.irr() { #expect(abs(a - b) < 1e-6 * max(1, abs(a))) } else { #expect(r.irr == nil && own.irr() == nil) }
        }
    }

    @Test(arguments: seeds)
    func flowFreeIntervalsCompoundToValueRatio(seed: UInt64) {
        let o = options(seed)
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let lastTransaction = ledger.lastTransactionDay!
        let end = o.start.advanced(by: o.days - 1)
        #expect(end.distance(to: lastTransaction) < -30)
        for scope in scopes(file) {
            // After the last transaction nothing flows: TTWROR must equal V_end / V_start − 1.
            let quiet = ledger.valuation(in: DayInterval(start: lastTransaction, end: end), scope: scope)
            #expect(quiet.totalInflows == 0 && quiet.totalOutflows == 0)
            if quiet.values.allSatisfy({ $0 > 0 }) {
                let expected = Double(quiet.finalValue) / Double(quiet.initialValue) - 1
                #expect(abs(quiet.returns().total - expected) < 1e-9)
            }
            // The same holds for every flow-free stretch inside the history.
            let series = ledger.valuation(in: DayInterval(start: o.start, end: end), scope: scope)
            let returns = series.returns()
            var runStart = 0
            var checked = 0
            for i in 1...series.count {
                let breaks = i == series.count || series.inflows[i] != 0 || series.outflows[i] != 0 || series.values[i] <= 0
                guard breaks else { continue }
                if i - 1 > runStart, series.values[runStart] > 0 {
                    let expected = Double(series.values[i - 1]) / Double(series.values[runStart])
                    let actual = returns.daily[(runStart + 1)...(i - 1)].reduce(1.0) { $0 * (1 + $1) }
                    #expect(abs(actual / expected - 1) < 1e-9)
                    checked += 1
                }
                runStart = i
            }
            if case .portfolio = scope { #expect(checked > 10) }
        }
    }

    @Test func reportingCurrencyOverrideReconciles() {
        let file = makeRandomPortfolio(RandomPortfolioOptions(seed: 99))
        let ledger = Ledger(file, reportingCurrency: "USD")
        #expect(ledger.reportingCurrency == "USD")
        let interval = DayInterval(start: d("2015-06-01"), end: d("2016-12-31"))
        let report = ledger.performance(in: interval)
        expectReconciled(report.breakdown)
        #expect(report.currency == "USD" && report.breakdown.currency == "USD")
        #expect(report.breakdown.finalValue == ledger.snapshot(on: interval.end).totalValue.minor)
        #expect(abs(report.breakdown.roundingResidue) < 1_000)
        #expect(!report.diagnostics.contains { if case .missingExchangeRate = $0 { return true } else { return false } })
    }
}

/// The selling point: speed. 20 years × 60 securities × 5 000 transactions.
@Suite(.serialized) struct BenchmarkTests {
    @Test func twentyYearPortfolio() {
        var o = RandomPortfolioOptions(seed: 2024)
        o.securities = 60
        o.days = 7_305
        o.transactions = 5_000
        o.activeFraction = 0.999
        o.start = Day(year: 2005, month: 1, day: 1)
        let file = makeRandomPortfolio(o)
        let interval = DayInterval(start: o.start.advanced(by: -1), end: o.start.advanced(by: o.days - 1))

        var ledger = Ledger(file)
        let build = bestMilliseconds { ledger = Ledger(file) }
        var series = ledger.valuation(in: interval)
        let valuation = bestMilliseconds { series = ledger.valuation(in: interval) }
        var total = 0.0
        let returns = bestMilliseconds { total = series.returns().total }
        var report = ledger.performance(in: interval)
        let performance = bestMilliseconds { report = ledger.performance(in: interval) }
        var snapshot = ledger.snapshot(on: interval.end)
        let snapshotTime = bestMilliseconds { snapshot = ledger.snapshot(on: interval.end) }
        var breakdown = ledger.breakdown(in: interval)
        let breakdownTime = bestMilliseconds { breakdown = ledger.breakdown(in: interval) }

        let prices = file.securities.reduce(0) { $0 + $1.prices.count }
        func f(_ ms: Double) -> String { String(format: "%8.3f ms", ms) }
        print("""
        [benchmark] \(file.securities.count) securities, \(ledger.transactions.count) transactions, \
        \(series.count) days, \(prices) quotes, \(snapshot.positions.count) open positions
        [benchmark]   Ledger build ................ \(f(build))
        [benchmark]   daily valuation series ...... \(f(valuation))
        [benchmark]   TTWROR from series .......... \(f(returns))
        [benchmark]   snapshot (with cost basis) .. \(f(snapshotTime))
        [benchmark]   reconciling breakdown ....... \(f(breakdownTime))
        [benchmark]   full performance report ..... \(f(performance))  (series + TTWROR + IRR + breakdown + \
        \(report.securities.count) security records + risk)
        """)

        #expect(series.finalValue == snapshot.totalValue.minor)
        #expect(breakdown == report.breakdown && total == report.ttwror)
        #expect(snapshot.positions.count >= 50)
        #if DEBUG
        // Unoptimized builds are 10–30× slower; only guard against pathological regressions.
        #expect(valuation < 3_000)
        #expect(performance < 6_000)
        #expect(build < 2_000)
        #else
        #expect(valuation < 50, "daily valuation must stay well under 50 ms")
        #expect(performance < 150)
        #expect(build < 30)
        #expect(snapshotTime < 20)
        #endif
    }

    /// The analytics built on top of the core, on the same 20-year portfolio.
    @Test func twentyYearAnalytics() {
        var o = RandomPortfolioOptions(seed: 2024)
        o.securities = 60
        o.days = 7_305
        o.transactions = 5_000
        o.activeFraction = 0.999
        o.start = Day(year: 2005, month: 1, day: 1)
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let interval = DayInterval(start: o.start.advanced(by: -1), end: o.start.advanced(by: o.days - 1))
        let taxonomy = AllocationTests.randomTaxonomy(file, seed: 3)
        let plan = InvestmentPlan(
            name: "Plan", securityID: file.securities[0].id, depotID: file.depots[0].id, accountID: file.accounts[0].id,
            amount: Money(250, "EUR"), start: o.start.advanced(by: 30))

        var trades = ledger.trades(on: interval.end)
        let tradesTime = bestMilliseconds { trades = ledger.trades(on: interval.end) }
        var earnings = ledger.earnings(in: interval)
        let earningsTime = bestMilliseconds { earnings = ledger.earnings(in: interval) }
        var allocation = ledger.allocation(for: taxonomy, on: interval.end)
        let allocationTime = bestMilliseconds { allocation = ledger.allocation(for: taxonomy, on: interval.end) }
        var proposal = allocation.rebalancing(RebalancingOptions(cash: 1_000_000, mode: .noSales, wholeShares: true))
        let rebalancingTime = bestMilliseconds {
            proposal = allocation.rebalancing(RebalancingOptions(cash: 1_000_000, mode: .noSales, wholeShares: true))
        }
        var issues = ledger.consistencyIssues(options: .init(today: interval.end))
        let checkTime = bestMilliseconds { issues = ledger.consistencyIssues(options: .init(today: interval.end)) }
        var planned = ledger.planTransactions(plan, through: interval.end)
        let planTime = bestMilliseconds { planned = ledger.planTransactions(plan, through: interval.end) }
        var facadeChecksum: Int64 = 0
        let facadeTime = bestMilliseconds {
            let a = Analysis(ledger: ledger, interval: interval)
            facadeChecksum = a.snapshot.totalValue.minor + a.breakdown.finalValue + Int64(a.securities.count)
                + Int64(a.trades.closed.count) + a.earnings.total.net + Int64(a.heatmap.rows.count)
                + Int64(a.risk.volatility * 1_000) + a.allocation(for: taxonomy).totalValue
        }

        func f(_ ms: Double) -> String { String(format: "%8.3f ms", ms) }
        print("""
        [benchmark] analytics on \(ledger.transactions.count) transactions
        [benchmark]   trades (\(trades.closed.count) closed, \(trades.open.count) open) ... \(f(tradesTime))
        [benchmark]   earnings (\(earnings.months.count) months, \(earnings.payments.count) payments) \(f(earningsTime))
        [benchmark]   taxonomy allocation ......... \(f(allocationTime))
        [benchmark]   rebalancing proposal ........ \(f(rebalancingTime))
        [benchmark]   consistency check (\(issues.count) issues) \(f(checkTime))
        [benchmark]   plan catch-up (\(planned.transactions.count) executions) \(f(planTime))
        [benchmark]   Analysis facade, everything . \(f(facadeTime))
        """)

        #expect(facadeChecksum != 0)
        #expect(trades.closed.count > 100 && earnings.months.count == 240)
        #expect(allocation.totalValue == ledger.snapshot(on: interval.end).totalValue.minor)
        #expect(proposal.orders.reduce(0) { $0 + $1.amount } + proposal.residualCash == 1_000_000)
        #expect(planned.transactions.count > 200)
        #if DEBUG
        #expect(tradesTime < 1_000 && earningsTime < 1_000 && checkTime < 2_000 && facadeTime < 8_000)
        #else
        #expect(tradesTime < 10 && earningsTime < 10 && allocationTime < 10 && rebalancingTime < 5)
        #expect(checkTime < 30 && planTime < 30)
        #expect(facadeTime < 150)
        #endif
    }
}
