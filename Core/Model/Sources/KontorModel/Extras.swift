import Foundation

public struct Watchlist: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var securityIDs: [UUID]
    public init(id: UUID = UUID(), name: String, securityIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.securityIDs = securityIDs
    }
}

/// A recurring purchase (savings plan), deposit or withdrawal.
public struct InvestmentPlan: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case purchase, deposit, withdrawal }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var securityID: UUID?
    public var depotID: UUID?
    public var accountID: UUID?
    /// Amount per execution, in the account's currency (purchases: total incl. fees).
    public var amount: Money
    public var fees: Int64
    public var start: Day
    public var end: Day?
    /// Interval in months (1 = monthly, 3 = quarterly, …).
    public var intervalMonths: Int
    public var note: String
    /// Due dates the user deliberately skipped; no transaction is generated for them.
    public var skippedDates: [Day]?

    public init(
        id: UUID = UUID(), name: String, kind: Kind = .purchase, securityID: UUID? = nil, depotID: UUID? = nil,
        accountID: UUID? = nil, amount: Money, fees: Int64 = 0, start: Day, end: Day? = nil, intervalMonths: Int = 1,
        note: String = "", skippedDates: [Day]? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.securityID = securityID
        self.depotID = depotID
        self.accountID = accountID
        self.amount = amount
        self.fees = fees
        self.start = start
        self.end = end
        self.intervalMonths = intervalMonths
        self.note = note
        self.skippedDates = skippedDates
    }
}

/// Daily exchange rates: 1 unit of `base` = `rate` units of `quote`.
public struct ExchangeRateSeries: Hashable, Codable, Sendable {
    public var base: CurrencyCode
    public var quote: CurrencyCode
    /// Days since 1970-01-01, strictly ascending.
    public var days: [Int32]
    /// Rates, parallel to `days`.
    public var rates: [Double]

    public init(base: CurrencyCode, quote: CurrencyCode, days: [Int32] = [], rates: [Double] = []) {
        precondition(days.count == rates.count)
        self.base = base
        self.quote = quote
        self.days = days
        self.rates = rates
    }

    /// The most recent rate on or before `day`; before the first data point, the first known rate.
    public func rate(on day: Day) -> Double? {
        guard !days.isEmpty else { return nil }
        var lo = 0, hi = days.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if days[mid] <= day.rawValue { lo = mid + 1 } else { hi = mid }
        }
        return rates[max(lo - 1, 0)]
    }

    /// Merges rates (any order); incoming values replace existing ones on the same day.
    public mutating func merge(_ points: some Sequence<(day: Day, rate: Double)>) {
        var merged = [Int32: Double](minimumCapacity: days.count)
        for i in days.indices { merged[days[i]] = rates[i] }
        for p in points { merged[p.day.rawValue] = p.rate }
        let sorted = merged.sorted { $0.key < $1.key }
        days = sorted.map(\.key)
        rates = sorted.map(\.value)
    }
}

/// A user-configurable dashboard. Widget kinds and their configuration keys are defined by the app.
public struct Dashboard: Identifiable, Hashable, Codable, Sendable {
    public struct Widget: Identifiable, Hashable, Codable, Sendable {
        public var id: UUID
        public var kind: String
        public var title: String
        /// Width in grid columns (1…4).
        public var span: Int
        public var config: [String: String]
        public init(id: UUID = UUID(), kind: String, title: String = "", span: Int = 1, config: [String: String] = [:]) {
            self.id = id
            self.kind = kind
            self.title = title
            self.span = span
            self.config = config
        }
    }
    public var id: UUID
    public var name: String
    public var widgets: [Widget]
    public init(id: UUID = UUID(), name: String, widgets: [Widget] = []) {
        self.id = id
        self.name = name
        self.widgets = widgets
    }
}

public enum CostMethod: String, Codable, Sendable, CaseIterable {
    /// First in, first out.
    case fifo
    /// Moving average purchase price.
    case average
}

public struct Settings: Hashable, Codable, Sendable {
    /// Currency all reports are converted to.
    public var baseCurrency: CurrencyCode
    public var costMethod: CostMethod
    /// Securities used as benchmarks in performance charts.
    public var benchmarkSecurityIDs: [UUID]
    /// Annual risk-free rate for Sharpe ratio etc. (0.02 = 2 %).
    public var riskFreeRate: Double
    /// Free-form app/UI preferences that should travel with the file.
    public var preferences: [String: String]

    public init(
        baseCurrency: CurrencyCode = "EUR", costMethod: CostMethod = .fifo, benchmarkSecurityIDs: [UUID] = [],
        riskFreeRate: Double = 0, preferences: [String: String] = [:]
    ) {
        self.baseCurrency = baseCurrency
        self.costMethod = costMethod
        self.benchmarkSecurityIDs = benchmarkSecurityIDs
        self.riskFreeRate = riskFreeRate
        self.preferences = preferences
    }
}
