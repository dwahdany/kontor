import Foundation
import KontorModel
import Testing
@testable import KontorMarketData

private let today = day("2024-01-15")

private func updater(_ provider: FakeProvider, rates: FakeRates? = nil, options: UpdateOptions = UpdateOptions()) -> QuoteUpdater {
    QuoteUpdater(registry: ProviderRegistry([provider, ManualProvider()]), rateProvider: rates, options: options,
                 now: { date("2024-01-15T18:00:00Z") })
}

private let echo = FakeProvider { request in
    QuoteHistory(points: [PricePoint(day: request.range.upperBound, price: Price(10))], currency: request.currency)
}

@Suite struct UpdatePlanTests {
    @Test func requestsFromTheDayAfterTheLastPrice() {
        let a = security("A", symbol: "A", prices: [point("2024-01-09", 1), point("2024-01-10", 2)])
        let plan = updater(echo).plan(for: PortfolioFile(securities: [a]), today: today)
        #expect(plan.today == today)
        #expect(plan.securities.count == 1)
        #expect(plan.securities[0].id == a.id)
        #expect(plan.securities[0].name == "A")
        #expect(plan.securities[0].request?.range == day("2024-01-11")...today)
        #expect(plan.securities[0].request?.feed == a.feed)
        #expect(plan.securities[0].request?.ticker == "A")
        #expect(plan.rates.isEmpty)
        #expect(plan.targetCount == 1)
    }

    @Test func emptySecuritiesGetTheConfiguredHistory() {
        let empty = security("New", symbol: "N")
        var file = PortfolioFile(securities: [empty])
        #expect(updater(echo).plan(for: file, today: today).securities[0].request?.range == day("1970-01-01")...today)

        let fixed = UpdateOptions(historyStart: .day(day("2015-01-01")))
        #expect(updater(echo, options: fixed).plan(for: file, today: today).securities[0].request?.range == day("2015-01-01")...today)

        let relative = UpdateOptions(historyStart: .beforeFirstTransaction(days: 30))
        #expect(updater(echo, options: relative).plan(for: file, today: today).securities[0].request?.range == day("2023-12-16")...today)
        file.transactions = [
            Transaction(kind: .buy, date: day("2021-06-15"), securityID: empty.id, amount: Money(100, "EUR")),
            Transaction(kind: .buy, date: day("2020-03-31"), securityID: empty.id, amount: Money(100, "EUR")),
            Transaction(kind: .deposit, date: day("2019-01-01"), amount: Money(100, "EUR")),
        ]
        #expect(updater(echo, options: relative).plan(for: file, today: today).securities[0].request?.range == day("2020-03-01")...today)
    }

    @Test func skipsRetiredManualAndFeedlessSecurities() {
        var retired = security("Retired", symbol: "R")
        retired.isRetired = true
        var manual = security("Manual", symbol: "")
        manual.feed = .manual
        var feedless = security("None", symbol: "")
        feedless.feed = nil
        let unknown = security("Unknown", symbol: "U", provider: "bloomberg")
        let active = security("Active", symbol: "A")
        let file = PortfolioFile(securities: [retired, manual, feedless, unknown, active])
        let plan = updater(echo).plan(for: file, today: today)
        // Unknown providers stay in the plan so that the run reports them as failed.
        #expect(plan.securities.map(\.name) == ["Unknown", "Active"])
        #expect(updater(echo).plan(for: file, today: today, only: [active.id]).securities.map(\.name) == ["Active"])
    }

    @Test func refetchesAProvisionalLastDay() {
        // Stored at 15:00 UTC on the day itself: possibly an intraday price → fetch that day again.
        let intraday = security("Intraday", symbol: "I", prices: [point("2024-01-10", 1)], updatedAt: date("2024-01-10T15:00:00Z"))
        // Stored the next morning: the close is final.
        let final = security("Final", symbol: "F", prices: [point("2024-01-10", 1)], updatedAt: date("2024-01-11T03:00:00Z"))
        let file = PortfolioFile(securities: [intraday, final])
        let plan = updater(echo).plan(for: file, today: today)
        #expect(plan.securities[0].request?.range == day("2024-01-10")...today)
        #expect(plan.securities[1].request?.range == day("2024-01-11")...today)
        let strict = updater(echo, options: UpdateOptions(refreshesProvisionalDay: false)).plan(for: file, today: today)
        #expect(strict.securities[0].request?.range == day("2024-01-11")...today)
    }

