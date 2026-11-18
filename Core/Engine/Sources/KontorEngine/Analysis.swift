import Foundation
import KontorModel

/// One-stop facade for the screens of the app: everything about one scope and interval, computed
/// lazily, each shared intermediate result at most once, safe to use from any thread.
///
/// ```swift
/// let analysis = Analysis(ledger: ledger, scope: .portfolio, period: .ytd, today: .today)
/// analysis.snapshot.totalValue        // replay only
/// analysis.ttwror                     // + daily pass
/// analysis.securities                 // reuses both
/// ```
///
/// **Cost model** (release build, 20 years × 60 securities × ~4 750 transactions; scale linearly):
///
/// | first access to …                                             | work done                               | ≈ time  |
/// |---------------------------------------------------------------|-----------------------------------------|---------|
/// | `snapshot`, `initialSnapshot`, `breakdown`                    | one lot replay of the transactions      | 0.3 ms  |
/// | `valuation`, `returns`, `ttwror`, `irr`, `risk`, `heatmap`, `drawdowns`, `investedCapital`, `rollingReturns` | one daily pass (days × open positions) | 5–8 ms |
/// | `securities`, `report`                                        | both of the above (shared)              | —       |
/// | `trades`, `earnings`                                          | one extra pass over the transactions each | 0.3 ms |
/// | `allocation(for:)`, `rebalancing(for:options:)`               | reuse `snapshot`; O(assignments)        | < 0.1 ms |
/// | `benchmark(securityID:)`                                      | one pass over the security's quotes     | < 0.1 ms |
///
/// Every later access returns the cached value. Results are immutable values; the object holds
/// them until it is released, so create a new `Analysis` whenever the ledger, scope or interval
/// changes. Concurrent first accesses are serialized (the second caller waits and gets the cache).
public final class Analysis: @unchecked Sendable {
    public let ledger: Ledger
    public let scope: Scope
    public let interval: DayInterval
    /// The currency of all results (the ledger's reporting currency).
    public var currency: CurrencyCode { ledger.reportingCurrency }

    private let lock = NSRecursiveLock()
    private let resolved: ResolvedScope
    private var _daily: (series: ValuationSeries, securities: [SecurityAccumulator])?
    private var _replay: LotReplay?
    private var _snapshot: Snapshot?
    private var _initialSnapshot: Snapshot?
    private var _breakdown: PerformanceBreakdown?
    private var _securities: [SecurityPerformance]?
    private var _returns: ReturnSeries?
    private var _irr: Double??
    private var _risk: RiskMetrics?
    private var _trades: TradeReport?
    private var _earnings: EarningsReport?
    private var _heatmap: ReturnHeatmap?
    private var _benchmarks: [UUID: ReturnSeries?] = [:]
    private var _allocations: [Taxonomy: TaxonomyAllocation] = [:]

    /// Analyses `scope` of `ledger` over `interval`. Nothing is computed until it is asked for.
    public init(ledger: Ledger, scope: Scope = .portfolio, interval: DayInterval) {
        self.ledger = ledger
        self.scope = scope
        self.interval = interval
        self.resolved = ResolvedScope(scope, ledger: ledger)
    }

    /// Analyses a reporting period ending `today`.
    public convenience init(ledger: Ledger, scope: Scope = .portfolio, period: ReportingPeriod, today: Day = .today) {
        self.init(ledger: ledger, scope: scope, interval: period.interval(today: today, ledger: ledger))
    }

    /// Indexes `file` (optionally in another reporting currency) and analyses it. Prefer sharing
    /// one `Ledger` between several analyses of the same file.
    public convenience init(
        file: PortfolioFile, scope: Scope = .portfolio, interval: DayInterval, reportingCurrency: CurrencyCode? = nil
    ) {
        self.init(ledger: Ledger(file, reportingCurrency: reportingCurrency), scope: scope, interval: interval)
    }

    private func cached<T>(_ slot: ReferenceWritableKeyPath<Analysis, T?>, _ make: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if let value = self[keyPath: slot] { return value }
        let value = make()
        self[keyPath: slot] = value
        return value
    }

    // MARK: Shared intermediates

    private var daily: (series: ValuationSeries, securities: [SecurityAccumulator]) {
        cached(\._daily) { ledger.dailyPass(interval, resolved, perSecurity: true) }
    }

    /// The lot replay with the period started at `interval.start`, advanced through `interval.end`.
    private var replay: LotReplay {
        cached(\._replay) {
            var replay = LotReplay(ledger: ledger, scope: resolved)
            replay.beginPeriod(at: interval.start)
            _initialSnapshot = ledger.snapshot(from: replay, on: interval.start)
            replay.advance(through: interval.end)
            return replay
        }
    }

    // MARK: Statement of assets

    /// Positions and balances at the end of the interval.
    public var snapshot: Snapshot {
        cached(\._snapshot) { ledger.snapshot(from: replay, on: interval.end) }
    }

