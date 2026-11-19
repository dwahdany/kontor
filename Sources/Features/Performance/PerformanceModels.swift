import SwiftUI
import KontorUI

// Everything the Performance screen shows is derived here, off the main actor, from the store's
// shared `Analysis` — plain `Sendable` values that the views only lay out. Every number is an
// engine result; this file selects, groups and labels them.

// MARK: - Overview (header tiles + main chart)

/// A security drawn into the return chart next to the portfolio.
struct ComparisonInfo: Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// True for `Settings.benchmarkSecurityIDs`, false for an ad-hoc comparison.
    var isBenchmark: Bool
    /// Return of the security over the period.
    var total: Double
}

/// The inputs of the overview besides scope and period.
struct OverviewQuery: Hashable, Sendable {
    /// Ad-hoc comparison securities of the window.
    var compare: [UUID]
    /// Name of the scope's own series in the chart ("Portfolio", "Kids Depot").
    var scopeName: String
}

enum ComparisonRules {
    /// Whether the engine can draw `securityID` as a comparison line: it needs a price (a quote, or
    /// one derived from its transactions) and an exchange rate into the reporting currency.
    static func canDraw(_ securityID: UUID, ledger: Ledger, on day: Day) -> Bool {
        guard let security = ledger.security(securityID), ledger.price(of: securityID, on: day) != nil else { return false }
        return ledger.converter.canConvert(from: security.currency, to: ledger.reportingCurrency)
    }
}

/// Header figures and the series of the main chart for the window's scope and period.
struct OverviewModel: Sendable {
    /// The palette has eight slots and is never cycled: the portfolio plus seven comparisons.
    static let comparisonLimit = 7
    static let portfolioSeriesID = "portfolio"

    var currency: CurrencyCode
    var interval: DayInterval
    /// False when the scope holds nothing and nothing flows in the whole period.
    var hasActivity: Bool

    var ttwror: Double
    var ttwrorAnnualized: Double?
    var irr: Double?
    var absolutePerformance: Int64
    var initialValue: Int64
    var finalValue: Int64
    var maxDrawdown: RiskMetrics.Drawdown?
    var volatility: Double
    var sharpeRatio: Double?
    var riskFreeRate: Double

    /// Chart inputs — dense daily engine series (index `i` = `interval.start + i`).
    var returnSeries: [TimeSeries]
    var valueSeries: [TimeSeries]
    var drawdownSeries: [TimeSeries]
    var comparisons: [ComparisonInfo]
    /// Ad-hoc comparisons that were asked for but cannot be drawn (no price, no exchange rate).
    var undrawnComparisons: [UUID]
    /// What the engine had to leave out or estimate for these figures.
    var warnings: [DataWarning]

    /// Days the figures really cover: the period, but not from before the first transaction. A
    /// portfolio that is four weeks old has four weeks of history whatever period is selected.
    var measuredDays: Int

    /// Annualizing less than a year extrapolates; the screen then shows the plain return only.
    var showsAnnualized: Bool { ReturnHorizon.isAnnualized(days: measuredDays) }
    /// The IRR as shown: per year for long periods, else the money-weighted return of the period.
    var moneyWeightedReturn: Double? { ReturnHorizon.moneyWeighted(irr: irr, days: measuredDays) }
    /// The Sharpe ratio divides an annualized return; for less than a year that is an extrapolation.
    var showsSharpeRatio: Bool { ReturnHorizon.hasFullYear(days: measuredDays) }
    var shownSharpeRatio: Double? { showsSharpeRatio ? sharpeRatio : nil }
    /// Volatility from a handful of days says nothing.
    var showsVolatility: Bool { ReturnHorizon.hasEnoughHistory(days: measuredDays) }

    init(_ analysis: Analysis, compare: [UUID], scopeName: String = "Portfolio") {
        let ledger = analysis.ledger
        let valuation = analysis.valuation
        let returns = analysis.returns
        let risk = analysis.risk
        let breakdown = analysis.breakdown
        let start = analysis.interval.start
        currency = analysis.currency
        interval = analysis.interval
        measuredDays = analysis.measuredInterval.dayCount
        hasActivity = valuation.values.contains { $0 != 0 } || valuation.totalInflows != 0 || valuation.totalOutflows != 0

        ttwror = returns.total
        ttwrorAnnualized = returns.annualized
        irr = analysis.irr
        absolutePerformance = breakdown.absolutePerformance
        initialValue = breakdown.initialValue
        finalValue = breakdown.finalValue
        maxDrawdown = risk.maxDrawdown
        volatility = risk.volatility
        sharpeRatio = risk.sharpeRatio
        riskFreeRate = ledger.settings.riskFreeRate

        var returnSeries = [TimeSeries(id: Self.portfolioSeriesID, scopeName, start: start, values: returns.cumulative, color: ChartColors.series(0))]
        var drawdownSeries = [TimeSeries(id: Self.portfolioSeriesID, scopeName, start: start, values: analysis.drawdowns.map { -$0 }, style: .area)]
        valueSeries = [
            TimeSeries(id: Self.portfolioSeriesID, "Value", start: start, values: valuation.values, style: .area, color: ChartColors.series(0)),
            TimeSeries(id: "invested", "Invested Capital", start: start, values: analysis.investedCapital, style: .step, color: ChartColors.comparison),
        ]

        let benchmarks = ledger.settings.benchmarkSecurityIDs
        var seen = Set<UUID>()
        var infos: [ComparisonInfo] = []
        var undrawn: [UUID] = []
        // Palette slot 0 is the scope itself; every drawn comparison takes the next free slot.
        var nextSlot = 1
        for id in benchmarks + compare {
            guard seen.insert(id).inserted, let security = ledger.security(id) else { continue }
            let isBenchmark = benchmarks.contains(id)
            guard infos.count < Self.comparisonLimit, let series = analysis.benchmark(securityID: id) else {
                if !isBenchmark { undrawn.append(id) }
                continue
            }
            // A benchmark drawn first takes the neutral comparison color; everything else a palette slot.
            let color: Color
            if infos.isEmpty, isBenchmark {
                color = ChartColors.comparison
            } else {
                color = ChartColors.series(nextSlot)
                nextSlot += 1
            }
            infos.append(ComparisonInfo(id: id, name: security.name, isBenchmark: isBenchmark, total: series.total))
            returnSeries.append(TimeSeries(id: id.uuidString, security.name, start: start, values: series.cumulative, color: color, dashed: isBenchmark))
            drawdownSeries.append(TimeSeries(id: id.uuidString, security.name, start: start, values: series.drawdowns().map { -$0 },
                                             color: color, dashed: isBenchmark))
        }
        self.returnSeries = returnSeries
        self.drawdownSeries = drawdownSeries
        comparisons = infos
        undrawnComparisons = undrawn
        // Last: the engine collects diagnostics while it computes the figures above.
        warnings = DataWarning.warnings(for: analysis)
    }