    @Test func upToDateSecuritiesNeedNoRequest() async {
        let done = security("Done", symbol: "D", prices: [point("2024-01-15", 1)], updatedAt: date("2024-01-16T09:00:00Z"))
        let provider = FakeProvider { _ in QuoteHistory() }
        let u = updater(provider)
        let file = PortfolioFile(securities: [done])
        #expect(u.plan(for: file, today: today).securities[0].request == nil)
        let result = await u.update(file, today: today)
        #expect(result.statuses == [.security(done.id): .success(newPoints: 0)])
        #expect(provider.requests.isEmpty)
        #expect(result.securities.isEmpty)
    }

    @Test func plansExchangeRatesForEveryForeignCurrency() {
        let rates = FakeRates { _ in RateBatch() }
        let usd = security("US", symbol: "US", currency: "USD")
        var file = PortfolioFile(
            securities: [usd, security("EU", symbol: "EU")],
            accounts: [Account(name: "Cash", currency: "EUR"), Account(name: "Franken", currency: "CHF")],
            exchangeRates: [
                ExchangeRateSeries(base: "EUR", quote: "USD", days: [day("2024-01-08").rawValue, day("2024-01-09").rawValue], rates: [1.09, 1.1]),
                ExchangeRateSeries(base: "USD", quote: "CHF", days: [day("2024-01-12").rawValue], rates: [0.85]), // not euro-based: ignored
            ]
        )
        let plan = updater(echo, rates: rates).plan(for: file, today: today)
        #expect(plan.rates == [
            RateRequest(currency: "CHF", from: day("1999-01-04"), hasHistory: false),
            RateRequest(currency: "USD", from: day("2024-01-10"), hasHistory: true),
        ])
        #expect(plan.targetCount == 3)

        // A dollar-based file needs EUR → USD (and EUR → CHF) too: everything is triangulated via the euro.
        file.settings.baseCurrency = "USD"
        #expect(updater(echo, rates: rates).plan(for: file, today: today).rates.map(\.currency) == ["CHF", "USD"])

        let limited = UpdateOptions(rateHistoryStart: .day(day("2020-01-01")))
        #expect(updater(echo, rates: rates, options: limited).plan(for: file, today: today).rates[0].from == day("2020-01-01"))
        #expect(updater(echo, rates: rates, options: UpdateOptions(updatesExchangeRates: false)).plan(for: file, today: today).rates.isEmpty)
        #expect(updater(echo, rates: nil).plan(for: file, today: today).rates.isEmpty)
    }

    @Test func singleCurrencyFilesNeedNoRates() {
        let rates = FakeRates { _ in RateBatch() }
        let file = PortfolioFile(securities: [security("EU", symbol: "EU")], accounts: [Account(name: "Cash", currency: "EUR")])
        #expect(updater(echo, rates: rates).plan(for: file, today: today).rates.isEmpty)
        var dollars = PortfolioFile(settings: Settings(baseCurrency: "USD"), accounts: [Account(name: "Cash", currency: "USD")])
        #expect(updater(echo, rates: rates).plan(for: dollars, today: today).rates.isEmpty)
        dollars.accounts.append(Account(name: "Euro", currency: "EUR"))
        #expect(updater(echo, rates: rates).plan(for: dollars, today: today).rates == [RateRequest(currency: "USD", from: day("1999-01-04"), hasHistory: false)])
    }
}

