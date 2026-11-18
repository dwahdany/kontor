import Foundation
import KontorModel

/// Quotes from the Yahoo Finance chart API, plus symbol search.
///
/// - Symbol: a Yahoo ticker such as `AAPL`, `EUNL.DE`, `^GSPC`, `EURUSD=X`, `BTC-USD`. If the
///   feed's symbol is empty, the security's ticker is used.
/// - Prices are the unadjusted daily closes (Yahoo adjusts them for splits, not for dividends).
/// - Quotes in minor units (`GBp`, `ZAc`, `ILA`) are converted to the major unit unless the
///   security itself is kept in that minor unit (`GBX`).
public struct YahooProvider: QuoteProvider, SymbolSearching {
    public static let id = "yahoo"

    private let http: any HTTPClient
    private let hosts: [String]
    private let userAgent: String

    /// - Parameters:
    ///   - hosts: tried in order; the next one is used when a host is rate limited or failing.
    public init(http: any HTTPClient, hosts: [String] = ["query1.finance.yahoo.com", "query2.finance.yahoo.com"],
                userAgent: String = UserAgent.minimal) {
        self.http = http
        self.hosts = hosts
        self.userAgent = userAgent
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.id,
            name: "Yahoo Finance",
            summary: "Daily closing prices, dividends and splits for stocks, ETFs, funds, indices, currencies and crypto assets from most exchanges worldwide.",
            symbol: ProviderOption(
                key: "symbol", label: "Symbol",
                help: "The Yahoo Finance ticker including the exchange suffix, e.g. EUNL.DE for Xetra or VOD.L for London. Leave empty to use the security's ticker.",
                placeholder: "EUNL.DE"
            ),
            supportsSearch: true
        )
    }

    // MARK: Quotes

    public func history(_ request: QuoteRequest) async throws -> QuoteHistory {
        let symbol = try Self.symbol(for: request)
        // Days are local to the exchange; pad the UTC window and filter afterwards.
        let period1 = Int64(request.range.lowerBound.rawValue - 1) * 86_400
        let period2 = Int64(request.range.upperBound.rawValue + 2) * 86_400
        let query = "period1=\(period1)&period2=\(period2)&interval=1d&events=div%2Csplits"
        let data = try await fetch(path: "/v8/finance/chart/\(Self.encode(symbol))", query: query)
        return try Self.parseChart(data, symbol: symbol, range: request.range, securityCurrency: request.currency)
    }

    public func latest(_ request: QuoteRequest) async throws -> LatestQuote {
        let symbol = try Self.symbol(for: request)
        let data = try await fetch(path: "/v8/finance/chart/\(Self.encode(symbol))", query: "range=1d&interval=1d")
        let history = try Self.parseChart(data, symbol: symbol, range: Day(rawValue: Int32.min / 2)...Day(rawValue: Int32.max / 2), securityCurrency: request.currency)
        if let latest = history.latest { return latest }
        guard let point = history.points.last else { throw MarketDataError.malformedResponse("Yahoo Finance sent no quote for \(symbol).") }
        return LatestQuote(point: point, currency: history.currency, name: history.name)
    }

    // MARK: Search

    /// Searches instruments by name, ticker or ISIN.
    public func search(_ query: String) async throws -> [SymbolMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? trimmed
        let data = try await fetch(path: "/v1/finance/search", query: "q=\(q)&quotesCount=12&newsCount=0&listsCount=0&enableFuzzyQuery=false")
        return try Self.parseSearch(data)
    }

    /// Instruments listed under an ISIN (Yahoo's search understands ISINs).
    public func lookup(isin: String) async throws -> [SymbolMatch] {
        let normalized = isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ISIN.isPlausible(normalized) else { return [] }
        return try await search(normalized)
    }

    // MARK: Transport

    private func fetch(path: String, query: String) async throws -> Data {
        var lastError: Error = MarketDataError.invalidConfiguration("No Yahoo Finance host configured.")
        for host in hosts {
            guard let url = URL(string: "https://\(host)\(path)?\(query)") else { throw MarketDataError.invalidURL(path) }
            do {
                let response = try await http.send(HTTPRequest(url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"]))
                if response.isSuccess { return response.body }
                let error = MarketDataError(status: response.status, url: url)
                // Rate limiting and server trouble are per host: try the next one.
                if response.status == 429 || response.status >= 500 {
                    lastError = error
                    continue
                }
                // A client error is final. Yahoo explains it in an error document, which
                // `parseChart` understands — hand that over instead of the bare status.
                if Self.hasErrorDocument(response.body) { return response.body }
                throw error
            } catch let error as MarketDataError {
                switch error {
                case .network, .timeout, .rateLimited, .http(500..., _): lastError = error
                default: throw error
                }
            }
        }
        throw lastError
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ symbol: String) -> String {
        symbol.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "="))) ?? symbol
    }

    private static func symbol(for request: QuoteRequest) throws -> String {
        let symbol = request.feed.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if !symbol.isEmpty { return symbol }
        let ticker = request.ticker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticker.isEmpty else { throw MarketDataError.invalidConfiguration("Yahoo Finance needs a ticker symbol.") }
        return ticker
    }

    // MARK: Parsing

    private struct Envelope: Decodable {
        struct Chart: Decodable {
            var result: [Result]?
            var error: APIError?
        }
        struct APIError: Decodable {
            var code: String?
            var description: String?
        }
        struct Result: Decodable {
            var meta: Meta
            var timestamp: [Int64]?
            var events: Events?
            var indicators: Indicators?
        }
        struct Meta: Decodable {
            var currency: String?
            var symbol: String?
            var exchangeName: String?
            var fullExchangeName: String?
            var gmtoffset: Int?
            var exchangeTimezoneName: String?
            var regularMarketPrice: Double?
            var regularMarketTime: Int64?
            var longName: String?
            var shortName: String?
        }
        struct Events: Decodable {
            struct Dividend: Decodable {
                var amount: Double
                var date: Int64
            }
            struct Split: Decodable {
                var date: Int64
                var numerator: Double
                var denominator: Double
            }
            var dividends: [String: Dividend]?
            var splits: [String: Split]?
        }
        struct Indicators: Decodable {
            struct Quote: Decodable {
                var close: [Double?]?
            }
            var quote: [Quote]?
        }
        var chart: Chart
    }

    private static func hasErrorDocument(_ body: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: body))?.chart.error != nil
    }

    /// Yahoo's answer (HTTP 400) to a window that lies entirely after the newest quote.
    private static func isEmptyWindow(_ error: Envelope.APIError) -> Bool {
        error.description?.hasPrefix("Data doesn't exist for startDate") == true
    }

    /// Parses a `v8/finance/chart` response. Quotes, events and timestamps that cannot be real
    /// (non-positive, non-finite, out of range) are skipped; an error document throws, except
    /// for "no data in this window", which yields an empty history.
    ///
    /// - Parameters:
    ///   - range: points and events outside of it are dropped.
    ///   - securityCurrency: decides whether minor-unit quotes are converted, see ``MinorCurrency``.
    public static func parseChart(_ data: Data, symbol: String, range: ClosedRange<Day>, securityCurrency: CurrencyCode) throws -> QuoteHistory {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw MarketDataError.malformedResponse("Yahoo Finance sent an unreadable answer for \(symbol).")
        }
        if let error = envelope.chart.error {
            if error.code == "Not Found" { throw MarketDataError.symbolNotFound(symbol) }
            // "No quotes in this window" is an empty history, not a failure.
            if isEmptyWindow(error) { return QuoteHistory() }
            throw MarketDataError.malformedResponse(error.description ?? error.code ?? "Yahoo Finance reported an error.")
        }
        guard let result = envelope.chart.result?.first else { throw MarketDataError.symbolNotFound(symbol) }
        let meta = result.meta
        let unit = MinorCurrency.resolve(reported: meta.currency, securityCurrency: securityCurrency)
        var zone = ExchangeZone(identifier: meta.exchangeTimezoneName, fallbackOffset: meta.gmtoffset ?? 0)

        let timestamps = result.timestamp ?? []
        let closes = result.indicators?.quote?.first?.close ?? []
        var points = [PricePoint]()
        points.reserveCapacity(timestamps.count)
        for i in 0..<min(timestamps.count, closes.count) {
            guard let close = closes[i], let price = Price(checkedQuote: cleanedQuote(close) / unit.divisor),
                  let day = zone.day(of: timestamps[i]), range.contains(day) else { continue }
            if let last = points.last, last.day == day {
                points[points.count - 1].price = price // a live bar on top of the daily bar
            } else {
                points.append(PricePoint(day: day, price: price))
            }
        }

        var events = [QuoteEvent]()
        for dividend in (result.events?.dividends ?? [:]).values {
            // Same sanity bounds as for quotes: positive, finite, representable.
            guard Price(checkedQuote: dividend.amount / unit.divisor) != nil,
                  let day = zone.day(of: dividend.date), range.contains(day) else { continue }
            let detail = Self.amountText(cleanedQuote(dividend.amount), divisor: unit.divisor)
            events.append(QuoteEvent(day: day, kind: .dividend, detail: detail))
        }
        for split in (result.events?.splits ?? [:]).values {
            guard Self.plausibleSplitTerm(split.numerator), Self.plausibleSplitTerm(split.denominator),
                  let day = zone.day(of: split.date), range.contains(day) else { continue }
            events.append(QuoteEvent(day: day, kind: .split, detail: "\(compactDescription(split.numerator)):\(compactDescription(split.denominator))"))
        }
        events.sort { ($0.day, $0.kind.rawValue) < ($1.day, $1.kind.rawValue) }

        let name = meta.longName ?? meta.shortName
        var latest: LatestQuote?
        if let quote = meta.regularMarketPrice, let price = Price(checkedQuote: cleanedQuote(quote) / unit.divisor),
           let time = meta.regularMarketTime, let day = zone.day(of: time) {
            latest = LatestQuote(point: PricePoint(day: day, price: price), time: Date(timeIntervalSince1970: Double(time)),
                                 currency: unit.currency, name: name)
        }
        return QuoteHistory(points: normalized(points), currency: unit.currency, name: name,
                            exchange: meta.fullExchangeName ?? meta.exchangeName, events: events, latest: latest)
    }

    /// Split ratios are small positive numbers; anything else is a damaged response.
    private static func plausibleSplitTerm(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 1_000_000
    }

    /// Formats a per-share amount, dividing in decimal space so that 2.5 pence becomes "0.025"
    /// rather than "0.025000000000000001".
    static func amountText(_ amount: Double, divisor: Double) -> String {
        let text = compactDescription(amount)
        guard divisor != 1, let decimal = Decimal(string: text) else { return text }
        return "\(decimal / Decimal(divisor))"
    }

    private struct SearchEnvelope: Decodable {
        struct Quote: Decodable {
            var symbol: String?
            var shortname: String?
            var longname: String?
            var exchange: String?
            var exchDisp: String?
            var quoteType: String?
        }
        var quotes: [Quote]?
    }

    /// Parses a `v1/finance/search` response (Yahoo's ranking is kept).
    public static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        let envelope: SearchEnvelope
        do {
            envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        } catch {
            throw MarketDataError.malformedResponse("Yahoo Finance sent an unreadable search result.")
        }
        return (envelope.quotes ?? []).compactMap { quote in
            guard let symbol = quote.symbol, !symbol.isEmpty else { return nil }
            let type: SymbolMatch.InstrumentType
            switch quote.quoteType?.uppercased() {
            case "EQUITY": type = .equity
            case "ETF": type = .etf
            case "MUTUALFUND": type = .fund
            case "INDEX": type = .index
            case "CURRENCY": type = .currency
            case "CRYPTOCURRENCY": type = .crypto
            case "FUTURE": type = .future
            case "OPTION": type = .option
            default: type = .other
            }
            return SymbolMatch(symbol: symbol, name: quote.longname ?? quote.shortname ?? symbol, exchange: quote.exchange ?? "",
                               exchangeName: quote.exchDisp ?? quote.exchange ?? "", type: type, provider: Self.id)
        }
    }
}

