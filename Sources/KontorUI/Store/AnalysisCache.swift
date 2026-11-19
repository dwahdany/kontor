import Foundation
import KontorModel
import KontorEngine

/// The shared, memoizing analysis layer behind `PortfolioStore.compute` / `.analyze`.
///
/// One instance per store. Everything in it belongs to exactly one document revision; when a newer
/// revision asks for something, all cached values are dropped and all in-flight work is cancelled.
///
/// * The engine `Ledger` is built once per revision (off the main actor, or synchronously by
///   `PortfolioStore.ledger` — whoever comes first).
/// * `Analysis` facades are shared per (scope, interval), so two screens looking at the same scope
///   and period share the daily pass and the lot replay.
/// * Results of `value(…)` are memoized per key. Concurrent requests for the same key share one
///   computation (in-flight de-duplication). Work whose every requester went away before it
///   started is skipped.
///
/// Thread-safe; all state is guarded by one lock that is never held while computing.
public final class AnalysisCache: @unchecked Sendable {
    /// Counters for tests and diagnostics.
    public struct Statistics: Equatable, Sendable {
        /// Requests answered from memory.
        public var hits = 0
        /// Requests that started a computation.
        public var misses = 0
        /// Requests that joined a computation already in flight.
        public var joins = 0
        /// Computations that ran to completion.
        public var computed = 0
        /// Computations cancelled before they produced a value (stale revision, or nobody waiting).
        public var cancelled = 0
        /// Times the cache was emptied because the document changed.
        public var invalidations = 0
        /// Ledgers built (at most one per revision).
        public var ledgersBuilt = 0
    }

    struct Key: Hashable, @unchecked Sendable {
        let base: AnyHashable
        let type: ObjectIdentifier
    }

    private struct AnalysisKey: Hashable {
        let scope: Scope
        let interval: DayInterval
    }

    /// Mutable state (`waiters`) is only touched while holding the cache lock.
    private final class Flight: @unchecked Sendable {
        let id: UInt64
        let task: Task<any Sendable, any Error>
        var waiters = 1
        init(id: UInt64, task: Task<any Sendable, any Error>) {
            self.id = id
            self.task = task
        }
    }

    private enum Lookup<Value> { case hit(Value), flight(Flight), stale }

    private let lock = NSLock()
    private var revision = -1
    private var ledger: Ledger?
    private var ledgerTask: Task<Ledger, Never>?
    private var analyses: [AnalysisKey: Analysis] = [:]
    private var ready: [Key: any Sendable] = [:]
    /// Keys of `ready`, least recently used first.
    private var order: [Key] = []
    private var flights: [Key: Flight] = [:]
    private var nextFlightID: UInt64 = 0
    private var stats = Statistics()

    /// Upper bound of memoized values per revision (least recently used ones are dropped first).
    public let capacity: Int

    public init(capacity: Int = 96) {
        self.capacity = max(1, capacity)
    }

    public var statistics: Statistics { lock.withLock { stats } }

    /// Number of computations currently running or queued.
    public var inFlightCount: Int { lock.withLock { flights.count } }

    // MARK: Revision handling

    /// Moves the cache to `newRevision` if it is newer: drops everything and cancels in-flight work.
    /// Returns false if `newRevision` is older than what the cache already serves.
    @discardableResult
    private func enter(_ newRevision: Int) -> Bool {
        // lock must be held
        if newRevision == revision { return true }
        guard newRevision > revision else { return false }
        if revision >= 0 { stats.invalidations += 1 }
        revision = newRevision
        ledger = nil
        ledgerTask = nil // a build in flight finishes on its own; its result is no longer adopted
        analyses.removeAll()
        ready.removeAll()
        order.removeAll()
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        return true
    }

    /// Drops everything (explicit invalidation, e.g. on memory pressure). The next request rebuilds.
    public func removeAll() {
        lock.withLock {
            let current = revision
            revision = -1
            enter(current)
        }
    }