    func day(at fraction: Double) -> Day {
        interval.start.advanced(by: Int((Double(interval.dayCount) * min(max(fraction, 0), 1)).rounded()))
    }
}

/// Engine figures for a sub-range selected in the chart.
struct RangeFigures: Sendable, Equatable {
    var interval: DayInterval
    var currency: CurrencyCode
    var ttwror: Double
    var irr: Double?
    var absolutePerformance: Int64
    var maxDrawdown: Double?

    var measuredDays: Int

    var isAnnualized: Bool { ReturnHorizon.isAnnualized(days: measuredDays) }
    /// Per year for ranges longer than a year, else the money-weighted return of the range.
    var moneyWeightedReturn: Double? { ReturnHorizon.moneyWeighted(irr: irr, days: measuredDays) }

    init(_ analysis: Analysis) {
        interval = analysis.interval
        measuredDays = analysis.measuredInterval.dayCount
        currency = analysis.currency
        ttwror = analysis.ttwror
        irr = analysis.irr
        absolutePerformance = analysis.breakdown.absolutePerformance
        maxDrawdown = analysis.risk.maxDrawdown?.depth
    }
}

/// One row of the period comparison.
struct PeriodFigures: Sendable, Equatable {
    var ttwror: Double
    var ttwrorAnnualized: Double?
    var irr: Double?
    var absolutePerformance: Int64
    var currency: CurrencyCode
    var dayCount: Int

    var isAnnualized: Bool { ReturnHorizon.isAnnualized(days: dayCount) }
    /// Per year for periods longer than a year, else the money-weighted return of the period.
    var moneyWeightedReturn: Double? { ReturnHorizon.moneyWeighted(irr: irr, days: dayCount) }

    init(_ analysis: Analysis) {
        ttwror = analysis.ttwror
        ttwrorAnnualized = analysis.ttwrorAnnualized
        irr = analysis.irr
        absolutePerformance = analysis.breakdown.absolutePerformance
        currency = analysis.currency
        dayCount = analysis.measuredInterval.dayCount
    }
}

// MARK: - Calculation

/// A row of the reconciling statement.
enum StatementLine: String, Sendable, Hashable, CaseIterable {
    case initialValue, deposits, withdrawals, deliveriesIn, deliveriesOut, transfersIn, transfersOut, netFlows
    case realizedGains, unrealizedGains, dividends, interest, fees, taxes, cashCurrencyGains, roundingResidue
    case performance, finalValue

    enum Role: Sendable { case total, subtotal, component }

    var role: Role {
        switch self {
        case .initialValue, .finalValue: .total
        case .netFlows, .performance: .subtotal
        default: .component
        }
    }

    var title: String {
        switch self {
        case .netFlows: "Net Inflows"
        case .performance: "Performance"
        default: engineLine?.title ?? rawValue
        }
    }

    /// The engine's breakdown line this row shows (subtotals have none).
    var engineLine: PerformanceBreakdown.Line? { PerformanceBreakdown.Line(rawValue: rawValue) }

    var helpTopic: HelpTopic? {
        switch self {
        case .deposits, .withdrawals, .netFlows: .externalFlows
        case .deliveriesIn, .deliveriesOut: .delivery
        case .transfersIn, .transfersOut: .scope
        case .realizedGains: .realizedGains
        case .unrealizedGains: .unrealizedGains
        case .cashCurrencyGains: .currencyGains
        case .dividends, .interest: .grossVersusNet
        case .performance: .absolutePerformance
        default: nil
        }
    }