/// Converts exchange timestamps to calendar days in the exchange's time zone, caching the UTC
/// offset between daylight-saving transitions.
struct ExchangeZone {
    private let zone: TimeZone?
    private let fallbackOffset: Int
    private var validFrom = Int64.max
    private var validUntil = Int64.min
    private var offset = 0

    init(identifier: String?, fallbackOffset: Int) {
        zone = identifier.flatMap { TimeZone(identifier: $0) }
        self.fallbackOffset = fallbackOffset
    }

    /// Timestamps outside of this range (years 1653 … 2286) are not exchange timestamps.
    private static let plausible: ClosedRange<Int64> = -10_000_000_000...10_000_000_000

    /// The exchange-local day of a Unix timestamp; nil for timestamps that cannot be real.
    mutating func day(of timestamp: Int64) -> Day? {
        guard Self.plausible.contains(timestamp) else { return nil }
        var seconds = timestamp
        if let zone {
            if timestamp < validFrom || timestamp >= validUntil {
                let date = Date(timeIntervalSince1970: Double(timestamp))
                offset = zone.secondsFromGMT(for: date)
                validFrom = timestamp
                validUntil = zone.nextDaylightSavingTimeTransition(after: date).map { Int64($0.timeIntervalSince1970) } ?? Int64.max
            }
            seconds += Int64(offset)
        } else {
            seconds += Int64(fallbackOffset)
        }
        return Day(rawValue: Int32(clamping: seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400))
    }
}

