import Foundation
import KontorModel
import Testing
@testable import KontorMarketData

private let wide = day("1990-01-01")...day("2100-01-01")

@Suite struct YahooTests {
    @Test func parsesUSEquityChart() throws {
        let history = try YahooProvider.parseChart(fixture("yahoo_chart_AAPL.json"), symbol: "AAPL", range: wide, securityCurrency: "USD")
        #expect(history.points == [
            point("2024-01-02", 185.64), point("2024-01-03", 184.25), point("2024-01-04", 181.91), point("2024-01-05", 181.18),
            point("2024-01-08", 185.56), point("2024-01-09", 185.14), point("2024-01-10", 186.19), point("2024-01-11", 185.59),
            point("2024-01-12", 185.92),
        ])
        #expect(history.points[0].price.raw == 18_564_000_000)
        #expect(history.currency == "USD")
        #expect(history.name == "Apple Inc.")
        #expect(history.exchange == "NasdaqGS")
        #expect(history.events.isEmpty)
        // Latest quote from the meta block: 2026-11-18 16:00:01 New York time.
        #expect(history.latest?.point == point("2026-11-18", 352.45))
        #expect(history.latest?.time == Date(timeIntervalSince1970: 1_795_035_601))
        #expect(history.latest?.currency == "USD")
    }

    @Test func parsesXetraETFChart() throws {
        let history = try YahooProvider.parseChart(fixture("yahoo_chart_EUNL.DE.json"), symbol: "EUNL.DE", range: wide, securityCurrency: "EUR")
        #expect(history.points.count == 9)
        #expect(history.points.first == point("2024-01-02", 82.216))
        #expect(history.points.last == point("2024-01-12", 82.684))
        #expect(history.points.map(\.day.iso) == ["2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05", "2024-01-08", "2024-01-09", "2024-01-10", "2024-01-11", "2024-01-12"])
        #expect(history.currency == "EUR")
        #expect(history.name == "iShares Core MSCI World UCITS ETF USD (Acc)")
        #expect(history.exchange == "XETRA")
    }

    @Test func surfacesDividendsAndSplits() throws {
        let history = try YahooProvider.parseChart(fixture("yahoo_chart_AAPL_events.json"), symbol: "AAPL", range: wide, securityCurrency: "USD")
        #expect(history.points.count == 22)
        #expect(history.points.first == point("2020-08-03", 108.9375))
        #expect(history.points.last == point("2020-09-01", 134.18))
        #expect(history.events == [
            QuoteEvent(day: day("2020-08-07"), kind: .dividend, detail: "0.205"),
            QuoteEvent(day: day("2020-08-31"), kind: .split, detail: "4:1"),
        ])
    }

    @Test func restrictsPointsAndEventsToTheRange() throws {
        let range = day("2020-08-10")...day("2020-08-14")
        let history = try YahooProvider.parseChart(fixture("yahoo_chart_AAPL_events.json"), symbol: "AAPL", range: range, securityCurrency: "USD")
        #expect(history.points.map(\.day.iso) == ["2020-08-10", "2020-08-11", "2020-08-12", "2020-08-13", "2020-08-14"])
        #expect(history.events.isEmpty)
    }

    @Test func convertsPenceToPounds() throws {
        let data = fixture("yahoo_chart_VOD.L.json")
        let pounds = try YahooProvider.parseChart(data, symbol: "VOD.L", range: wide, securityCurrency: "GBP")
        #expect(pounds.currency == "GBP")
        #expect(pounds.points == [
            point("2024-01-02", 0.6976), point("2024-01-03", 0.6951), point("2024-01-04", 0.7045), point("2024-01-05", 0.704),
            point("2024-01-08", 0.6998), point("2024-01-09", 0.7001),
        ])
        #expect(pounds.latest?.point.price == Price(1.1405))

        // A security kept in pence keeps the quotes as delivered.
        let pence = try YahooProvider.parseChart(data, symbol: "VOD.L", range: wide, securityCurrency: "GBX")
        #expect(pence.currency == "GBX")
        #expect(pence.points.first == point("2024-01-02", 69.76))
    }

    @Test func minorCurrencyRules() {
        #expect(MinorCurrency.resolve(reported: "GBp", securityCurrency: "GBP") == ("GBP", 100))
        #expect(MinorCurrency.resolve(reported: "GBp", securityCurrency: "EUR") == ("GBP", 100))
        #expect(MinorCurrency.resolve(reported: "GBp", securityCurrency: "GBX") == ("GBX", 1))
        #expect(MinorCurrency.resolve(reported: "ZAc", securityCurrency: "ZAR") == ("ZAR", 100))
        #expect(MinorCurrency.resolve(reported: "ILA", securityCurrency: "ILS") == ("ILS", 100))
        #expect(MinorCurrency.resolve(reported: "GBP", securityCurrency: "GBP") == ("GBP", 1))
        #expect(MinorCurrency.resolve(reported: nil, securityCurrency: "GBP") == (nil, 1))
        #expect(YahooProvider.amountText(2.5, divisor: 100) == "0.025")
        #expect(YahooProvider.amountText(0.205, divisor: 1) == "0.205")
    }

    @Test func usesExchangeTimeZoneIncludingDaylightSaving() {
        // 2024-07-01 00:00 Berlin summer time is 2024-06-30 22:00 UTC. The current (winter) offset
        // alone would put it on June 30th.
        var berlin = ExchangeZone(identifier: "Europe/Berlin", fallbackOffset: 3600)
        #expect(berlin.day(of: 1_719_784_800) == day("2024-07-01"))
        #expect(berlin.day(of: 1_704_182_400) == day("2024-01-02"))
        var fallback = ExchangeZone(identifier: nil, fallbackOffset: -18_000)
        #expect(fallback.day(of: 1_704_171_600) == day("2024-01-02")) // 05:00 UTC = midnight EST
        #expect(fallback.day(of: 1_704_171_599) == day("2024-01-01"))
        var unknown = ExchangeZone(identifier: "Nowhere/Land", fallbackOffset: 0)
        #expect(unknown.day(of: -1) == day("1969-12-31"))
    }

    @Test func skipsNullCloses() throws {
        let json = #"{"chart":{"result":[{"meta":{"currency":"EUR","gmtoffset":3600,"exchangeTimezoneName":"Europe/Berlin"},"timestamp":[1704182400,1704268800,1704355200],"indicators":{"quote":[{"close":[10.5,null,11.25]}]}}],"error":null}}"#
        let history = try YahooProvider.parseChart(Data(json.utf8), symbol: "X", range: wide, securityCurrency: "EUR")
        #expect(history.points == [point("2024-01-02", 10.5), point("2024-01-04", 11.25)])
        #expect(history.latest == nil)
    }

    @Test func mapsUnknownSymbols() async {
        #expect(throws: MarketDataError.symbolNotFound("NOPE")) {
            _ = try YahooProvider.parseChart(fixture("yahoo_chart_notfound.json"), symbol: "NOPE", range: wide, securityCurrency: "USD")
        }
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/NOPE", status: 404, body: fixture("yahoo_chart_notfound.json"))
        let provider = YahooProvider(http: http)
        let request = QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "NOPE"), currency: "USD", range: day("2024-01-01")...day("2024-01-31"))
        await #expect(throws: MarketDataError.symbolNotFound("NOPE")) { _ = try await provider.history(request) }
        #expect(http.requests.count == 1) // an unknown symbol is not retried on the second host
    }

    @Test func buildsChartRequests() async throws {
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/", body: fixture("yahoo_chart_AAPL.json"))
        let provider = YahooProvider(http: http)
        let range = day("2024-01-03")...day("2024-01-10")
        let history = try await provider.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "AAPL"), currency: "USD", range: range))
        #expect(history.points.first?.day == day("2024-01-03"))
        #expect(history.points.last?.day == day("2024-01-10"))
        // One day of padding before, two after (exchange-local days vs. UTC).
        #expect(http.requestedURLs == ["https://query1.finance.yahoo.com/v8/finance/chart/AAPL?period1=1704153600&period2=1705017600&interval=1d&events=div%2Csplits"])
        #expect(http.requests[0].headers["User-Agent"] == UserAgent.minimal)
        #expect(http.requests[0].headers["Cookie"] == nil)

        // Special characters are escaped; an empty symbol falls back to the ticker.
        _ = try? await provider.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: ""), currency: "USD", ticker: "^GSPC", range: range))
        #expect(http.requestedURLs.last?.contains("/chart/%5EGSPC?") == true)
        await #expect(throws: MarketDataError.self) {
            _ = try await provider.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: " "), currency: "USD", range: range))
        }
    }

    @Test func fallsBackToSecondHost() async throws {
        let http = StubHTTPClient()
        http.on("query1.finance.yahoo.com", status: 429)
        http.on("query2.finance.yahoo.com", body: fixture("yahoo_chart_AAPL.json"))
        let latest = try await YahooProvider(http: http).latest(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "AAPL"), currency: "USD", range: wide))
        #expect(latest.point == point("2026-11-18", 352.45))
        #expect(latest.name == "Apple Inc.")
        #expect(http.requestedURLs == [
            "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=1d&interval=1d",
            "https://query2.finance.yahoo.com/v8/finance/chart/AAPL?range=1d&interval=1d",
        ])

        let down = StubHTTPClient()
        down.on("finance.yahoo.com", status: 429)
        await #expect(throws: MarketDataError.rateLimited(host: "query2.finance.yahoo.com")) {
            _ = try await YahooProvider(http: down).search("apple")
        }
    }

    @Test func parsesSearchResults() throws {
        let matches = try YahooProvider.parseSearch(fixture("yahoo_search_apple.json"))
        #expect(matches.map(\.symbol) == ["AAPL", "SAAPL=F", "TAAPL=F", "XAAPL=F", "APLE", "AAPL.TO"])
        #expect(matches[0] == SymbolMatch(symbol: "AAPL", name: "Apple Inc.", exchange: "NMS", exchangeName: "NASDAQ", type: .equity, provider: "yahoo"))
        #expect(matches[1].type == .future)
        #expect(matches[2].name == "BTIC Apple Inc Stock Futures,De") // no long name: short name
        #expect(matches[0].feed == QuoteFeed(provider: "yahoo", symbol: "AAPL"))
    }

    @Test func looksUpByISIN() async throws {
        let http = StubHTTPClient()
        http.on("/v1/finance/search", body: fixture("yahoo_search_isin.json"))
        let provider = YahooProvider(http: http)
        let matches = try await provider.lookup(isin: " ie00b4l5y983 ")
        #expect(matches == [SymbolMatch(symbol: "IWDA.L", name: "iShares Core MSCI World UCITS ETF USD (Acc)", exchange: "LSE", exchangeName: "London", type: .etf, provider: "yahoo")])
        #expect(http.requestedURLs == ["https://query1.finance.yahoo.com/v1/finance/search?q=IE00B4L5Y983&quotesCount=12&newsCount=0&listsCount=0&enableFuzzyQuery=false"])
        #expect(try await provider.lookup(isin: "NOTANISIN").isEmpty)
        #expect(http.requests.count == 1)
    }

    @Test func validatesISINs() {
        #expect(ISIN.isPlausible("IE00B4L5Y983"))
        #expect(ISIN.isPlausible("US0378331005"))
        #expect(ISIN.isPlausible("DE0007164600"))
        #expect(!ISIN.isPlausible("US0378331006"))
        #expect(!ISIN.isPlausible("AAPL"))
        #expect(!ISIN.isPlausible("us0378331005"))
    }
}

