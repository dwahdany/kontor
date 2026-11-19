import Foundation
import KontorModel

/// Where the history of a security (or currency) without any stored data starts.
public enum HistoryStart: Hashable, Sendable {
    /// Everything the source has (securities: from 1970; ECB rates: from 1999).
    case earliest
    /// A fixed first day.
    case day(Day)
    /// This many days before the first transaction (of the security; for exchange rates: of the
    /// file). Falls back to this many days before today when there are no transactions.
    case beforeFirstTransaction(days: Int)
}

/// Tuning knobs of ``QuoteUpdater``.
public struct UpdateOptions: Hashable, Sendable {
    /// Upper bound of downloads in flight (per-host pacing is the HTTP client's job).
    public var maxConcurrentDownloads: Int
    /// First day requested for securities that have no prices yet.
    public var historyStart: HistoryStart
    /// First day requested for currencies that have no rates yet.
    public var rateHistoryStart: HistoryStart
    /// Whether exchange rates are part of the update.
    public var updatesExchangeRates: Bool
    /// Whether dividends and splits reported by providers are collected.
    public var collectsEvents: Bool
    /// Re-download the last stored day when it was fetched while that day was still in progress
    /// (it then holds an intraday price rather than the close).
    public var refreshesProvisionalDay: Bool
    /// Fail a security whose feed reports another currency than the security's.
    public var checksCurrency: Bool
    /// Request every security from ``historyStart`` on, even if it already has prices — the
    /// "reload history" command, usually combined with `only:`. Stored prices that differ from
    /// the downloaded ones are corrected (e.g. after a split, when the provider has re-based
    /// its history); stored days the provider does not know are kept.
    public var reloadsFullHistory: Bool

    public init(
        maxConcurrentDownloads: Int = 8, historyStart: HistoryStart = .earliest, rateHistoryStart: HistoryStart = .earliest,
        updatesExchangeRates: Bool = true, collectsEvents: Bool = true, refreshesProvisionalDay: Bool = true,
        checksCurrency: Bool = true, reloadsFullHistory: Bool = false
    ) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.historyStart = historyStart
        self.rateHistoryStart = rateHistoryStart
        self.updatesExchangeRates = updatesExchangeRates
        self.collectsEvents = collectsEvents
        self.refreshesProvisionalDay = refreshesProvisionalDay
        self.checksCurrency = checksCurrency
        self.reloadsFullHistory = reloadsFullHistory
    }
}

/// One unit of work of an update run.
public enum UpdateTarget: Hashable, Sendable {
    case security(UUID)
    case exchangeRates

    /// The security's id; nil for the exchange-rate target.
    public var securityID: UUID? {
        if case .security(let id) = self { return id }
        return nil
    }
}

/// Lifecycle of one ``UpdateTarget``.
public enum UpdateStatus: Hashable, Sendable {
    case pending
    case running
    /// Finished; `newPoints` prices (or rates) were added or changed.
    case success(newPoints: Int)
    /// Failed with a message suitable for display. Other targets are unaffected.
    case failed(message: String)
    /// The run was cancelled before this target finished.
    case cancelled

    /// Whether the target will not change state any more.
    public var isFinal: Bool {
        switch self {
        case .pending, .running: return false
        default: return true
        }
    }

    /// The message of a failed target, nil otherwise.
    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// A status change during an update run. `id` is the target, so a list keyed by it shows one
/// row per target that moves through the states.
public struct UpdateProgress: Hashable, Sendable, Identifiable {
    public var id: UpdateTarget { target }
    public var target: UpdateTarget
    /// Display name: the security's name, or "Exchange rates".
    public var name: String
    public var status: UpdateStatus
    /// Number of targets in a final state.
    public var completed: Int
    /// Number of targets in this run.
    public var total: Int

    public init(target: UpdateTarget, name: String, status: UpdateStatus, completed: Int, total: Int) {
        self.target = target
        self.name = name
        self.status = status
        self.completed = completed
        self.total = total
    }

    /// 0…1.
    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// An element of ``QuoteUpdater/updates(for:today:only:)``.
public enum UpdateEvent: Hashable, Sendable {
    case progress(UpdateProgress)
    /// The last element: the complete result.
    case finished(UpdateResult)
}

/// What an update run is going to request — computed without touching the network.
public struct UpdatePlan: Hashable, Sendable {
    /// One security with an automatic feed.
    public struct SecurityItem: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        /// The request to send; nil when the security is already up to date.
        public var request: QuoteRequest?

        public init(id: UUID, name: String, request: QuoteRequest?) {
            self.id = id
            self.name = name
            self.request = request
        }
    }

    /// The day the plan was made for (the last day requested).
    public var today: Day
    /// All non-retired securities with an automatic feed, in file order.
    public var securities: [SecurityItem]
    /// Currencies whose rates against the euro are wanted, sorted by code. Empty for
    /// single-currency files.
    public var rates: [RateRequest]

