import Foundation

/// Where quotes for a security come from. `provider` is an identifier understood by the
/// market-data layer (e.g. "yahoo", "coingecko", "json-url", "csv-url", "manual").
public struct QuoteFeed: Hashable, Codable, Sendable {
    public var provider: String
    /// Provider-specific symbol/identifier (e.g. Yahoo ticker "VWCE.DE", a URL for generic feeds).
    public var symbol: String
    /// Additional provider-specific options (e.g. JSON paths, column names).
    public var options: [String: String]

    public init(provider: String, symbol: String, options: [String: String] = [:]) {
        self.provider = provider
        self.symbol = symbol
        self.options = options
    }
    public static let manual = QuoteFeed(provider: "manual", symbol: "")
}

/// A corporate action or annotation on a security.
public struct SecurityEvent: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case split, dividend, note }
    public var id: UUID
    public var day: Day
    public var kind: Kind
    /// For splits: "2:1" style ratio (new:old). For dividends: per-share amount as text. Otherwise free text.
    public var detail: String

    public init(id: UUID = UUID(), day: Day, kind: Kind, detail: String) {
        self.id = id
        self.day = day
        self.kind = kind
        self.detail = detail
    }
}

/// An investment instrument: stock, ETF, fund, bond, crypto asset, index (for benchmarks) …
public struct Security: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Currency in which `prices` are quoted.
    public var currency: CurrencyCode
    public var isin: String
    public var wkn: String
    public var ticker: String
    public var note: String
    /// Retired securities are hidden from pickers and not updated.
    public var isRetired: Bool
    public var feed: QuoteFeed?
    /// Historical closing prices in `currency`.
    public var prices: PriceSeries
    public var events: [SecurityEvent]
    /// Free-form user attributes (e.g. "TER": "0.22").
    public var attributes: [String: String]
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(), name: String, currency: CurrencyCode, isin: String = "", wkn: String = "",
        ticker: String = "", note: String = "", isRetired: Bool = false, feed: QuoteFeed? = nil,
        prices: PriceSeries = PriceSeries(), events: [SecurityEvent] = [], attributes: [String: String] = [:],
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.isin = isin
        self.wkn = wkn
        self.ticker = ticker
        self.note = note
        self.isRetired = isRetired
        self.feed = feed
        self.prices = prices
        self.events = events
        self.attributes = attributes
        self.updatedAt = updatedAt
    }
}