@Suite struct UpdateRunTests {
    @Test func collectsOnlyNewAndChangedPoints() async {
        let existing = security("A", symbol: "A", prices: [point("2024-01-10", 10), point("2024-01-11", 11)], updatedAt: date("2024-01-11T12:00:00Z"))
        let provider = FakeProvider { _ in
            QuoteHistory(
                points: [point("2024-01-10", 10), point("2024-01-11", 11.5), point("2024-01-12", 12), point("2024-01-15", 13)],
                currency: "EUR",
                events: [QuoteEvent(day: day("2024-01-12"), kind: .dividend, detail: "0.5")]
            )
        }
        let result = await updater(provider).update(PortfolioFile(securities: [existing]), today: today)
        // The request starts on the provisional last day; the unchanged 10th is outside and dropped.
        #expect(provider.requests.map(\.range) == [day("2024-01-11")...today])
        #expect(result.securities == [SecurityUpdate(
            id: existing.id, points: [point("2024-01-11", 11.5), point("2024-01-12", 12), point("2024-01-15", 13)],
            events: [QuoteEvent(day: day("2024-01-12"), kind: .dividend, detail: "0.5")], fetchedAt: date("2024-01-15T18:00:00Z")
        )])
        #expect(result.statuses == [.security(existing.id): .success(newPoints: 3)])
        #expect(result.newPriceCount == 3)
        #expect(result.hasNewData)
        #expect(!result.wasCancelled)
        #expect(result.failures.isEmpty)
    }

    @Test func oneFailingSecurityDoesNotAffectTheOthers() async {
        let securities = (0..<8).map { security("S\($0)", symbol: "S\($0)") }
        let unknown = security("Unknown", symbol: "U", provider: "bloomberg")
        let foreign = security("Dollar", symbol: "USD", currency: "CHF")
        let provider = FakeProvider { request in
            if request.feed.symbol == "S3" { throw MarketDataError.symbolNotFound("S3") }
            if request.feed.symbol == "S5" { throw URLError(.badServerResponse) }
            if request.feed.symbol == "USD" { return QuoteHistory(points: [point("2024-01-12", 1)], currency: "USD") }
            return QuoteHistory(points: [point("2024-01-12", 10), point("2024-01-15", 11)], currency: "EUR")
        }
        let rates = FakeRates { _ in throw MarketDataError.http(status: 503, host: "www.ecb.europa.eu") }
        let file = PortfolioFile(securities: securities + [unknown, foreign])
        let result = await updater(provider, rates: rates).update(file, today: today)

        #expect(result.statuses.count == 11)
        #expect(result.statuses[.security(securities[3].id)] == .failed(message: "Unknown symbol “S3”."))
        if case .failed = result.statuses[.security(securities[5].id)] {} else { Issue.record("S5 should have failed") }
        #expect(result.statuses[.security(unknown.id)] == .failed(message: "Unknown quote provider “bloomberg”."))
        #expect(result.statuses[.security(foreign.id)] == .failed(message: "The feed quotes in USD, but the security is kept in CHF."))
        #expect(result.statuses[.exchangeRates] == .failed(message: "www.ecb.europa.eu answered with HTTP 503."))
        for i in [0, 1, 2, 4, 6, 7] {
            #expect(result.statuses[.security(securities[i].id)] == .success(newPoints: 2))
        }
        #expect(result.securities.map(\.id) == [0, 1, 2, 4, 6, 7].map { securities[$0].id }) // file order
        #expect(result.failures.count == 5)
        #expect(!result.wasCancelled)
    }

    @Test func currencyCheckCanBeDisabled() async {
        let foreign = security("Dollar", symbol: "USD", currency: "CHF")
        let provider = FakeProvider { _ in QuoteHistory(points: [point("2024-01-12", 1)], currency: "USD") }
        let result = await updater(provider, options: UpdateOptions(checksCurrency: false)).update(PortfolioFile(securities: [foreign]), today: today)
        #expect(result.statuses[.security(foreign.id)] == .success(newPoints: 1))
    }

    @Test func boundsConcurrency() async {
        let securities = (0..<12).map { security("S\($0)", symbol: "S\($0)") }
        let provider = FakeProvider { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return QuoteHistory(points: [point("2024-01-12", 10)])
        }
        let result = await updater(provider, options: UpdateOptions(maxConcurrentDownloads: 3)).update(PortfolioFile(securities: securities), today: today)
        #expect(provider.requests.count == 12)
        #expect(provider.peakConcurrency <= 3)
        #expect(provider.peakConcurrency >= 2)
        #expect(result.newPriceCount == 12)
    }

    @Test func reportsProgressForEveryTarget() async {
        let a = security("A", symbol: "A"), b = security("B", symbol: "B")
        let provider = FakeProvider { request in
            if request.feed.symbol == "B" { throw MarketDataError.timeout }
            return QuoteHistory(points: [point("2024-01-12", 10)])
        }
        let rates = FakeRates { _ in RateBatch(series: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [1, 2], rates: [1, 1.1])]) }
        let file = PortfolioFile(securities: [a, b], accounts: [Account(name: "USD", currency: "USD")])
        let events = Collector<UpdateProgress>()
        let result = await updater(provider, rates: rates).update(file, today: today) { events.add($0) }

        let all = events.all
        #expect(all.count == 9) // 3 × (pending, running, final)
        #expect(all.prefix(3).map(\.status) == [.pending, .pending, .pending])
        #expect(all.prefix(3).map(\.target) == [.exchangeRates, .security(a.id), .security(b.id)])
        #expect(all.prefix(3).map(\.name) == ["Exchange rates", "A", "B"])
        #expect(all.allSatisfy { $0.total == 3 })
        func statuses(_ target: UpdateTarget) -> [UpdateStatus] { all.filter { $0.target == target }.map(\.status) }
        #expect(statuses(.security(a.id)) == [.pending, .running, .success(newPoints: 1)])
        #expect(statuses(.security(b.id)) == [.pending, .running, .failed(message: "The server did not answer in time.")])
        #expect(statuses(.exchangeRates) == [.pending, .running, .success(newPoints: 2)])
        #expect(all.map(\.completed) == all.map(\.completed).sorted()) // never goes backwards
        #expect(all.last?.completed == 3)
        #expect(all.last?.fraction == 1)
        #expect(result.newRateCount == 2)
        #expect(rates.requests == [[RateRequest(currency: "USD", from: day("1999-01-04"), hasHistory: false)]])
    }

    @Test func cancellationStopsTheRunAndKeepsFinishedWork() async {
        let securities = (0..<6).map { security("S\($0)", symbol: "S\($0)") }
        let started = Collector<String>()
        let provider = FakeProvider { request in
            if request.feed.symbol == "S0" { return QuoteHistory(points: [point("2024-01-12", 10)]) }
            started.add(request.feed.symbol)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return QuoteHistory()
        }
        let u = updater(provider, options: UpdateOptions(maxConcurrentDownloads: 2))
        let file = PortfolioFile(securities: securities)
        let task = Task { await u.update(file, today: today) }
        while started.all.count < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
        let begin = Date()
        task.cancel()
        let result = await task.value

        #expect(Date().timeIntervalSince(begin) < 5)
        #expect(result.wasCancelled)
        #expect(result.statuses.count == 6)
        #expect(result.statuses[.security(securities[0].id)] == .success(newPoints: 1))
        #expect(result.statuses.values.filter { $0 == .cancelled }.count == 5)
        #expect(result.securities.map(\.id) == [securities[0].id])
        #expect(provider.requests.count == 3) // nothing new was started after the cancellation
    }

    @Test func streamDeliversProgressThenTheResult() async {
        let a = security("A", symbol: "A")
        let provider = FakeProvider { _ in QuoteHistory(points: [point("2024-01-12", 10)]) }
        var progress = [UpdateStatus]()
        var final: UpdateResult?
        for await event in updater(provider).updates(for: PortfolioFile(securities: [a]), today: today) {
            switch event {
            case .progress(let p): progress.append(p.status)
            case .finished(let result): final = result
            }
        }
        #expect(progress == [.pending, .running, .success(newPoints: 1)])
        #expect(final?.newPriceCount == 1)
    }

    @Test func endToEndWithRecordedResponses() async throws {
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/AAPL", body: fixture("yahoo_chart_AAPL.json"))
        http.on("/v8/finance/chart/EUNL.DE", body: fixture("yahoo_chart_EUNL.DE.json"))
        http.on("/v8/finance/chart/VOD.L", body: fixture("yahoo_chart_VOD.L.json"))
        http.on("/v8/finance/chart/GONE", status: 404, body: fixture("yahoo_chart_notfound.json"))
        http.on("eurofxref-daily.xml", body: fixture("ecb_daily.xml"))
        http.on("eurofxref-hist.xml", body: fixture("ecb_90d.xml")) // GBP has no history yet → full file

        let apple = security("Apple", symbol: "AAPL", provider: "yahoo", currency: "USD", prices: [point("2024-01-03", 184.25)], updatedAt: date("2024-01-04T08:00:00Z"))
        let world = security("World", symbol: "EUNL.DE", provider: "yahoo")
        let vodafone = security("Vodafone", symbol: "VOD.L", provider: "yahoo", currency: "GBP")
        let gone = security("Gone", symbol: "GONE", provider: "yahoo")
        var file = PortfolioFile(
            securities: [apple, world, vodafone, gone],
            exchangeRates: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [day("2026-11-12").rawValue], rates: [1.1])]
        )
        let updater = QuoteUpdater(http: http, options: UpdateOptions(historyStart: .day(day("2024-01-01"))))
        let result = await updater.update(file, today: day("2024-01-10"))

        #expect(result.statuses[.security(apple.id)] == .success(newPoints: 5))
        #expect(result.statuses[.security(world.id)] == .success(newPoints: 7))
        #expect(result.statuses[.security(vodafone.id)] == .success(newPoints: 6))
        #expect(result.statuses[.security(gone.id)] == .failed(message: "Unknown symbol “GONE”."))
        #expect(result.statuses[.exchangeRates] == .success(newPoints: 12)) // GBP: 8 days of history file, USD: 4 new days
        #expect(http.requestedURLs.contains { $0.contains("/chart/AAPL?period1=1704240000&period2=1705017600") }) // 2024-01-04 − 1 … 2024-01-10 + 2

        let summary = apply(result, to: &file)
        #expect(summary.prices == 18)
        #expect(summary.rates == 12)
        #expect(file.securities[0].prices.map(\.day.iso) == ["2024-01-03", "2024-01-04", "2024-01-05", "2024-01-08", "2024-01-09", "2024-01-10"])
        #expect(file.securities[0].prices.latest == point("2024-01-10", 186.19))
        #expect(file.securities[1].prices.count == 7)
        #expect(file.securities[2].prices.price(on: day("2024-01-09")) == Price(0.7001))
        #expect(file.securities[3].prices.isEmpty)
        #expect(file.securities[3].updatedAt == nil)
        #expect(http.requestedURLs.filter { $0.contains("eurofxref") }.map { URL(string: $0)!.lastPathComponent } == ["eurofxref-daily.xml", "eurofxref-hist.xml"])
        try #require(file.exchangeRates.count == 2)
        #expect(file.exchangeRates.map(\.quote) == ["USD", "GBP"])
        #expect(file.exchangeRates[0].days.count == 5)
        #expect(file.exchangeRates[0].rate(on: day("2026-11-18")) == 1.0968)
        #expect(file.exchangeRates[1].rate(on: day("2026-11-10")) == 0.83545)
    }
}