    /// Plain-language explanation shown with the contributing entries.
    var explanation: String {
        switch self {
        case .initialValue: "Market value of everything in scope at the end of the day before the period starts."
        case .deposits: "Cash paid into the accounts in scope."
        case .withdrawals: "Cash taken out of the accounts in scope."
        case .deliveriesIn: "Securities delivered into a depot without a purchase, at their recorded value."
        case .deliveriesOut: "Securities delivered out of a depot without a sale, at their recorded value."
        case .transfersIn: "Value that entered this scope from the rest of the portfolio — for example purchases paid from an account outside the scope, or transfers between accounts and depots."
        case .transfersOut: "Value that left this scope for the rest of the portfolio — for example sale proceeds and dividends credited to an account outside the scope."
        case .netFlows: "Everything that was added to or removed from the scope. This is your money moving, not performance."
        case .realizedGains: "Gains and losses of positions sold in the period, before fees and taxes. Positions held at the start count from their value on that day."
        case .unrealizedGains: "Change in value of the positions still held at the end, before fees and taxes."
        case .dividends: "Dividends received, before fees and withholding taxes."
        case .interest: "Interest received before taxes, less interest charged."
        case .fees: "All fees of the period, including those inside purchases, sales and dividends, less refunds."
        case .taxes: "All taxes of the period, including those withheld on sales, dividends and interest, less refunds."
        case .cashCurrencyGains: "Exchange-rate changes on cash held in other currencies, and spreads on currency conversions."
        case .roundingResidue: "Sub-cent differences from converting currencies and applying classification weights transaction by transaction."
        case .performance: "What the scope earned in the period: all gains and earnings less all costs."
        case .finalValue: "Market value of everything in scope at the end of the period."
        }
    }

    /// Lines whose amount is made of individual transactions (the others are valuations or sums).
    var listsTransactions: Bool {
        switch self {
        case .initialValue, .finalValue, .netFlows, .performance, .unrealizedGains, .cashCurrencyGains, .roundingResidue: false
        default: true
        }
    }

    static let flowLines: [StatementLine] = [.deposits, .deliveriesIn, .transfersIn, .withdrawals, .deliveriesOut, .transfersOut]
    static let componentLines: [StatementLine] = [
        .realizedGains, .unrealizedGains, .dividends, .interest, .fees, .taxes, .cashCurrencyGains, .roundingResidue,
    ]
}

/// A transaction that contributes to a statement line.
struct ContributionRow: Sendable, Identifiable, Hashable {
    let id: UUID
    var date: Day
    var kind: KontorModel.Transaction.Kind
    /// Security name, or the account for cash bookings.
    var subject: String
    var note: String
    /// The part of the transaction that belongs to the line, signed like the line, in the
    /// transaction's own currency.
    var amount: Money
    /// `amount` in the reporting currency at the transaction day's rate; nil when there is no rate
    /// (the engine then leaves the amount out of the line).
    var value: Int64?

    var kindTitle: String { kind.title }
    /// Sort key of the amount column: comparable across currencies.
    var sortValue: Int64 { value ?? 0 }
}

/// A security's share of a gain line (engine figures, reporting currency).
struct SecurityContribution: Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var amount: Int64
    var currencyPart: Int64?
}

struct StatementEntry: Sendable, Identifiable, Hashable {
    var line: StatementLine
    var amount: Int64
    /// "of which currency" for the capital-gain lines.
    var currencyPart: Int64?
    var id: StatementLine { line }
}

/// The reconciling breakdown of the period: statement rows and waterfall steps.
struct CalculationModel: Sendable {
    var currency: CurrencyCode
    var interval: DayInterval
    var entries: [StatementEntry]
    var waterfall: [WaterfallStep]
    /// `initialValue + flows + performance − finalValue`; zero by construction.
    var reconciliationGap: Int64

    func amount(_ line: StatementLine) -> Int64 { entries.first { $0.line == line }?.amount ?? 0 }

    init(_ analysis: Analysis) {
        let b = analysis.breakdown
        currency = analysis.currency
        interval = analysis.interval

        let signed = Dictionary(uniqueKeysWithValues: b.lines.map { ($0.line, $0.amount) })
        func value(_ line: StatementLine) -> Int64 { line.engineLine.flatMap { signed[$0] } ?? 0 }

        var rows: [StatementEntry] = [StatementEntry(line: .initialValue, amount: b.initialValue)]
        // Deposits and withdrawals are always listed; the rarer flows only when they occur.
        for line in StatementLine.flowLines where value(line) != 0 || line == .deposits || line == .withdrawals {
            rows.append(StatementEntry(line: line, amount: value(line)))
        }
        rows.append(StatementEntry(line: .netFlows, amount: b.inflows - b.outflows))
        for line in StatementLine.componentLines {
            let amount = value(line)
            if amount == 0, line == .cashCurrencyGains || line == .roundingResidue { continue }
            var entry = StatementEntry(line: line, amount: amount)
            if line == .realizedGains, b.realizedCurrencyGains != 0 { entry.currencyPart = b.realizedCurrencyGains }
            if line == .unrealizedGains, b.unrealizedCurrencyGains != 0 { entry.currencyPart = b.unrealizedCurrencyGains }
            rows.append(entry)
        }
        rows.append(StatementEntry(line: .performance, amount: b.absolutePerformance))
        rows.append(StatementEntry(line: .finalValue, amount: b.finalValue))
        entries = rows
        reconciliationGap = b.initialValue + b.inflows - b.outflows + b.componentSum - b.finalValue
        waterfall = WaterfallStep.steps(from: b)
    }
}

struct LineDetailQuery: Hashable, Sendable {
    var line: StatementLine
    var sortOrder: [KeyPathComparator<ContributionRow>]
}

