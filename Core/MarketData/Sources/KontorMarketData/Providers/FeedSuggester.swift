import Foundation
import KontorModel

/// A proposed quote feed for a security.
public struct FeedSuggestion: Hashable, Sendable, Identifiable {
    /// Ready to assign to `Security.feed`.
    public var feed: QuoteFeed
    /// The instrument behind the suggestion.
    public var match: SymbolMatch
    /// Quote currency: confirmed by the provider when `isVerified`, otherwise inferred from the
    /// exchange (nil if unknown).
    public var currency: CurrencyCode?
    /// Whether the currency was confirmed with a live quote.
    public var isVerified: Bool
    /// Ranking score (higher is better); only meaningful relative to other suggestions.
    public var score: Int
    public var id: String { match.id }

    public init(feed: QuoteFeed, match: SymbolMatch, currency: CurrencyCode? = nil, isVerified: Bool = false, score: Int = 0) {
        self.feed = feed
        self.match = match
        self.currency = currency
        self.isVerified = isVerified
        self.score = score
    }
}

/// Suggests quote feeds for a security from its ISIN, ticker or name by searching Yahoo
/// Finance and ranking the listings by how well exchange and currency fit the security.
///
/// ```swift
/// let suggester = FeedSuggester(yahoo: YahooProvider(http: http))
/// if let best = try await suggester.suggestions(for: security).first { security.feed = best.feed }
/// ```
public struct FeedSuggester: Sendable {
    private let search: any SymbolSearching
    private let quotes: (any QuoteProvider)?

    /// - Parameters:
    ///   - search: the symbol search (normally a ``YahooProvider``).
    ///   - quotes: used to confirm the quote currency of the top candidates; nil skips
    ///     verification.
    public init(search: any SymbolSearching, quotes: (any QuoteProvider)?) {
        self.search = search
        self.quotes = quotes
    }

    /// Suggester backed by Yahoo Finance.
    public init(yahoo: YahooProvider) {
        self.init(search: yahoo, quotes: yahoo)
    }

    /// Ranked suggestions, best first; empty if nothing was found.
    ///
    /// Searches by ISIN first (an exact identity), then by ticker, then by name. If the ISIN
    /// only yields listings in other currencies, the instrument's name is searched to discover
    /// its other listings. The quote currency of up to `verify` top candidates is confirmed
    /// with a live quote; candidates confirmed in the security's currency move to the top,
    /// those confirmed in another currency to the bottom.
    public func suggestions(for security: Security, verify: Int = 3) async throws -> [FeedSuggestion] {
        let isin = security.isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ticker = security.ticker.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = security.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = security.currency.uppercased()

        var candidates = [FeedSuggestion]()
        var seen = Set<String>()
        func add(_ matches: [SymbolMatch], trust: Int) {
            for (rank, match) in matches.enumerated() where seen.insert(match.symbol).inserted {
                candidates.append(Self.candidate(match, rank: rank, trust: trust, currency: currency, ticker: ticker))
            }
        }
        var firstError: Error?
        func run(_ query: String) async throws -> [SymbolMatch] {
            do {
                return try await search.search(query)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                return []
            }
        }

        if ISIN.isPlausible(isin) {
            let hits = try await run(isin)
            add(hits, trust: 300)
            // Yahoo often returns a single listing for an ISIN. Look for sibling listings (same
            // instrument name) when none of the hits trades in the security's currency.
            if let first = hits.first, !hits.contains(where: { ExchangeDirectory.currency(of: $0) == currency }) {
                let siblings = try await run(first.name).filter { $0.name.caseInsensitiveCompare(first.name) == .orderedSame }
                add(siblings, trust: 250)
            }
        }
        if !ticker.isEmpty {
            add(try await run(ticker), trust: 100)
        }
        if candidates.isEmpty, !name.isEmpty {
            add(try await run(name), trust: 50)
        }
        if candidates.isEmpty, let firstError { throw firstError }
        candidates.sort { ($0.score, $1.match.symbol) > ($1.score, $0.match.symbol) }

        if let quotes, verify > 0 {
            let today = Day.today
            var confirmedMatch = false
            for i in candidates.indices.prefix(verify) where !confirmedMatch {
                let request = QuoteRequest(feed: candidates[i].feed, currency: security.currency, ticker: ticker, isin: isin, range: today...today)
                guard let latest = try? await quotes.latest(request), let reported = latest.currency else {
                    try Task.checkCancellation()
                    continue
                }
                candidates[i].currency = reported
                candidates[i].isVerified = true
                if reported.caseInsensitiveCompare(security.currency) == .orderedSame {
                    candidates[i].score += 1000
                    confirmedMatch = true
                } else {
                    candidates[i].score -= 1000
                }
            }
            candidates.sort { ($0.score, $1.match.symbol) > ($1.score, $0.match.symbol) }
        }
        return candidates
    }

