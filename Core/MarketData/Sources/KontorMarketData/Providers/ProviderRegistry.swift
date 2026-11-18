import Foundation
import KontorModel

/// The set of quote providers, keyed by `QuoteFeed.provider`.
///
/// ```swift
/// let registry = ProviderRegistry.standard()            // real network
/// let provider = try registry.provider(for: security.feed!)
/// for descriptor in registry.descriptors { … }           // build the feed picker / form
/// ```
public struct ProviderRegistry: Sendable {
    private var providers: [String: any QuoteProvider] = [:]
    private var order: [String] = []

    /// A registry with the given providers, in display order.
    public init(_ providers: [any QuoteProvider] = []) {
        for provider in providers { register(provider) }
    }

    /// All built-in providers (`yahoo`, `coingecko`, `json-url`, `csv-url`, `manual`) on top of
    /// `http` — by default the production stack with throttling and retries.
    public static func standard(http: any HTTPClient = ResilientHTTPClient.standard()) -> ProviderRegistry {
        ProviderRegistry([
            YahooProvider(http: http),
            CoinGeckoProvider(http: http),
            JSONURLProvider(http: http),
            CSVURLProvider(http: http),
            ManualProvider(),
        ])
    }

    /// Adds a provider, replacing one with the same id.
    public mutating func register(_ provider: any QuoteProvider) {
        let id = provider.descriptor.id
        if providers.updateValue(provider, forKey: id) == nil { order.append(id) }
    }

    /// The provider with the given id.
    public func provider(id: String) -> (any QuoteProvider)? { providers[id] }

    /// The provider for a feed. Throws ``MarketDataError/unknownProvider(_:)``.
    public func provider(for feed: QuoteFeed) throws -> any QuoteProvider {
        guard let provider = providers[feed.provider] else { throw MarketDataError.unknownProvider(feed.provider) }
        return provider
    }

    /// Descriptors of all providers in registration order.
    public var descriptors: [ProviderDescriptor] { order.compactMap { providers[$0]?.descriptor } }

    /// The descriptor of one provider.
    public func descriptor(id: String) -> ProviderDescriptor? { providers[id]?.descriptor }

    /// Whether a feed leads to downloads (`false` for nil, "manual" and unknown providers).
    public func isAutomatic(_ feed: QuoteFeed?) -> Bool {
        guard let feed, let provider = providers[feed.provider] else { return false }
        return provider.descriptor.isAutomatic
    }

    /// Checks a feed's configuration without touching the network: known provider, required
    /// symbol and options present, path expressions and formats well-formed. Returns
    /// human-readable problems (empty = looks fine).
    public func validate(_ feed: QuoteFeed) -> [String] {
        guard let descriptor = descriptor(id: feed.provider) else { return [MarketDataError.unknownProvider(feed.provider).description] }
        var problems = [String]()
        func value(_ option: ProviderOption) -> String {
            (option.key == "symbol" ? feed.symbol : feed.options[option.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for option in [descriptor.symbol].compactMap({ $0 }) + descriptor.options {
            let text = value(option)
            if text.isEmpty {
                if option.isRequired { problems.append("“\(option.label)” is required.") }
                continue
            }
            switch option.kind {
            case .jsonPath:
                do { _ = try JSONPath(text) } catch { problems.append("\(error)") }
            case .urlTemplate:
                let probe = URLTemplate.Context(ticker: "X", isin: "X", wkn: "X", currency: "EUR", from: Day(rawValue: 0), to: Day(rawValue: 0))
                if (try? URLTemplate.url(text, probe)) == nil { problems.append("“\(option.label)” is not a valid http(s) address.") }
            case .choice(let choices):
                if !choices.contains(where: { $0.value == text }) { problems.append("“\(text)” is not a valid value for “\(option.label)”.") }
            case .text, .secret:
                if option.key == "dateFormat", DateFormat(option: text) == nil { problems.append("Unknown date format “\(text)”.") }
                if option.key == "factor", (NumberParser.parse(text) ?? 0) <= 0 { problems.append("The factor must be a positive number.") }
            }
        }
        return problems
    }
}