/// What is behind one statement line: the transactions and, for capital gains, the securities.
struct LineDetail: Sendable {
    var line: StatementLine
    var currency: CurrencyCode
    var transactions: [ContributionRow]
    var securities: [SecurityContribution]
    /// True when amounts of this scope are counted by classification weight.
    var isWeighted: Bool
    /// True when every listed amount is in the reporting currency, so the list adds up to the line.
    var isSingleCurrency: Bool
    /// Listed amounts without an exchange rate — shown, but not part of the line.
    var unconvertedCount: Int

    init(_ analysis: Analysis, query: LineDetailQuery) {
        let ledger = analysis.ledger
        let line = query.line
        self.line = line
        currency = analysis.currency

        // Securities behind the two capital-gain lines (period basis, like the breakdown).
        switch line {
        case .realizedGains, .unrealizedGains:
            securities = analysis.securities.compactMap { p in
                let value = line == .realizedGains ? p.periodRealizedGain : p.periodUnrealizedGain
                guard value != 0 else { return nil }
                return SecurityContribution(id: p.securityID, name: ledger.security(p.securityID)?.name ?? "Unknown Security", amount: value)
            }
            .sorted { abs($0.amount) > abs($1.amount) }
        default:
            securities = []
        }

        var rows: [ContributionRow] = []
        isWeighted = ScopeFilter.isWeighted(analysis.scope)
        // Only lines made of transactions need the replay that attributes them.
        if line.listsTransactions {
            let attribution = PositionAttribution(ledger)
            let filter = ScopeFilter(analysis.scope, attribution: attribution)
            let period = analysis.interval
            let converter = ledger.converter
            for t in ledger.transactions where period.contains(t.date) && !attribution.skipped.contains(t.id) {
                let minor = Self.contribution(of: t, to: line, filter: filter)
                guard minor != 0 else { continue }
                let subject = t.securityID.flatMap { ledger.security($0)?.name } ?? t.accountID.flatMap { ledger.account($0)?.name } ?? ""
                let currency = t.amount.currency
                let value = currency == analysis.currency ? minor : converter.convert(minor: minor, from: currency, to: analysis.currency, on: t.date)
                rows.append(ContributionRow(id: t.id, date: t.date, kind: t.kind, subject: subject, note: t.note,
                                            amount: Money(minor: minor, currency: currency), value: value))
            }
        }
        isSingleCurrency = rows.allSatisfy { $0.amount.currency == analysis.currency }
        unconvertedCount = rows.count { $0.value == nil }
        transactions = rows.sorted(using: query.sortOrder)
    }

    /// The part of a transaction that belongs to a statement line, signed like the line, in the
    /// transaction's own currency (0 = does not contribute). Follows the transaction sign
    /// conventions of the model: fees and taxes are included in `amount`, `grossMinor` strips them.
    static func contribution(of t: KontorModel.Transaction, to line: StatementLine, filter: ScopeFilter) -> Int64 {
        let position = filter.includesPosition(t), account = filter.includesAccount(t)
        // A fee or tax booking follows its security when it names one, else its account.
        let standalone = filter.hasSecurity(t) ? position : account
        switch line {
        case .deposits: return t.kind == .deposit && account ? t.amount.minor : 0
        case .withdrawals: return t.kind == .withdrawal && account ? -t.amount.minor : 0
        case .deliveriesIn: return t.kind == .deliveryIn && position ? t.amount.minor : 0
        case .deliveriesOut: return t.kind == .deliveryOut && position ? -t.amount.minor : 0
        case .realizedGains: return (t.kind == .sell || t.kind == .deliveryOut) && position ? t.grossMinor : 0
        case .dividends: return t.kind == .dividend && position ? t.grossMinor : 0
        case .interest:
            guard account else { return 0 }
            return t.kind == .interest ? t.grossMinor : t.kind == .interestCharge ? -t.amount.minor : 0
        case .fees:
            switch t.kind {
            case .fee: return standalone ? -t.amount.minor : 0
            case .feeRefund: return standalone ? t.amount.minor : 0
            case .buy, .sell, .deliveryIn, .deliveryOut, .dividend: return position ? -t.fees : 0
            case .interest: return account ? -t.fees : 0
            default: return 0
            }
        case .taxes:
            switch t.kind {
            case .tax: return standalone ? -t.amount.minor : 0
            case .taxRefund: return standalone ? t.amount.minor : 0
            case .buy, .sell, .deliveryIn, .deliveryOut, .dividend: return position ? -t.taxes : 0
            case .interest: return account ? -t.taxes : 0
            default: return 0
            }
        case .transfersIn, .transfersOut:
            // Value crossing the boundary of a partial scope: one leg of the booking is inside,
            // the other outside (the engine's external-flow rule, with in/out instead of weights).
            let flow = boundaryFlow(of: t, filter: filter)
            if line == .transfersIn { return flow > 0 ? t.amount.minor : 0 }
            return flow < 0 ? -t.amount.minor : 0
        default:
            return 0
        }
    }

    /// +1 when the booking moves value into the scope from the rest of the portfolio, −1 when it
    /// moves value out, 0 when both legs are on the same side (or it is an external flow).
    private static func boundaryFlow(of t: KontorModel.Transaction, filter: ScopeFilter) -> Int {
        if filter.isWholePortfolio { return 0 }
        let position = filter.includesPosition(t) ? 1 : 0, account = filter.includesAccount(t) ? 1 : 0
        switch t.kind {
        case .buy: return position - account
        case .sell, .dividend: return account - position
        case .fee, .tax: return filter.hasSecurity(t) ? position - account : 0
        case .feeRefund, .taxRefund: return filter.hasSecurity(t) ? account - position : 0
        case .cashTransfer: return (filter.includesCounterAccount(t) ? 1 : 0) - account
        case .securityTransfer: return (filter.includesCounterPosition(t) ? 1 : 0) - position
        case .deposit, .withdrawal, .deliveryIn, .deliveryOut, .interest, .interestCharge: return 0
        }
    }
}

