import Foundation
import KontorUI

/// Which securities the master list shows.
enum SecurityFilter: Hashable, Sendable {
    case all, held, notHeld, retired, missingQuotes
    case watchlist(UUID)

    /// `--state filter=held|notheld|retired|missing|watchlist:<uuid | name | 1-based index>`
    init?(launchValue: String, file: PortfolioFile) {
        switch launchValue.lowercased() {
        case "all": self = .all
        case "held": self = .held
        case "notheld", "not-held": self = .notHeld
        case "retired": self = .retired
        case "missing", "missingquotes": self = .missingQuotes
        default:
            guard launchValue.lowercased().hasPrefix("watchlist:") else { return nil }
            let key = String(launchValue.dropFirst("watchlist:".count))
            if let id = UUID(uuidString: key), file.watchlists.contains(where: { $0.id == id }) {
                self = .watchlist(id)
            } else if let index = Int(key), file.watchlists.indices.contains(index - 1) {
                self = .watchlist(file.watchlists[index - 1].id)
            } else if let list = file.watchlists.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                self = .watchlist(list.id)
            } else {
                return nil
            }
        }
    }
}

extension SecurityFilter {
    /// The filter itself — or `.all` when it names a watchlist that no longer exists (deleted, or
    /// its creation undone), which would otherwise leave an empty list under no chip.
    func validated(in watchlists: [Watchlist]) -> SecurityFilter {
        if case .watchlist(let id) = self, !watchlists.contains(where: { $0.id == id }) { return .all }
        return self
    }
}

/// Sort keys of the master list (`--state sort=name|price|day|period|value|updated`).
enum SecuritySort: String, CaseIterable, Sendable, Identifiable {
    case name, price, day, period, value, updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .price: "Latest Price"
        case .day: "Day Change"
        case .period: "Period Change"
        case .value: "Holding Value"
        case .updated: "Latest Quote"
        }
    }

    /// Numbers read best largest-first, names A–Z.
    var defaultAscending: Bool { self == .name }
}

/// Everything the list depends on besides the document and the reporting period.
struct SecurityListQuery: Hashable, Sendable {
    var text = ""
    var filter = SecurityFilter.all
    var sort = SecuritySort.name
    var ascending = true
    var today: Day
}

/// State of a security's quotes, for the status glyph of a row.
enum QuoteHealth: Hashable, Sendable {
    /// Quotes are current (or the security is retired, where old quotes are expected).
    case current
    /// The newest quote is `days` old.
    case stale(days: Int)
    /// No quotes at all.
    case missing
}

