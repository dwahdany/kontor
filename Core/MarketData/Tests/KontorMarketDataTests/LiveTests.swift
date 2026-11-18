import Foundation
import KontorModel
import Testing
@testable import KontorMarketData

/// Smoke tests against the real endpoints. Run with `KONTOR_LIVE_TESTS=1 swift test --filter Live`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KONTOR_LIVE_TESTS"] == "1"), .serialized)
struct LiveTests {
    let http = ResilientHTTPClient.standard()

    @Test func yahooHistoryLatestAndSearch() async throws {
        let yahoo = YahooProvider(http: http)
        let range = day("2024-01-02")...day("2024-01-12")
        let apple = try await yahoo.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "AAPL"), currency: "USD", range: range))
        #expect(apple.points.count == 9)
        #expect(apple.points.first == point("2024-01-02", 185.64))
        #expect(apple.currency == "USD")

        let events = try await yahoo.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "AAPL"), currency: "USD", range: day("2020-08-01")...day("2020-09-01")))
        #expect(events.events.contains(QuoteEvent(day: day("2020-08-31"), kind: .split, detail: "4:1")))

        let vodafone = try await yahoo.latest(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "VOD.L"), currency: "GBP", range: range))
        #expect(vodafone.currency == "GBP")
        #expect(vodafone.point.price.doubleValue < 20) // pounds, not pence

        let matches = try await yahoo.lookup(isin: "IE00B4L5Y983")
        #expect(!matches.isEmpty)

        // A window that starts after "now" (Yahoo: HTTP 400 "Data doesn't exist …") is simply empty.
        let future = Day(date: Date(), timeZone: TimeZone(secondsFromGMT: 0)!).advanced(by: 3)
        let nothing = try await yahoo.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "AAPL"), currency: "USD", range: future...future.advanced(by: 2)))
        #expect(nothing.points.isEmpty)

        // Sydney's daily bars are stamped on the previous UTC day; they must land on local weekdays.
        let today = Day.today
        let sydney = try await yahoo.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "BHP.AX"), currency: "AUD", range: today.advanced(by: -30)...today))
        #expect(sydney.points.count >= 15)
        #expect(sydney.points.allSatisfy { !$0.day.isWeekend })

        await #expect(throws: MarketDataError.symbolNotFound("NOPE12345XX")) {
            _ = try await yahoo.history(QuoteRequest(feed: QuoteFeed(provider: "yahoo", symbol: "NOPE12345XX"), currency: "USD", range: range))
        }
    }

    @Test func ecbIncrementalAndFullHistory() async throws {
        let ecb = ECBProvider(http: http)
        let recent = try await ecb.rates(for: [RateRequest(currency: "USD", from: Day.today.advanced(by: -10), hasHistory: true)])
        #expect(recent.series.first?.days.isEmpty == false)

        let raw = try await http.get(URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml")!)
        let parseStart = Date()
        let table = try ECBProvider.parse(raw)
        print("ECB full history: parsed \(raw.count) bytes, \(table.count) currencies in \(Date().timeIntervalSince(parseStart) * 1000) ms")
        let start = Date()
        let full = try await ecb.rates(for: [RateRequest(currency: "USD", from: ECBProvider.firstDay, hasHistory: false), RateRequest(currency: "BTC", from: ECBProvider.firstDay, hasHistory: false)])
        let usd = try #require(full.series.first)
        #expect(usd.days.first == day("1999-01-04").rawValue)
        #expect(usd.rates.first == 1.1789)
        #expect(usd.days.count > 6500)
        #expect(full.unsupported == ["BTC"])
        print("ECB full history: \(usd.days.count) USD rates in \(Date().timeIntervalSince(start)) s (download + parse)")
    }

    @Test func coinGeckoRecentHistoryAndSearch() async throws {
        let coingecko = CoinGeckoProvider(http: http)
        let today = Day(date: Date(), timeZone: TimeZone(secondsFromGMT: 0)!)
        let history = try await coingecko.history(QuoteRequest(feed: QuoteFeed(provider: "coingecko", symbol: "bitcoin"), currency: "EUR", range: today.advanced(by: -5)...today))
        #expect(history.points.count >= 5)
        #expect(history.points.last?.day == today)
        #expect(history.currency == "EUR")
        #expect(try await coingecko.search("ethereum").first?.symbol == "ethereum")
    }

    @Test func updaterEndToEnd() async throws {
        var file = PortfolioFile(
            securities: [
                Security(name: "MSCI World", currency: "EUR", feed: QuoteFeed(provider: "yahoo", symbol: "EUNL.DE")),
                Security(name: "Apple", currency: "USD", feed: QuoteFeed(provider: "yahoo", symbol: "AAPL")),
                Security(name: "Bitcoin", currency: "EUR", feed: QuoteFeed(provider: "coingecko", symbol: "bitcoin")),
                Security(name: "Ether via JSON", currency: "EUR", ticker: "ethereum", feed: QuoteFeed(
                    provider: "json-url", symbol: "https://api.coingecko.com/api/v3/coins/{TICKER}/market_chart?vs_currency={CURRENCY}&days=20&interval=daily",
                    options: ["datePath": "$.prices[*][0]", "closePath": "$.prices[*][1]"])),
                Security(name: "Broken", currency: "EUR", feed: QuoteFeed(provider: "yahoo", symbol: "NOPE12345XX")),
            ]
        )
        let updater = QuoteUpdater(http: http, options: UpdateOptions(historyStart: .day(Day.today.advanced(by: -30)), rateHistoryStart: .day(Day.today.advanced(by: -30))))
        let result = await updater.update(file) { print("  \($0.name): \($0.status)") }
        let summary = apply(result, to: &file)
        print("Live update: \(summary.prices) prices, \(summary.rates) rates, failures: \(result.failures.values.sorted())")
        #expect(file.securities[0].prices.count > 10)
        #expect(file.securities[1].prices.count > 10)
        #expect(file.securities[2].prices.count > 20)
        #expect(file.securities[3].prices.count > 15)
        #expect(result.statuses[.security(file.securities[4].id)] == .failed(message: "Unknown symbol “NOPE12345XX”."))
        #expect(file.exchangeRates.first { $0.quote == "USD" }?.days.isEmpty == false)
    }

    @Test func suggestsAFeed() async throws {
        let suggester = FeedSuggester(yahoo: YahooProvider(http: http))
        let etf = Security(name: "iShares Core MSCI World UCITS ETF", currency: "EUR", isin: "IE00B4L5Y983")
        let suggestions = try await suggester.suggestions(for: etf)
        print("Suggestions: \(suggestions.map { "\($0.match.symbol) [\($0.currency ?? "?")\($0.isVerified ? " ✓" : "")] \($0.score)" })")
        let best = try #require(suggestions.first)
        #expect(best.currency == "EUR")
        let apple = try await suggester.suggestFeed(for: Security(name: "Apple", currency: "USD", isin: "US0378331005", ticker: "AAPL"))
        #expect(apple == QuoteFeed(provider: "yahoo", symbol: "AAPL"))
    }

    @Test func browserUserAgentProbe() async throws {
        // Informational: which User-Agent strings Yahoo accepts from URLSession.
        for agent in [UserAgent.minimal, UserAgent.browser] {
            let raw = URLSessionHTTPClient()
            let response = try await raw.send(HTTPRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/MSFT?range=1d&interval=1d")!, headers: ["User-Agent": agent]))
            print("Yahoo with User-Agent “\(agent.prefix(40))…”: HTTP \(response.status)")
        }
    }
}
