import Foundation
import KontorModel

/// Quotes from any URL that returns JSON.
///
/// - Symbol: the URL, optionally with ``URLTemplate`` placeholders.
/// - Options: `datePath` and `closePath` (required, ``JSONPath`` expressions that must match the
///   same number of values), `dateFormat` (``DateFormat/init(option:)``), `factor` (multiplier
///   applied to every price, e.g. `0.01` for pence).
///
/// ```swift
/// QuoteFeed(provider: "json-url", symbol: "https://example.com/api/{ISIN}?from={FROM}",
///           options: ["datePath": "$.data[*].date", "closePath": "$.data[*].close"])
/// ```
public struct JSONURLProvider: QuoteProvider {
    public static let id = "json-url"
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.id,
            name: "JSON (URL)",
            summary: "Reads quotes from any web address that returns JSON. Two path expressions select the dates and the prices.",
            symbol: GenericFeed.urlOption(example: "https://example.com/quotes/{ISIN}?from={FROM}&to={TO}"),
            options: [
                ProviderOption(key: "datePath", label: "Path to dates",
                               help: "Path expression selecting all dates, e.g. $.prices[*].date — or $.series.*~ when the dates are the member names of an object.",
                               kind: .jsonPath, isRequired: true, placeholder: "$.data[*].date"),
                ProviderOption(key: "closePath", label: "Path to prices",
                               help: "Path expression selecting all prices, in the same order as the dates.",
                               kind: .jsonPath, isRequired: true, placeholder: "$.data[*].close"),
                GenericFeed.dateFormatOption,
                GenericFeed.factorOption,
            ]
        )
    }

    public func history(_ request: QuoteRequest) async throws -> QuoteHistory {
        let url = try GenericFeed.url(for: request)
        guard let dateExpression = request.option("datePath"), let closeExpression = request.option("closePath") else {
            throw MarketDataError.invalidConfiguration("The JSON feed needs a path to the dates and a path to the prices.")
        }
        let datePath = try JSONPath(dateExpression)
        let closePath = try JSONPath(closeExpression)
        let format = try GenericFeed.dateFormat(for: request)
        let factor = try GenericFeed.factor(for: request)
        let data = try await http.get(url, headers: GenericFeed.headers(accept: "application/json, */*;q=0.5"))
        try GenericFeed.rejectWebPage(data)
        let points = try Self.parse(data, datePath: datePath, closePath: closePath, dateFormat: format, factor: factor)
        return QuoteHistory(points: points.filter { request.range.contains($0.day) })
    }

    /// Extracts price points from a JSON document. Pairs with an unreadable date or price
    /// (e.g. `null`) are skipped.
    public static func parse(_ data: Data, datePath: JSONPath, closePath: JSONPath, dateFormat: DateFormat = .auto, factor: Double = 1) throws -> [PricePoint] {
        let json = try JSONValue(data: data)
        let dates = datePath.evaluate(json)
        let closes = closePath.evaluate(json)
        guard !dates.isEmpty else { throw MarketDataError.malformedResponse("The path “\(datePath)” matched nothing in the response.") }
        guard dates.count == closes.count else {
            throw MarketDataError.malformedResponse("“\(datePath)” matched \(dates.count) dates but “\(closePath)” matched \(closes.count) prices.")
        }
        var points = [PricePoint]()
        points.reserveCapacity(dates.count)
        for i in dates.indices {
            let day: Day?
            switch dates[i] {
            case .string(let s): day = dateFormat.parse(s)
            case .number(let n): day = dateFormat.parse(number: n)
            default: day = nil
            }
            let value: Double?
            switch closes[i] {
            case .number(let n): value = n
            case .string(let s): value = NumberParser.parse(s)
            default: value = nil
            }
            guard let day, let value, let price = Price(checkedQuote: cleanedQuote(value) * factor) else { continue }
            points.append(PricePoint(day: day, price: price))
        }
        guard !points.isEmpty else { throw MarketDataError.malformedResponse("The response contains no readable quotes.") }
        return normalized(points)
    }
}

/// Quotes from any URL that returns CSV (or TSV) text.
///
/// - Symbol: the URL, optionally with ``URLTemplate`` placeholders.
/// - Options (all optional, everything is auto-detected): `dateColumn`, `closeColumn` (header
///   title or 1-based number), `delimiter`, `decimalSeparator` (`.` or `,`), `dateFormat`, `factor`.
public struct CSVURLProvider: QuoteProvider {
    public static let id = "csv-url"
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public var descriptor: ProviderDescriptor {
        let auto = ProviderOption.Choice("", "Detect automatically")
        return ProviderDescriptor(
            id: Self.id,
            name: "CSV (URL)",
            summary: "Reads quotes from any web address that returns a CSV table. Columns, delimiter and number format are detected automatically.",
            symbol: GenericFeed.urlOption(example: "https://example.com/quotes/{TICKER}.csv?from={FROM}"),
            options: [
                ProviderOption(key: "dateColumn", label: "Date column", help: "Column title or number (1 = first). Leave empty to detect.", placeholder: "Date"),
                ProviderOption(key: "closeColumn", label: "Price column", help: "Column title or number (1 = first). Leave empty to detect.", placeholder: "Close"),
                ProviderOption(key: "delimiter", label: "Delimiter",
                               kind: .choice([auto, .init(",", "Comma (,)"), .init(";", "Semicolon (;)"), .init("tab", "Tab"), .init("|", "Pipe (|)")])),
                ProviderOption(key: "decimalSeparator", label: "Decimal separator",
                               kind: .choice([auto, .init(".", "Point (1234.56)"), .init(",", "Comma (1234,56)")])),
                GenericFeed.dateFormatOption,
                GenericFeed.factorOption,
            ]
        )
    }