@Suite struct ApplyTests {
    private func sampleFile() -> (PortfolioFile, Security, Security) {
        let a = security("A", symbol: "A", prices: [point("2024-01-10", 10), point("2024-01-11", 11)])
        var b = security("B", symbol: "B", currency: "USD")
        b.events = [SecurityEvent(day: day("2024-01-05"), kind: .dividend, detail: "0.4")]
        let file = PortfolioFile(
            securities: [a, b], accounts: [Account(name: "Cash", currency: "EUR")],
            exchangeRates: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [10, 11], rates: [1.1, 1.2])]
        )
        return (file, a, b)
    }

    @Test func mergesPricesEventsRatesAndTimestamps() {
        var (file, a, b) = sampleFile()
        let fetched = date("2024-01-15T18:00:00Z")
        let result = UpdateResult(
            securities: [
                SecurityUpdate(id: a.id, points: [point("2024-01-11", 11.5), point("2024-01-12", 12)], events: [], fetchedAt: fetched),
                SecurityUpdate(id: b.id, points: [], events: [
                    QuoteEvent(day: day("2024-01-05"), kind: .dividend, detail: "0.41"), // already known: kept as is
                    QuoteEvent(day: day("2024-01-02"), kind: .split, detail: "2:1"),
                ], fetchedAt: fetched),
                SecurityUpdate(id: UUID(), points: [point("2024-01-12", 1)], events: [], fetchedAt: fetched), // deleted meanwhile
            ],
            exchangeRates: [
                ExchangeRateSeries(base: "EUR", quote: "USD", days: [11, 12], rates: [1.2, 1.3]),
                ExchangeRateSeries(base: "EUR", quote: "CHF", days: [12], rates: [0.95]),
            ]
        )
        let summary = apply(result, to: &file)

        #expect(summary == ApplySummary(prices: 2, events: 1, rates: 2, changedSecurities: [a.id, b.id]))
        #expect(summary.hasChanges)
        #expect(Array(file.securities[0].prices) == [point("2024-01-10", 10), point("2024-01-11", 11.5), point("2024-01-12", 12)])
        #expect(file.securities[0].updatedAt == fetched)
        #expect(file.securities[1].updatedAt == fetched)
        #expect(file.securities[1].events.map(\.day.iso) == ["2024-01-02", "2024-01-05"])
        #expect(file.securities[1].events.map(\.detail) == ["2:1", "0.4"])
        #expect(file.exchangeRates == [
            ExchangeRateSeries(base: "EUR", quote: "USD", days: [10, 11, 12], rates: [1.1, 1.2, 1.3]),
            ExchangeRateSeries(base: "EUR", quote: "CHF", days: [12], rates: [0.95]),
        ])
    }

    @Test func applyingTwiceChangesNothingMore() {
        var (file, a, _) = sampleFile()
        let result = UpdateResult(
            securities: [SecurityUpdate(id: a.id, points: [point("2024-01-12", 12)], events: [QuoteEvent(day: day("2024-01-12"), kind: .dividend, detail: "1")], fetchedAt: date("2024-01-15T18:00:00Z"))],
            exchangeRates: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [12], rates: [1.3])]
        )
        #expect(result.apply(to: &file).hasChanges)
        let once = file
        let second = result.apply(to: &file)
        #expect(!second.hasChanges)
        #expect(second.changedSecurities.isEmpty)
        #expect(file == once)
    }

    @Test func emptyResultLeavesTheFileUntouched() {
        var (file, _, _) = sampleFile()
        let before = file
        #expect(apply(UpdateResult(), to: &file) == ApplySummary())
        #expect(file == before)
        #expect(!UpdateResult().hasNewData)
    }

    @Test func derivesCrossRatesForNonEuroBaseCurrencies() {
        var file = PortfolioFile(
            settings: Settings(baseCurrency: "USD"),
            securities: [security("UK", symbol: "UK", currency: "GBP"), security("EU", symbol: "EU", currency: "EUR")],
            accounts: [Account(name: "Cash", currency: "USD")]
        )
        let result = UpdateResult(exchangeRates: [
            ExchangeRateSeries(base: "EUR", quote: "USD", days: [10, 11, 12], rates: [1.25, 1.0, 2.0]),
            ExchangeRateSeries(base: "EUR", quote: "GBP", days: [11, 12, 13], rates: [0.8, 0.9, 0.85]),
        ])
        #expect(apply(result, to: &file).rates == 6)
        #expect(file.exchangeRates.count == 4)
        #expect(file.exchangeRates[2] == ExchangeRateSeries(base: "USD", quote: "GBP", days: [11, 12], rates: [0.8, 0.45]))
        #expect(file.exchangeRates[3] == ExchangeRateSeries(base: "USD", quote: "EUR", days: [10, 11, 12], rates: [0.8, 1.0, 0.5]))

        // A later update extends the derived series in place.
        let later = UpdateResult(exchangeRates: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [13], rates: [1.7])])
        apply(later, to: &file)
        #expect(file.exchangeRates.count == 4)
        #expect(file.exchangeRates[2] == ExchangeRateSeries(base: "USD", quote: "GBP", days: [11, 12, 13], rates: [0.8, 0.45, 0.5]))
        #expect(file.exchangeRates[3].days == [10, 11, 12, 13])
    }

    @Test func rateLookupTriangulates() {
        let file = PortfolioFile(exchangeRates: [
            ExchangeRateSeries(base: "EUR", quote: "USD", days: [10], rates: [1.25]),
            ExchangeRateSeries(base: "EUR", quote: "GBP", days: [10], rates: [0.8]),
        ])
        let d = Day(rawValue: 10)
        #expect(ExchangeRates.rate(from: "EUR", to: "EUR", on: d, in: file) == 1)
        #expect(ExchangeRates.rate(from: "EUR", to: "USD", on: d, in: file) == 1.25)
        #expect(ExchangeRates.rate(from: "USD", to: "EUR", on: d, in: file) == 0.8)
        #expect(ExchangeRates.rate(from: "USD", to: "GBP", on: d, in: file) == 0.64)
        #expect(ExchangeRates.rate(from: "USD", to: "JPY", on: d, in: file) == nil)
        let cross = ExchangeRates.triangulate(base: "EUR", quote: "USD", pivotToBase: nil, pivotToQuote: file.exchangeRates[0])
        #expect(cross == file.exchangeRates[0])
    }
}