@Suite struct ECBTests {
    @Test func parsesDailyFile() throws {
        let table = try ECBProvider.parse(fixture("ecb_daily.xml"))
        #expect(table.count == 29)
        let d = day("2026-11-18").rawValue
        #expect(table["USD"] == ECBProvider.Column(days: [d], rates: [1.0968]))
        #expect(table["JPY"]?.rates == [174.85])
        #expect(table["GBP"]?.rates == [0.8329])
        #expect(table["IDR"]?.rates == [20020.71])
        #expect(table["ZAR"]?.rates == [18.8897])
        #expect(table["EUR"] == nil)
    }

    @Test func parsesHistoryFileAscending() throws {
        let table = try ECBProvider.parse(fixture("ecb_90d.xml"), currencies: ["USD", "GBP"])
        #expect(Set(table.keys) == ["USD", "GBP"])
        let days = ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-16", "2026-11-17", "2026-11-18"].map { day($0).rawValue }
        #expect(table["GBP"] == ECBProvider.Column(days: days, rates: [0.8343, 0.83545, 0.83618, 0.83595, 0.83559, 0.8345, 0.83305, 0.8329]))
        #expect(table["USD"]?.days == days)
        #expect(table["USD"]?.rates[1] == 1.1214)
        #expect(table["USD"]?.rates[6] == 1.0989)
        #expect(table["USD"]?.rates[7] == 1.0968)
    }