    public func history(_ request: QuoteRequest) async throws -> QuoteHistory {
        let url = try GenericFeed.url(for: request)
        let options = try Self.options(for: request)
        let factor = try GenericFeed.factor(for: request)
        let data = try await http.get(url, headers: GenericFeed.headers(accept: "text/csv, text/plain, */*;q=0.5"))
        try GenericFeed.rejectWebPage(data)
        var points = try CSVQuoteParser.parse(data, options: options).filter { request.range.contains($0.day) }
        if factor != 1 {
            points = points.compactMap { point in
                Price(checkedQuote: point.price.doubleValue * factor).map { PricePoint(day: point.day, price: $0) }
            }
        }
        return QuoteHistory(points: points)
    }

    /// Translates feed options into ``CSVOptions``.
    public static func options(for request: QuoteRequest) throws -> CSVOptions {
        var decimal: DecimalSeparator?
        if let text = request.option("decimalSeparator"), text.lowercased() != "auto" {
            guard let parsed = DecimalSeparator(rawValue: text) else {
                throw MarketDataError.invalidConfiguration("The decimal separator must be “.” or “,”.")
            }
            decimal = parsed
        }
        return CSVOptions(
            delimiter: request.option("delimiter"), dateColumn: request.option("dateColumn"), closeColumn: request.option("closeColumn"),
            decimalSeparator: decimal, dateFormat: try GenericFeed.dateFormat(for: request)
        )
    }
}

/// The "manual" provider: prices are maintained by hand, nothing is downloaded.
public struct ManualProvider: QuoteProvider {
    public static let id = "manual"

    public init() {}

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: Self.id, name: "Manual", summary: "Prices are entered or imported by hand; nothing is downloaded.",
                           symbol: nil, isAutomatic: false)
    }

    public func history(_ request: QuoteRequest) async throws -> QuoteHistory { QuoteHistory() }

    public func latest(_ request: QuoteRequest) async throws -> LatestQuote {
        throw MarketDataError.unsupported("Manual securities have no online quote.")
    }
}

/// Shared pieces of the generic URL providers.
enum GenericFeed {
    static func urlOption(example: String) -> ProviderOption {
        ProviderOption(
            key: "symbol", label: "URL",
            help: "Web address of the data. Placeholders: {TICKER}, {ISIN}, {WKN}, {CURRENCY}, {FROM}, {TO} (dates as yyyy-MM-dd; other notations with {FROM:unix}, {FROM:yyyyMMdd}, {TO:dd.MM.yyyy} …).",
            kind: .urlTemplate, isRequired: true, placeholder: example
        )
    }

    static let dateFormatOption = ProviderOption(
        key: "dateFormat", label: "Date format",
        help: "Leave empty to detect. Otherwise “unix”, “unix-ms” or a pattern such as dd.MM.yyyy, MM/dd/yyyy or d-MMM-yy.",
        placeholder: "auto"
    )

    static let factorOption = ProviderOption(
        key: "factor", label: "Factor",
        help: "Every price is multiplied by this number, e.g. 0.01 to convert pence to pounds.",
        placeholder: "1", defaultValue: "1"
    )

    /// Bot walls and error pages answer 200 with HTML; say so instead of reporting a parse error.
    static func rejectWebPage(_ data: Data) throws {
        let head = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") {
            throw MarketDataError.malformedResponse("The address returned a web page instead of data.")
        }
    }

    static func headers(accept: String) -> [String: String] {
        ["User-Agent": UserAgent.minimal, "Accept": accept]
    }

    static func url(for request: QuoteRequest) throws -> URL {
        let template = request.feed.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw MarketDataError.invalidConfiguration("The feed needs a URL.") }
        return try URLTemplate.url(template, request.templateContext)
    }

    static func dateFormat(for request: QuoteRequest) throws -> DateFormat {
        guard let format = DateFormat(option: request.option("dateFormat")) else {
            throw MarketDataError.invalidConfiguration("Unknown date format “\(request.option("dateFormat") ?? "")”.")
        }
        return format
    }

    static func factor(for request: QuoteRequest) throws -> Double {
        guard let text = request.option("factor") else { return 1 }
        guard let factor = NumberParser.parse(text), factor > 0 else {
            throw MarketDataError.invalidConfiguration("The factor must be a positive number.")
        }
        return factor
    }
}