/// Which legs of a transaction lie inside a scope — mirrors how the engine attributes amounts:
/// security-related amounts follow the position, cash bookings follow the account.
struct ScopeFilter: Sendable {
    private let scope: Scope
    private let attribution: PositionAttribution

    init(_ scope: Scope, attribution: PositionAttribution) {
        self.scope = scope
        self.attribution = attribution
    }

    var isWholePortfolio: Bool { scope == .portfolio }
    var isWeighted: Bool { Self.isWeighted(scope) }
    /// A fee or tax follows its security when it names one the file contains, else its account.
    func hasSecurity(_ t: KontorModel.Transaction) -> Bool { attribution.hasSecurity(t) }
    static func isWeighted(_ scope: Scope) -> Bool { if case .weighted = scope { true } else { false } }

    func includesPosition(_ t: KontorModel.Transaction) -> Bool {
        switch scope {
        case .portfolio:
            return true
        case .subset(let depots, _):
            // Bookings without a depot follow the depot that holds the security (see `PositionAttribution`).
            return attribution.isPosition(of: t, in: depots)
        case .security(let id, let depot):
            guard t.securityID == id else { return false }
            return depot.map { attribution.isPosition(of: t, in: [$0]) } ?? true
        case .weighted(let securities, _):
            return t.securityID.map { (securities[$0] ?? 0) > 0 } ?? false
        }
    }

    /// The receiving depot of a security transfer.
    func includesCounterPosition(_ t: KontorModel.Transaction) -> Bool {
        switch scope {
        case .portfolio: true
        case .subset(let depots, _): t.counterDepotID.map(depots.contains) ?? false
        case .security(let id, let depot): t.securityID == id && (depot == nil || t.counterDepotID == depot)
        case .weighted(let securities, _): t.securityID.map { (securities[$0] ?? 0) > 0 } ?? false
        }
    }

    /// The receiving account of a cash transfer.
    func includesCounterAccount(_ t: KontorModel.Transaction) -> Bool {
        switch scope {
        case .portfolio: true
        case .subset(_, let accounts): t.counterAccountID.map(accounts.contains) ?? false
        case .security: false
        case .weighted(_, let accounts): t.counterAccountID.map { (accounts[$0] ?? 0) > 0 } ?? false
        }
    }

    func includesAccount(_ t: KontorModel.Transaction) -> Bool {
        switch scope {
        case .portfolio: true
        case .subset(_, let accounts): t.accountID.map(accounts.contains) ?? false
        case .security: false
        case .weighted(_, let accounts): t.accountID.map { (accounts[$0] ?? 0) > 0 } ?? false
        }
    }
}

// MARK: - Returns

struct ReturnExtreme: Sendable, Identifiable, Hashable {
    var id: String
    /// "Day", "Month", "Year", "12 Months"
    var span: String
    var best: Double?
    var bestLabel: String
    var worst: Double?
    var worstLabel: String
}

struct ReturnsModel: Sendable {
    var interval: DayInterval
    var heatmap: ReturnHeatmap
    /// Heatmap rows, newest first; a year the period covers only partly is marked with "*".
    var heatmapRows: [HeatmapRow]
    var years: [BarCategory]
    var yearlyReturns: [Double]
    /// Explains the "*" years ("2025 covers Jul–Dec only"); nil when every year is complete.
    var partialYearsNote: String?
    /// Names the edge months the period cuts off; nil when every month is complete.
    var partialMonthsNote: String?
    var rollingOneYear: [Double?]
    var rollingThreeYears: [Double?]
    var hasRollingOneYear: Bool
    var hasRollingThreeYears: Bool
    var extremes: [ReturnExtreme]
    /// Complete calendar months in the period, and how many of them ended with a gain.
    var monthCount: Int
    var positiveMonths: Int
    /// Share of 12-month windows that ended with a gain (nil without enough windows).
    var positiveYearWindows: Double?
    var averageYearWindow: Double?

