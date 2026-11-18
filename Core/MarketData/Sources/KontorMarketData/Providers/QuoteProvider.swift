import Foundation
import KontorModel

/// What a provider is asked for: the quotes of one instrument over a range of days.
public struct QuoteRequest: Hashable, Sendable {
    /// The feed configuration (`symbol` and `options` are provider-specific).
    public var feed: QuoteFeed
    /// The currency the security is kept in. Providers use it to pick the quote currency
    /// (CoinGecko), to fill `{CURRENCY}` and to decide whether pence quotes are converted.
    public var currency: CurrencyCode
    public var ticker: String
    public var isin: String
    public var wkn: String
    /// First and last day wanted (inclusive).
    public var range: ClosedRange<Day>

    public init(feed: QuoteFeed, currency: CurrencyCode, ticker: String = "", isin: String = "", wkn: String = "", range: ClosedRange<Day>) {
        self.feed = feed
        self.currency = currency
        self.ticker = ticker
        self.isin = isin
        self.wkn = wkn
        self.range = range
    }

    /// Builds the request for a security's configured feed. Returns nil if it has none.
    public init?(security: Security, range: ClosedRange<Day>) {
        guard let feed = security.feed else { return nil }
        self.init(feed: feed, currency: security.currency, ticker: security.ticker, isin: security.isin, wkn: security.wkn, range: range)
    }

    /// Values for ``URLTemplate`` placeholders.
    public var templateContext: URLTemplate.Context {
        URLTemplate.Context(ticker: ticker, isin: isin, wkn: wkn, currency: currency, from: range.lowerBound, to: range.upperBound)
    }

    /// A trimmed, non-empty option value.
    public func option(_ key: String) -> String? {
        guard let value = feed.options[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// A dividend or split reported by a provider alongside the quotes.
public struct QuoteEvent: Hashable, Sendable {
    public var day: Day
    public var kind: SecurityEvent.Kind
    /// Same conventions as `SecurityEvent.detail`: splits `"4:1"` (new:old), dividends the
    /// per-share amount in the quote currency, e.g. `"0.205"`.
    public var detail: String

    public init(day: Day, kind: SecurityEvent.Kind, detail: String) {
        self.day = day
        self.kind = kind
        self.detail = detail
    }
}

/// The most recent quote of an instrument.
public struct LatestQuote: Hashable, Sendable {
    public var point: PricePoint
    /// Time of the quote, when the provider reports it.
    public var time: Date?
    public var currency: CurrencyCode?
    public var name: String?

    public init(point: PricePoint, time: Date? = nil, currency: CurrencyCode? = nil, name: String? = nil) {
        self.point = point
        self.time = time
        self.currency = currency
        self.name = name
    }
}

/// Historical quotes plus whatever metadata the provider knows about the instrument.
public struct QuoteHistory: Hashable, Sendable {
    /// Daily closes, ascending, one per day, within the requested range.
    public var points: [PricePoint]
    /// Currency of `points` (already converted from minor units such as pence), if known.
    public var currency: CurrencyCode?
    /// Instrument name as known to the provider.
    public var name: String?
    /// Exchange name as known to the provider.
    public var exchange: String?
    /// Dividends and splits within the requested range, ascending.
    public var events: [QuoteEvent]
    /// The latest quote, when the response carries one for free.
    public var latest: LatestQuote?

    public init(points: [PricePoint] = [], currency: CurrencyCode? = nil, name: String? = nil, exchange: String? = nil,
                events: [QuoteEvent] = [], latest: LatestQuote? = nil) {
        self.points = points
        self.currency = currency
        self.name = name
        self.exchange = exchange
        self.events = events
        self.latest = latest
    }
}

/// A source of quotes. One instance serves all securities using it, concurrently.
public protocol QuoteProvider: Sendable {
    /// Identity, display name and the options the provider understands.
    var descriptor: ProviderDescriptor { get }

    /// Daily closes for `request.range`. An empty result is not an error (weekends, holidays).
    func history(_ request: QuoteRequest) async throws -> QuoteHistory

    /// The most recent quote. `request.range` is ignored.
    func latest(_ request: QuoteRequest) async throws -> LatestQuote
}

extension QuoteProvider {
    /// Default: the last point of the past two weeks of history.
    public func latest(_ request: QuoteRequest) async throws -> LatestQuote {
        var recent = request
        let today = Day.today
        recent.range = today.advanced(by: -14)...today
        let history = try await history(recent)
        if let latest = history.latest { return latest }
        guard let point = history.points.last else {
            throw MarketDataError.malformedResponse("No recent quote available.")
        }
        return LatestQuote(point: point, currency: history.currency, name: history.name)
    }
}

/// Describes a provider to the UI: how to label it and which settings to offer.
public struct ProviderDescriptor: Hashable, Sendable, Identifiable {
    /// The value stored in `QuoteFeed.provider`.
    public var id: String
    /// Human-readable name ("Yahoo Finance").
    public var name: String
    /// One or two sentences about the source.
    public var summary: String
    /// How `QuoteFeed.symbol` is used. nil = the provider has no symbol field.
    public var symbol: ProviderOption?
    /// The keys of `QuoteFeed.options` the provider understands, in display order.
    public var options: [ProviderOption]
    /// Whether ``SymbolSearching`` is available for this provider.
    public var supportsSearch: Bool
    /// Whether the provider downloads anything at all (`false` for "manual").
    public var isAutomatic: Bool

    public init(id: String, name: String, summary: String, symbol: ProviderOption?, options: [ProviderOption] = [],
                supportsSearch: Bool = false, isAutomatic: Bool = true) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.options = options
        self.supportsSearch = supportsSearch
        self.isAutomatic = isAutomatic
    }
}

/// One configurable value of a provider — enough to render a form field generically.
public struct ProviderOption: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Free text.
        case text
        /// A URL template; show ``URLTemplate/placeholders`` as hints.
        case urlTemplate
        /// A ``JSONPath`` expression.
        case jsonPath
        /// A secret such as an API key (use a secure field).
        case secret
        /// One of a fixed set of values.
        case choice([Choice])
    }

