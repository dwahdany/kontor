import Foundation
import KontorEngine
import KontorModel
import Testing

@Suite struct RiskTests {
    /// Sunday 2024-01-07 as baseline, so indices 1…5 are Monday…Friday.
    private func series(_ daily: [Double], start: String = "2024-01-07") -> ReturnSeries {
        let s = d(start)
        return ReturnSeries(interval: DayInterval(start: s, end: s.advanced(by: daily.count - 1)), daily: daily)
    }

    @Test func returnSeriesBasics() {
        let r = series([0.5, 0.10, -0.20, 0.05, 0.25, -0.02]) // the baseline entry is forced to 0
        #expect(r.daily[0] == 0 && r.cumulative[0] == 0)
        // Wealth: 1, 1.1, 0.88, 0.924, 1.155, 1.1319
        let wealth = [1, 1.1, 0.88, 0.924, 1.155, 1.1319]
        for (c, w) in zip(r.cumulative, wealth) { #expect(abs(c - (w - 1)) < 1e-12) }
        #expect(abs(r.total - 0.1319) < 1e-12)
        #expect(r.day(at: 1) == d("2024-01-08") && r.count == 6)
        let fromLevels = ReturnSeries(interval: r.interval, levels: [100, 110, 88, 92.4, 115.5, 113.19])
        for (a, b) in zip(fromLevels.daily, r.daily) { #expect(abs(a - b) < 1e-12) }
        let drawdowns = r.drawdowns()
        for (a, b) in zip(drawdowns, [0, 0, 0.2, 0.16, 0, 0.02]) { #expect(abs(a - b) < 1e-12) }
    }

    @Test func maxDrawdown() {
        let risk = RiskMetrics(returns: series([0, 0.10, -0.20, 0.05, 0.25, -0.02]))
        // Peak 1.1 on Monday, trough 0.88 on Tuesday (−20 %), back above 1.1 on Thursday (1.155).
        let dd = risk.maxDrawdown!
        #expect(abs(dd.depth - 0.2) < 1e-12)
        #expect(dd.peak == d("2024-01-08") && dd.trough == d("2024-01-09") && dd.recovery == d("2024-01-11"))
        #expect(dd.declineDays == 1 && dd.durationDays == 3)

        let unrecovered = RiskMetrics(returns: series([0, 0.2, -0.5, 0.1])).maxDrawdown!
        #expect(abs(unrecovered.depth - 0.5) < 1e-12 && unrecovered.recovery == nil && unrecovered.durationDays == nil)
        #expect(unrecovered.peak == d("2024-01-08"))

        // A decline right from the start counts from the baseline.
        let fromStart = RiskMetrics(returns: series([0, -0.1, -0.1])).maxDrawdown!
        #expect(abs(fromStart.depth - 0.19) < 1e-12 && fromStart.peak == d("2024-01-07"))

        #expect(RiskMetrics(returns: series([0, 0.1, 0.1, 0])).maxDrawdown == nil)
    }

    @Test func volatilitySharpeAndExtremes() {
        let daily = [0, 0.10, -0.20, 0.05, 0.25, -0.02]
        let risk = RiskMetrics(returns: series(daily), riskFreeRate: 0.02)
        // mean = 0.18 / 5 = 0.036; deviations 0.064, −0.236, 0.014, 0.214, −0.056
        // Σd² = 0.004096 + 0.055696 + 0.000196 + 0.045796 + 0.003136 = 0.10892
        let expectedVolatility = (0.10892 / 4 * 252).squareRoot()
        #expect(abs(risk.volatility - expectedVolatility) < 1e-12)
        // Downside: only the negative deviations: 0.055696 + 0.003136 = 0.058832
        #expect(abs(risk.semiVolatility - (0.058832 / 4 * 252).squareRoot()) < 1e-12)
        // Sharpe: (annualized − 2 %) / volatility with annualized = 1.1319^(365/5) − 1
        let annualized = pow(1.1319, 73.0) - 1
        #expect(abs(risk.sharpeRatio! / ((annualized - 0.02) / expectedVolatility) - 1) < 1e-9)
        #expect(risk.bestDay == RiskMetrics.DayReturn(day: d("2024-01-11"), value: 0.25))
        #expect(risk.worstDay == RiskMetrics.DayReturn(day: d("2024-01-09"), value: -0.20))

        // Weekend days (Saturday, Sunday) do not enter the volatility sample.
        let withWeekend = RiskMetrics(returns: series(daily + [0, 0]))
        #expect(abs(withWeekend.volatility - expectedVolatility) < 1e-12)
        // A different annualization factor.
        let daily365 = RiskMetrics(returns: series(daily), tradingDaysPerYear: 365)
        #expect(abs(daily365.volatility - (0.10892 / 4 * 365).squareRoot()) < 1e-12)

        let flat = RiskMetrics(returns: series([0, 0, 0, 0]))
        #expect(flat.volatility == 0 && flat.semiVolatility == 0 && flat.sharpeRatio == nil)
        let single = RiskMetrics(returns: series([0]))
        #expect(single.bestDay == nil && single.worstMonth == nil && single.volatility == 0)
    }

    @Test func monthlyAndYearlyReturns() {
        // Baseline 2023-12-30; 12-31: +10 %; 01-01: +10 %; 01-02: −50 %; … ; 02-01: +100 %
        var daily = [0, 0.10, 0.10, -0.50]
        daily += [Double](repeating: 0, count: 29) // 01-03 … 01-31
        daily.append(1.0) // 02-01
        let r = series(daily, start: "2023-12-30")
        #expect(r.day(at: daily.count - 1) == d("2024-02-01"))
        let months = r.monthlyReturns()
        #expect(months.map(\.month) == [12, 1, 2] && months.map(\.year) == [2023, 2024, 2024])
        #expect(abs(months[0].value - 0.10) < 1e-12)
        #expect(abs(months[1].value - (1.1 * 0.5 - 1)) < 1e-12)
        #expect(abs(months[2].value - 1.0) < 1e-12)
        let years = r.yearlyReturns()
        #expect(years.map(\.year) == [2023, 2024])
        #expect(abs(years[1].value - (0.55 * 2 - 1)) < 1e-12)
        let risk = RiskMetrics(returns: r)
        #expect(risk.bestMonth == months[2] && risk.worstMonth == months[1])
    }

    @Test func reportUsesRiskFreeRateFromSettings() {
        var f = Fixture()
        f.file.settings.riskFreeRate = 0.03
        let account = f.account("Cash"), depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [
            ("2024-01-01", 100), ("2024-01-02", 104), ("2024-01-03", 101), ("2024-01-04", 107), ("2024-01-05", 105),
        ])
        f.add(.deposit, "2024-01-01", account: account, amount: 1_000)
        f.add(.buy, "2024-01-01", account: account, depot: depot, security: stock, shares: 10, amount: 1_000)
        let report = f.ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-05")))
        #expect(abs(report.ttwror - 0.05) < 1e-12)
        let expected = (report.ttwrorAnnualized! - 0.03) / report.risk.volatility
        #expect(abs(report.risk.sharpeRatio! - expected) < 1e-9)
        #expect(abs(report.risk.maxDrawdown!.depth - (1 - 101.0 / 104)) < 1e-12)
    }
}

@Suite struct ReportingPeriodTests {
    let today = d("2024-05-15")
    let first = d("2020-03-10")

    private func resolve(_ p: ReportingPeriod, today: Day? = nil) -> DayInterval {
        p.interval(today: today ?? self.today, firstTransactionDay: first)
    }

    @Test func resolution() {
        #expect(resolve(.ytd) == DayInterval(start: d("2023-12-31"), end: today))
        #expect(resolve(.monthToDate) == DayInterval(start: d("2024-04-30"), end: today))
        #expect(ReportingPeriod.quarterToDate.interval(today: d("2024-05-20"), firstTransactionDay: nil)
            == DayInterval(start: d("2024-03-31"), end: d("2024-05-20")))
        #expect(ReportingPeriod.quarterToDate.interval(today: d("2024-01-01"), firstTransactionDay: nil).start == d("2023-12-31"))
        #expect(ReportingPeriod.quarterToDate.shortTitle == "QTD" && ReportingPeriod.quarterToDate.title == "Quarter to date")
        #expect(resolve(.lastDays(30)) == DayInterval(start: d("2024-04-15"), end: today))
        #expect(resolve(.lastMonths(3)) == DayInterval(start: d("2024-02-15"), end: today))
        #expect(resolve(.lastYears(1)) == DayInterval(start: d("2023-05-15"), end: today))
        #expect(resolve(.year(2023)) == DayInterval(start: d("2022-12-31"), end: d("2023-12-31")))
        #expect(resolve(.year(2024)) == DayInterval(start: d("2023-12-31"), end: today)) // running year ends today
        #expect(resolve(.year(2025)) == DayInterval(start: d("2024-12-31"), end: d("2025-12-31")))
        #expect(resolve(.allTime) == DayInterval(start: d("2020-03-09"), end: today))
        #expect(resolve(.custom(from: d("2024-02-01"), to: d("2024-01-01"))) == DayInterval(start: d("2024-01-01"), end: d("2024-02-01")))
        // Month arithmetic clamps the day: Mar 31 − 1 month = Feb 29 (leap year).
        #expect(resolve(.lastMonths(1), today: d("2024-03-31")).start == d("2024-02-29"))
        #expect(resolve(.lastYears(1), today: d("2024-02-29")).start == d("2023-02-28"))
        // Without transactions "all time" is just today.
        #expect(ReportingPeriod.allTime.interval(today: today, firstTransactionDay: nil) == DayInterval(start: d("2024-05-14"), end: today))
        // A first transaction in the future does not produce a reversed interval.
        #expect(ReportingPeriod.allTime.interval(today: today, firstTransactionDay: d("2030-01-01")).end == today)
    }

    @Test func resolutionAgainstLedger() {
        var f = Fixture()
        let account = f.account("Cash")
        f.add(.deposit, "2021-06-15", account: account, amount: 100)
        f.add(.deposit, "2019-02-03", account: account, amount: 100)
        let ledger = f.ledger
        #expect(ReportingPeriod.allTime.interval(today: today, ledger: ledger) == DayInterval(start: d("2019-02-02"), end: today))
        let report = ledger.performance(for: .allTime, today: today)
        #expect(report.valuation.initialValue == 0 && report.valuation.finalValue == 20_000)
        #expect(report.valuation.inflows[1] == 10_000)
    }

    @Test func intervalProperties() {
        let i = DayInterval(start: d("2023-12-31"), end: d("2024-12-31"))
        #expect(i.dayCount == 366 && i.firstDay == d("2024-01-01"))
        #expect(!i.contains(d("2023-12-31")) && i.contains(d("2024-01-01")) && i.contains(d("2024-12-31")))
        #expect(!i.contains(d("2025-01-01")))
        #expect(abs(i.years - 366.0 / 365) < 1e-12)
        #expect(i.description == "2023-12-31…2024-12-31")
    }

    @Test func titlesAndCoding() throws {
        #expect(ReportingPeriod.ytd.title == "Year to date")
        #expect(ReportingPeriod.lastMonths(1).title == "Last month")
        #expect(ReportingPeriod.lastMonths(3).title == "Last 3 months")
        #expect(ReportingPeriod.lastYears(5).title == "Last 5 years")
        #expect(ReportingPeriod.lastDays(30).title == "Last 30 days")
        #expect(ReportingPeriod.year(2023).title == "2023")
        #expect(ReportingPeriod.allTime.title == "All time")
        #expect(ReportingPeriod.custom(from: d("2024-01-01"), to: d("2024-06-30")).title == "2024-01-01 – 2024-06-30")
        #expect(ReportingPeriod.lastMonths(6).shortTitle == "6M" && ReportingPeriod.allTime.shortTitle == "Max")
        let all: [ReportingPeriod] = ReportingPeriod.presets + [.monthToDate, .quarterToDate, .lastDays(7), .year(2022), .custom(from: d("2024-01-01"), to: d("2024-06-30"))]
        let decoded = try JSONDecoder().decode([ReportingPeriod].self, from: JSONEncoder().encode(all))
        #expect(decoded == all)
        let interval = DayInterval(start: d("2024-01-01"), end: d("2024-06-30"))
        #expect(try JSONDecoder().decode(DayInterval.self, from: JSONEncoder().encode(interval)) == interval)
    }
}

@Suite struct ComparisonTests {
    @Test func benchmarkInOwnCurrency() {
        var f = Fixture()
        let index = f.security("Index", prices: [("2024-01-02", 100), ("2024-01-03", 110), ("2024-01-05", 121)])
        let empty = f.security("Empty")
        let ledger = f.ledger
        let b = ledger.benchmark(securityID: index, in: DayInterval(start: d("2024-01-02"), end: d("2024-01-06")))!
        // 01-02 100 (base), 01-03 110, 01-04 110 (no quote), 01-05 121, 01-06 121
        for (a, e) in zip(b.cumulative, [0, 0.10, 0.10, 0.21, 0.21]) { #expect(abs(a - e) < 1e-12) }
        #expect(b.daily[2] == 0 && abs(b.daily[3] - 0.10) < 1e-12)
        // Starting before the first quote: flat until the series begins.
        let early = ledger.benchmark(securityID: index, in: DayInterval(start: d("2023-12-30"), end: d("2024-01-03")))!
        for (a, e) in zip(early.cumulative, [0, 0, 0, 0, 0.10]) { #expect(abs(a - e) < 1e-12) }
        #expect(ledger.benchmark(securityID: empty, in: early.interval) == nil)
        #expect(ledger.benchmark(securityID: UUID(), in: early.interval) == nil)
        #expect(ledger.priceLevels(securityID: index, in: early.interval) == [100, 100, 100, 100, 110])
    }

    @Test func benchmarkInReportingCurrency() {
        var f = Fixture()
        f.rates("EUR", "USD", [("2024-01-01", 1.10), ("2024-01-03", 1.25)])
        let index = f.security("US index", "USD", prices: [("2024-01-02", 100), ("2024-01-03", 110)])
        let exotic = f.security("Exotic", "XXX", prices: [("2024-01-02", 100)])
        let ledger = f.ledger
        let interval = DayInterval(start: d("2024-01-02"), end: d("2024-01-03"))
        // EUR: 100 / 1.10 = 90.909 → 110 / 1.25 = 88.00 → −3.2 %
        let eur = ledger.benchmark(securityID: index, in: interval)!
        #expect(abs(eur.total - (88 / (100 / 1.1) - 1)) < 1e-12)
        let usd = ledger.benchmark(securityID: index, in: interval, basis: .securityCurrency)!
        #expect(abs(usd.total - 0.10) < 1e-12)
        #expect(ledger.benchmark(securityID: exotic, in: interval) == nil) // not convertible
        #expect(ledger.benchmark(securityID: exotic, in: interval, basis: .securityCurrency)?.total == 0)
        // Same day axis as the portfolio series.
        #expect(eur.count == ledger.valuation(in: interval).count)
    }

    @Test func downsampling() {
        var values = (0..<1_000).map { sin(Double($0) / 40) * 100 }
        values[123] = 500 // global maximum
        values[777] = -500 // global minimum
        let picked = Downsampler.indices(values, maxPoints: 50)
        #expect(picked.count <= 50 && picked.count >= 26)
        #expect(picked.first == 0 && picked.last == 999)
        #expect(picked.contains(123) && picked.contains(777))
        #expect(zip(picked, picked.dropFirst()).allSatisfy { $0 < $1 })
        #expect(Downsampler.downsample(values, maxPoints: 50).max() == 500)

        // Short inputs are returned unchanged; tiny limits keep at least the end points.
        #expect(Downsampler.indices([3, 1, 2], maxPoints: 10) == [0, 1, 2])
        #expect(Downsampler.indices([Int](), maxPoints: 10).isEmpty)
        #expect(Downsampler.indices(values, maxPoints: 2) == [0, 999])
        #expect(Downsampler.indices(values, maxPoints: 0) == [0, 999])
        #expect(Downsampler.indices(values, maxPoints: 3) == [0, 999])
        for limit in [4, 5, 7, 64, 333, 999] {
            let p = Downsampler.indices(values, maxPoints: limit)
            #expect(p.count <= limit && p.first == 0 && p.last == 999)
            #expect(zip(p, p.dropFirst()).allSatisfy { $0 < $1 })
            #expect(p.contains(123) && p.contains(777))
        }
        // Integer series and chart helpers.
        let ints: [Int64] = (0..<500).map { Int64(($0 * 37) % 101) }
        #expect(Downsampler.indices(ints, maxPoints: 20).count <= 20)

        var f = Fixture()
        let account = f.account("Cash")
        f.add(.deposit, "2020-01-01", account: account, amount: 100)
        f.add(.deposit, "2021-01-01", account: account, amount: 900)
        let series = f.ledger.valuation(in: DayInterval(start: d("2019-12-31"), end: d("2022-12-31")))
        let points = series.chartPoints(maxPoints: 100)
        #expect(points.count <= 100 && points.first?.day == d("2019-12-31") && points.last?.value == 100_000)
        #expect(series.returns().chartPoints(maxPoints: 10).count <= 10)
    }
}
