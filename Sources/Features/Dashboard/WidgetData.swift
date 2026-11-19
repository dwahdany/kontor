import SwiftUI
import KontorUI

/// Everything a widget's numbers depend on besides the document, the scope and the interval — the
/// `variant:` of the widget's analysis request, so equal widgets share one cached result.
struct WidgetQuery: Hashable, Sendable {
    var kind: WidgetKind
    var today: Day
    var count = 0
    var taxonomy: Taxonomy?
    var benchmarks: [UUID] = []
    var securities: [UUID] = []
    var plans: [InvestmentPlan] = []
    var byYear = false
}

/// The Sendable result of a widget's computation. Built off the main actor by ``compute(_:_:)``;
/// views only format and draw.
enum WidgetData: Sendable {
    case netWorth(NetWorth)
    case stat(Stat)
    case performance(PerformanceChart)
    case value(ValueChart)
    case allocation(Allocation)
    case movers(Movers)
    case holdings(Holdings)
    case earnings(Earnings)
    case heatmap([HeatmapRow])
    case cash(Cash)
    case plans([PlanRow])
    case transactions([TransactionRow])
    case watchlist([WatchRow])
    case consistency(Consistency)
    case checklist(Checklist)

    struct NetWorth: Sendable {
        var total: Money
        var dayChange: Money
        var dayFraction: Double?
        /// The day the change refers to (the latest day on which the value moved).
        var changeDay: Day
        var sparkline: [Double]
        var hasData: Bool
    }

    struct Stat: Sendable {
        enum Value: Sendable {
            case percent(Double?)
            case money(Money?)
            case ratio(Double?)
        }
        var value: Value
        /// Color the value by its sign (gain/loss).
        var isSigned: Bool
        var detail: String?

        var sign: Double {
            switch value {
            case .percent(let v), .ratio(let v): v ?? 0
            case .money(let m): Double(m?.minor ?? 0)
            }
        }
    }

    struct PerformanceChart: Sendable {
        struct Benchmark: Sendable, Identifiable {
            var id: UUID
            var name: String
            var points: [ChartPoint<Double>]
            var total: Double
        }
        var interval: DayInterval
        var portfolio: [ChartPoint<Double>]
        var total: Double
        var benchmarks: [Benchmark]
        var hasData: Bool
    }

    struct ValueChart: Sendable {
        var currency: CurrencyCode
        var start: Day
        var value: [ChartPoint<Int64>]
        var invested: [Int64]
        var finalValue: Money
        var finalInvested: Money
        var hasData: Bool
    }

    struct Allocation: Sendable {
        var taxonomyID: UUID
        var taxonomyName: String
        var currency: CurrencyCode
        var slices: [ChartSlice]
    }

    struct Mover: Sendable, Identifiable {
        var id: UUID
        var name: String
        var change: Double
        var gain: Money
    }

    struct Movers: Sendable {
        var best: [Mover]
        var worst: [Mover]
        var positionCount: Int
    }

    struct Holding: Sendable, Identifiable {
        var id: UUID
        var name: String
        var value: Money
        var weight: Double
        var gainFraction: Double?
    }

    struct Holdings: Sendable {
        var rows: [Holding]
        var total: Int
        var maxWeight: Double
    }

    struct Earnings: Sendable {
        var currency: CurrencyCode
        var categories: [BarCategory]
        var dividends: [Int64]
        var interest: [Int64]
        /// Sum of everything shown.
        var total: Money
        /// Dividends + interest of the running calendar year.
        var thisYear: Money
        var year: Int
        var byYear: Bool
        var isEmpty: Bool { dividends.allSatisfy { $0 == 0 } && interest.allSatisfy { $0 == 0 } }
    }

    struct CashRow: Sendable, Identifiable {
        var id: UUID
        var name: String
        var balance: Money
        var value: Money
    }

    struct Cash: Sendable {
        var rows: [CashRow]
        var total: Money
        var accountCount: Int
    }

    struct PlanRow: Sendable, Identifiable {
        var id: UUID
        var name: String
        var detail: String
        var amount: Money
        var isOutflow: Bool
        var nextDue: Day?
        var overdue: Int
    }

