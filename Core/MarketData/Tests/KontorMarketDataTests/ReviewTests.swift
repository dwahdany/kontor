import Foundation
import KontorModel
import Testing
@testable import KontorMarketData

/// Regression tests for defects found in review.

/// A clock that stands still at 0 and whose `sleep` really suspends (until cancelled) while
/// `blocks` is set.
private final class BlockingClock: MarketDataClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var blocking = true

    var sleeps: [TimeInterval] { lock.withLock { recorded } }
    func unblock() { lock.withLock { blocking = false } }

    func now() -> TimeInterval { 0 }
    func sleep(seconds: TimeInterval) async throws {
        let block = lock.withLock {
            recorded.append(seconds)
            return blocking
        }
        if block { try await Task.sleep(nanoseconds: 60_000_000_000) }
    }
}

@Suite struct ThrottleReviewTests {
    @Test func cancelledWaitersGiveTheirSlotsBack() async throws {
        let stub = StubHTTPClient()
        stub.on("example.com", status: 200)
        let clock = BlockingClock()
        let http = ResilientHTTPClient(stub, retry: .none, throttle: ThrottlePolicy(defaultInterval: 10), clock: clock)
        let url = URL(string: "https://example.com/x")!

        _ = try await http.send(HTTPRequest(url: url)) // takes the slot at t = 0
        // Five more requests queue up for the slots at 10 … 50 s; then the update is cancelled.
        let waiters = (0..<5).map { _ in Task { try await http.send(HTTPRequest(url: url)) } }
        while clock.sleeps.count < 5 { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(clock.sleeps.sorted() == [10, 20, 30, 40, 50])
        for waiter in waiters { waiter.cancel() }
        for waiter in waiters {
            await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        }
        #expect(stub.requests.count == 1)

        // The next request gets the first free slot (10 s), not one behind the abandoned queue (60 s).
        clock.unblock()
        _ = try await http.send(HTTPRequest(url: url))
        #expect(clock.sleeps.last == 10)
    }

    @Test func aCancelledWaiterInTheMiddleKeepsLaterSlotsIntact() async throws {
        let stub = StubHTTPClient()
        stub.on("example.com", status: 200)
        let clock = BlockingClock()
        let http = ResilientHTTPClient(stub, retry: .none, throttle: ThrottlePolicy(defaultInterval: 10), clock: clock)
        let url = URL(string: "https://example.com/x")!
        _ = try await http.send(HTTPRequest(url: url))
        let first = Task { try await http.send(HTTPRequest(url: url)) }
        while clock.sleeps.count < 1 { try await Task.sleep(nanoseconds: 1_000_000) }
        let second = Task { try await http.send(HTTPRequest(url: url)) }
        while clock.sleeps.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        first.cancel()
        _ = try? await first.value
        // `second` still holds the slot at 20 s, so a newcomer must queue behind it.
        clock.unblock()
        _ = try await http.send(HTTPRequest(url: url))
        #expect(clock.sleeps == [10, 20, 30])
        second.cancel()
    }
}

@Suite struct YahooReviewTests {
    private let range = day("2024-01-03")...day("2024-01-10")
    private func request(_ symbol: String = "AAPL") -> QuoteRequest {
        QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: symbol), currency: "USD", range: range)
    }

    /// Yahoo answers a window that starts after "now" with HTTP 400 and this body (recorded
    /// 2026-11-18). That is "no new quotes", not a failure of the security.
    @Test func aWindowWithoutDataIsAnEmptyHistory() async throws {
        let body = #"{"chart":{"result":null,"error":{"code":"Bad Request","description":"Data doesn't exist for startDate = 1795046400, endDate = 1795305600"}}}"#
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/AAPL", status: 400, text: body)
        let history = try await YahooProvider(http: http).history(request())
        #expect(history.points.isEmpty)
        #expect(history.events.isEmpty)
        #expect(http.requests.count == 1)
        // Other 400s stay errors.
        let other = StubHTTPClient()
        other.on("/v8/finance/chart/AAPL", status: 400, text: #"{"chart":{"result":null,"error":{"code":"Bad Request","description":"Invalid input - interval=1x is not supported"}}}"#)
        await #expect(throws: MarketDataError.malformedResponse("Invalid input - interval=1x is not supported")) {
            _ = try await YahooProvider(http: other).history(request())
        }
    }

    @Test func serverErrorsWithAnErrorDocumentStillFallBackToTheSecondHost() async throws {
        let http = StubHTTPClient()
        http.on("query1.finance.yahoo.com", status: 500, text: #"{"chart":{"result":null,"error":{"code":"Internal Server Error","description":"backend unavailable"}}}"#)
        http.on("query2.finance.yahoo.com", body: fixture("yahoo_chart_AAPL.json"))
        let history = try await YahooProvider(http: http).history(request())
        #expect(history.points.count == 6) // Jan 3, 4, 5, 8, 9, 10
        #expect(http.requests.map(\.url.host) == ["query1.finance.yahoo.com", "query2.finance.yahoo.com"])
    }

    @Test func symbolsAreEscapedInThePath() async throws {
        let http = StubHTTPClient()
        http.on("finance.yahoo.com", body: fixture("yahoo_chart_AAPL.json"))
        let yahoo = YahooProvider(http: http)
        for symbol in ["EURUSD=X", "BRK-B", "^GDAXI", "RDS/A", "A B?c=d&e#f", "ÅKER.OL", "ES=F"] {
            _ = try await yahoo.history(request(symbol))
        }
        let paths = http.requests.map { $0.url.absoluteString.dropFirst("https://query1.finance.yahoo.com/v8/finance/chart/".count).prefix { $0 != "?" } }
        #expect(paths == ["EURUSD=X", "BRK-B", "%5EGDAXI", "RDS%2FA", "A%20B%3Fc=d%26e%23f", "%C3%85KER.OL", "ES=F"])
        // (“=” is legal inside a path segment and part of many Yahoo symbols.) The query is never polluted by the symbol.
        #expect(http.requests.allSatisfy { $0.url.query == "period1=1704153600&period2=1705017600&interval=1d&events=div%2Csplits" })
    }

    /// Sydney trades 10:00–16:00 local time, i.e. the daily bar of Monday 2026-11-16 is stamped
    /// Sunday 23:00 UTC; a second, live bar for the same local day follows during the session
    /// (response shape recorded 2026-11-18 for BHP.AX).
    @Test func barsOfExchangesAheadOfUTCLandOnTheLocalDay() throws {
        let json = #"""
        {"chart":{"result":[{"meta":{"currency":"AUD","gmtoffset":39600,"exchangeTimezoneName":"Australia/Sydney",
        "regularMarketPrice":54.34,"regularMarketTime":1794979188},
        "timestamp":[1794524400,1794783600,1794956400,1794979188],
        "indicators":{"quote":[{"close":[58.86000061035156,57.209999084472656,55.0,54.34000015258789]}]}}],"error":null}}
        """#
        let history = try YahooProvider.parseChart(Data(json.utf8), symbol: "BHP.AX", range: day("2026-11-01")...day("2026-11-30"), securityCurrency: "AUD")
        // Independently: 1794524400 = 2026-11-12T23:00Z = Fri 13th 10:00 AEDT; 1794783600 = Mon 16th;
        // 1794956400 = 2026-11-17T23:00Z = Wed 18th 10:00; 1794979188 = Wed 18th 16:19 (live bar wins).
        #expect(history.points == [point("2026-11-13", 58.86), point("2026-11-16", 57.21), point("2026-11-18", 54.34)])
        #expect(history.latest?.point == point("2026-11-18", 54.34))
    }
}

@Suite struct UpdaterReviewTests {
    private let today = day("2024-01-15")

    @Test func aConcurrencyLimitOfZeroStillRuns() async {
        let provider = FakeProvider { request in QuoteHistory(points: [PricePoint(day: request.range.upperBound, price: Price(10))]) }
        var updater = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil)
        updater.options.maxConcurrentDownloads = 0 // bypasses the clamp in UpdateOptions.init
        let securities = (0..<3).map { security("S\($0)", symbol: "S\($0)") }
        let result = await updater.update(PortfolioFile(securities: securities), today: today)
        #expect(result.newPriceCount == 3)
        #expect(!result.wasCancelled)
    }

    @Test func cancellingAfterTheWorkIsDoneIsNotAPartialResult() async {
        let provider = FakeProvider { _ in QuoteHistory(points: [point("2024-01-12", 10)]) }
        let updater = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil)
        let file = PortfolioFile(securities: [security("A", symbol: "A")])
        let finished = Collector<UpdateStatus>()
        let gate = Collector<Bool>()
        let task = Task {
            await updater.update(file, today: today) { progress in
                if progress.status.isFinal {
                    finished.add(progress.status)
                    // Hold the run right after its last target completed until the test has cancelled it.
                    while gate.all.isEmpty { Thread.sleep(forTimeInterval: 0.001) }
                }
            }
        }
        while finished.all.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        gate.add(true)
        let result = await task.value
        #expect(result.statuses.values.allSatisfy { $0 == .success(newPoints: 1) })
        #expect(!result.wasCancelled) // every target finished: nothing is missing from the result
    }

    /// "Reload history": a security that already has prices (a single hand-entered one, or a
    /// series from before a split) can be re-synchronised from the start of its history.
    @Test func fullHistoryCanBeReloaded() async {
        let provider = FakeProvider { request in
            QuoteHistory(points: [point("2024-01-08", 5), point("2024-01-09", 6), point("2024-01-10", 7)].filter { request.range.contains($0.day) })
        }
        // Stored: the 9th at an outdated value and the 10th as downloaded.
        let stored = security("A", symbol: "A", prices: [point("2024-01-09", 12), point("2024-01-10", 7)], updatedAt: date("2024-01-12T09:00:00Z"))
        var file = PortfolioFile(securities: [stored, security("B", symbol: "B", prices: [point("2024-01-10", 7)], updatedAt: date("2024-01-12T09:00:00Z"))])

        let normal = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil)
        #expect(normal.plan(for: file, today: today).securities[0].request?.range == day("2024-01-11")...today)

        let options = UpdateOptions(historyStart: .day(day("2024-01-01")), reloadsFullHistory: true)
        let reload = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil, options: options)
        let plan = reload.plan(for: file, today: today, only: [stored.id])
        #expect(plan.securities.map(\.request?.range) == [day("2024-01-01")...today])
        let result = await reload.run(plan, file: file)
        // Only what differs from the stored series is reported: the new 8th and the corrected 9th.
        #expect(result.securities.first?.points == [point("2024-01-08", 5), point("2024-01-09", 6)])
        #expect(apply(result, to: &file).prices == 2)
        #expect(Array(file.securities[0].prices) == [point("2024-01-08", 5), point("2024-01-09", 6), point("2024-01-10", 7)])
        #expect(file.securities[1].prices.count == 1)
    }

    @Test func aPriceDatedAfterTodayNeedsNoRequest() {
        let provider = FakeProvider { _ in QuoteHistory() }
        let updater = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil)
        let ahead = security("A", symbol: "A", prices: [point("2024-01-16", 1)]) // today is the 15th
        let onTheDay = security("B", symbol: "B", prices: [point("2024-01-15", 1)])
        let yesterday = security("C", symbol: "C", prices: [point("2024-01-14", 1)])
        let plan = updater.plan(for: PortfolioFile(securities: [ahead, onTheDay, yesterday]), today: today)
        #expect(plan.securities.map(\.request?.range) == [nil, nil, today...today])
        #expect(plan.hasWork)
    }

    /// Dropping the stream (the consumer's task is cancelled, a view disappears) must stop the
    /// downloads instead of letting them run on unobserved.
    @Test func abandoningTheStreamCancelsTheDownloads() async throws {
        let cancelled = Collector<Bool>()
        let started = Collector<Bool>()
        let provider = FakeProvider { _ in
            started.add(true)
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                cancelled.add(true)
                throw error
            }
            return QuoteHistory()
        }
        let updater = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil)
        let file = PortfolioFile(securities: [security("A", symbol: "A"), security("B", symbol: "B")])
        let consumer = Task {
            for await _ in updater.updates(for: file, today: today) {}
        }
        while started.all.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        consumer.cancel()
        await consumer.value
        let deadline = Date().addingTimeInterval(5)
        while cancelled.all.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(cancelled.all.count == 2)
    }

    @Test func rateFailuresDoNotAffectSecuritiesAndViceVersa() async {
        let provider = FakeProvider { request in
            if request.feed.symbol == "BAD" { throw MarketDataError.timeout }
            return QuoteHistory(points: [point("2024-01-12", 10)])
        }
        let failingRates = FakeRates { _ in throw MarketDataError.http(status: 503, host: "www.ecb.europa.eu") }
        let good = security("Good", symbol: "GOOD", currency: "USD"), bad = security("Bad", symbol: "BAD")
        var file = PortfolioFile(securities: [good, bad])
        let result = await QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: failingRates).update(file, today: today)
        #expect(result.statuses == [
            .exchangeRates: .failed(message: "www.ecb.europa.eu answered with HTTP 503."),
            .security(good.id): .success(newPoints: 1),
            .security(bad.id): .failed(message: "The server did not answer in time."),
        ])
        #expect(result.failures.count == 2)
        #expect(!result.wasCancelled)
        let summary = apply(result, to: &file)
        #expect(summary.prices == 1 && summary.rates == 0)
        #expect(file.securities[1].updatedAt == nil) // a failed security keeps its stamp
    }

    @Test func splitAndDividendOnTheSameDayAreBothKept() async {
        let provider = FakeProvider { _ in
            QuoteHistory(events: [
                QuoteEvent(day: day("2024-01-10"), kind: .dividend, detail: "0.5"),
                QuoteEvent(day: day("2024-01-10"), kind: .split, detail: "2:1"),
                QuoteEvent(day: day("2024-01-10"), kind: .dividend, detail: "0.5"), // duplicate in the response
            ])
        }
        let updater = QuoteUpdater(registry: ProviderRegistry([provider]), rateProvider: nil)
        var file = PortfolioFile(securities: [security("A", symbol: "A")])
        let result = await updater.update(file, today: today)
        #expect(result.securities.first?.events.count == 2)
        #expect(apply(result, to: &file).events == 2)
        #expect(Set(file.securities[0].events.map(\.kind)) == [.dividend, .split])
    }
}

@Suite struct CrossRateReviewTests {
    private func dollarFile() -> PortfolioFile {
        PortfolioFile(
            settings: Settings(baseCurrency: "USD"),
            securities: [security("UK", symbol: "UK", currency: "GBP")],
            accounts: [Account(name: "Cash", currency: "USD")]
        )
    }

    /// A `base → X` series may hold rates that did not come from the ECB (imported from another
    /// program, or older than the ECB's history). Deriving cross rates must not wipe them.
    @Test func derivedRatesAreMergedIntoExistingSeries() {
        var file = dollarFile()
        file.exchangeRates = [ExchangeRateSeries(base: "USD", quote: "GBP", days: [5, 11], rates: [0.61, 0.99])]
        let result = UpdateResult(exchangeRates: [
            ExchangeRateSeries(base: "EUR", quote: "USD", days: [11, 12], rates: [1.0, 2.0]),
            ExchangeRateSeries(base: "EUR", quote: "GBP", days: [11, 12], rates: [0.8, 0.9]),
        ])
        apply(result, to: &file)
        // Day 5 survives; day 11 is replaced by the reference rate 0.8 / 1.0; day 12 = 0.9 / 2.0 is added.
        #expect(file.exchangeRates[0] == ExchangeRateSeries(base: "USD", quote: "GBP", days: [5, 11, 12], rates: [0.61, 0.8, 0.45]))
    }

    /// The base currency was switched to USD after the euro rates had been downloaded: the next
    /// update brings no new rates, but the derived series must still appear.
    @Test func crossRatesAreDerivedEvenWithoutNewRates() {
        var file = dollarFile()
        file.exchangeRates = [
            ExchangeRateSeries(base: "EUR", quote: "USD", days: [11, 12], rates: [1.0, 2.0]),
            ExchangeRateSeries(base: "EUR", quote: "GBP", days: [11, 12], rates: [0.8, 0.9]),
        ]
        let upToDate = UpdateResult(statuses: [.exchangeRates: .success(newPoints: 0)])
        let summary = apply(upToDate, to: &file)
        #expect(summary.rates == 0)
        #expect(summary.derivedRates == 2)
        #expect(summary.hasChanges)
        #expect(file.exchangeRates.last == ExchangeRateSeries(base: "USD", quote: "GBP", days: [11, 12], rates: [0.8, 0.45]))
        // Idempotent.
        let again = apply(upToDate, to: &file)
        #expect(!again.hasChanges)
        #expect(again.derivedRates == 0)
    }

    @Test func euroFilesNeverGetDerivedSeries() {
        var file = PortfolioFile(securities: [security("US", symbol: "US", currency: "USD"), security("UK", symbol: "UK", currency: "GBP")])
        let result = UpdateResult(exchangeRates: [
            ExchangeRateSeries(base: "EUR", quote: "USD", days: [11], rates: [1.1]),
            ExchangeRateSeries(base: "EUR", quote: "GBP", days: [11], rates: [0.8]),
        ], statuses: [.exchangeRates: .success(newPoints: 2)])
        let summary = apply(result, to: &file)
        #expect(summary.rates == 2 && summary.derivedRates == 0)
        #expect(file.exchangeRates.map { $0.base + $0.quote } == ["EURUSD", "EURGBP"])
    }
}

@Suite struct ECBReviewTests {
    /// Calendar facts checked independently (python `datetime`): 2026-04-02 is a Thursday,
    /// Good Friday is 04-03, Easter Monday 04-06, the next publication Tuesday 04-07.
    @Test func feedSelectionAcrossWeekendsAndHolidays() {
        let thursday = day("2026-04-02"), tuesday = day("2026-04-07")
        #expect(thursday.weekday == 4 && tuesday.weekday == 2)
        // Last stored rate Thursday → wanted from Good Friday; the first publication after Easter
        // is four days later: the daily file alone would do, the 90-day file is the safe choice.
        #expect(ECBFeed.smallest(covering: thursday.advanced(by: 1), latestPublication: tuesday) == .last90Days)
        // Asked on Easter Sunday: the latest publication is still Thursday's → nothing to load.
        #expect(ECBFeed.smallest(covering: thursday.advanced(by: 1), latestPublication: thursday) == nil)
        // Friday → Monday over a plain weekend.
        #expect(ECBFeed.smallest(covering: day("2026-11-14"), latestPublication: day("2026-11-16")) == .daily)
        #expect(ECBFeed.smallest(covering: day("2026-11-15"), latestPublication: day("2026-11-16")) == .daily)
        // A real business day in between needs history.
        #expect(ECBFeed.smallest(covering: day("2026-11-13"), latestPublication: day("2026-11-16")) == .last90Days)
        // The 90-day file reached back 89 days when recorded (2026-08-21 … 2026-11-18); 80 are trusted.
        #expect(ECBFeed.smallest(covering: day("2026-11-18").advanced(by: -80), latestPublication: day("2026-11-18")) == .last90Days)
        #expect(ECBFeed.smallest(covering: day("2026-11-18").advanced(by: -81), latestPublication: day("2026-11-18")) == .full)
    }

    /// A gap that spans a holiday is filled from the history file, and only days on or after
    /// `from` are delivered, in ascending order.
    @Test func incrementalUpdateDeliversExactlyTheMissingDays() async throws {
        func cube(_ day: String, _ usd: String) -> String { "<Cube time=\"\(day)\"><Cube currency=\"USD\" rate=\"\(usd)\"/></Cube>" }
        let http = StubHTTPClient()
        http.on("eurofxref-daily.xml", text: "<Cube>" + cube("2026-04-08", "1.10") + "</Cube>")
        http.on("eurofxref-hist-90d.xml", text: "<Cube>" + [cube("2026-04-08", "1.10"), cube("2026-04-07", "1.09"), cube("2026-04-02", "1.08"), cube("2026-04-01", "1.07")].joined() + "</Cube>")
        let batch = try await ECBProvider(http: http).rates(for: [RateRequest(currency: "USD", from: day("2026-04-03"), hasHistory: true)])
        #expect(batch.series == [ExchangeRateSeries(base: "EUR", quote: "USD", days: [day("2026-04-07").rawValue, day("2026-04-08").rawValue], rates: [1.09, 1.10])])
    }
}

@Suite struct DatePatternReviewTests {
    /// People paste full timestamp patterns. `mm` (minutes) must not be taken for a month, and
    /// the time part must be optional in the data.
    @Test func timePartsInPatternsAreIgnored() throws {
        let iso = try #require(DatePattern("yyyy-MM-dd'T'HH:mm:ss"))
        #expect(iso.parse("2024-01-31T16:45:00") == day("2024-01-31"))
        #expect(iso.parse("2024-01-31T16:45:00+01:00") == day("2024-01-31"))
        #expect(iso.parse("2024-01-31") == day("2024-01-31"))
        let german = try #require(DatePattern("dd.MM.yyyy HH:mm"))
        #expect(german.parse("31.01.2024 16:45") == day("2024-01-31"))
        #expect(german.parse("31.01.2024") == day("2024-01-31"))
        #expect(german.parse("31.13.2024 16:45") == nil)
        #expect(DateFormat(option: "MM/dd/yyyy hh:mm")?.parse("01/31/2024 04:45") == day("2024-01-31"))
        // Formatting (URL templates) keeps literals up to the time fields.
        #expect(DatePattern("yyyy-MM-dd'T'00:00")?.format(day("2024-01-31")) == "2024-01-31T00:00")
        // The same field twice inside the date is a mistake.
        #expect(DatePattern("dd.dd.yyyy") == nil)
        #expect(DatePattern("yyyy-yy-dd") == nil)
    }
}

/// Shapes of real-world exports that the sniffer has to get right without any options.
@Suite struct CSVReviewTests {
    @Test func investingStyleExportWithQuotedDatesAndThousands() throws {
        let csv = """
            "Date","Price","Open","High","Low","Vol.","Change %"
            "Jan 04, 2024","4,688.68","4,697.42","4,726.78","4,687.53","","-0.34%"
            "Jan 03, 2024","4,704.81","4,725.07","4,729.29","4,699.71","","-0.80%"
            "Jan 02, 2024","4,742.83","4,745.20","4,754.33","4,722.67","","-0.57%"
            """
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 4742.83), point("2024-01-03", 4704.81), point("2024-01-04", 4688.68)])
    }

    @Test func germanExportWithThousandsPointsAndTimeColumn() throws {
        let csv = """
            Datum;Zeit;Eröffnung;Hoch;Tief;Schluss;Volumen
            04.01.2024;17:35;16.617,29;16.682,53;16.585,37;16.617,29;58.123.456
            03.01.2024;17:35;16.701,63;16.714,89;16.482,32;16.538,39;71.234.567
            """
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-03", 16538.39), point("2024-01-04", 16617.29)])
    }

    @Test func yahooStyleDownloadPrefersCloseOverAdjustedClose() throws {
        let csv = """
            Date,Open,High,Low,Close,Adj Close,Volume
            2024-01-02,187.149994,188.440002,183.889999,185.639999,184.734970,82488700
            2024-01-03,null,null,null,null,null,null
            2024-01-04,182.149994,183.089996,180.880005,181.910004,181.023163,71983600
            """
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 185.639999), point("2024-01-04", 181.910004)])
    }

    @Test func timestampsWithTimesAndCRLF() throws {
        let csv = "timestamp,nav\r\n2024-01-02T00:00:00Z,101.5\r\n2024-01-03 18:00:00,102.25\r\n\r\n"
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 101.5), point("2024-01-03", 102.25)])
    }

    @Test func singleDataRowAndUnixSeconds() throws {
        // 1704153600 = 2024-01-02T00:00:00Z
        #expect(try CSVQuoteParser.parse("1704153600;82,21\n") == [point("2024-01-02", 82.21)])
    }
}