    // MARK: Ledger

    /// The ledger of `revision` if it has been built already.
    func cachedLedger(revision requested: Int) -> Ledger? {
        lock.withLock { requested == revision ? ledger : nil }
    }

    /// Adopts a ledger built elsewhere (the store's synchronous accessor).
    func adopt(_ built: Ledger, revision requested: Int) {
        lock.withLock {
            guard enter(requested), ledger == nil else { return }
            ledger = built
            stats.ledgersBuilt += 1
        }
    }

    /// The ledger of `revision`, built off the calling actor at most once.
    public func ledger(revision requested: Int, file: PortfolioFile) async -> Ledger {
        enum Source { case ready(Ledger), building(Task<Ledger, Never>), stale }
        let source: Source = lock.withLock {
            guard enter(requested) else { return .stale }
            if let ledger { return .ready(ledger) }
            if let ledgerTask { return .building(ledgerTask) }
            let task = Task.detached(priority: .userInitiated) { [self] in
                let built = Ledger(file)
                lock.withLock {
                    if revision == requested, ledger == nil {
                        ledger = built
                        stats.ledgersBuilt += 1
                    }
                }
                return built
            }
            ledgerTask = task
            return .building(task)
        }
        switch source {
        case .ready(let ledger): return ledger
        case .building(let task): return await task.value
        case .stale:
            // A caller that still holds an older revision: serve it without touching the cache.
            return await Task.detached(priority: .userInitiated) { Ledger(file) }.value
        }
    }

    // MARK: Analysis facades

    /// The shared engine facade for a scope and interval of the given ledger's revision.
    func analysis(revision requested: Int, ledger: Ledger, scope: Scope, interval: DayInterval) -> Analysis {
        lock.withLock {
            guard requested == revision else { return Analysis(ledger: ledger, scope: scope, interval: interval) }
            let key = AnalysisKey(scope: scope, interval: interval)
            if let existing = analyses[key] { return existing }
            if analyses.count >= 24 { analyses.removeAll() }
            let created = Analysis(ledger: ledger, scope: scope, interval: interval)
            analyses[key] = created
            return created
        }
    }

    // MARK: Memoized values

