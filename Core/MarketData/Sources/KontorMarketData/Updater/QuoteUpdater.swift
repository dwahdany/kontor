import Foundation
import KontorModel

/// Brings the market data of a `PortfolioFile` up to date.
///
/// ```swift
/// let updater = QuoteUpdater()                                   // real network
/// let result = await updater.update(file) { progress in … }      // never throws
/// apply(result, to: &document.file)                               // pure, on the main actor
/// ```
///
/// The updater only reads the file. Downloads run concurrently (bounded by
/// ``UpdateOptions/maxConcurrentDownloads``); a failing security never affects the others.
/// Cancelling the surrounding task stops the run and returns what had finished until then.
public struct QuoteUpdater: Sendable {
    public var registry: ProviderRegistry
    public var rateProvider: (any ExchangeRateProvider)?
    public var options: UpdateOptions
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - rateProvider: source of exchange rates; nil disables rate updates.
    ///   - now: wall clock used for time stamps (injectable for tests).
    public init(registry: ProviderRegistry, rateProvider: (any ExchangeRateProvider)?, options: UpdateOptions = UpdateOptions(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.rateProvider = rateProvider
        self.options = options
        self.now = now
    }

    /// The standard setup: all built-in providers and ECB rates on top of one HTTP client.
    public init(http: any HTTPClient = ResilientHTTPClient.standard(), options: UpdateOptions = UpdateOptions()) {
        self.init(registry: .standard(http: http), rateProvider: ECBProvider(http: http), options: options)
    }

    // MARK: Planning

    /// Works out what has to be downloaded.
    ///
    /// - Securities: every non-retired security with an automatic feed. The range starts the day
    ///   after its last price — or on that day if the price was stored while the day was still in
    ///   progress (``UpdateOptions/refreshesProvisionalDay``) — or at
    ///   ``UpdateOptions/historyStart`` if it has no prices (or
    ///   ``UpdateOptions/reloadsFullHistory`` is set); it ends `today`.
    /// - Exchange rates: for files with more than one currency, every currency except the euro
    ///   (rates are euro-based; other pairs are triangulated), each from the day after its last
    ///   stored `EUR → X` rate.
    ///
    /// - Parameters:
    ///   - today: the last day to request.
    ///   - ids: restricts the plan to these securities (exchange rates are always included).
    public func plan(for file: PortfolioFile, today: Day = .today, only ids: Set<UUID>? = nil) -> UpdatePlan {
        var firstTransaction = [UUID: Day]()
        var firstTransactionOverall: Day?
        let needsTransactions: Bool = {
            if case .beforeFirstTransaction = options.historyStart { return true }
            if case .beforeFirstTransaction = options.rateHistoryStart { return true }
            return false
        }()
        if needsTransactions {
            for t in file.transactions {
                firstTransactionOverall = min(firstTransactionOverall ?? t.date, t.date)
                if let id = t.securityID { firstTransaction[id] = min(firstTransaction[id] ?? t.date, t.date) }
            }
        }
        func start(_ rule: HistoryStart, earliest: Day, firstTransaction: Day?) -> Day {
            switch rule {
            case .earliest: return earliest
            case .day(let day): return day
            case .beforeFirstTransaction(let days): return (firstTransaction ?? today).advanced(by: -days)
            }
        }

        var items = [UpdatePlan.SecurityItem]()
        for security in file.securities where !security.isRetired {
            guard let feed = security.feed, registry.isAutomatic(feed) || registry.provider(id: feed.provider) == nil,
                  feed.provider != ManualProvider.id else { continue }
            if let ids, !ids.contains(security.id) { continue }
            var from: Day
            if let last = security.prices.lastDay, !options.reloadsFullHistory {
                from = last.advanced(by: 1)
                if options.refreshesProvisionalDay, let updatedAt = security.updatedAt, Self.isProvisional(last, storedAt: updatedAt) {
                    from = last
                }
            } else {
                from = start(options.historyStart, earliest: Self.earliestQuoteDay, firstTransaction: firstTransaction[security.id])
            }
            let request = from <= today ? QuoteRequest(security: security, range: from...today) : nil
            items.append(UpdatePlan.SecurityItem(id: security.id, name: security.name, request: request))
        }

        var rates = [RateRequest]()
        if options.updatesExchangeRates, let rateProvider {
            let currencies = file.currencies
            if currencies.count > 1 {
                var lastDay = [CurrencyCode: Int32]()
                for series in file.exchangeRates where series.base == rateProvider.baseCurrency {
                    if let last = series.days.last { lastDay[series.quote] = last }
                }
                let historyStart = start(options.rateHistoryStart, earliest: ECBProvider.firstDay, firstTransaction: firstTransactionOverall)
                for currency in currencies.sorted() where currency != rateProvider.baseCurrency {
                    let last = lastDay[currency]
                    rates.append(RateRequest(currency: currency, from: last.map { Day(rawValue: $0 + 1) } ?? historyStart, hasHistory: last != nil))
                }
            }
        }
        return UpdatePlan(today: today, securities: items, rates: rates)
    }

    /// The first day requested with ``HistoryStart/earliest``.
    public static let earliestQuoteDay = Day(year: 1970, month: 1, day: 1)

    /// Whether a price for `day` that was stored at `storedAt` may be an intraday price: every
    /// market has closed (and data vendors have caught up) two hours after the end of that day
    /// in UTC.
    static func isProvisional(_ day: Day, storedAt: Date) -> Bool {
        storedAt < day.utcDate.addingTimeInterval(26 * 3600)
    }

    // MARK: Running

    /// Plans and runs an update. Never throws: failures are reported per target in the result.
    ///
    /// - Parameters:
    ///   - progress: called for every status change — first `.pending` for all targets, then
    ///     `.running` and a final status each. Calls are serialized but arrive on arbitrary
    ///     threads.
    public func update(
        _ file: PortfolioFile, today: Day = .today, only ids: Set<UUID>? = nil,
        progress: (@Sendable (UpdateProgress) -> Void)? = nil
    ) async -> UpdateResult {
        await run(plan(for: file, today: today, only: ids), file: file, progress: progress)
    }

    /// Runs a previously computed plan against the file it was computed for.
    public func run(_ plan: UpdatePlan, file: PortfolioFile, progress: (@Sendable (UpdateProgress) -> Void)? = nil) async -> UpdateResult {
        let startedAt = now()
        var securityIndex = [UUID: Int](minimumCapacity: file.securities.count)
        for (i, security) in file.securities.enumerated() { securityIndex[security.id] = i }

        var jobs = [Job]()
        jobs.reserveCapacity(plan.targetCount)
        if !plan.rates.isEmpty { jobs.append(Job(target: .exchangeRates, name: "Exchange rates", work: .rates(plan.rates))) }
        for item in plan.securities {
            guard let i = securityIndex[item.id] else { continue }
            jobs.append(Job(target: .security(item.id), name: item.name, work: .security(file.securities[i], item.request)))
        }

        let tracker = ProgressTracker(total: jobs.count, callback: progress)
        for job in jobs { await tracker.report(job.target, job.name, .pending) }

        var outcomes = [Outcome?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var next = 0
            func startNext(_ group: inout TaskGroup<(Int, Outcome)>) {
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask {
                    await tracker.report(job.target, job.name, .running)
                    let outcome = await self.perform(job)
                    await tracker.report(job.target, job.name, outcome.status)
                    return (index, outcome)
                }
            }
            // `options` is mutable, so the clamp of `UpdateOptions.init` may have been bypassed.
            let width = max(1, options.maxConcurrentDownloads)
            while next < min(width, jobs.count) { startNext(&group) }
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                if next < jobs.count, !Task.isCancelled { startNext(&group) }
            }
        }

        // `wasCancelled` means "the result is partial": a cancellation that arrives after the
        // last target finished changes nothing.
        var result = UpdateResult(startedAt: startedAt)
        for (index, job) in jobs.enumerated() {
            guard let outcome = outcomes[index] else {
                // Never started because the run was cancelled.
                result.statuses[job.target] = .cancelled
                result.wasCancelled = true
                await tracker.report(job.target, job.name, .cancelled)
                continue
            }
            result.statuses[job.target] = outcome.status
            if let update = outcome.security { result.securities.append(update) }
            if let batch = outcome.rates {
                result.exchangeRates = batch.series
                result.unsupportedCurrencies = batch.unsupported
            }
            if case .cancelled = outcome.status { result.wasCancelled = true }
        }
        result.finishedAt = now()
        return result
    }