    /// The best suggestion, or nil.
    public func suggestFeed(for security: Security) async throws -> QuoteFeed? {
        try await suggestions(for: security).first?.feed
    }

    private static func candidate(_ match: SymbolMatch, rank: Int, trust: Int, currency: CurrencyCode, ticker: String) -> FeedSuggestion {
        var score = trust - rank // the provider's own ranking breaks ties
        let exchangeCurrency = ExchangeDirectory.currency(of: match)
        if let exchangeCurrency {
            score += exchangeCurrency == currency ? 200 : -200
        }
        score += ExchangeDirectory.liquidityBonus(exchange: match.exchange)
        switch match.type {
        case .equity, .etf, .fund, .index, .crypto, .currency: break
        case .future, .option, .other: score -= 150
        }
        if !ticker.isEmpty {
            let base = match.symbol.split(separator: ".").first.map(String.init) ?? match.symbol
            if match.symbol.caseInsensitiveCompare(ticker) == .orderedSame { score += 40 }
            else if base.caseInsensitiveCompare(ticker) == .orderedSame { score += 20 }
        }
        return FeedSuggestion(feed: match.feed, match: match, currency: exchangeCurrency, isVerified: false, score: score)
    }
}

/// What is known about Yahoo's exchange codes.
public enum ExchangeDirectory {
    /// Trading currency of exchanges that (almost) exclusively trade in one currency. Venues
    /// with several trading currencies (London, Swiss ETF segment …) are deliberately absent.
    public static let currencyByExchange: [String: CurrencyCode] = {
        var map = [String: CurrencyCode]()
        func set(_ currency: CurrencyCode, _ codes: String) {
            for code in codes.split(separator: " ") { map[String(code)] = currency }
        }
        set("EUR", "GER FRA STU MUN HAM DUS BER HAN PAR AMS BRU LIS MIL MCE VIE HEL ISE ATH TAL RIS LIT")
        set("USD", "NMS NGM NCM NYQ ASE PCX BTS PNK OQB OQX NAS NYS")
        set("CAD", "TOR VAN CNQ NEO")
        set("SEK", "STO")
        set("DKK", "CPH")
        set("NOK", "OSL")
        set("JPY", "JPX")
        set("HKD", "HKG")
        set("AUD", "ASX")
        set("NZD", "NZE")
        set("SGD", "SES")
        set("KRW", "KSC KOE")
        set("CNY", "SHH SHZ")
        set("TWD", "TAI TWO")
        set("INR", "BSE NSI")
        set("BRL", "SAO")
        set("MXN", "MEX")
        set("ZAR", "JNB")
        set("ILS", "TLV")
        set("PLN", "WSE")
        set("CZK", "PRA")
        set("HUF", "BUD")
        set("TRY", "IST")
        return map
    }()

    /// The likely quote currency of a search hit: from its exchange, or for currency pairs and
    /// crypto assets from the symbol (`BTC-EUR`, `EURUSD=X`).
    public static func currency(of match: SymbolMatch) -> CurrencyCode? {
        if let currency = currencyByExchange[match.exchange] { return currency }
        let symbol = match.symbol.uppercased()
        if match.type == .crypto, let dash = symbol.lastIndex(of: "-") {
            let suffix = symbol[symbol.index(after: dash)...]
            if suffix.count == 3 { return String(suffix) }
        }
        if match.type == .currency, symbol.hasSuffix("=X") {
            let pair = symbol.dropLast(2)
            if pair.count == 6 { return String(pair.suffix(3)) }
            if pair.count == 3 { return String(pair) } // "EUR=X" is USD → EUR
        }
        return nil
    }

    /// Small preference for the most liquid venue among listings in the same currency.
    static func liquidityBonus(exchange: String) -> Int {
        switch exchange {
        case "GER", "NMS", "NYQ", "LSE", "PAR", "AMS", "MIL", "TOR", "EBS", "JPX", "HKG", "ASX", "STO": return 30
        case "FRA", "NGM", "NCM", "PCX", "ASE": return 10
        default: return 0
        }
    }
}
