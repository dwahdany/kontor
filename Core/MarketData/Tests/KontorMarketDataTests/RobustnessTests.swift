import Foundation
import KontorModel
import Testing
@testable import KontorMarketData

private let wide = day("1990-01-01")...day("2100-01-01")

/// Deterministic generator (SplitMix64) so that fuzz failures are reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Every prefix of `data` (stepping so that large fixtures stay fast) plus variants with random
/// bytes overwritten, deleted or duplicated.
private func mutations(of data: Data, seed: UInt64, garbled: Int = 300) -> [Data] {
    var out = [Data]()
    let step = max(1, data.count / 1500)
    for length in stride(from: 0, to: data.count, by: step) { out.append(data.prefix(length)) }
    var rng = SplitMix64(state: seed)
    let interesting: [UInt8] = Array("\"'{}[]<>=,:.-+eE0919nulltrue \n\\/".utf8) + [0, 0xFF, 0x80]
    for _ in 0..<garbled {
        var bytes = [UInt8](data)
        for _ in 0..<Int.random(in: 1...4, using: &rng) where !bytes.isEmpty {
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: bytes[at] = interesting.randomElement(using: &rng)!
            case 1: bytes.remove(at: at)
            case 2: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + 9)], at: at)
            default: bytes[at] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        out.append(Data(bytes))
    }
    return out
}

/// The parsers must answer garbage with an error (or with whatever they can salvage) — never
/// with a crash. A trap anywhere in here takes the whole test process down.
@Suite struct ParserFuzzTests {
    @Test(arguments: ["yahoo_chart_AAPL.json", "yahoo_chart_AAPL_events.json", "yahoo_chart_EUNL.DE.json", "yahoo_chart_VOD.L.json", "yahoo_chart_notfound.json"])
    func yahooChartSurvivesDamagedResponses(name: String) {
        for (i, data) in mutations(of: fixture(name), seed: 1).enumerated() {
            if let history = try? YahooProvider.parseChart(data, symbol: "X", range: wide, securityCurrency: "GBP") {
                #expect(isStrictlyAscending(history.points), "mutation \(i)")
                #expect(history.points.allSatisfy { $0.price.raw > 0 }, "mutation \(i)")
            }
        }
    }

    @Test(arguments: ["yahoo_search_apple.json", "yahoo_search_isin.json"])
    func yahooSearchSurvivesDamagedResponses(name: String) {
        for data in mutations(of: fixture(name), seed: 2) { _ = try? YahooProvider.parseSearch(data) }
    }

    @Test(arguments: ["coingecko_daily.json", "coingecko_hourly.json", "coingecko_notfound.json", "coingecko_search.json"])
    func coinGeckoSurvivesDamagedResponses(name: String) {
        for (i, data) in mutations(of: fixture(name), seed: 3).enumerated() {
            if let points = try? CoinGeckoProvider.parseMarketChart(data) {
                #expect(isStrictlyAscending(points), "mutation \(i)")
            }
            _ = try? CoinGeckoProvider.parseSearch(data)
        }
    }

    @Test(arguments: ["ecb_daily.xml", "ecb_90d.xml"])
    func ecbSurvivesDamagedResponses(name: String) {
        for (i, data) in mutations(of: fixture(name), seed: 4, garbled: 600).enumerated() {
            guard let table = try? ECBProvider.parse(data) else { continue }
            for column in table.values {
                #expect(column.days.count == column.rates.count, "mutation \(i)")
                #expect(zip(column.days, column.days.dropFirst()).allSatisfy { $0 < $1 }, "mutation \(i)")
                #expect(column.rates.allSatisfy { $0 > 0 && $0.isFinite }, "mutation \(i)")
            }
        }
    }