    @Test func toleratesSingleQuotesGapsAndGarbage() throws {
        let xml = "<Cube><Cube time='2024-01-03'><Cube currency='USD' rate='1.0919'/><Cube currency='RUB' rate='N/A'/></Cube><Cube time=\"2024-01-02\"><Cube rate=\"1.0956\" currency=\"USD\"/></Cube></Cube>"
        let table = try ECBProvider.parse(Data(xml.utf8))
        #expect(table == ["USD": ECBProvider.Column(days: [day("2024-01-02").rawValue, day("2024-01-03").rawValue], rates: [1.0956, 1.0919])])
        #expect(throws: MarketDataError.self) { _ = try ECBProvider.parse(Data("<html>Service unavailable</html>".utf8)) }
    }

    @Test func picksSmallestFeed() {
        let latest = day("2026-11-18") // a Wednesday
        #expect(ECBFeed.smallest(covering: day("2026-11-19"), latestPublication: latest) == nil)
        #expect(ECBFeed.smallest(covering: latest, latestPublication: latest) == .daily)
        #expect(ECBFeed.smallest(covering: day("2026-11-17"), latestPublication: latest) == .last90Days)
        #expect(ECBFeed.smallest(covering: day("2026-08-30"), latestPublication: latest) == .last90Days)
        #expect(ECBFeed.smallest(covering: day("2026-08-29"), latestPublication: latest) == .full)
        #expect(ECBFeed.smallest(covering: day("1999-01-04"), latestPublication: latest) == .full)
        // Saturday → Monday: only Monday's publication can be missing.
        #expect(ECBFeed.smallest(covering: day("2026-11-14"), latestPublication: day("2026-11-16")) == .daily)
        #expect(ECBFeed.smallest(covering: day("2026-11-15"), latestPublication: day("2026-11-16")) == .daily)
        #expect(ECBFeed.smallest(covering: day("2026-11-13"), latestPublication: day("2026-11-16")) == .last90Days)
    }