    public init(today: Day, securities: [SecurityItem] = [], rates: [RateRequest] = []) {
        self.today = today
        self.securities = securities
        self.rates = rates
    }

    /// Number of targets a run of this plan reports on.
    public var targetCount: Int { securities.count + (rates.isEmpty ? 0 : 1) }
    /// Whether running the plan would send any request at all.
    public var hasWork: Bool { !rates.isEmpty || securities.contains { $0.request != nil } }
}

/// New data for one security.
public struct SecurityUpdate: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Prices that are new or differ from the stored ones, ascending.
    public var points: [PricePoint]
    /// Dividends/splits not yet present in the security's events.
    public var events: [QuoteEvent]
    /// When the download completed (becomes `Security.updatedAt`).
    public var fetchedAt: Date

    public init(id: UUID, points: [PricePoint] = [], events: [QuoteEvent] = [], fetchedAt: Date) {
        self.id = id
        self.points = points
        self.events = events
        self.fetchedAt = fetchedAt
    }
}

/// The outcome of an update run: everything needed to bring a file up to date, as a value.
/// Nothing is modified until it is passed to ``apply(_:to:)``.
public struct UpdateResult: Hashable, Sendable {
    /// Securities that were downloaded successfully (possibly with no new points).
    public var securities: [SecurityUpdate]
    /// New euro-based rates (`EUR → X`), one series per currency.
    public var exchangeRates: [ExchangeRateSeries]
    /// Final status of every target of the run.
    public var statuses: [UpdateTarget: UpdateStatus]
    /// Currencies without ECB reference rates (e.g. crypto tickers) — informational.
    public var unsupportedCurrencies: [CurrencyCode]
    public var startedAt: Date
    public var finishedAt: Date
    /// Whether the run was cancelled; the result then holds what had finished until then.
    public var wasCancelled: Bool

    public init(securities: [SecurityUpdate] = [], exchangeRates: [ExchangeRateSeries] = [], statuses: [UpdateTarget: UpdateStatus] = [:],
                unsupportedCurrencies: [CurrencyCode] = [], startedAt: Date = Date(), finishedAt: Date = Date(), wasCancelled: Bool = false) {
        self.securities = securities
        self.exchangeRates = exchangeRates
        self.statuses = statuses
        self.unsupportedCurrencies = unsupportedCurrencies
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wasCancelled = wasCancelled
    }

    /// Number of new or changed prices across all securities.
    public var newPriceCount: Int { securities.reduce(0) { $0 + $1.points.count } }
    /// Number of new rates across all currencies.
    public var newRateCount: Int { exchangeRates.reduce(0) { $0 + $1.days.count } }
    /// Whether applying the result would add any prices, events or rates.
    public var hasNewData: Bool {
        newRateCount > 0 || securities.contains { !$0.points.isEmpty || !$0.events.isEmpty }
    }
    /// Messages of all failed targets.
    public var failures: [UpdateTarget: String] {
        var out = [UpdateTarget: String]()
        for (target, status) in statuses {
            if case .failed(let message) = status { out[target] = message }
        }
        return out
    }

    /// Convenience for ``apply(_:to:)``.
    @discardableResult
    public func apply(to file: inout PortfolioFile) -> ApplySummary {
        KontorMarketData.apply(self, to: &file)
    }
}

/// What ``apply(_:to:)`` changed.
public struct ApplySummary: Hashable, Sendable {
    /// Prices added or changed.
    public var prices = 0
    /// Dividend/split events added.
    public var events = 0
    /// Exchange rates added or changed (euro-based series only).
    public var rates = 0
    /// Derived cross rates (`base → X`) added or changed; always 0 for euro-based files.
    public var derivedRates = 0
    /// Securities whose prices or events changed.
    public var changedSecurities: [UUID] = []

    public init(prices: Int = 0, events: Int = 0, rates: Int = 0, derivedRates: Int = 0, changedSecurities: [UUID] = []) {
        self.prices = prices
        self.events = events
        self.rates = rates
        self.derivedRates = derivedRates
        self.changedSecurities = changedSecurities
    }

    /// Whether the file's market data changed at all (ignoring `updatedAt` stamps).
    public var hasChanges: Bool { prices > 0 || events > 0 || rates > 0 || derivedRates > 0 }
}