    /// Runs an update and delivers progress and the final result as a stream. Cancelling the
    /// consuming task (or dropping the stream) cancels the update; the stream then still ends
    /// with `.finished` carrying the partial result if it is being consumed.
    public func updates(for file: PortfolioFile, today: Day = .today, only ids: Set<UUID>? = nil) -> AsyncStream<UpdateEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                let result = await update(file, today: today, only: ids) { continuation.yield(.progress($0)) }
                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Work

    private struct Job: Sendable {
        enum Work: Sendable {
            case security(Security, QuoteRequest?)
            case rates([RateRequest])
        }
        var target: UpdateTarget
        var name: String
        var work: Work
    }

    private struct Outcome: Sendable {
        var status: UpdateStatus
        var security: SecurityUpdate?
        var rates: RateBatch?
    }

    private func perform(_ job: Job) async -> Outcome {
        do {
            try Task.checkCancellation()
            switch job.work {
            case .security(let security, let request):
                guard let request else {
                    return Outcome(status: .success(newPoints: 0)) // already up to date
                }
                let update = try await download(security, request)
                return Outcome(status: .success(newPoints: update.points.count), security: update)
            case .rates(let requests):
                guard let rateProvider else { return Outcome(status: .success(newPoints: 0)) }
                let batch = try await rateProvider.rates(for: requests)
                return Outcome(status: .success(newPoints: batch.series.reduce(0) { $0 + $1.days.count }), rates: batch)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return Outcome(status: .cancelled) }
            return Outcome(status: .failed(message: Self.message(for: error)))
        }
    }