@Suite struct SuggesterTests {
    private func yahoo(_ configure: (StubHTTPClient) -> Void) -> (YahooProvider, StubHTTPClient) {
        let http = StubHTTPClient()
        configure(http)
        return (YahooProvider(http: http), http)
    }

    @Test func prefersTheListingInTheSecurityCurrency() async throws {
        let (provider, http) = yahoo { http in
            http.on("search?q=IE00B4L5Y983", body: fixture("yahoo_search_isin.json"))
            http.on("search?q=iShares", text: #"{"quotes":[{"exchange":"LSE","quoteType":"ETF","symbol":"IWDA.L","longname":"iShares Core MSCI World UCITS ETF USD (Acc)"},{"exchange":"GER","quoteType":"ETF","symbol":"EUNL.DE","longname":"iShares Core MSCI World UCITS ETF USD (Acc)","exchDisp":"XETRA"},{"exchange":"AMS","quoteType":"ETF","symbol":"IWDA.AS","longname":"iShares Core MSCI World UCITS ETF USD (Acc)"},{"exchange":"GER","quoteType":"ETF","symbol":"OTHER.DE","longname":"iShares Something Else"}]}"#)
            http.on("/chart/EUNL.DE", body: fixture("yahoo_chart_EUNL.DE.json"))
        }
        let etf = Security(name: "iShares Core MSCI World", currency: "EUR", isin: "IE00B4L5Y983")
        let suggestions = try await FeedSuggester(yahoo: provider).suggestions(for: etf)
        #expect(suggestions.map(\.match.symbol) == ["EUNL.DE", "IWDA.AS", "IWDA.L"])
        #expect(suggestions[0].feed == QuoteFeed(provider: "yahoo", symbol: "EUNL.DE"))
        #expect(suggestions[0].isVerified)
        #expect(suggestions[0].currency == "EUR")
        #expect(suggestions[1].currency == "EUR")
        #expect(!suggestions[1].isVerified) // verification stops at the first confirmed match
        #expect(suggestions[2].currency == nil) // London trades in several currencies
        #expect(http.requestedURLs.filter { $0.contains("/chart/") }.count == 1)
    }

    @Test func demotesListingsConfirmedInAnotherCurrency() async throws {
        let (provider, _) = yahoo { http in
            http.on("search?q=VOD", text: #"{"quotes":[{"exchange":"LSE","quoteType":"EQUITY","symbol":"VOD.L","longname":"Vodafone Group"},{"exchange":"NMS","quoteType":"EQUITY","symbol":"VOD","longname":"Vodafone Group ADR"}]}"#)
            http.on("/chart/VOD.L", body: fixture("yahoo_chart_VOD.L.json"))
            http.on("/chart/VOD?", body: fixture("yahoo_chart_AAPL.json"))
        }
        // Pence quotes are converted, so London matches a GBP security …
        let pounds = try await FeedSuggester(yahoo: provider).suggestFeed(for: Security(name: "Vodafone", currency: "GBP", ticker: "VOD"))
        #expect(pounds == QuoteFeed(provider: "yahoo", symbol: "VOD.L"))
        // … while a USD security gets the US listing.
        let dollars = try await FeedSuggester(yahoo: provider).suggestions(for: Security(name: "Vodafone", currency: "USD", ticker: "VOD"))
        #expect(dollars.map(\.match.symbol) == ["VOD", "VOD.L"])
        #expect(dollars[0].isVerified)
    }

    @Test func fallsBackToTheNameAndSkipsDerivatives() async throws {
        let (provider, http) = yahoo { http in
            http.on("search?q=apple", body: fixture("yahoo_search_apple.json"))
        }
        let suggestions = try await FeedSuggester(search: provider, quotes: nil).suggestions(for: Security(name: "apple", currency: "USD"))
        #expect(suggestions.first?.match.symbol == "AAPL")
        let symbols = suggestions.map(\.match.symbol)
        #expect(symbols.firstIndex(of: "SAAPL=F")! > symbols.firstIndex(of: "APLE")!) // derivatives rank below shares
        #expect(suggestions.allSatisfy { !$0.isVerified })
        #expect(http.requests.count == 1)
    }

    @Test func returnsNothingOrTheSearchError() async throws {
        let (empty, _) = yahoo { $0.on("search", text: #"{"quotes":[]}"#) }
        #expect(try await FeedSuggester(yahoo: empty).suggestFeed(for: Security(name: "Nothing", currency: "EUR", ticker: "ZZZ")) == nil)
        #expect(try await FeedSuggester(yahoo: empty).suggestions(for: Security(name: "", currency: "EUR")).isEmpty)
        let (down, _) = yahoo { $0.on("search", status: 500) }
        await #expect(throws: MarketDataError.self) {
            _ = try await FeedSuggester(yahoo: down).suggestions(for: Security(name: "X", currency: "EUR", ticker: "X"))
        }
    }

    @Test func exchangeDirectory() {
        #expect(ExchangeDirectory.currency(of: SymbolMatch(symbol: "EUNL.DE", name: "", exchange: "GER", provider: "yahoo")) == "EUR")
        #expect(ExchangeDirectory.currency(of: SymbolMatch(symbol: "AAPL", name: "", exchange: "NMS", provider: "yahoo")) == "USD")
        #expect(ExchangeDirectory.currency(of: SymbolMatch(symbol: "IWDA.L", name: "", exchange: "LSE", provider: "yahoo")) == nil)
        #expect(ExchangeDirectory.currency(of: SymbolMatch(symbol: "BTC-EUR", name: "", exchange: "CCC", type: .crypto, provider: "yahoo")) == "EUR")
        #expect(ExchangeDirectory.currency(of: SymbolMatch(symbol: "EURUSD=X", name: "", exchange: "CCY", type: .currency, provider: "yahoo")) == "USD")
    }
}