    /// Returns the memoized value for `key`, computing it with `work` (off the calling actor) if
    /// necessary. Concurrent callers with the same key share one computation.
    ///
    /// - Throws: `CancellationError` if the calling task was cancelled, or if the document moved
    ///   on to a newer revision while the value was being computed.
    public func value<Value: Sendable>(
        revision requested: Int, file: PortfolioFile, key: some Hashable & Sendable,
        _ work: @escaping @Sendable (Ledger) throws -> Value
    ) async throws -> Value {
        let cacheKey = Key(base: AnyHashable(key), type: ObjectIdentifier(Value.self))
        let lookup: Lookup<Value> = lock.withLock {
            guard enter(requested) else { return .stale }
            if let boxed = ready[cacheKey] as? Boxed<Value> {
                stats.hits += 1
                touch(cacheKey)
                return .hit(boxed.value)
            }
            if let flight = flights[cacheKey] {
                flight.waiters += 1
                stats.joins += 1
                return .flight(flight)
            }
            stats.misses += 1
            nextFlightID += 1
            let flightID = nextFlightID
            let task = Task<any Sendable, any Error>.detached(priority: .userInitiated) { [self] in
                let ledger = await ledger(revision: requested, file: file)
                do {
                    // Nobody waiting any more, or the document changed: not worth starting.
                    try Task.checkCancellation()
                    // Boxed, so that Optional results (`Value == T?`, including nil) survive the
                    // type-erased storage: `nil as? T?` would otherwise look like a failed cast.
                    let value = Boxed(value: try work(ledger))
                    // A finished value is kept even if the last requester left meanwhile — unless
                    // the document moved on, in which case nobody may see it.
                    guard finish(cacheKey, flightID, revision: requested, value: value) else { throw CancellationError() }
                    return value
                } catch {
                    fail(cacheKey, flightID, cancelled: error is CancellationError)
                    throw error
                }
            }
            let flight = Flight(id: flightID, task: task)
            flights[cacheKey] = flight
            return .flight(flight)
        }

        switch lookup {
        case .hit(let value):
            try Task.checkCancellation()
            return value
        case .stale:
            // The store has moved on; the caller's own task is about to be replaced.
            throw CancellationError()
        case .flight(let flight):
            let result = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                leave(cacheKey, flight)
            }
            try Task.checkCancellation()
            guard let boxed = result as? Boxed<Value> else { throw CancellationError() }
            return boxed.value
        }
    }

    /// Stores a computed value. Returns false if the document changed meanwhile (value dropped).
    private func finish(_ key: Key, _ flightID: UInt64, revision requested: Int, value: any Sendable) -> Bool {
        lock.withLock {
            guard requested == revision else { return false }
            stats.computed += 1
            if flights[key]?.id == flightID { flights[key] = nil }
            ready[key] = value
            touch(key)
            while order.count > capacity {
                ready[order.removeFirst()] = nil
            }
            return true
        }
    }

    private func fail(_ key: Key, _ flightID: UInt64, cancelled: Bool) {
        lock.withLock {
            if cancelled { stats.cancelled += 1 }
            if flights[key]?.id == flightID { flights[key] = nil }
        }
    }

    /// A waiter was cancelled. When nobody is left, work that has not started yet is not worth starting.
    private func leave(_ key: Key, _ flight: Flight) {
        lock.withLock {
            flight.waiters -= 1
            guard flight.waiters <= 0, flights[key] === flight else { return }
            flight.task.cancel()
            flights[key] = nil
        }
    }

    private func touch(_ key: Key) {
        // lock must be held
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// Identifies a memoized analysis result: who computes it (`id`), for which scope and interval,
/// plus any further inputs (`variant`, e.g. a taxonomy id or a chart resolution).
public struct AnalysisRequestKey<Variant: Hashable & Sendable>: Hashable, Sendable {
    public var id: String
    public var scope: Scope
    public var interval: DayInterval?
    public var variant: Variant
}

/// Placeholder variant for requests without extra inputs.
public struct NoVariant: Hashable, Sendable {
    public init() {}
}

extension PortfolioStore {
    // MARK: Ledger

    /// The engine's index of the current file. Built lazily, once per revision, and shared with the
    /// asynchronous analysis layer.
    ///
    /// Building costs about 0.3 µs per transaction (release) — fine on the main actor for ordinary
    /// files. Screens that compute anything substantial should not call it but use
    /// ``compute(_:_:)`` / ``analyze(_:scope:interval:variant:_:)``, which build the ledger off the
    /// main actor.
    public var ledger: Ledger {
        let revision = revision
        if let cached = analysisCache.cachedLedger(revision: revision) { return cached }
        let built = Ledger(file)
        analysisCache.adopt(built, revision: revision)
        return built
    }

    /// The ledger of the current revision, built off the main actor if it does not exist yet.
    public func ledgerOffMain() async -> Ledger {
        let revision = revision, file = file
        beginBusy()
        defer { endBusy() }
        return await analysisCache.ledger(revision: revision, file: file)
    }

    // MARK: Memoized computations

    /// Runs `work` off the main actor with the current revision's ledger and memoizes the result
    /// under `key` until the document changes. Requests with an equal key (and result type) that
    /// arrive while it is being computed share the computation; later ones get the stored value
    /// immediately.
    ///
    /// ```swift
    /// let rows = try await store.compute("securities.rows") { ledger in
    ///     ledger.securities.map { SecurityRow($0, count: ledger.transactions(forSecurity: $0.id).count) }
    /// }
    /// ```
    ///
    /// The store counts as busy (`isBusy`) while a request is pending, so loading indicators and
    /// the screenshot mode wait for it.
    ///
    /// - Parameters:
    ///   - key: Everything the result depends on *besides the document* — namespaced by feature,
    ///     e.g. `"holdings.rows"` or a small `Hashable & Sendable` struct of your inputs.
    ///   - work: Pure function of the ledger. Runs on a background thread.
    /// - Throws: `CancellationError` when the calling task is cancelled or the document changed
    ///   while computing (your `.task(id:)` restarts in both cases, so simply `try?` it).
    public func compute<Value: Sendable>(
        _ key: some Hashable & Sendable, _ work: @escaping @Sendable (Ledger) throws -> Value
    ) async throws -> Value {
        let revision = revision, file = file
        beginBusy()
        defer { endBusy() }
        return try await analysisCache.value(revision: revision, file: file, key: key, work)
    }

    /// The shared engine facade for a scope and interval (defaults: the window's scope and
    /// reporting period). Obtaining it is cheap, but **its properties compute on first access** —
    /// read them inside ``analyze(_:scope:interval:variant:_:)`` or a detached task, never in `body`.
    public func analysis(scope: Scope? = nil, interval: DayInterval? = nil) async -> Analysis {
        let revision = revision, file = file
        let scope = scope ?? self.scope, interval = interval ?? periodInterval
        beginBusy()
        defer { endBusy() }
        let ledger = await analysisCache.ledger(revision: revision, file: file)
        return analysisCache.analysis(revision: revision, ledger: ledger, scope: scope, interval: interval)
    }

    /// The shared engine facade for a scope and a reporting period resolved against `today`.
    public func analysis(scope: Scope? = nil, period: ReportingPeriod) async -> Analysis {
        await analysis(scope: scope, interval: interval(for: period))
    }

    /// Derives a screen model from the shared ``Analysis`` of a scope and interval, off the main
    /// actor, memoized by (revision, `id`, scope, interval, `variant`).
    ///
    /// ```swift
    /// let model = try await store.analyze("performance.summary") { analysis in
    ///     PerformanceSummary(report: analysis.report, heatmap: analysis.heatmap)
    /// }
    /// ```
    ///
    /// Screens showing the same scope and period share one `Analysis`, so the engine's expensive
    /// intermediates (daily valuation pass, lot replay) run once no matter how many screens ask.
    ///
    /// - Parameters:
    ///   - id: Names the computation, namespaced by feature (`"holdings.rows"`).
    ///   - scope: Defaults to the window's scope (`store.scope`).
    ///   - interval: Defaults to the reporting period (`store.periodInterval`).
    ///   - variant: Further inputs the result depends on (taxonomy id, options, …).
    public func analyze<Value: Sendable, Variant: Hashable & Sendable>(
        _ id: String, scope: Scope? = nil, interval: DayInterval? = nil, variant: Variant,
        _ work: @escaping @Sendable (Analysis) throws -> Value
    ) async throws -> Value {
        let revision = revision
        let scope = scope ?? self.scope, interval = interval ?? periodInterval
        let cache = analysisCache
        return try await compute(AnalysisRequestKey(id: id, scope: scope, interval: interval, variant: variant)) { ledger in
            try work(cache.analysis(revision: revision, ledger: ledger, scope: scope, interval: interval))
        }
    }

    /// ``analyze(_:scope:interval:variant:_:)`` without extra inputs.
    public func analyze<Value: Sendable>(
        _ id: String, scope: Scope? = nil, interval: DayInterval? = nil,
        _ work: @escaping @Sendable (Analysis) throws -> Value
    ) async throws -> Value {
        try await analyze(id, scope: scope, interval: interval, variant: NoVariant(), work)
    }
}

/// Type-erased storage wrapper of a memoized value (see `AnalysisCache.value`).
private struct Boxed<Value: Sendable>: Sendable {
    let value: Value
}
