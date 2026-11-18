import Foundation
import KontorModel

/// Crypto asset prices from the public CoinGecko API (`market_chart/range`).
///
/// - Symbol: the CoinGecko coin id (`bitcoin`, `ethereum`, `solana`) — find it with ``search(_:)``.
/// - Quote currency: the security's currency (override with option `currency`).
/// - The daily close of a day is the price at 24:00 UTC, i.e. the last sample up to and including
///   the following midnight; the running day carries the most recent price.
/// - Without a paid plan CoinGecko serves the past 365 days only; older days are not requested.
public struct CoinGeckoProvider: QuoteProvider, SymbolSearching {
    public static let id = "coingecko"
    /// Days of history the keyless/demo API serves.
    public static let publicHistoryDays = 365

    private let http: any HTTPClient
    private let today: @Sendable () -> Day

    /// - Parameter today: the current UTC day (injectable for tests).
    public init(http: any HTTPClient, today: @escaping @Sendable () -> Day = { Day(date: Date(), timeZone: TimeZone(secondsFromGMT: 0)!) }) {
        self.http = http
        self.today = today
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.id,
            name: "CoinGecko",
            summary: "Daily prices of crypto assets in any major currency. The free API covers the past 365 days.",
            symbol: ProviderOption(
                key: "symbol", label: "Coin ID", help: "The CoinGecko identifier of the coin, e.g. bitcoin or ethereum.",
                isRequired: true, placeholder: "bitcoin"
            ),
            options: [
                ProviderOption(key: "currency", label: "Quote currency",
                               help: "Currency of the downloaded prices. Defaults to the currency of the security.", placeholder: "EUR"),
                ProviderOption(key: "apiKey", label: "API key", help: "Optional CoinGecko API key for higher rate limits.", kind: .secret),
                ProviderOption(key: "plan", label: "Plan", help: "Paid plans use the Pro API and are not limited to 365 days of history.",
                               kind: .choice([.init("demo", "Free / Demo"), .init("pro", "Pro")]), defaultValue: "demo"),
            ],
            supportsSearch: true
        )
    }

    public func history(_ request: QuoteRequest) async throws -> QuoteHistory {
        let coin = request.feed.symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !coin.isEmpty else { throw MarketDataError.invalidConfiguration("CoinGecko needs a coin ID such as “bitcoin”.") }
        let currency = (request.option("currency") ?? request.currency).uppercased()
        let isPro = request.option("plan")?.lowercased() == "pro"

        var lower = request.range.lowerBound
        let upper = min(request.range.upperBound, today())
        if !isPro { lower = max(lower, today().advanced(by: -(Self.publicHistoryDays - 1))) }
        guard lower <= upper else { return QuoteHistory(currency: currency) }

        let from = Int64(lower.rawValue) * 86_400
        let to = Int64(upper.rawValue + 1) * 86_400
        let id = coin.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? coin
        let data = try await get(
            "/coins/\(id)/market_chart/range?vs_currency=\(currency.lowercased())&from=\(from)&to=\(to)",
            request: request, coin: coin
        )
        let points = try Self.parseMarketChart(data).filter { lower...upper ~= $0.day }
        return QuoteHistory(points: points, currency: currency)
    }

    /// Searches coins by name or ticker; `SymbolMatch.symbol` is the coin id.
    public func search(_ query: String) async throws -> [SymbolMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        return try Self.parseSearch(try await get("/search?query=\(q)", request: nil, coin: trimmed))
    }

    private func get(_ pathAndQuery: String, request: QuoteRequest?, coin: String) async throws -> Data {
        let isPro = request?.option("plan")?.lowercased() == "pro"
        let host = isPro ? "pro-api.coingecko.com" : "api.coingecko.com"
        guard let url = URL(string: "https://\(host)/api/v3\(pathAndQuery)") else { throw MarketDataError.invalidURL(pathAndQuery) }
        var headers = ["User-Agent": UserAgent.minimal, "Accept": "application/json"]
        if let key = request?.option("apiKey") { headers[isPro ? "x-cg-pro-api-key" : "x-cg-demo-api-key"] = key }
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        if response.isSuccess { return response.body }
        if response.status == 404 { throw MarketDataError.symbolNotFound(coin) }
        if response.status != 429, let message = Self.errorMessage(in: response.body) {
            throw MarketDataError.unsupported("CoinGecko: \(message)")
        }
        throw MarketDataError(status: response.status, url: url)
    }

    /// CoinGecko reports errors as `{"error": "…"}` or `{"error": {"status": {"error_message": "…"}}}`
    /// or `{"status": {"error_message": "…"}}`.
    private static func errorMessage(in body: Data) -> String? {
        guard let json = try? JSONValue(data: body) else { return nil }
        let message = json["error"]?.stringValue
            ?? json["error"]?["status"]?["error_message"]?.stringValue
            ?? json["status"]?["error_message"]?.stringValue
        return message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct MarketChart: Decodable {
        var prices: [[Double]]
    }

    /// Parses a `market_chart` response into daily closes (see the type documentation for the
    /// day assignment). Works for 5-minute, hourly and daily granularity alike.
    public static func parseMarketChart(_ data: Data) throws -> [PricePoint] {
        let chart: MarketChart
        do {
            chart = try JSONDecoder().decode(MarketChart.self, from: data)
        } catch {
            throw MarketDataError.malformedResponse("CoinGecko sent an unreadable answer.")
        }
        var points = [PricePoint]()
        for sample in chart.prices where sample.count >= 2 {
            // Milliseconds since 1970; beyond ±1e13 (year 2286) the sample is garbage.
            guard abs(sample[0]) <= 1e13, let price = Price(checkedQuote: sample[1]) else { continue }
            // A sample at exactly midnight is the close of the day that just ended.
            let day = Day(rawValue: Int32(((sample[0] - 1) / 86_400_000).rounded(.down)))
            if let last = points.last, last.day == day {
                points[points.count - 1].price = price
            } else {
                points.append(PricePoint(day: day, price: price))
            }
        }
        return normalized(points)
    }

    private struct SearchResult: Decodable {
        struct Coin: Decodable {
            var id: String
            var name: String?
            var symbol: String?
        }
        var coins: [Coin]?
    }

    /// Parses a `/search` response.
    public static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        let result: SearchResult
        do {
            result = try JSONDecoder().decode(SearchResult.self, from: data)
        } catch {
            throw MarketDataError.malformedResponse("CoinGecko sent an unreadable search result.")
        }
        return (result.coins ?? []).map { coin in
            let ticker = coin.symbol.map { " (\($0.uppercased()))" } ?? ""
            return SymbolMatch(symbol: coin.id, name: (coin.name ?? coin.id) + ticker, exchangeName: "CoinGecko", type: .crypto, provider: Self.id)
        }
    }
}