    private func stub() -> StubHTTPClient {
        let http = StubHTTPClient()
        http.on("eurofxref-daily.xml", body: fixture("ecb_daily.xml"))
        http.on("eurofxref-hist-90d.xml", body: fixture("ecb_90d.xml"))
        http.on("eurofxref-hist.xml", body: fixture("ecb_90d.xml")) // stands in for the 7 MB file
        return http
    }

    private func files(_ http: StubHTTPClient) -> [String] {
        http.requests.map(\.url.lastPathComponent)
    }

    @Test func oneMissingDayNeedsOnlyTheDailyFile() async throws {
        let http = stub()
        let batch = try await ECBProvider(http: http).rates(for: [
            RateRequest(currency: "USD", from: day("2026-11-18"), hasHistory: true),
            RateRequest(currency: "CHF", from: day("2026-11-19"), hasHistory: true), // already up to date
            RateRequest(currency: "EUR", from: day("2026-11-01"), hasHistory: false), // the base itself is ignored
        ])
        #expect(files(http) == ["eurofxref-daily.xml"])
        #expect(batch.series == [ExchangeRateSeries(base: "EUR", quote: "USD", days: [day("2026-11-18").rawValue], rates: [1.0968])])
        #expect(batch.unsupported.isEmpty)
    }

    @Test func aFewMissingDaysUseThe90DayFile() async throws {
        let http = stub()
        let batch = try await ECBProvider(http: http).rates(for: [
            RateRequest(currency: "USD", from: day("2026-11-12"), hasHistory: true),
            RateRequest(currency: "GBP", from: day("2026-11-17"), hasHistory: true),
        ])
        #expect(files(http) == ["eurofxref-daily.xml", "eurofxref-hist-90d.xml"])
        #expect(batch.series.map(\.quote) == ["GBP", "USD"])
        #expect(batch.series[0].days == [day("2026-11-17").rawValue, day("2026-11-18").rawValue])
        #expect(batch.series[0].rates == [0.83305, 0.8329])
        #expect(batch.series[1].days.map { Day(rawValue: $0).iso } == ["2026-11-12", "2026-11-13", "2026-11-16", "2026-11-17", "2026-11-18"])
    }

    @Test func longGapsAndNewCurrenciesUseTheFullFile() async throws {
        let http = stub()
        let batch = try await ECBProvider(http: http).rates(for: [RateRequest(currency: "USD", from: ECBProvider.firstDay, hasHistory: false)])
        #expect(files(http) == ["eurofxref-daily.xml", "eurofxref-hist.xml"])
        #expect(batch.series.first?.days.count == 8)
    }

    @Test func upToDateFilesCostOneTinyRequest() async throws {
        let http = stub()
        let batch = try await ECBProvider(http: http).rates(for: [RateRequest(currency: "USD", from: day("2026-11-19"), hasHistory: true)])
        #expect(files(http) == ["eurofxref-daily.xml"])
        #expect(batch == RateBatch())
    }