/// One row of the master list — plain values, built off the main actor.
struct SecurityRow: Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var ticker: String
    var isin: String
    var wkn: String
    var currency: CurrencyCode
    var isRetired: Bool
    var isBenchmark: Bool
    var latest: Price?
    var latestDay: Day?
    /// Newest quote against the one before it.
    var dayChange: Double?
    /// Price change over the window's reporting period, in the security's currency.
    var periodChange: Double?
    /// About one year of closes, thinned for the sparkline.
    var spark: [Double]
    var shares: Shares
    /// Market value today in the reporting currency; nil when not held or when it cannot be valued.
    var value: Money?
    /// Why a held position has no value ("No quote", "No GBP → EUR exchange rate"); nil otherwise.
    var valuationProblem: String?
    var quoteCount: Int
    var health: QuoteHealth
    /// Display name of the quote feed ("Yahoo Finance", "Manual"), empty without one.
    var feedName: String
    var hasAutomaticFeed: Bool

    var isHeld: Bool { !shares.isZero }

    /// What the list shows as the name (a security without a name is still a row one can pick).
    var displayName: String { name.isEmpty ? Security.untitledName : name }

    /// "VWCE · IE00BK5BQT80" — whatever identifiers exist.
    var identifiers: String {
        [ticker, isin.isEmpty ? wkn : isin].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The master list: filtered, sorted rows plus the counts behind the filter chips.
struct SecurityListModel: Sendable {
    struct Counts: Sendable, Hashable {
        var all = 0, held = 0, notHeld = 0, retired = 0, missingQuotes = 0
        var watchlists: [UUID: Int] = [:]
    }

    var rows: [SecurityRow] = []
    /// The query these rows answer (the list view is rebuilt when it changes).
    var query = SecurityListQuery(today: Day(rawValue: 0))
    var counts = Counts()
    /// Reporting currency of the holding values.
    var currency: CurrencyCode = "EUR"
    /// Sum of the holding values of the listed rows that can be valued.
    var totalValue: Int64 = 0
    /// Listed holdings that are left out of `totalValue` because a quote or exchange rate is missing.
    var unvaluedCount = 0
    /// The day the holdings are valued on (today — not the end of the reporting period).
    var valuationDay = Day(rawValue: 0)

    /// A quote older than this many days counts as stale for a security that is still active.
    static let staleAfterDays = 10

    /// Display names of the built-in feeds; kept here so that the list does not need a provider
    /// registry (which lives in KontorMarketData and is not `Sendable`-free to construct per row).
    static func feedName(_ feed: QuoteFeed?, names: [String: String]) -> String {
        guard let feed else { return "" }
        return names[feed.provider] ?? feed.provider
    }

    init() {}

    init(_ analysis: Analysis, query: SecurityListQuery, watchlists: [Watchlist], providerNames: [String: String],
         automaticProviders: Set<String>) {
        let ledger = analysis.ledger
        let interval = analysis.interval
        // Shares, "Held" and the values are today's — like the price next to them. Only the
        // percentage follows the window's reporting period (which may have ended years ago).
        let snapshot = interval.end == query.today ? analysis.snapshot : ledger.snapshot(on: query.today)
        valuationDay = query.today
        self.query = query
        currency = analysis.currency
        let benchmarks = Set(ledger.settings.benchmarkSecurityIDs)
        var membership = [UUID: Set<UUID>]()
        for list in watchlists {
            for id in list.securityIDs { membership[id, default: []].insert(list.id) }
        }

        var all = [SecurityRow]()
        all.reserveCapacity(ledger.securities.count)
        for security in ledger.securities {
            let prices = security.prices
            let latest = prices.latest
            var dayChange: Double?
            if prices.count >= 2 {
                let previous = prices[prices.count - 2].price.raw
                if previous > 0, let latest { dayChange = Double(latest.price.raw) / Double(previous) - 1 }
            }
            var periodChange: Double?
            // Like the engine's price levels: a period that starts before the first quote is
            // measured from the first quote.
            if let start = prices.point(onOrBefore: interval.start) ?? prices.first, let end = prices.point(onOrBefore: interval.end),
               start.price.raw > 0, end.day > start.day {
                periodChange = Double(end.price.raw) / Double(start.price.raw) - 1
            }
            let health: QuoteHealth
            if let latest {
                let age = latest.day.distance(to: query.today)
                health = !security.isRetired && age > Self.staleAfterDays ? .stale(days: age) : .current
            } else {
                health = .missing
            }
            let position = snapshot.position(security.id)
            // The engine reports an unvalued position with a value of 0; that is "unknown", not zero.
            let problem = position.flatMap { ValuationProblem($0, security: security, reportingCurrency: analysis.currency) }
            let row = SecurityRow(
                id: security.id, name: security.name, ticker: security.ticker, isin: security.isin, wkn: security.wkn,
                currency: security.currency, isRetired: security.isRetired, isBenchmark: benchmarks.contains(security.id),
                latest: latest?.price, latestDay: latest?.day, dayChange: dayChange, periodChange: periodChange,
                spark: Self.spark(prices, through: query.today), shares: position?.shares ?? .zero,
                value: problem == nil ? position?.value : nil, valuationProblem: problem?.message,
                quoteCount: prices.count, health: health,
                feedName: Self.feedName(security.feed, names: providerNames),
                hasAutomaticFeed: security.feed.map { automaticProviders.contains($0.provider) } ?? false
            )
            all.append(row)
        }

        counts.all = all.count
        for row in all {
            if row.isHeld { counts.held += 1 } else { counts.notHeld += 1 }
            if row.isRetired { counts.retired += 1 }
            if row.health != .current { counts.missingQuotes += 1 }
        }
        for list in watchlists {
            let known = Set(all.map(\.id))
            counts.watchlists[list.id] = Set(list.securityIDs).intersection(known).count
        }

        let text = QuickFilter(query.text)
        var filtered = all.filter { row in
            switch query.filter {
            case .all: break
            case .held: guard row.isHeld else { return false }
            case .notHeld: guard !row.isHeld else { return false }
            case .retired: guard row.isRetired else { return false }
            case .missingQuotes: guard row.health != .current else { return false }
            case .watchlist(let id): guard membership[row.id]?.contains(id) == true else { return false }
            }
            return text.isEmpty || text.matches(row.name, row.ticker, row.isin, row.wkn, row.currency)
        }
        filtered.sort { a, b in
            let ordered = Self.precedes(a, b, by: query.sort, ascending: query.ascending)
            return ordered ?? (a.name.localizedStandardCompare(b.name) == .orderedAscending)
        }
        rows = filtered
        totalValue = filtered.reduce(0) { $0 + ($1.value?.minor ?? 0) }
        unvaluedCount = filtered.count { $0.valuationProblem != nil }
    }

    /// nil = equal on the key (the caller falls back to the name). Missing values always sort last.
    private static func precedes(_ a: SecurityRow, _ b: SecurityRow, by sort: SecuritySort, ascending: Bool) -> Bool? {
        func compare<T: Comparable>(_ x: T?, _ y: T?) -> Bool? {
            switch (x, y) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?): return x == y ? nil : (x < y) == ascending
            }
        }
        switch sort {
        case .name:
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? nil : (order == .orderedAscending) == ascending
        case .price: return compare(a.latest?.raw, b.latest?.raw)
        case .day: return compare(a.dayChange, b.dayChange)
        case .period: return compare(a.periodChange, b.periodChange)
        case .value: return compare(a.value?.minor, b.value?.minor)
        case .updated: return compare(a.latestDay, b.latestDay)
        }
    }

    /// The closes of the year before the newest quote (a retired security keeps its last year),
    /// thinned to at most ~60 points.
    private static func spark(_ prices: PriceSeries, through today: Day) -> [Double] {
        guard let last = prices.lastDay else { return [] }
        let end = min(last, today)
        let from = end.advanced(by: -365)
        var lower = 0, upper = prices.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if prices.days[mid] < from.rawValue { lower = mid + 1 } else { upper = mid }
        }
        let endIndex = (prices.index(onOrBefore: end) ?? -1) + 1
        guard endIndex - lower >= 2 else { return [] }
        let step = max(1, (endIndex - lower + 59) / 60)
        var values = [Double]()
        values.reserveCapacity(64)
        var i = lower
        while i < endIndex {
            values.append(Double(prices.values[i]))
            i += step
        }
        if (endIndex - 1 - lower) % step != 0 { values.append(Double(prices.values[endIndex - 1])) }
        return values
    }
}

/// Why the engine could not value a held position.
enum ValuationProblem: Hashable, Sendable {
    case noQuote
    case noExchangeRate(from: CurrencyCode, to: CurrencyCode)

    /// Nil when the position is valued.
    init?(_ position: Snapshot.Position, security: Security, reportingCurrency: CurrencyCode) {
        guard !position.isValued else { return nil }
        self = position.price == nil ? .noQuote : .noExchangeRate(from: security.currency, to: reportingCurrency)
    }

    var message: String {
        switch self {
        case .noQuote: "No quote"
        case .noExchangeRate(let from, let to): "No \(from) → \(to) exchange rate"
        }
    }
}

extension Security {
    /// Shown wherever a security without a name appears.
    static let untitledName = "Untitled Security"
    /// The name, or the placeholder for a security that has none yet.
    var displayName: String { name.isEmpty ? Self.untitledName : name }
}
