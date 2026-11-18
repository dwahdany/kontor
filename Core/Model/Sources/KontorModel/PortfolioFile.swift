import Foundation

/// The root of a Kontor document: everything that is saved to a `.kontor` file.
///
/// The on-disk format is a single UTF-8 JSON document (see `encoded()` / `init(data:)`), which makes
/// files portable across platforms, diff-able and easy to process with other tools.
public struct PortfolioFile: Hashable, Codable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "kontor"
    public static let uniformTypeIdentifier = "app.kontor.portfolio"

    public var formatVersion: Int
    public var name: String
    public var settings: Settings
    public var securities: [Security]
    public var accounts: [Account]
    public var depots: [Depot]
    public var transactions: [Transaction]
    public var taxonomies: [Taxonomy]
    public var watchlists: [Watchlist]
    public var plans: [InvestmentPlan]
    public var exchangeRates: [ExchangeRateSeries]
    public var dashboards: [Dashboard]

    public init(
        name: String = "", settings: Settings = Settings(), securities: [Security] = [], accounts: [Account] = [],
        depots: [Depot] = [], transactions: [Transaction] = [], taxonomies: [Taxonomy] = [],
        watchlists: [Watchlist] = [], plans: [InvestmentPlan] = [], exchangeRates: [ExchangeRateSeries] = [],
        dashboards: [Dashboard] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.name = name
        self.settings = settings
        self.securities = securities
        self.accounts = accounts
        self.depots = depots
        self.transactions = transactions
        self.taxonomies = taxonomies
        self.watchlists = watchlists
        self.plans = plans
        self.exchangeRates = exchangeRates
        self.dashboards = dashboards
    }

    // MARK: Lookup helpers (linear; build dictionaries for hot paths)

    public func security(_ id: UUID?) -> Security? { id.flatMap { id in securities.first { $0.id == id } } }
    public func account(_ id: UUID?) -> Account? { id.flatMap { id in accounts.first { $0.id == id } } }
    public func depot(_ id: UUID?) -> Depot? { id.flatMap { id in depots.first { $0.id == id } } }

    /// All currencies used by accounts and securities, base currency first.
    public var currencies: [CurrencyCode] {
        var seen = Set([settings.baseCurrency])
        var result = [settings.baseCurrency]
        for c in accounts.map(\.currency) + securities.map(\.currency) where seen.insert(c).inserted {
            result.append(c)
        }
        return result
    }

    // MARK: Serialization

    public enum FormatError: Error, Equatable, CustomStringConvertible {
        case newerVersion(Int)
        public var description: String {
            switch self {
            case .newerVersion(let v):
                return "This file was written by a newer version of Kontor (format \(v)). Please update the app."
            }
        }
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(PortfolioFile.self, from: data)
        guard file.formatVersion <= Self.currentFormatVersion else {
            throw FormatError.newerVersion(file.formatVersion)
        }
        self = file
    }

    /// Serializes the file as JSON. `pretty` adds indentation (larger, but nicer diffs).
    public func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // Missing keys decode to their defaults so that older/hand-written files keep loading.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, settings, securities, accounts, depots, transactions, taxonomies, watchlists, plans,
             exchangeRates, dashboards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        securities = try c.decodeIfPresent([Security].self, forKey: .securities) ?? []
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        depots = try c.decodeIfPresent([Depot].self, forKey: .depots) ?? []
        transactions = try c.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []
        taxonomies = try c.decodeIfPresent([Taxonomy].self, forKey: .taxonomies) ?? []
        watchlists = try c.decodeIfPresent([Watchlist].self, forKey: .watchlists) ?? []
        plans = try c.decodeIfPresent([InvestmentPlan].self, forKey: .plans) ?? []
        exchangeRates = try c.decodeIfPresent([ExchangeRateSeries].self, forKey: .exchangeRates) ?? []
        dashboards = try c.decodeIfPresent([Dashboard].self, forKey: .dashboards) ?? []
    }
}