    @Test func reportsUnsupportedAndHandlesDiscontinuedCurrencies() async throws {
        let http = stub()
        let batch = try await ECBProvider(http: http).rates(for: [
            RateRequest(currency: "BTC", from: ECBProvider.firstDay, hasHistory: false),
            RateRequest(currency: "HRK", from: day("2023-01-01"), hasHistory: true), // joined the euro: nothing more to fetch
        ])
        #expect(files(http) == ["eurofxref-daily.xml"])
        #expect(batch == RateBatch(series: [], unsupported: ["BTC"]))

        // A discontinued currency without any stored history is loaded once from the full file.
        let second = stub()
        _ = try await ECBProvider(http: second).rates(for: [RateRequest(currency: "HRK", from: ECBProvider.firstDay, hasHistory: false)])
        #expect(files(second) == ["eurofxref-daily.xml", "eurofxref-hist.xml"])
    }

    @Test func propagatesServerErrors() async {
        let http = StubHTTPClient()
        http.on("eurofxref", status: 503)
        await #expect(throws: MarketDataError.http(status: 503, host: "www.ecb.europa.eu")) {
            _ = try await ECBProvider(http: http).rates(for: [RateRequest(currency: "USD", from: day("2026-11-18"), hasHistory: true)])
        }
    }
}

@Suite struct CoinGeckoTests {
    @Test func hourlySamplesBecomeDailyCloses() throws {
        let points = try CoinGeckoProvider.parseMarketChart(fixture("coingecko_hourly.json"))
        #expect(points.map(\.day.iso) == ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"])
        // Closes are the samples at the following midnight UTC; the last day is still running.
        #expect(points.map(\.price.raw) == [6_459_200_038_798, 6_197_078_114_304, 5_816_667_246_200, 5_925_902_640_392])
    }

    @Test func dailySamplesCloseThePreviousDay() throws {
        let points = try CoinGeckoProvider.parseMarketChart(fixture("coingecko_daily.json"))
        #expect(points.map(\.day.iso) == ["2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07"])
        #expect(points.first?.price.raw == 6_708_226_050_005)
        #expect(points.last?.price.raw == 6_821_595_214_674)
    }

    @Test func requestsTheSecurityCurrencyAndClampsToPublicHistory() async throws {
        let http = StubHTTPClient()
        http.on("/coins/bitcoin/market_chart/range", body: fixture("coingecko_hourly.json"))
        let provider = CoinGeckoProvider(http: http, today: { day("2026-11-15") })
        let request = QuoteRequest(feed: QuoteFeed(provider: "coingecko", symbol: " Bitcoin "), currency: "EUR", range: day("2020-01-01")...day("2026-11-20"))
        let history = try await provider.history(request)
        // 364 days before "today" … midnight after "today".
        #expect(http.requestedURLs == ["https://api.coingecko.com/api/v3/coins/bitcoin/market_chart/range?vs_currency=eur&from=1763251200&to=1794787200"])
        #expect(history.currency == "EUR")
        #expect(history.points.map(\.day.iso) == ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"])
        #expect(http.requests[0].headers["x-cg-demo-api-key"] == nil)
    }

    @Test func honorsOptions() async throws {
        let http = StubHTTPClient()
        http.on("market_chart/range", body: fixture("coingecko_daily.json"))
        let provider = CoinGeckoProvider(http: http, today: { day("2026-11-15") })
        let feed = QuoteFeed(provider: "coingecko", symbol: "bitcoin", options: ["currency": "usd", "apiKey": "secret", "plan": "pro"])
        let history = try await provider.history(QuoteRequest(feed: feed, currency: "EUR", range: day("2026-05-03")...day("2026-05-05")))
        #expect(http.requestedURLs == ["https://pro-api.coingecko.com/api/v3/coins/bitcoin/market_chart/range?vs_currency=usd&from=1777766400&to=1778025600"])
        #expect(http.requests[0].headers["x-cg-pro-api-key"] == "secret")
        #expect(history.currency == "USD")
        #expect(history.points.map(\.day.iso) == ["2026-05-03", "2026-05-04", "2026-05-05"])
    }