    public struct Choice: Hashable, Sendable, Identifiable {
        /// The stored value.
        public var value: String
        /// The label to display.
        public var label: String
        public var id: String { value }
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    /// Key in `QuoteFeed.options` (for the symbol field: `"symbol"`).
    public var key: String
    public var label: String
    /// Explanatory text for a tooltip or footnote.
    public var help: String
    public var kind: Kind
    public var isRequired: Bool
    /// Example input.
    public var placeholder: String
    /// The value assumed when the option is absent.
    public var defaultValue: String
    public var id: String { key }

    public init(key: String, label: String, help: String = "", kind: Kind = .text, isRequired: Bool = false,
                placeholder: String = "", defaultValue: String = "") {
        self.key = key
        self.label = label
        self.help = help
        self.kind = kind
        self.isRequired = isRequired
        self.placeholder = placeholder
        self.defaultValue = defaultValue
    }
}

/// A search hit: an instrument a provider can deliver quotes for.
public struct SymbolMatch: Hashable, Sendable, Identifiable {
    /// Coarse instrument category.
    public enum InstrumentType: String, Hashable, Sendable, CaseIterable {
        case equity, etf, fund, index, currency, crypto, future, option, other
    }

    /// The provider-specific symbol to store in `QuoteFeed.symbol`.
    public var symbol: String
    public var name: String
    /// Provider's exchange code ("GER", "NMS"); empty if not applicable.
    public var exchange: String
    /// Display name of the exchange ("XETRA", "NASDAQ").
    public var exchangeName: String
    public var type: InstrumentType
    /// The provider id to store in `QuoteFeed.provider`.
    public var provider: String
    public var id: String { provider + ":" + symbol }

    public init(symbol: String, name: String, exchange: String = "", exchangeName: String = "", type: InstrumentType = .other, provider: String) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.exchangeName = exchangeName
        self.type = type
        self.provider = provider
    }

    /// A feed pointing at this instrument.
    public var feed: QuoteFeed { QuoteFeed(provider: provider, symbol: symbol) }
}

/// Providers that can look up instruments by name, ticker or ISIN.
public protocol SymbolSearching: Sendable {
    /// Instruments matching `query`, best match first.
    func search(_ query: String) async throws -> [SymbolMatch]
}