    /// Positions and balances at the baseline (end of `interval.start`).
    public var initialSnapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        _ = replay
        return _initialSnapshot!
    }

    // MARK: Performance

    /// Daily values and external flows.
    public var valuation: ValuationSeries { daily.series }
    /// Daily and cumulative time-weighted returns.
    public var returns: ReturnSeries { cached(\._returns) { daily.series.returns() } }
    /// True time-weighted rate of return over the interval.
    public var ttwror: Double { returns.total }
    public var ttwrorAnnualized: Double? { returns.annualized }
    /// Internal rate of return (annual, money-weighted); nil if undefined.
    public var irr: Double? { cached(\._irr) { daily.series.irr() } }
    /// `final − initial − inflows + outflows`.
    public var absolutePerformance: Int64 { breakdown.absolutePerformance }
    /// The reconciling breakdown of the interval.
    public var breakdown: PerformanceBreakdown {
        cached(\._breakdown) { ledger.analyze(interval, replay: replay, accumulators: []).breakdown }
    }
    /// One record per security held or traded in the interval.
    public var securities: [SecurityPerformance] {
        cached(\._securities) { ledger.analyze(interval, replay: replay, accumulators: daily.securities).securities }
    }
    public func security(_ id: UUID) -> SecurityPerformance? { securities.first { $0.securityID == id } }
    public var risk: RiskMetrics {
        cached(\._risk) { RiskMetrics(returns: returns, riskFreeRate: ledger.settings.riskFreeRate) }
    }
    /// The underwater curve (see `ReturnSeries.drawdowns()`).
    public var drawdowns: [Double] { returns.drawdowns() }
    /// Baseline value plus cumulative net flows per day.
    public var investedCapital: [Int64] { daily.series.investedCapital() }
    /// TTWROR per calendar month and year.
    public var heatmap: ReturnHeatmap { cached(\._heatmap) { returns.heatmap() } }
    public func rollingReturns(windowDays: Int, annualized: Bool = false) -> RollingReturns {
        returns.rollingReturns(windowDays: windowDays, annualized: annualized)
    }

    /// The same content as `Ledger.performance(in:scope:)`, assembled from the cached parts.
    public var report: PerformanceReport {
        var diagnostics = DiagnosticCollector(daily.series.diagnostics)
        diagnostics.add(contentsOf: replay.diagnostics.items)
        return PerformanceReport(
            interval: interval, currency: currency, valuation: daily.series, returns: returns, irr: irr,
            breakdown: breakdown, securities: securities, risk: risk, diagnostics: diagnostics.items)
    }

    // MARK: Further analytics

    /// Trades closed within the interval and positions open at its end.
    public var trades: TradeReport {
        cached(\._trades) { ledger.trades(on: interval.end, closedAfter: interval.start, scope: scope) }
    }

    /// Dividends, interest, fees and taxes of the interval.
    public var earnings: EarningsReport {
        cached(\._earnings) { ledger.earnings(in: interval, scope: scope) }
    }

    /// Price performance of a benchmark security on the same day axis (cached per security).
    public func benchmark(securityID: UUID, basis: PriceBasis = .reportingCurrency) -> ReturnSeries? {
        guard basis == .reportingCurrency else { return ledger.benchmark(securityID: securityID, in: interval, basis: basis) }
        lock.lock()
        defer { lock.unlock() }
        if let hit = _benchmarks[securityID] { return hit }
        let series = ledger.benchmark(securityID: securityID, in: interval, basis: basis)
        _benchmarks[securityID] = series
        return series
    }

    /// Allocation of the closing snapshot across `taxonomy` (cached per taxonomy value).
    public func allocation(for taxonomy: Taxonomy) -> TaxonomyAllocation {
        lock.lock()
        defer { lock.unlock() }
        if let hit = _allocations[taxonomy] { return hit }
        let allocation = ledger.allocation(for: taxonomy, snapshot: snapshot)
        _allocations[taxonomy] = allocation
        return allocation
    }

    /// Rebalancing proposal for the closing snapshot.
    public func rebalancing(for taxonomy: Taxonomy, options: RebalancingOptions = RebalancingOptions()) -> RebalancingProposal {
        allocation(for: taxonomy).rebalancing(options)
    }

    /// Diagnostics of everything computed so far plus the ledger's own.
    public var diagnostics: [EngineDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        var all = DiagnosticCollector(ledger.diagnostics)
        if let d = _daily { all.add(contentsOf: d.series.diagnostics) }
        if let r = _replay { all.add(contentsOf: r.diagnostics.items) }
        if let s = _snapshot { all.add(contentsOf: s.diagnostics) }
        if let t = _trades { all.add(contentsOf: t.diagnostics) }
        if let e = _earnings { all.add(contentsOf: e.diagnostics) }
        return all.items
    }
}