/// Handling of currencies quoted in 1/100 of the major unit (pence sterling, South African
/// cents, Israeli agorot).
public enum MinorCurrency {
    /// Minor-unit codes as used by data vendors, mapped to their ISO major currency.
    public static let majorUnit: [String: CurrencyCode] = [
        "GBp": "GBP", "GBX": "GBP", "GBx": "GBP",
        "ZAc": "ZAR", "ZAC": "ZAR", "ZAX": "ZAR",
        "ILA": "ILS", "ILa": "ILS", "ILX": "ILS",
    ]

    /// Decides how quotes reported in `reported` are stored for a security kept in
    /// `securityCurrency`: converted to the major unit (divisor 100) — unless the security is
    /// itself kept in a minor unit of the same currency, in which case quotes stay as they are.
    public static func resolve(reported: String?, securityCurrency: CurrencyCode) -> (currency: CurrencyCode?, divisor: Double) {
        guard let reported, let major = majorUnit[reported] else { return (reported, 1) }
        if majorUnit[securityCurrency] == major { return (securityCurrency, 1) }
        return (major, 100)
    }
}

/// ISIN syntax helpers.
public enum ISIN {
    /// Two letters, nine alphanumerics, one check digit — and a valid Luhn checksum.
    public static func isPlausible(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 12, bytes[0...1].allSatisfy({ $0 >= 65 && $0 <= 90 }), bytes[11] >= 48, bytes[11] <= 57 else { return false }
        var digits = [Int]()
        digits.reserveCapacity(24)
        for b in bytes {
            switch b {
            case 48...57: digits.append(Int(b - 48))
            case 65...90:
                let v = Int(b - 55)
                digits.append(v / 10)
                digits.append(v % 10)
            default: return false
            }
        }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