    init(_ analysis: Analysis) {
        let returns = analysis.returns
        let risk = analysis.risk
        interval = analysis.interval
        heatmap = analysis.heatmap
        let coverage = CalendarCoverage(interval: analysis.interval, firstTransactionDay: analysis.ledger.firstTransactionDay)

        // Calendar years: a year cut off by a period edge is shown, but marked and never ranked.
        let yearly = returns.yearlyReturns()
        let partialYears = yearly.map(\.year).filter { !coverage.isComplete(year: $0) }
        years = yearly.map { y in
            partialYears.contains(y.year)
                ? BarCategory(id: String(y.year), label: "\(y.year)*", detail: "\(y.year) (\(coverage.monthsLabel(of: y.year)) only)")
                : BarCategory.year(y.year)
        }
        yearlyReturns = yearly.map(\.value)
        heatmapRows = heatmap.rows.reversed().map { row in
            HeatmapRow(id: String(row.year), label: partialYears.contains(row.year) ? "\(row.year)*" : String(row.year),
                       cells: row.months, total: row.total)
        }
        partialYearsNote = partialYears.isEmpty ? nil
            : "* " + partialYears.map { "\($0) covers \(coverage.monthsLabel(of: $0)) only" }.joined(separator: ", ") + "."

        let one = analysis.rollingReturns(windowDays: 365)
        let three = analysis.rollingReturns(windowDays: 365 * 3, annualized: true)
        rollingOneYear = one.values
        rollingThreeYears = three.values
        // A line needs more than a handful of end dates: a period of exactly one year has a single
        // 12-month window, which would draw as one lonely dot — and is no statistic either.
        hasRollingOneYear = one.best != nil && rollingOneYear.lazy.filter { $0 != nil }.count >= 5
        hasRollingThreeYears = three.best != nil
        positiveYearWindows = hasRollingOneYear ? one.positiveShare : nil
        averageYearWindow = hasRollingOneYear ? one.average : nil

        // Month statistics count complete calendar months only.
        let monthly = returns.monthlyReturns()
        let complete = monthly.filter { coverage.isComplete(year: $0.year, month: $0.month) }
        let partialMonths = monthly.filter { !coverage.isComplete(year: $0.year, month: $0.month) }
        monthCount = complete.count
        positiveMonths = complete.filter { $0.value > 0 }.count
        if partialMonths.isEmpty {
            partialMonthsNote = nil
        } else {
            let names = partialMonths.map { Fmt.month(year: $0.year, month: $0.month) }
            partialMonthsNote = "\(names.joined(separator: " and ")) \(names.count == 1 ? "is" : "are") only partly inside the period and not counted as \(names.count == 1 ? "a month" : "months")."
        }

        var rows: [ReturnExtreme] = []
        if risk.bestDay != nil || risk.worstDay != nil {
            rows.append(ReturnExtreme(
                id: "day", span: "Day",
                best: risk.bestDay?.value, bestLabel: risk.bestDay.map { Fmt.day($0.day, style: .medium) } ?? "",
                worst: risk.worstDay?.value, worstLabel: risk.worstDay.map { Fmt.day($0.day, style: .medium) } ?? ""))
        }
        if complete.count > 1, let best = complete.max(by: { $0.value < $1.value }), let worst = complete.min(by: { $0.value < $1.value }) {
            rows.append(ReturnExtreme(
                id: "month", span: "Month",
                best: best.value, bestLabel: Fmt.month(year: best.year, month: best.month),
                worst: worst.value, worstLabel: Fmt.month(year: worst.year, month: worst.month)))
        }
        let completeYears = yearly.filter { !partialYears.contains($0.year) }
        if completeYears.count > 1, let best = completeYears.max(by: { $0.value < $1.value }),
           let worst = completeYears.min(by: { $0.value < $1.value }) {
            rows.append(ReturnExtreme(id: "year", span: "Calendar Year", best: best.value, bestLabel: String(best.year),
                                      worst: worst.value, worstLabel: String(worst.year)))
        }
        if hasRollingOneYear {
            func windowLabel(_ target: Double?) -> String {
                guard let target, let index = one.values.firstIndex(where: { $0 == target }) else { return "" }
                let end = one.day(at: index)
                return "to \(Fmt.day(end, style: .medium))"
            }
            rows.append(ReturnExtreme(id: "rolling", span: "12 Months", best: one.best, bestLabel: windowLabel(one.best),
                                      worst: one.worst, worstLabel: windowLabel(one.worst)))
        }
        extremes = rows
    }
}

// MARK: - Risk

/// One peak-to-recovery episode of the underwater curve.
struct DrawdownEpisode: Sendable, Identifiable, Hashable {
    var id: Int32 { peak.rawValue }
    var depth: Double
    var peak: Day
    var trough: Day
    var recovery: Day?
    var declineDays: Int { peak.distance(to: trough) }
    var recoveryDays: Int? { recovery.map { trough.distance(to: $0) } }
    /// Peak to recovery, or peak to the end of the period while still under water.
    var durationDays: Int

    /// Splits the engine's underwater curve (0 at a peak) into its episodes. This only finds where
    /// the curve leaves and returns to zero; the depths are the engine's values.
    static func episodes(underwater: [Double], start: Day) -> [DrawdownEpisode] {
        var out: [DrawdownEpisode] = []
        var peakIndex: Int?
        var troughIndex = 0
        var depth = 0.0
        for (i, value) in underwater.enumerated() {
            if value > 0 {
                if peakIndex == nil { peakIndex = max(i - 1, 0); depth = 0 }
                if value > depth { depth = value; troughIndex = i }
            } else if let p = peakIndex {
                out.append(DrawdownEpisode(depth: depth, peak: start.advanced(by: p), trough: start.advanced(by: troughIndex),
                                           recovery: start.advanced(by: i), durationDays: i - p))
                peakIndex = nil
            }
        }
        if let p = peakIndex {
            out.append(DrawdownEpisode(depth: depth, peak: start.advanced(by: p), trough: start.advanced(by: troughIndex),
                                       recovery: nil, durationDays: underwater.count - 1 - p))
        }
        return out
    }
}