    @Test func skipsRequestsEntirelyOutsidePublicHistory() async throws {
        let http = StubHTTPClient()
        let provider = CoinGeckoProvider(http: http, today: { day("2026-11-15") })
        let history = try await provider.history(QuoteRequest(feed: QuoteFeed(provider: "coingecko", symbol: "bitcoin"), currency: "EUR", range: day("2020-01-01")...day("2020-12-31")))
        #expect(history.points.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func mapsErrors() async {
        let http = StubHTTPClient()
        http.on("/coins/nope/", status: 404, body: fixture("coingecko_notfound.json"))
        http.on("/coins/limited/", status: 429, text: "{}")
        http.on("/coins/old/", status: 401, text: #"{"error":{"status":{"error_code":10012,"error_message":"Your request exceeds the allowed time range."}}}"#)
        let provider = CoinGeckoProvider(http: http, today: { day("2026-11-15") })
        func request(_ coin: String) -> QuoteRequest {
            QuoteRequest(feed: QuoteFeed(provider: "coingecko", symbol: coin), currency: "EUR", range: day("2026-11-01")...day("2026-11-15"))
        }
        await #expect(throws: MarketDataError.symbolNotFound("nope")) { _ = try await provider.history(request("nope")) }
        await #expect(throws: MarketDataError.rateLimited(host: "api.coingecko.com")) { _ = try await provider.history(request("limited")) }
        await #expect(throws: MarketDataError.unsupported("CoinGecko: Your request exceeds the allowed time range.")) { _ = try await provider.history(request("old")) }
        await #expect(throws: MarketDataError.self) { _ = try await provider.history(request("")) }
    }

    @Test func searchesCoins() async throws {
        let http = StubHTTPClient()
        http.on("/api/v3/search?query=bitcoin", body: fixture("coingecko_search.json"))
        let matches = try await CoinGeckoProvider(http: http).search("bitcoin")
        #expect(matches.map(\.symbol) == ["bitcoin", "bitcoin-cash", "bitcoin-cash-sv"])
        #expect(matches[0] == SymbolMatch(symbol: "bitcoin", name: "Bitcoin (BTC)", exchangeName: "CoinGecko", type: .crypto, provider: "coingecko"))
    }
}

@Suite struct GenericProviderTests {
    let range = day("2024-01-01")...day("2024-01-31")