/// Merges an ``UpdateResult`` into a file: prices (`PriceSeries.merge`), new events, exchange
/// rates (plus derived cross rates for files whose base currency is not the euro, see
/// ``ExchangeRates``) and `Security.updatedAt`. Existing data is only ever added to or
/// corrected day by day — nothing is removed.
///
/// Pure and synchronous — call it on the main actor inside an undo group. Securities that no
/// longer exist in the file are ignored.
@discardableResult
public func apply(_ result: UpdateResult, to file: inout PortfolioFile) -> ApplySummary {
    var summary = ApplySummary()

    if !result.securities.isEmpty {
        var index = [UUID: Int](minimumCapacity: file.securities.count)
        for (i, security) in file.securities.enumerated() { index[security.id] = i }
        for update in result.securities {
            guard let i = index[update.id] else { continue }
            var touched = false
            if !update.points.isEmpty {
                let changed = mergePrices(update.points, into: &file.securities[i].prices)
                summary.prices += changed
                touched = changed > 0
            }
            if !update.events.isEmpty {
                var known = Set(file.securities[i].events.map { EventKey(day: $0.day, kind: $0.kind) })
                var added = 0
                for event in update.events where known.insert(EventKey(day: event.day, kind: event.kind)).inserted {
                    file.securities[i].events.append(SecurityEvent(day: event.day, kind: event.kind, detail: event.detail))
                    added += 1
                }
                if added > 0 {
                    file.securities[i].events.sort { $0.day < $1.day }
                    summary.events += added
                    touched = true
                }
            }
            file.securities[i].updatedAt = update.fetchedAt
            if touched { summary.changedSecurities.append(update.id) }
        }
    }

    if !result.exchangeRates.isEmpty {
        var index = [String: Int](minimumCapacity: file.exchangeRates.count)
        for (i, series) in file.exchangeRates.enumerated() { index[series.base + "/" + series.quote] = i }
        for incoming in result.exchangeRates where !incoming.days.isEmpty {
            if let i = index[incoming.base + "/" + incoming.quote] {
                let changed = countChanges(of: incoming, against: file.exchangeRates[i])
                guard changed > 0 else { continue }
                file.exchangeRates[i].merge(zip(incoming.days, incoming.rates).lazy.map { (day: Day(rawValue: $0.0), rate: $0.1) })
                summary.rates += changed
            } else {
                index[incoming.base + "/" + incoming.quote] = file.exchangeRates.count
                file.exchangeRates.append(incoming)
                summary.rates += incoming.days.count
            }
        }
    }
    // Derived series depend on the stored rates *and* on the file (base currency, currencies in
    // use), so they are brought in line after every run that looked at exchange rates — also
    // when it downloaded nothing new.
    if !result.exchangeRates.isEmpty || result.statuses[.exchangeRates] != nil {
        summary.derivedRates = ExchangeRates.refreshCrossRates(in: &file)
    }
    return summary
}

/// Merges `points` into `series` with the semantics of `PriceSeries.merge` (incoming points
/// win; returns the number of days added or changed) — but without rebuilding the series when
/// that can be avoided.
///
/// `PriceSeries.merge` costs O(n log n) in the length of the stored history, whatever the size
/// of the update. The everyday update appends one close to thousands of stored ones, for every
/// security, on the main actor; here that is O(1) per point. Corrections of stored days are
/// O(log n); only a larger back-fill between stored days goes through the general merge.
func mergePrices(_ points: [PricePoint], into series: inout PriceSeries) -> Int {
    /// Back-fills up to this size are inserted one by one (each is an O(n) array insert).
    let insertLimit = 16
    guard !points.isEmpty else { return 0 }

    // First download of a history: build the columns in one go (the model's bulk initializer adopts
    // ascending input as-is and otherwise sorts with "last value per day wins", like `merge`).
    if series.isEmpty {
        series = PriceSeries(days: points.map(\.day.rawValue), values: points.map(\.price.raw))
        return series.count
    }

    // Classify against the stored series in one forward pass (both sides ascending). The scope
    // keeps the column copies from outliving the pass, so the mutation below stays in place.
    let plan: (pending: [PricePoint], inserts: Int)? = {
        let days = series.days, values = series.values
        let last = days.last
        var pending = [PricePoint]()
        var inserts = 0
        var j = 0
        var previous: Int32?
        for point in points {
            let day = point.day.rawValue
            if let previous, day <= previous { return nil } // unsorted or duplicate days
            previous = day
            while j < days.count, days[j] < day { j += 1 }
            if j < days.count, days[j] == day {
                if values[j] != point.price.raw { pending.append(point) }
            } else {
                pending.append(point)
                if let last, day < last { inserts += 1 }
            }
        }
        return (pending, inserts)
    }()

    guard let plan, plan.inserts <= insertLimit else { return series.merge(points) }
    for point in plan.pending { series.set(point.price, on: point.day) }
    return plan.pending.count
}

struct EventKey: Hashable {
    var day: Day
    var kind: SecurityEvent.Kind
}

/// Number of points in `incoming` that are missing from or different in `existing`.
func countChanges(of incoming: ExchangeRateSeries, against existing: ExchangeRateSeries) -> Int {
    var changed = 0
    var j = 0
    for i in incoming.days.indices {
        let day = incoming.days[i]
        while j < existing.days.count, existing.days[j] < day { j += 1 }
        if j < existing.days.count, existing.days[j] == day, existing.rates[j] == incoming.rates[i] { continue }
        changed += 1
    }
    return changed
}