struct RiskModel: Sendable {
    var interval: DayInterval
    var maxDrawdown: RiskMetrics.Drawdown?
    /// Deepest first, at most `episodeLimit`.
    var episodes: [DrawdownEpisode]
    var episodeCount: Int
    /// How far the scope is below its last peak at the end of the period (0 = at a peak).
    var currentDrawdown: Double
    var volatility: Double
    var semiVolatility: Double
    var sharpeRatio: Double?
    var riskFreeRate: Double
    var annualizedReturn: Double?
    /// False for periods of less than a year: the Sharpe ratio would rest on an extrapolated return.
    var showsSharpeRatio: Bool
    var dailyHistogram: Histogram
    var monthlyHistogram: Histogram
    var dailyCount: Int
    /// Complete calendar months in the period.
    var monthlyCount: Int

    static let episodeLimit = 10
    /// Dips shallower than this are noise, not drawdowns worth a table row.
    static let episodeThreshold = 0.01

    init(_ analysis: Analysis) {
        let returns = analysis.returns
        let risk = analysis.risk
        let curve = analysis.drawdowns
        interval = analysis.interval
        maxDrawdown = risk.maxDrawdown
        let all = DrawdownEpisode.episodes(underwater: curve, start: analysis.interval.start)
        let relevant = all.filter { $0.depth >= Self.episodeThreshold }.sorted { $0.depth > $1.depth }
        episodeCount = relevant.count
        episodes = Array(relevant.prefix(Self.episodeLimit))
        currentDrawdown = curve.last ?? 0
        volatility = risk.volatility
        semiVolatility = risk.semiVolatility
        sharpeRatio = risk.sharpeRatio
        riskFreeRate = analysis.ledger.settings.riskFreeRate
        annualizedReturn = returns.annualized
        showsSharpeRatio = ReturnHorizon.hasFullYear(days: analysis.measuredInterval.dayCount)

        // Like the engine's volatility: weekends are structurally zero and left out. Days before
        // anything was held are left out too.
        let values = analysis.valuation.values
        var daily: [Double] = []
        daily.reserveCapacity(returns.daily.count)
        for i in returns.daily.indices.dropFirst() where !returns.day(at: i).isWeekend && (values[i] != 0 || values[i - 1] != 0) {
            daily.append(returns.daily[i])
        }
        dailyCount = daily.count
        dailyHistogram = Histogram(daily, targetBins: 41)
        // Complete calendar months only: a month cut off by a period edge is not a monthly return.
        let coverage = CalendarCoverage(interval: analysis.interval, firstTransactionDay: analysis.ledger.firstTransactionDay)
        let monthly = returns.monthlyReturns().filter { coverage.isComplete(year: $0.year, month: $0.month) }.map(\.value)
        monthlyCount = monthly.count
        monthlyHistogram = Histogram(monthly, targetBins: 21)
    }
}

// MARK: - Securities

struct SecurityRow: Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var isRetired: Bool
    var isHeld: Bool
    var marketValue: Int64
    var ttwror: Double
    /// Money-weighted return as shown: per year for periods over a year, else of the period itself.
    var irr: Double?
    var absolutePerformance: Int64
    var realized: Int64
    var unrealized: Int64
    var dividends: Int64
    var fees: Int64
    var taxes: Int64
    /// This security's result relative to the size of the total result (nil when the total is 0).
    var share: Double?
    /// Set when the engine could not value the security from quotes.
    var priceIssue: PriceIssue?

    enum PriceIssue: Sendable, Hashable {
        /// No quotes: valued at the prices of its own transactions.
        case derived
        /// No price at all: valued at zero.
        case missing

        var explanation: String {
            switch self {
            case .derived: "No quotes — valued at the price of its own transactions, so its gain only changes when you trade."
            case .missing: "No price — valued at zero."
            }
        }
    }

    /// Sort keys for optional columns: missing values sort below everything.
    var irrKey: Double { irr ?? -.infinity }
    var shareKey: Double { share ?? -.infinity }
}

struct SecuritiesQuery: Hashable, Sendable {
    var filter: String
    var sortOrder: [KeyPathComparator<SecurityRow>]
}

struct SecuritiesModel: Sendable {
    var currency: CurrencyCode
    var rows: [SecurityRow]
    var totalCount: Int
    /// Sum of the securities' results, and the scope's total result.
    var securitiesResult: Int64
    var totalResult: Int64
    /// True when the IRR column is per year (periods over a year).
    var irrIsAnnualized: Bool
    /// What `totalResult − securitiesResult` is made of; adds up to it exactly.
    var remainder: [RemainderPart]

    /// A part of the result that is not tied to a security.
    struct RemainderPart: Sendable, Identifiable, Hashable {
        var label: String
        var amount: Int64
        var id: String { label }
    }

