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
    /// Top movers "since the previous day": every position's change on its latest quoted day.
    var dayMode = false
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

    /// Balances and positions that could not be valued (no exchange rate, no price). The engine
    /// counts them as zero, so every total that leaves something out says so.
    struct Gaps: Sendable, Equatable {
        /// One sentence per balance or position: "Swiss Account: 5,000.00 CHF — no CHF → EUR exchange rate".
        var messages: [String] = []
        var cashCount = 0
        var positionCount = 0
        var isEmpty: Bool { messages.isEmpty }

        /// - Parameters:
        ///   - cash: include cash balances (false for a list of positions).
        ///   - positions: include security positions (false for a list of cash accounts).
        init(_ snapshot: Snapshot, _ ledger: Ledger, cash includesCash: Bool = true, positions includesPositions: Bool = true) {
            let currency = snapshot.currency
            for cash in snapshot.cash where includesCash && !cash.isValued && !cash.balance.isZero {
                cashCount += 1
                let name = ledger.account(cash.accountID)?.name ?? ""
                messages.append("\(name.isEmpty ? "Untitled Account" : name): \(Fmt.money(cash.balance)) — no \(cash.balance.currency) → \(currency) exchange rate")
            }
            for position in snapshot.positions where includesPositions && !position.isValued {
                positionCount += 1
                let security = ledger.security(position.securityID)
                let name = security?.name ?? "Unknown Security"
                let reason = position.price == nil || security?.currency == currency
                    ? "no price" : "no \(security?.currency ?? "") → \(currency) exchange rate"
                messages.append("\(name): \(Fmt.shares(position.shares, maxDecimals: 4)) shares — \(reason)")
            }
        }

        init() {}

        /// Tooltip of the warning next to a total.
        var help: String {
            (["Not included, because it cannot be valued:"] + messages.prefix(6).map { "• \($0)" }
                + (messages.count > 6 ? ["• and \(Fmt.integer(messages.count - 6)) more"] : [])).joined(separator: "\n")
        }

        var summary: String {
            let parts = [
                cashCount == 0 ? nil : cashCount == 1 ? "1 cash balance" : "\(Fmt.integer(cashCount)) cash balances",
                positionCount == 0 ? nil : positionCount == 1 ? "1 position" : "\(Fmt.integer(positionCount)) positions",
            ].compactMap { $0 }
            return "\(parts.joined(separator: " and ")) cannot be valued and \(cashCount + positionCount == 1 ? "is" : "are") not included"
        }
    }

    struct NetWorth: Sendable {
        var total: Money
        var dayChange: Money
        var dayFraction: Double?
        /// The day the change refers to (the latest day on which the value moved).
        var changeDay: Day
        var sparkline: [Double]
        var hasData: Bool
        var gaps = Gaps()
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
        var gaps = Gaps()
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
        /// Day mode: the days the changes are from, ascending (usually one; two when some markets
        /// were closed on the latest day). Empty in period mode.
        var days: [Day] = []
    }

    struct Holding: Sendable, Identifiable {
        var id: UUID
        var name: String
        var value: Money
        var weight: Double
        var gainFraction: Double?
        /// False: no price or exchange rate — the value is unknown (counted as zero).
        var isValued = true
    }

    struct Holdings: Sendable {
        var rows: [Holding]
        var total: Int
        var maxWeight: Double
        var gaps = Gaps()
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
        /// False: no exchange rate into the reporting currency — not part of the total.
        var isValued = true
    }

    struct Cash: Sendable {
        var rows: [CashRow]
        var total: Money
        var accountCount: Int
        var gaps = Gaps()
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
            let floor = max(index - (WidgetRequest.dayLookback - 1), 1)
            func change(_ i: Int) -> Int64 {
                guard i >= 1, i < values.count else { return 0 }
                return values[i] - values[i - 1] - valuation.inflows[i] + valuation.outflows[i]
            }
            while index > floor, change(index) == 0 { index -= 1 }
            if change(index) == 0 { index = max(values.count - 1, 0) }
            let snapshot = analysis.snapshot
            return .netWorth(NetWorth(
                total: snapshot.totalValue,
                dayChange: Money(minor: change(index), currency: currency),
                dayFraction: daily.indices.contains(index) && index >= 1 ? daily[index] : nil,
                changeDay: valuation.day(at: index),
                sparkline: valuation.chartPoints(maxPoints: 160).map { Double($0.value) },
                hasData: hasData, gaps: Gaps(snapshot, ledger)))

        case .ttwror:
            // Annualizing only says something new for periods longer than a year.
            let annualized = analysis.measuredInterval.dayCount > 380 ? analysis.ttwrorAnnualized : nil
            return .stat(Stat(value: .percent(hasData ? analysis.ttwror : nil), isSigned: true,
                              detail: annualized.map { "\(Fmt.percent($0, signed: true)) per year" } ?? "time-weighted"))
        case .annualizedReturn:
            return .stat(Stat(value: .percent(hasData ? analysis.ttwrorAnnualized : nil), isSigned: true,
                              detail: "over \(Fmt.duration(days: analysis.measuredInterval.dayCount))"))
        case .irr:
            // Per year only when there is more than a year to measure: a portfolio that is a few
            // weeks old (or a short period) shows the money-weighted return of that stretch.
            let isAnnual = analysis.measuredInterval.dayCount > 366
            return .stat(Stat(value: .percent(hasData ? (isAnnual ? analysis.irr : analysis.irrOfPeriod) : nil), isSigned: true,
                              detail: isAnnual ? "per year, money-weighted" : "money-weighted, not annualized"))
        case .absoluteGain:
            return .stat(Stat(value: .money(hasData ? Money(minor: analysis.absolutePerformance, currency: currency) : nil), isSigned: true,
                              detail: "after deposits and withdrawals"))
        case .maxDrawdown:
            let drawdown = hasData ? analysis.risk.maxDrawdown : nil
            let detail = drawdown.map(drawdownDetail)
            return .stat(Stat(value: .percent(drawdown.map { -$0.depth } ?? (hasData ? 0 : nil)), isSigned: true,
                              detail: detail ?? (hasData ? "no decline in this period" : nil)))
        case .volatility:
            // Estimated from daily returns: a handful of days says nothing.
            let enough = analysis.measuredInterval.dayCount >= 30
            return .stat(Stat(value: .percent(hasData && enough ? analysis.risk.volatility : nil), isSigned: false,
                              detail: enough ? "per year" : "needs a month of history"))
        case .sharpeRatio:
            // Divides an annualized return: less than a year would be an extrapolation.
            let enough = analysis.measuredInterval.dayCount >= 365
            return .stat(Stat(value: .ratio(hasData && enough ? analysis.risk.sharpeRatio : nil), isSigned: false,
                              detail: enough ? "risk-free rate \(Fmt.percent(ledger.settings.riskFreeRate))" : "needs a full year"))

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
                                          slices: ChartSlice.slices(from: allocation), gaps: Gaps(analysis.snapshot, ledger)))

        case .topMovers:
            var days: [Day] = []
            let held: [SecurityPerformance]
            if query.dayMode {
                (held, days) = latestDayPerformance(analysis)
            } else {
                held = analysis.securities.filter { $0.marketValue != 0 || $0.initialValue != 0 }
            }
            let sorted = held.sorted { $0.ttwror > $1.ttwror }
            func mover(_ p: SecurityPerformance) -> Mover {
                Mover(id: p.securityID, name: ledger.security(p.securityID)?.name ?? "Unknown Security", change: p.ttwror,
                      gain: Money(minor: p.absolutePerformance, currency: currency))
            }
            let best = sorted.prefix(query.count).filter { $0.ttwror > 0 }
            let worst = sorted.reversed().prefix(query.count).filter { $0.ttwror < 0 }
            return .movers(Movers(best: best.map(mover), worst: worst.map(mover), positionCount: held.count, days: days))

        case .holdings:
            let snapshot = analysis.snapshot
            let sorted = snapshot.positions.sorted { $0.value.minor > $1.value.minor }
            let rows = sorted.prefix(query.count).map { p in
                Holding(id: p.securityID, name: ledger.security(p.securityID)?.name ?? "Unknown Security", value: p.value,
                        weight: snapshot.share(of: p) ?? 0, gainFraction: p.isValued ? p.unrealizedGainFraction : nil,
                        isValued: p.isValued)
            }
            return .holdings(Holdings(rows: rows, total: sorted.count, maxWeight: rows.map(\.weight).max() ?? 0,
                                      gaps: Gaps(snapshot, ledger, cash: false)))

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
            // The interval is "all time": months before the first transaction are empty cells (nil),
            // the first and the running year are the only partial ones.
            guard hasData else { return .heatmap([]) }
            return .heatmap(analysis.heatmap.rows.suffix(query.count).reversed().map {
                HeatmapRow(label: String($0.year), cells: $0.months, total: $0.total)
            })

        case .cash:
            let snapshot = analysis.snapshot
            let rows = snapshot.cash.compactMap { c -> CashRow? in
                guard let account = ledger.account(c.accountID), !(account.isRetired && c.balance.isZero) else { return nil }
                return CashRow(id: c.accountID, name: account.name.isEmpty ? "Untitled Account" : account.name, balance: c.balance, value: c.value,
                               isValued: c.isValued || c.balance.isZero)
            }
            return .cash(Cash(rows: rows.sorted { $0.value.minor > $1.value.minor }, total: snapshot.cashValue, accountCount: rows.count,
                              gaps: Gaps(snapshot, ledger, positions: false)))

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

    /// "Mar 2021 – Aug 2023 · recovered Jul 2025": the decline (peak to trough) and the month the
    /// old peak was reached again — a date, so nobody has to guess what a duration is measured from.
    static func drawdownDetail(_ drawdown: RiskMetrics.Drawdown) -> String {
        let span = "\(Fmt.day(drawdown.peak, style: .shortMonthYear)) – \(Fmt.day(drawdown.trough, style: .shortMonthYear))"
        if let recovery = drawdown.recovery { return "\(span) · recovered \(Fmt.day(recovery, style: .shortMonthYear))" }
        return "\(span) · not yet recovered"
    }

    /// Top movers "since the previous day": for every position, its return on the latest day it
    /// was quoted (within the request's look-back window) against the day before. A calendar
    /// "yesterday → today" would be empty on weekends, on holidays and every morning before the
    /// day's quotes arrive; markets that trade on other days (crypto) keep their own latest day.
    ///
    /// `analysis` covers the look-back window ending today. Returns the rows and the days used.
    static func latestDayPerformance(_ analysis: Analysis) -> (rows: [SecurityPerformance], days: [Day]) {
        let ledger = analysis.ledger
        let today = analysis.interval.end
        let earliest = analysis.interval.start
        var quoteDay: [UUID: Day] = [:]
        for position in analysis.snapshot.positions {
            guard let day = position.priceDay, day > earliest else { continue }
            quoteDay[position.securityID] = min(day, today)
        }
        var byDay: [Day: Set<UUID>] = [today: []]
        for (id, day) in quoteDay { byDay[day, default: []].insert(id) }
        var rows: [SecurityPerformance] = []
        var days: Set<Day> = []
        for (day, ids) in byDay {
            let oneDay = Analysis(ledger: ledger, scope: analysis.scope, interval: DayInterval(start: day.advanced(by: -1), end: day))
            for performance in oneDay.securities {
                // Positions closed today have no place in the snapshot but did move today.
                let closedToday = day == today && performance.marketValue == 0 && performance.initialValue != 0
                guard ids.contains(performance.securityID) || closedToday else { continue }
                guard performance.marketValue != 0 || performance.initialValue != 0 else { continue }
                rows.append(performance)
                if performance.ttwror != 0 { days.insert(day) }
            }
        }
        return (rows, days.sorted())
    }
}