    struct TransactionRow: Sendable, Identifiable {
        var id: UUID
        var date: Day
        var kind: Transaction.Kind
        var title: String
        var amount: Money
    }

    struct WatchRow: Sendable, Identifiable {
        var id: UUID
        var name: String
        var currency: CurrencyCode
        var price: Price?
        var change: Double?
        var sparkline: [Double]
    }

    struct Consistency: Sendable {
        var errors: Int
        var warnings: Int
        var hints: Int
        var headline: String?
        var total: Int { errors + warnings + hints }
    }

    struct Checklist: Sendable {
        var hasAccount: Bool
        var hasSecurity: Bool
        var hasTransaction: Bool
        var hasImport: Bool
        var doneCount: Int { [hasAccount, hasSecurity, hasTransaction, hasImport].filter { $0 }.count }
    }
}

extension WidgetData {
    /// Pure; runs off the main actor inside the store's analysis layer. Every figure comes from the
    /// engine — this function only selects, sorts and trims.
    static func compute(_ query: WidgetQuery, _ analysis: Analysis) -> WidgetData {
        let ledger = analysis.ledger
        let currency = analysis.currency
        let hasData = !ledger.transactions.isEmpty

        switch query.kind {
        case .netWorth:
            let valuation = analysis.valuation
            let daily = analysis.returns.daily
            let values = valuation.values
            // The latest day (within the last week) on which the portfolio moved: weekends and
            // holidays without quotes would otherwise always show "unchanged".
            var index = max(values.count - 1, 0)
            let floor = max(index - 6, 1)
            func change(_ i: Int) -> Int64 {
                guard i >= 1, i < values.count else { return 0 }
                return values[i] - values[i - 1] - valuation.inflows[i] + valuation.outflows[i]
            }
            while index > floor, change(index) == 0 { index -= 1 }
            if change(index) == 0 { index = max(values.count - 1, 0) }
            return .netWorth(NetWorth(
                total: analysis.snapshot.totalValue,
                dayChange: Money(minor: change(index), currency: currency),
                dayFraction: daily.indices.contains(index) && index >= 1 ? daily[index] : nil,
                changeDay: valuation.day(at: index),
                sparkline: valuation.chartPoints(maxPoints: 160).map { Double($0.value) },
                hasData: hasData))

        case .ttwror:
            // Annualizing only says something new for periods longer than a year.
            let annualized = analysis.interval.dayCount > 380 ? analysis.ttwrorAnnualized : nil
            return .stat(Stat(value: .percent(hasData ? analysis.ttwror : nil), isSigned: true,
                              detail: annualized.map { "\(Fmt.percent($0, signed: true)) per year" } ?? "time-weighted"))
        case .annualizedReturn:
            return .stat(Stat(value: .percent(hasData ? analysis.ttwrorAnnualized : nil), isSigned: true,
                              detail: "over \(Fmt.duration(days: analysis.interval.dayCount))"))
        case .irr:
            return .stat(Stat(value: .percent(hasData ? analysis.irr : nil), isSigned: true, detail: "per year, money-weighted"))
        case .absoluteGain:
            return .stat(Stat(value: .money(hasData ? Money(minor: analysis.absolutePerformance, currency: currency) : nil), isSigned: true,
                              detail: "after deposits and withdrawals"))
        case .maxDrawdown:
            let drawdown = hasData ? analysis.risk.maxDrawdown : nil
            let detail = drawdown.map { d -> String in
                let span = "\(Fmt.day(d.peak, style: .shortMonthYear)) – \(Fmt.day(d.trough, style: .shortMonthYear))"
                if let days = d.durationDays { return "\(span) · recovered in \(Fmt.duration(days: days))" }
                return "\(span) · not yet recovered"
            }
            return .stat(Stat(value: .percent(drawdown.map { -$0.depth } ?? (hasData ? 0 : nil)), isSigned: true,
                              detail: detail ?? (hasData ? "no decline in this period" : nil)))
        case .volatility:
            return .stat(Stat(value: .percent(hasData ? analysis.risk.volatility : nil), isSigned: false, detail: "annualized"))
        case .sharpeRatio:
            return .stat(Stat(value: .ratio(hasData ? analysis.risk.sharpeRatio : nil), isSigned: false,
                              detail: "risk-free rate \(Fmt.percent(ledger.settings.riskFreeRate))"))

        case .performanceChart:
            let returns = analysis.returns
            let benchmarks = query.benchmarks.compactMap { id -> PerformanceChart.Benchmark? in
                guard let security = ledger.security(id), let series = analysis.benchmark(securityID: id) else { return nil }
                return .init(id: id, name: security.name, points: series.chartPoints(maxPoints: 700), total: series.total)
            }
            return .performance(PerformanceChart(
                interval: analysis.interval, portfolio: returns.chartPoints(maxPoints: 700), total: returns.total,
                benchmarks: benchmarks, hasData: hasData))

        case .valueChart:
            let valuation = analysis.valuation
            let invested = analysis.investedCapital
            return .value(ValueChart(
                currency: currency, start: analysis.interval.start, value: valuation.chartPoints(maxPoints: 700),
                invested: invested, finalValue: Money(minor: valuation.finalValue, currency: currency),
                finalInvested: Money(minor: invested.last ?? 0, currency: currency), hasData: hasData))

        case .allocation:
            guard let taxonomy = query.taxonomy else {
                return .allocation(Allocation(taxonomyID: UUID(), taxonomyName: "", currency: currency, slices: []))
            }
            let allocation = analysis.allocation(for: taxonomy)
            return .allocation(Allocation(taxonomyID: taxonomy.id, taxonomyName: taxonomy.name, currency: currency,
                                          slices: ChartSlice.slices(from: allocation)))

        case .topMovers:
            let held = analysis.securities.filter { $0.marketValue != 0 || $0.initialValue != 0 }
            let sorted = held.sorted { $0.ttwror > $1.ttwror }
            func mover(_ p: SecurityPerformance) -> Mover {
                Mover(id: p.securityID, name: ledger.security(p.securityID)?.name ?? "Unknown Security", change: p.ttwror,
                      gain: Money(minor: p.absolutePerformance, currency: currency))
            }
            let best = sorted.prefix(query.count).filter { $0.ttwror > 0 }
            let worst = sorted.reversed().prefix(query.count).filter { $0.ttwror < 0 }
            return .movers(Movers(best: best.map(mover), worst: worst.map(mover), positionCount: held.count))

        case .holdings:
            let snapshot = analysis.snapshot
            let sorted = snapshot.positions.sorted { $0.value.minor > $1.value.minor }
            let rows = sorted.prefix(query.count).map { p in
                Holding(id: p.securityID, name: ledger.security(p.securityID)?.name ?? "Unknown Security", value: p.value,
                        weight: snapshot.share(of: p) ?? 0, gainFraction: p.unrealizedGainFraction)
            }
            return .holdings(Holdings(rows: rows, total: sorted.count, maxWeight: rows.map(\.weight).max() ?? 0))

        case .earnings:
            let today = query.today
            let yearToDate = ledger.earnings(in: ReportingPeriod.ytd.interval(today: today, ledger: ledger), scope: analysis.scope)
            let thisYear = Money(minor: yearToDate.total.earnings, currency: currency)
            if query.byYear {
                let report = ledger.earnings(in: ReportingPeriod.allTime.interval(today: today, ledger: ledger), scope: analysis.scope)
                let years = report.years.suffix(8)
                return .earnings(Earnings(
                    currency: currency, categories: years.map { BarCategory.year($0.year) },
                    dividends: years.map(\.total.dividends), interest: years.map { $0.total.interest - $0.total.interestCharges },
                    total: Money(minor: years.reduce(0) { $0 + $1.total.earnings }, currency: currency),
                    thisYear: thisYear, year: today.year, byYear: true))
            }
            // The twelve calendar months ending with the running one.
            let first = today.startOfMonth.addingMonths(-11)
            let report = ledger.earnings(in: DayInterval(start: first.advanced(by: -1), end: today), scope: analysis.scope)
            let months = report.months.suffix(12)
            return .earnings(Earnings(
                currency: currency, categories: BarCategory.months(months.map { ($0.year, $0.month) }),
                dividends: months.map(\.amounts.dividends), interest: months.map { $0.amounts.interest - $0.amounts.interestCharges },
                total: Money(minor: months.reduce(0) { $0 + $1.amounts.earnings }, currency: currency),
                thisYear: thisYear, year: today.year, byYear: false))

        case .monthlyReturns:
            guard hasData else { return .heatmap([]) }
            return .heatmap(analysis.heatmap.rows.suffix(query.count).reversed().map {
                HeatmapRow(label: String($0.year), cells: $0.months, total: $0.total)
            })

        case .cash:
            let snapshot = analysis.snapshot
            let rows = snapshot.cash.compactMap { c -> CashRow? in
                guard let account = ledger.account(c.accountID), !(account.isRetired && c.balance.isZero) else { return nil }
                return CashRow(id: c.accountID, name: account.name.isEmpty ? "Untitled Account" : account.name, balance: c.balance, value: c.value)
            }
            return .cash(Cash(rows: rows.sorted { $0.value.minor > $1.value.minor }, total: snapshot.cashValue, accountCount: rows.count))

        case .upcomingPlans:
            let rows = query.plans.compactMap { plan -> PlanRow? in
                let status = ledger.planStatus(plan, through: query.today)
                guard status.nextDue != nil || !status.missing.isEmpty else { return nil }
                let target = plan.kind == .purchase
                    ? ledger.security(plan.securityID ?? UUID())?.name
                    : ledger.account(plan.accountID ?? UUID())?.name
                return PlanRow(id: plan.id, name: plan.name.isEmpty ? plan.kind.title : plan.name,
                               detail: [plan.kind.title, target].compactMap { $0 }.joined(separator: " · "),
                               amount: plan.amount, isOutflow: plan.kind == .withdrawal, nextDue: status.nextDue,
                               overdue: status.missing.count)
            }
            let sorted = rows.sorted { ($0.overdue > 0 ? 0 : 1, $0.nextDue ?? .init(rawValue: .max)) < ($1.overdue > 0 ? 0 : 1, $1.nextDue ?? .init(rawValue: .max)) }
            return .plans(Array(sorted.prefix(query.count)))

        case .recentTransactions:
            return .transactions(ledger.transactions.suffix(query.count).reversed().map { t in
                let name = t.securityID.flatMap { ledger.security($0)?.name } ?? t.accountID.flatMap { ledger.account($0)?.name }
                    ?? t.depotID.flatMap { ledger.depot($0)?.name } ?? ""
                return TransactionRow(id: t.id, date: t.date, kind: t.kind, title: name,
                                      amount: Money(minor: t.kind.cashSign < 0 ? -t.amount.minor : t.amount.minor, currency: t.amount.currency))
            })

        case .watchlist:
            let interval = analysis.interval
            return .watchlist(query.securities.compactMap { id -> WatchRow? in
                guard let security = ledger.security(id) else { return nil }
                let levels = ledger.priceLevels(securityID: id, in: interval, basis: .securityCurrency) ?? []
                let change = levels.isEmpty ? nil : ReturnSeries(interval: interval, levels: levels).total
                return WatchRow(id: id, name: security.name, currency: security.currency,
                                price: security.prices.isEmpty ? nil : ledger.price(of: id, on: interval.end)?.price,
                                change: security.prices.isEmpty ? nil : change,
                                sparkline: security.prices.isEmpty ? [] : Downsampler.indices(levels, maxPoints: 90).map { levels[$0] })
            })

        case .consistency:
            let issues = ledger.consistencyIssues(options: .init(today: query.today, staleAfterDays: 10))
            func count(_ severity: ConsistencyIssue.Severity) -> Int { issues.filter { $0.severity == severity }.count }
            return .consistency(Consistency(errors: count(.error), warnings: count(.warning), hints: count(.info),
                                            headline: issues.first?.title))

        case .gettingStarted:
            return .checklist(Checklist(
                hasAccount: !ledger.accounts.isEmpty, hasSecurity: !ledger.securities.isEmpty, hasTransaction: hasData,
                hasImport: ledger.transactions.contains { t in
                    guard let source = t.source, !source.isEmpty else { return false }
                    return !source.lowercased().hasPrefix("plan:")
                }))
        }
    }
}