    private func download(_ security: Security, _ request: QuoteRequest) async throws -> SecurityUpdate {
        let provider = try registry.provider(for: request.feed)
        let history = try await provider.history(request)
        if options.checksCurrency, let currency = history.currency, !currency.isEmpty,
           currency.caseInsensitiveCompare(security.currency) != .orderedSame {
            throw MarketDataError.currencyMismatch(expected: security.currency, actual: currency)
        }

        // Keep only what differs from the stored series (both are ascending).
        let days = security.prices.days, values = security.prices.values
        var points = [PricePoint]()
        var j = 0
        for point in history.points where request.range.contains(point.day) {
            let day = point.day.rawValue
            while j < days.count, days[j] < day { j += 1 }
            if j < days.count, days[j] == day, values[j] == point.price.raw { continue }
            points.append(point)
        }

        var events = [QuoteEvent]()
        if options.collectsEvents, !history.events.isEmpty {
            var known = Set(security.events.map { EventKey(day: $0.day, kind: $0.kind) })
            events = history.events.filter { known.insert(EventKey(day: $0.day, kind: $0.kind)).inserted }
        }
        return SecurityUpdate(id: security.id, points: points, events: events, fetchedAt: now())
    }

    private static func message(for error: Error) -> String {
        if let error = error as? MarketDataError { return error.description }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// Serializes progress callbacks and keeps the completed count.
private actor ProgressTracker {
    private let total: Int
    private let callback: (@Sendable (UpdateProgress) -> Void)?
    private var final = Set<UpdateTarget>()

    init(total: Int, callback: (@Sendable (UpdateProgress) -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func report(_ target: UpdateTarget, _ name: String, _ status: UpdateStatus) {
        if status.isFinal { final.insert(target) }
        callback?(UpdateProgress(target: target, name: name, status: status, completed: final.count, total: total))
    }
}