    init(_ analysis: Analysis, query: SecuritiesQuery) {
        let ledger = analysis.ledger
        let breakdown = analysis.breakdown
        let days = analysis.measuredInterval.dayCount
        currency = analysis.currency
        totalResult = breakdown.absolutePerformance
        irrIsAnnualized = ReturnHorizon.isAnnualized(days: days)
        let total = totalResult
        let performances = analysis.securities
        var issues: [UUID: SecurityRow.PriceIssue] = [:]
        for diagnostic in analysis.diagnostics {
            switch diagnostic {
            case .pricesDerivedFromTransactions(let id): if issues[id] == nil { issues[id] = .derived }
            case .missingPrice(let id): issues[id] = .missing
            default: break
            }
        }
        let all = performances.map { p in
            let security = ledger.security(p.securityID)
            return SecurityRow(
                id: p.securityID, name: security?.name ?? "Unknown Security",
                symbol: security.map { $0.ticker.isEmpty ? $0.isin : $0.ticker } ?? "",
                isRetired: security?.isRetired ?? false, isHeld: !p.shares.isZero,
                marketValue: p.marketValue, ttwror: p.ttwror, irr: ReturnHorizon.moneyWeighted(irr: p.irr, days: days),
                absolutePerformance: p.absolutePerformance,
                realized: p.periodRealizedGain, unrealized: p.periodUnrealizedGain, dividends: p.dividends,
                fees: p.fees, taxes: p.taxes,
                share: total != 0 ? Double(p.absolutePerformance) / Double(abs(total)) : nil,
                priceIssue: issues[p.securityID])
        }
        totalCount = all.count
        securitiesResult = all.reduce(0) { $0 + $1.absolutePerformance }

        // The rest of the result, by what it is: the breakdown's lines less the securities' share.
        let otherFees = breakdown.fees - all.reduce(0) { $0 + $1.fees }
        let otherTaxes = breakdown.taxes - all.reduce(0) { $0 + $1.taxes }
        var parts = [
            RemainderPart(label: "Interest", amount: breakdown.interest),
            RemainderPart(label: "Account fees", amount: -otherFees),
            RemainderPart(label: otherTaxes < 0 ? "Tax refunds, less taxes" : "Taxes, less refunds", amount: -otherTaxes),
            RemainderPart(label: "Exchange rates on cash", amount: breakdown.cashCurrencyGains),
        ]
        let rest = totalResult - securitiesResult - parts.reduce(0) { $0 + $1.amount }
        parts.append(RemainderPart(label: "Rounding and other", amount: rest))
        remainder = parts.filter { $0.amount != 0 }
        let filter = QuickFilter(query.filter)
        rows = all.filter { filter.matches($0.name, $0.symbol) }.sorted(using: query.sortOrder)
    }

    static func tsv(_ rows: [SecurityRow], currency: CurrencyCode, irrIsAnnualized: Bool = true) -> String {
        func money(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: currency).decimalValue) }
        func fraction(_ value: Double?) -> String { value.map { TSV.number(Decimal($0)) } ?? "" }
        return TSV.string(
            header: ["Security", "Symbol", "Value", "TTWROR", irrIsAnnualized ? "IRR per Year" : "IRR (not annualized)", "Gain", "Realized", "Unrealized", "Dividends", "Fees", "Taxes",
                     "Share of Result", "Currency"],
            rows: rows.map {
                [$0.name, $0.symbol, money($0.marketValue), fraction($0.ttwror), fraction($0.irr), money($0.absolutePerformance),
                 money($0.realized), money($0.unrealized), money($0.dividends), money($0.fees), money($0.taxes), fraction($0.share),
                 currency]
            })
    }
}

/// The figures of one security for the inspector.
struct SecurityFigures: Sendable {
    var name: String
    var currency: CurrencyCode
    var performance: SecurityPerformance?
    var levels: [Double]
    var dayCount: Int

    var irrIsAnnualized: Bool { ReturnHorizon.isAnnualized(days: dayCount) }
    var moneyWeightedReturn: Double? { ReturnHorizon.moneyWeighted(irr: performance?.irr, days: dayCount) }

    init(_ analysis: Analysis, securityID: UUID) {
        dayCount = analysis.measuredInterval.dayCount
        name = analysis.ledger.security(securityID)?.name ?? "Unknown Security"
        currency = analysis.currency
        performance = analysis.security(securityID)
        levels = analysis.benchmark(securityID: securityID).map { Downsampler.downsample($0.cumulative, maxPoints: 160) } ?? []
    }
}

/// Summary for the "Copy Performance Summary" command.
struct PerformanceSummary: Sendable {
    var text: String

    init(_ analysis: Analysis, scopeTitle: String) {
        let risk = analysis.risk
        let currency = analysis.currency
        func money(_ minor: Int64) -> String { Fmt.money(minor: minor, currency: currency) }
        let days = analysis.measuredInterval.dayCount
        let annualized = ReturnHorizon.isAnnualized(days: days)
        var rows: [[String]] = [
            ["Scope", scopeTitle],
            ["Period", Fmt.interval(analysis.interval)],
            ["TTWROR", Fmt.percent(analysis.ttwror, signed: true)],
        ]
        // "Per year" figures only for periods over a year — anything shorter would be extrapolated.
        if annualized { rows.append(["TTWROR per Year", Fmt.percent(analysis.ttwrorAnnualized, signed: true)]) }
        rows += [
            [annualized ? "IRR per Year" : "IRR (not annualized)", Fmt.percent(ReturnHorizon.moneyWeighted(irr: analysis.irr, days: days), signed: true)],
            ["Absolute Performance", money(analysis.breakdown.absolutePerformance)],
            ["Initial Value", money(analysis.breakdown.initialValue)],
            ["Final Value", money(analysis.breakdown.finalValue)],
            ["Maximum Drawdown", Fmt.percent(risk.maxDrawdown.map { -$0.depth })],
            ["Volatility", Fmt.percent(risk.volatility)],
        ]
        if ReturnHorizon.hasFullYear(days: days) { rows.append(["Sharpe Ratio", Fmt.ratio(risk.sharpeRatio)]) }
        rows.append(contentsOf: analysis.breakdown.lines.dropFirst().dropLast().filter { $0.amount != 0 }.map { [$0.line.title, money($0.amount)] })
        text = TSV.string(rows: rows)
    }
}