    @Test func jsonFeedExpandsTemplateAndExtractsQuotes() async throws {
        let http = StubHTTPClient()
        http.on("example.com/api", text: #"{"data":[{"date":"2024-01-03","close":"101,50"},{"date":"2024-01-02","close":100.25},{"date":"2024-02-01","close":99},{"date":"2024-01-04","close":null}]}"#)
        let feed = QuoteFeed(provider: "json-url", symbol: "https://example.com/api/{ISIN}?from={FROM}&to={TO:unix}&c={CURRENCY}",
                             options: ["datePath": "$.data[*].date", "closePath": "$.data[*].close"])
        let history = try await JSONURLProvider(http: http).history(QuoteRequest(feed: feed, currency: "EUR", isin: "IE00B4L5Y983", range: range))
        #expect(http.requestedURLs == ["https://example.com/api/IE00B4L5Y983?from=2024-01-01&to=1706745599&c=EUR"])
        #expect(history.points == [point("2024-01-02", 100.25), point("2024-01-03", 101.5)])
    }

    @Test func jsonFeedHandlesMatricesKeyedObjectsAndFactor() throws {
        let matrix = Data(#"{"prices":[[1704153600000,6950.0],[1704240000000,7045.5]]}"#.utf8)
        let points = try JSONURLProvider.parse(matrix, datePath: JSONPath("$.prices[*][0]"), closePath: JSONPath("$.prices[*][1]"), factor: 0.01)
        #expect(points == [point("2024-01-02", 69.5), point("2024-01-03", 70.455)])

        let keyed = Data(#"{"Time Series (Daily)":{"2024-01-03":{"4. close":"101.5000"},"2024-01-02":{"4. close":"100.2500"}}}"#.utf8)
        let fromKeys = try JSONURLProvider.parse(keyed, datePath: JSONPath("$['Time Series (Daily)'].*~"), closePath: JSONPath("$['Time Series (Daily)'].*['4. close']"))
        #expect(fromKeys == [point("2024-01-02", 100.25), point("2024-01-03", 101.5)])

        let custom = Data(#"{"d":["02.01.24"],"c":[5]}"#.utf8)
        #expect(try JSONURLProvider.parse(custom, datePath: JSONPath("$.d[*]"), closePath: JSONPath("$.c[*]"), dateFormat: .pattern(DatePattern("dd.MM.yy")!)) == [point("2024-01-02", 5)])
    }

    @Test func jsonFeedReportsConfigurationProblems() async {
        let http = StubHTTPClient()
        http.on("example.com", text: #"{"d":["2024-01-02","2024-01-03"],"c":[1]}"#)
        let provider = JSONURLProvider(http: http)
        func request(_ symbol: String, _ options: [String: String]) -> QuoteRequest {
            QuoteRequest(feed: QuoteFeed(provider: "json-url", symbol: symbol, options: options), currency: "EUR", range: range)
        }
        await #expect(throws: MarketDataError.self) { _ = try await provider.history(request("", ["datePath": "$.d[*]", "closePath": "$.c[*]"])) }
        await #expect(throws: MarketDataError.self) { _ = try await provider.history(request("https://example.com", ["datePath": "$.d[*]"])) }
        await #expect(throws: MarketDataError.self) { _ = try await provider.history(request("https://example.com", ["datePath": "$.d[", "closePath": "$.c[*]"])) }
        await #expect(throws: MarketDataError.self) { _ = try await provider.history(request("https://example.com", ["datePath": "$.d[*]", "closePath": "$.c[*]", "factor": "zero"])) }
        // Paths that select a different number of values.
        await #expect(throws: MarketDataError.malformedResponse("“$.d[*]” matched 2 dates but “$.c[*]” matched 1 prices.")) {
            _ = try await provider.history(request("https://example.com", ["datePath": "$.d[*]", "closePath": "$.c[*]"]))
        }
        await #expect(throws: MarketDataError.malformedResponse("The path “$.x[*]” matched nothing in the response.")) {
            _ = try await provider.history(request("https://example.com", ["datePath": "$.x[*]", "closePath": "$.c[*]"]))
        }
    }

    @Test func csvFeedDownloadsAndParses() async throws {
        let http = StubHTTPClient()
        http.on("stooq.example/q", text: "Date,Open,High,Low,Close,Volume\n2023-12-29,1,1,1,9.5,10\n2024-01-02,1,1,1,10.5,10\n2024-01-03,1,1,1,11.5,10\n")
        let feed = QuoteFeed(provider: "csv-url", symbol: "https://stooq.example/q?s={TICKER}&d1={FROM:yyyyMMdd}", options: ["factor": "2"])
        let history = try await CSVURLProvider(http: http).history(QuoteRequest(feed: feed, currency: "USD", ticker: "aapl.us", range: range))
        #expect(http.requestedURLs == ["https://stooq.example/q?s=aapl.us&d1=20240101"])
        #expect(history.points == [point("2024-01-02", 21), point("2024-01-03", 23)])
    }

    @Test func csvFeedTranslatesOptions() throws {
        let feed = QuoteFeed(provider: "csv-url", symbol: "https://x.example", options: [
            "delimiter": ";", "dateColumn": "Datum", "closeColumn": "3", "decimalSeparator": ",", "dateFormat": "dd.MM.yyyy",
        ])
        let options = try CSVURLProvider.options(for: QuoteRequest(feed: feed, currency: "EUR", range: range))
        #expect(options == CSVOptions(delimiter: ";", dateColumn: "Datum", closeColumn: "3", decimalSeparator: .comma, dateFormat: .pattern(DatePattern("dd.MM.yyyy")!)))
        let bad = QuoteFeed(provider: "csv-url", symbol: "https://x.example", options: ["decimalSeparator": "x"])
        #expect(throws: MarketDataError.self) { _ = try CSVURLProvider.options(for: QuoteRequest(feed: bad, currency: "EUR", range: range)) }
    }

    @Test func httpErrorsSurface() async {
        let http = StubHTTPClient()
        http.on("wall.example", text: "<!DOCTYPE html><html><body>Please enable JavaScript</body></html>")
        for provider in ["csv-url", "json-url"] {
            let walled = QuoteFeed(provider: provider, symbol: "https://wall.example/data", options: ["datePath": "$.d", "closePath": "$.c"])
            await #expect(throws: MarketDataError.malformedResponse("The address returned a web page instead of data.")) {
                _ = try await ProviderRegistry.standard(http: http).provider(for: walled).history(QuoteRequest(feed: walled, currency: "EUR", range: range))
            }
        }
        let feed = QuoteFeed(provider: "csv-url", symbol: "https://gone.example/file.csv")
        await #expect(throws: MarketDataError.http(status: 404, host: "gone.example")) {
            _ = try await CSVURLProvider(http: http).history(QuoteRequest(feed: feed, currency: "EUR", range: range))
        }
    }
}

@Suite struct RegistryTests {
    let registry = ProviderRegistry.standard(http: StubHTTPClient())