    @Test func genericParsersSurviveDamagedResponses() throws {
        let datePath = try JSONPath("$.prices[*][0]"), closePath = try JSONPath("$.prices[*][1]")
        for data in mutations(of: fixture("coingecko_hourly.json"), seed: 5) {
            _ = try? JSONValue(data: data)
            _ = try? JSONURLProvider.parse(data, datePath: datePath, closePath: closePath)
        }
        let csv = Data("""
            Date,Open,High,Low,Close,Adj Close,Volume
            2024-01-02,187.15,188.44,183.89,185.64,184.73,82488700
            2024-01-03,184.22,185.88,183.43,184.25,183.35,58414500
            "2024-01-04","182.15","183.09","180.88","181.91","181.02","71983600"
            05.01.2024;181,99;182,76;180,17;181,18
            Jan 8, 2024\t182.09\t185.60\t181.50\t185.56
            """.utf8)
        for data in mutations(of: csv, seed: 6, garbled: 1500) {
            if let points = try? CSVQuoteParser.parse(data) { #expect(isStrictlyAscending(points)) }
        }
    }

    @Test func textParsersSurviveArbitraryInput() {
        var rng = SplitMix64(state: 7)
        let alphabet = Array("0123456789.,-+/: eETZ'\"%€$JanMärzDezyMd[]*~$\u{2212}\u{FEFF}").map(String.init)
        for _ in 0..<20_000 {
            let text = (0..<Int.random(in: 0...24, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
            _ = DayParser.parse(text)
            _ = NumberParser.parse(text)
            _ = DateFormat(option: text)?.parse("31.01.2024")
            _ = DatePattern(text)?.parse(text)
            _ = try? JSONPath(text)
            _ = try? JSONValue(parsing: text)
            _ = URLTemplate.expand("https://example.com/{FROM:\(text)}/{\(text)}", URLTemplate.Context(from: day("2024-01-01"), to: day("2024-01-31")))
        }
    }
}

private func isStrictlyAscending(_ points: [PricePoint]) -> Bool {
    zip(points, points.dropFirst()).allSatisfy { $0.day < $1.day }
}

/// Well-formed responses carrying absurd numbers: skipped, not trapped on.
@Suite struct ExtremeValueTests {
    @Test func yahooSkipsUnrepresentableQuotesAndTimestamps() throws {
        // 1704182400 = 2024-01-02 09:00 Berlin. Prices are stored as Int64 / 1e8: anything from
        // 9.3e10 up cannot be represented; timestamps beyond Int32 days are nonsense.
        let json = #"""
        {"chart":{"result":[{"meta":{"currency":"EUR","gmtoffset":3600,"exchangeTimezoneName":"Europe/Berlin",
        "regularMarketPrice":1e300,"regularMarketTime":1704182400},
        "timestamp":[1704182400,1704268800,1704355200,9200000000000000000,-9200000000000000000],
        "indicators":{"quote":[{"close":[10.5,1e300,93000000000,5,5]}]},
        "events":{"dividends":{"a":{"amount":1e300,"date":1704182400},"b":{"amount":0.5,"date":9200000000000000000}},
        "splits":{"a":{"date":1704182400,"numerator":1e300,"denominator":1}}}}],"error":null}}
        """#
        let history = try YahooProvider.parseChart(Data(json.utf8), symbol: "X", range: wide, securityCurrency: "EUR")
        #expect(history.points == [point("2024-01-02", 10.5)])
        #expect(history.latest == nil)
        #expect(history.events.allSatisfy { wide.contains($0.day) })
    }

    @Test func yahooKeepsSubCentQuotesButDropsWhatRoundsToZero() throws {
        let json = #"{"chart":{"result":[{"meta":{"currency":"USD","gmtoffset":0},"timestamp":[1704182400,1704268800],"indicators":{"quote":[{"close":[0.00000123,0.000000001]}]}}],"error":null}}"#
        let history = try YahooProvider.parseChart(Data(json.utf8), symbol: "X", range: wide, securityCurrency: "USD")
        #expect(history.points.map(\.price.raw) == [123]) // 1.23e-6 × 1e8; 1e-9 would be stored as a price of zero
    }

    @Test func coinGeckoSkipsUnrepresentableSamples() throws {
        // 1704153600000 ms = 2024-01-02 00:00 UTC, i.e. the close of 2024-01-01.
        let json = #"{"prices":[[1704153600000,40000.5],[1e30,5],[-1e30,5],[1704240000000,1e300],[1704326400000,41000]]}"#
        #expect(try CoinGeckoProvider.parseMarketChart(Data(json.utf8)) == [point("2024-01-01", 40000.5), point("2024-01-03", 41000)])
    }

    @Test func genericFeedsSkipUnrepresentablePrices() throws {
        let json = #"{"d":[{"t":"2024-01-02","c":1e300},{"t":"2024-01-03","c":12.5},{"t":"2024-01-04","c":"98765432109876"}]}"#
        let points = try JSONURLProvider.parse(Data(json.utf8), datePath: JSONPath("$.d[*].t"), closePath: JSONPath("$.d[*].c"))
        #expect(points == [point("2024-01-03", 12.5)])
        // A factor can push an ordinary quote out of range, too.
        let moderate = try JSONURLProvider.parse(Data(json.utf8), datePath: JSONPath("$.d[*].t"), closePath: JSONPath("$.d[*].c"), factor: 1e9)
        #expect(moderate.map(\.price.raw) == [1_250_000_000_000_000_000]) // 12.5e9 × 1e8
        #expect(throws: MarketDataError.self) {
            _ = try JSONURLProvider.parse(Data(json.utf8), datePath: JSONPath("$.d[*].t"), closePath: JSONPath("$.d[*].c"), factor: 1e12)
        }

        // A market-cap column mistaken for the price must not take the app down.
        let csv = "Date,Close\n2024-01-02,1234567890123456\n2024-01-03,12.5\n2024-01-04,1e400\n"
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-03", 12.5)])
    }

    @Test func csvFeedFactorCannotOverflow() async throws {
        let http = StubHTTPClient()
        http.on("example.com", text: "Date,Close\n2024-01-02,90000000000\n2024-01-03,12.5\n")
        let feed = QuoteFeed(provider: "csv-url", symbol: "https://example.com/q.csv", options: ["factor": "1000"])
        let history = try await CSVURLProvider(http: http).history(QuoteRequest(feed: feed, currency: "EUR", range: wide))
        #expect(history.points == [point("2024-01-03", 12500)])
    }

    @Test func checkedPriceConversion() {
        #expect(Price(checkedQuote: 185.64)?.raw == 18_564_000_000)
        #expect(Price(checkedQuote: 92_233_720_368) != nil)   // just below Int64.max / 1e8
        #expect(Price(checkedQuote: 92_233_720_369) == nil)
        #expect(Price(checkedQuote: 0) == nil)
        #expect(Price(checkedQuote: -1) == nil)
        #expect(Price(checkedQuote: .nan) == nil)
        #expect(Price(checkedQuote: .infinity) == nil)
        #expect(Price(checkedQuote: 4e-9) == nil)             // rounds to zero
        #expect(Price(checkedQuote: 5e-9)?.raw == 1)
    }
}

/// Coarse performance guards on realistic sizes. The bounds are an order of magnitude above
/// what a debug build needs on current hardware; they catch accidental quadratic behaviour,
/// not small regressions. Timings are printed for `swift test -c release`.
@Suite(.serialized) struct BenchmarkTests {
    private func measure(_ label: String, limit: TimeInterval, _ work: () throws -> Void) rethrows {
        let start = Date()
        try work()
        let elapsed = Date().timeIntervalSince(start)
        print("Benchmark \(label): \(String(format: "%.1f", elapsed * 1000)) ms")
        #expect(elapsed < limit, "\(label) took \(elapsed) s")
    }

    /// 7 000 publication days × 31 currencies ≈ the ECB's full history file (about 8 MB).
    @Test func ecbFullHistory() throws {
        var xml = "<gesmes:Envelope><Cube>"
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let codes: [String] = (0..<31).map { (i: Int) -> String in "C\(letters[i / 26])\(letters[i % 26])" }
        let first = day("1999-01-04")
        for d in stride(from: 6999, through: 0, by: -1) {
            xml += "<Cube time=\"\(first.advanced(by: d).iso)\">"
            for (k, code) in codes.enumerated() { xml += "<Cube currency=\"\(code)\" rate=\"\(k + 1).\(1000 + d)\"/>" }
            xml += "</Cube>\n"
        }
        xml += "</Cube></gesmes:Envelope>"
        let data = Data(xml.utf8)
        var table = [CurrencyCode: ECBProvider.Column]()
        try measure("ECB parse \(data.count / 1_000_000) MB", limit: 5) { table = try ECBProvider.parse(data) }
        #expect(table.count == 31)
        let column = try #require(table["CAC"]) // index 2
        #expect(column.days.count == 7000)
        #expect(column.days.first == first.rawValue)
        #expect(column.rates.first == 3.1)        // day 0: "3.1000"
        #expect(column.rates.last == 3.7999)      // day 6999: "3.7999"
    }

    /// 45 years of daily bars for one symbol, and applying 200 such histories to a file.
    @Test func yahooLongHistoryAndApply() throws {
        let count = 11_500
        let base: Int64 = 345_479_400 // 1980-12-12 14:30 UTC
        let timestamps = (0..<count).map { String(base + Int64($0) * 86_400) }.joined(separator: ",")
        let closes = (0..<count).map { String(Double($0) * 0.25 + 1) }.joined(separator: ",")
        let json = #"{"chart":{"result":[{"meta":{"currency":"USD","gmtoffset":-18000,"exchangeTimezoneName":"America/New_York"},"timestamp":[\#(timestamps)],"indicators":{"quote":[{"close":[\#(closes)]}]}}],"error":null}}"#
        var history = QuoteHistory()
        try measure("Yahoo parse \(count) bars", limit: 3) {
            history = try YahooProvider.parseChart(Data(json.utf8), symbol: "X", range: day("1970-01-01")...day("2100-01-01"), securityCurrency: "USD")
        }
        #expect(history.points.count == count)
        #expect(history.points.first == point("1980-12-12", 1))
        #expect(history.points.last?.price == Price(Double(count - 1) * 0.25 + 1))

        var file = PortfolioFile(securities: (0..<200).map { security("S\($0)", symbol: "S\($0)", currency: "USD") })
        let result = UpdateResult(securities: file.securities.map { SecurityUpdate(id: $0.id, points: history.points, events: [], fetchedAt: Date()) })
        var summary = ApplySummary()
        measure("apply 200 × \(count) prices", limit: 20) { summary = apply(result, to: &file) }
        #expect(summary.prices == 200 * count)
        measure("re-apply (no changes)", limit: 20) { summary = apply(result, to: &file) }
        #expect(!summary.hasChanges)

        // The everyday case: one new close per security on top of a long history. This runs on
        // the main actor, so it has to be cheap — independent of the length of the history.
        let next = history.points[count - 1].day.advanced(by: 1)
        let daily = UpdateResult(securities: file.securities.map {
            SecurityUpdate(id: $0.id, points: [PricePoint(day: next, price: Price(42))], events: [], fetchedAt: Date())
        })
        measure("apply daily increment (200 securities)", limit: 0.5) { summary = apply(daily, to: &file) }
        #expect(summary.prices == 200)
        #expect(file.securities.allSatisfy { $0.prices.count == count + 1 && $0.prices.latest == PricePoint(day: next, price: Price(42)) })
    }

    /// `apply` takes shortcuts around `PriceSeries.merge`; the result must be identical to it
    /// for every shape of update (appends, corrections, back-fills, unsorted input, duplicates).
    @Test func applyMatchesPriceSeriesMerge() {
        var rng = SplitMix64(state: 11)
        for round in 0..<400 {
            let existing = (0..<Int.random(in: 0...60, using: &rng)).map { _ in
                PricePoint(day: Day(rawValue: Int32.random(in: 100...220, using: &rng)), price: Price(raw: Int64.random(in: 1...5, using: &rng)))
            }
            var incoming = (0..<Int.random(in: 0...80, using: &rng)).map { _ in
                PricePoint(day: Day(rawValue: Int32.random(in: 80...260, using: &rng)), price: Price(raw: Int64.random(in: 1...5, using: &rng)))
            }
            // Most real updates are ascending without duplicates; keep a share of messy ones.
            if round % 4 != 0 { incoming = Array(PriceSeries(incoming)) }
            if round % 8 == 1 { incoming = incoming.filter { $0.day.rawValue > 215 } } // tail only
            let subject = Security(name: "S", currency: "EUR", prices: PriceSeries(existing))
            var expected = subject.prices
            let expectedChanges = expected.merge(incoming)

            var file = PortfolioFile(securities: [subject])
            let summary = apply(UpdateResult(securities: [SecurityUpdate(id: subject.id, points: incoming, events: [], fetchedAt: Date())]), to: &file)
            #expect(file.securities[0].prices == expected, "round \(round)")
            #expect(summary.prices == expectedChanges, "round \(round)")
            #expect(summary.changedSecurities == (expectedChanges > 0 ? [subject.id] : []), "round \(round)")
        }
    }
}