    @Test func listsBuiltInProviders() {
        #expect(registry.descriptors.map(\.id) == ["yahoo", "coingecko", "json-url", "csv-url", "manual"])
        #expect(registry.descriptors.map(\.name) == ["Yahoo Finance", "CoinGecko", "JSON (URL)", "CSV (URL)", "Manual"])
        #expect(registry.descriptor(id: "json-url")?.options.map(\.key) == ["datePath", "closePath", "dateFormat", "factor"])
        #expect(registry.descriptor(id: "csv-url")?.options.map(\.key) == ["dateColumn", "closeColumn", "delimiter", "decimalSeparator", "dateFormat", "factor"])
        #expect(registry.descriptor(id: "coingecko")?.options.map(\.key) == ["currency", "apiKey", "plan"])
        #expect(registry.descriptor(id: "yahoo")?.supportsSearch == true)
        #expect(registry.descriptor(id: "manual")?.symbol == nil)
        #expect(registry.descriptor(id: "json-url")?.symbol?.kind == .urlTemplate)
        for descriptor in registry.descriptors {
            #expect(!descriptor.summary.isEmpty)
            #expect(Set(descriptor.options.map(\.key)).count == descriptor.options.count)
        }
    }

    @Test func resolvesProviders() throws {
        #expect(try registry.provider(for: QuoteFeed(provider: "yahoo", symbol: "AAPL")).descriptor.id == "yahoo")
        #expect(throws: MarketDataError.unknownProvider("bloomberg")) { _ = try registry.provider(for: QuoteFeed(provider: "bloomberg", symbol: "X")) }
        #expect(registry.isAutomatic(QuoteFeed(provider: "yahoo", symbol: "AAPL")))
        #expect(!registry.isAutomatic(.manual))
        #expect(!registry.isAutomatic(nil))
        #expect(!registry.isAutomatic(QuoteFeed(provider: "bloomberg", symbol: "X")))
    }

    @Test func manualProviderDownloadsNothing() async throws {
        let manual = try registry.provider(for: .manual)
        let history = try await manual.history(QuoteRequest(feed: .manual, currency: "EUR", range: day("2024-01-01")...day("2024-01-02")))
        #expect(history == QuoteHistory())
    }

    @Test func validatesFeeds() {
        #expect(registry.validate(QuoteFeed(provider: "yahoo", symbol: "")).isEmpty) // falls back to the ticker
        #expect(registry.validate(QuoteFeed(provider: "coingecko", symbol: "")) == ["“Coin ID” is required."])
        #expect(registry.validate(QuoteFeed(provider: "coingecko", symbol: "bitcoin", options: ["plan": "gold"])) == ["“gold” is not a valid value for “Plan”."])
        #expect(registry.validate(QuoteFeed(provider: "nope", symbol: "")) == ["Unknown quote provider “nope”."])
        let good = QuoteFeed(provider: "json-url", symbol: "https://example.com/{ISIN}", options: ["datePath": "$.a[*]", "closePath": "$.b[*]"])
        #expect(registry.validate(good).isEmpty)
        let bad = QuoteFeed(provider: "json-url", symbol: "example.com", options: ["datePath": "$.a[", "dateFormat": "bogus", "factor": "-1"])
        #expect(registry.validate(bad).count == 5)
    }

    @Test func customProvidersCanBeRegistered() {
        var custom = ProviderRegistry([ManualProvider()])
        custom.register(FakeProvider(id: "fake") { _ in QuoteHistory() })
        custom.register(FakeProvider(id: "fake") { _ in QuoteHistory() })
        #expect(custom.descriptors.map(\.id) == ["manual", "fake"])
    }

    @Test func defaultLatestUsesRecentHistory() async throws {
        let provider = FakeProvider { request in
            QuoteHistory(points: [PricePoint(day: request.range.upperBound.advanced(by: -1), price: Price(12.5))], currency: "EUR", name: "Thing")
        }
        let latest = try await provider.latest(QuoteRequest(feed: QuoteFeed(provider: "fake", symbol: "X"), currency: "EUR", range: day("2000-01-01")...day("2000-01-01")))
        #expect(latest.point.price == Price(12.5))
        #expect(latest.currency == "EUR")
        #expect(provider.requests[0].range.count == 15)
    }
}
