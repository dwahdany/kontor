import SwiftUI
import KontorUI

// MARK: View state vocabulary

/// The figure the whole screen looks at (the "metric switch").
enum EarningsKind: String, CaseIterable, Identifiable, Sendable {
    case dividends, interest, earnings, fees, taxes, net

    var id: String { rawValue }

    /// The engine figure behind this choice.
    var metric: EarningsMetric {
        switch self {
        case .dividends: .dividends
        case .interest: .interest
        case .earnings: .earnings
        case .fees: .fees
        case .taxes: .taxes
        case .net: .net
        }
    }

    var title: String {
        switch self {
        case .dividends: "Dividends"
        case .interest: "Interest"
        case .earnings: "Dividends + Interest"
        case .fees: "Fees"
        case .taxes: "Taxes"
        case .net: "Net"
        }
    }

    /// For narrow windows.
    var shortTitle: String { self == .earnings ? "Div. + Int." : title }

    /// One sentence for tooltips and the breakdown card.
    var explanation: String {
        switch self {
        case .dividends: "Dividends before fees and taxes (gross)."
        case .interest: "Interest received before taxes (gross)."
        case .earnings: "Gross dividends plus interest, less interest you paid."
        case .fees: "All fees, including those inside buys, sells and dividends, less refunds."
        case .taxes: "All taxes, including those withheld from dividends and sales, less refunds."
        case .net: "Dividends and interest after all fees and taxes."
        }
    }

    /// Fees and taxes are money going out: more of it is not "good", so no gain colors.
    var isCost: Bool { self == .fees || self == .taxes }

    /// The stable series color of this figure (identity, not polarity).
    var color: Color {
        switch self {
        case .dividends, .earnings, .net: ChartColors.series(0)
        case .interest: ChartColors.series(1)
        case .fees: ChartColors.series(6)
        case .taxes: ChartColors.series(3)
        }
    }
}

/// The sub-views of the screen (`--state view=…`).
enum EarningsView: String, CaseIterable, Identifiable, Sendable {
    case chart, matrix, securities, accounts, payments, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chart: "Chart"
        case .matrix: "Months"
        case .securities: "Securities"
        case .accounts: "Accounts"
        case .payments: "Payments"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .chart: "chart.bar"
        case .matrix: "tablecells"
        case .securities: "building.columns"
        case .accounts: "banknote"
        case .payments: "list.bullet"
        case .calendar: "calendar"
        }
    }
}

/// Which years the screen covers: everything, or the window's reporting period.
enum EarningsRange: String, CaseIterable, Identifiable, Sendable {
    case all, period
    var id: String { rawValue }
}

/// Bar width of the chart view (`--state group=…`).
enum EarningsGrouping: String, CaseIterable, Identifiable, Sendable {
    case month, quarter, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .month: "Month"
        case .quarter: "Quarter"
        case .year: "Year"
        }
    }
}

// MARK: Model

/// Everything the Earnings screen shows, as plain values. Built off the main actor by
/// `EarningsModel.init(_:query:)` from the shared `Analysis` (engine `EarningsReport`s only — no
/// finance math here beyond sums, shares of a total and the documented projection).
struct EarningsModel: Sendable {
    /// Everything the model depends on besides the document, the scope and the selected interval.
    struct Query: Hashable, Sendable {
        var kind: EarningsKind
        var today: Day
        /// Inception → today; the tiles and the calendar always look at all years.
        var allYears: DayInterval
    }

    struct Tiles: Sendable {
        var year: Int
        var thisYear: Int64
        var lastYear: Int64
        /// Last year against the year before; nil when undefined.
        var lastYearGrowth: Double?
        var trailing: Int64
        var trailingInterval: DayInterval
        var averagePerMonth: Int64
        /// This year so far against the same days of last year.
        var samePeriodLastYear: Int64
        var samePeriodGrowth: Double?
        var samePeriodInterval: DayInterval
    }

    struct Chart: Sendable {
        var categories: [BarCategory] = []
        /// One or two series (the figure itself, or dividends + interest).
        var plain: [BarSeries] = []
        /// Stacked by security; nil when the figure cannot be attributed (anything but dividends).
        var bySecurity: [BarSeries]?
        /// Rolling twelve-month average on the scale of one bar; nil for yearly bars.
        var average: [Double?]?
        /// All categories per bar (for the breakdown of a selected bar).
        var amounts: [EarningsAmounts] = []
        var isEmpty: Bool { plain.allSatisfy { $0.values.allSatisfy { $0 == 0 } } }
    }

    struct MatrixRow: Identifiable, Sendable {
        var id: Int { year }
        var year: Int
        var values: [Int64]
        /// Months that lie inside the selected interval (others render blank instead of "–").
        var covered: [Bool]
        var total: Int64
        var growth: Double?
        /// The growth compares only the elapsed part of the year with the same days a year before.
        var growthIsSamePeriod: Bool
        var isPartial: Bool
    }

    struct SecurityRow: Identifiable, Sendable, Hashable {
        /// The security's id; a fixed id for the "not tied to a security" row.
        var id: UUID
        var securityID: UUID?
        var name: String
        var detail: String
        var amount: Int64
        var share: Double
        var count: Int
        var lastDay: Day?
        var lastGross: Int64
        var perShare: Price?
        var yieldOnCost: Double?
        var isRetired: Bool

        var lastDaySortKey: Int32 { lastDay?.rawValue ?? Int32.min }
        var perShareSortKey: Int64 { perShare?.raw ?? Int64.min }
        var yieldSortKey: Double { yieldOnCost ?? -Double.infinity }
    }

    struct AccountRow: Identifiable, Sendable, Hashable {
        var id: UUID
        var name: String
        var currency: CurrencyCode
        var dividends: Int64
        var interest: Int64
        var fees: Int64
        var taxes: Int64
        var net: Int64
        /// The selected figure and its share of the total.
        var amount: Int64
        var share: Double
    }

    struct CalendarRow: Identifiable, Sendable {
        var id: UUID
        var name: String
        var detail: String
        /// Calendar months (January first) with a payment in the last twelve months.
        var recent: [Bool]
        /// Calendar months with a payment in the two years before that.
        var earlier: [Bool]
        var paymentsPerYear: Int
        var shares: Shares
        /// Expected gross dividends for the twelve upcoming months, aligned with `Calendar.months`.
        var expected: [Int64]
        var expectedTotal: Int64
    }

    struct Calendar: Sendable {
        var rows: [CalendarRow] = []
        /// The twelve months after the current one.
        var months: [BarCategory] = []
        var expected: [Int64] = []
        var expectedTotal: Int64 = 0
        var interval: DayInterval
        /// The twelve months whose payments the projection repeats.
        var basisInterval: DayInterval
        var isEmpty: Bool { rows.isEmpty }
    }

    static let unattributedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!

    var kind: EarningsKind
    var currency: CurrencyCode
    var today: Day
    var interval: DayInterval
    /// Nothing was ever earned or charged in this scope → the screen shows its empty state.
    var isEmpty: Bool
    var tiles: Tiles
    /// All categories of the selected interval.
    var total: EarningsAmounts
    var totalValue: Int64
    var monthCount: Int
    var paymentCount: Int
    var charts: [EarningsGrouping: Chart]
    var matrix: [MatrixRow]
    var matrixColumnTotals: [Int64]
    var matrixMaximum: Int64
    var securities: [SecurityRow]
    var accounts: [AccountRow]
    var calendar: Calendar

    init(_ analysis: Analysis, query: Query) {
        let ledger = analysis.ledger
        let scope = analysis.scope
        let kind = query.kind
        let metric = kind.metric
        let today = query.today
        let report = analysis.earnings

        self.kind = kind
        currency = analysis.currency
        self.today = today
        interval = analysis.interval
        total = report.total
        totalValue = report.total[metric]
        monthCount = report.months.count
        paymentCount = report.payments.count

        // Tiles: fixed calendar windows, each an engine report of its own (one cheap pass each).
        let all = ledger.earnings(in: query.allYears, scope: scope)
        isEmpty = all.total.isZero && all.payments.isEmpty
        let year = today.year
        func value(_ interval: DayInterval) -> Int64 { ledger.earnings(in: interval, scope: scope).total[metric] }
        func calendarYear(_ y: Int) -> DayInterval {
            DayInterval(start: Day(year: y, month: 1, day: 1).advanced(by: -1), end: Day(year: y, month: 12, day: 31))
        }
        let thisYear = value(DayInterval(start: today.startOfYear.advanced(by: -1), end: today))
        let lastYear = value(calendarYear(year - 1))
        let yearBefore = value(calendarYear(year - 2))
        let samePeriodInterval = DayInterval(start: Day(year: year - 1, month: 1, day: 1).advanced(by: -1), end: today.addingYears(-1))
        let samePeriod = value(samePeriodInterval)
        let trailingInterval = DayInterval(start: today.startOfMonth.addingMonths(-11).advanced(by: -1), end: today)
        let trailingReport = ledger.earnings(in: trailingInterval, scope: scope)
        let trailing = trailingReport.total[metric]
        tiles = Tiles(
            year: year, thisYear: thisYear, lastYear: lastYear,
            lastYearGrowth: Self.growth(lastYear, over: yearBefore),
            trailing: trailing, trailingInterval: trailingInterval, averagePerMonth: trailing / 12,
            samePeriodLastYear: samePeriod, samePeriodGrowth: Self.growth(thisYear, over: samePeriod),
            samePeriodInterval: samePeriodInterval)

        // Chart
        charts = Self.makeCharts(report, kind: kind, ledger: ledger)

        // Matrix (newest year first)
        let growth = report.yearOverYear(metric)
        let first = analysis.interval.firstDay
        let firstMonthIndex = first.year * 12 + first.month - 1
        let lastMonthIndex = analysis.interval.end.year * 12 + analysis.interval.end.month - 1
        let startsMidYear = !(first.month == 1 && first.dayOfMonth == 1)
        let reachesBackToInception = first <= query.allYears.firstDay
        var rows: [MatrixRow] = []
        let years = report.years
        for (index, row) in years.enumerated() {
            let values = row.values(metric)
            let covered = (0..<12).map { m in
                let i = row.year * 12 + m
                return i >= firstMonthIndex && i <= lastMonthIndex
            }
            let isCurrent = row.year == year && analysis.interval.end >= today
            let endsMidYear = row.year == analysis.interval.end.year
                && !(analysis.interval.end.month == 12 && analysis.interval.end.dayOfMonth == 31)
            var rowGrowth = index < growth.count ? growth[index].growth : nil
            var samePeriodGrowth = false
            if index == 0 {
                rowGrowth = nil
            } else if index == 1, startsMidYear, !reachesBackToInception {
                // The first year of a cut-off period is incomplete: comparing against it misleads.
                rowGrowth = nil
            }
            if isCurrent, index > 0, !(index == 1 && startsMidYear && !reachesBackToInception) {
                rowGrowth = tiles.samePeriodGrowth
                samePeriodGrowth = true
            } else if endsMidYear, index > 0 {
                rowGrowth = nil
            }
            rows.append(MatrixRow(
                year: row.year, values: values, covered: covered, total: row.total[metric], growth: rowGrowth,
                growthIsSamePeriod: samePeriodGrowth,
                isPartial: (index == 0 && startsMidYear) || endsMidYear))
        }
        var columns = [Int64](repeating: 0, count: 12)
        var maximum: Int64 = 0
        for row in rows {
            for m in 0..<12 {
                columns[m] += row.values[m]
                maximum = max(maximum, abs(row.values[m]))
            }
        }
        matrix = rows.reversed()
        matrixColumnTotals = columns
        matrixMaximum = maximum

        // By security. Yield on cost is the engine's figure for the trailing twelve months.
        let yieldInterval = DayInterval(start: today.addingMonths(-12), end: today)
        var yields: [UUID: Double] = [:]
        if !report.bySecurity.isEmpty {
            for security in ledger.performance(in: yieldInterval, scope: scope).securities {
                if let y = security.dividendYieldOnCost, security.dividends > 0 { yields[security.securityID] = y }
            }
        }
        var lastPayment: [UUID: DividendPayment] = [:]
        for payment in report.payments { lastPayment[payment.securityID] = payment }
        let denominator = Double(totalValue)
        func share(_ amount: Int64) -> Double { denominator != 0 ? Double(amount) / denominator : 0 }
        var securityRows: [SecurityRow] = report.bySecurity.compactMap { entry in
            let amount = entry.amounts[metric]
            guard amount != 0 || (kind == .dividends && entry.dividendCount > 0) else { return nil }
            let security = ledger.security(entry.securityID)
            let last = lastPayment[entry.securityID]
            return SecurityRow(
                id: entry.securityID, securityID: entry.securityID, name: security?.name ?? "Unknown Security",
                detail: Self.detail(of: security), amount: amount, share: share(amount), count: entry.dividendCount,
                lastDay: last?.day, lastGross: last?.gross ?? 0, perShare: last?.perShare,
                yieldOnCost: yields[entry.securityID], isRetired: security?.isRetired ?? false)
        }
        let unattributed = report.withoutSecurity[metric]
        if unattributed != 0 {
            securityRows.append(SecurityRow(
                id: Self.unattributedID, securityID: nil, name: "Not tied to a security",
                detail: "Interest, account fees and taxes", amount: unattributed, share: share(unattributed), count: 0,
                lastDay: nil, lastGross: 0, perShare: nil, yieldOnCost: nil, isRetired: false))
        }
        securities = securityRows

        // By account
        accounts = report.byAccount.map { entry in
            let account = ledger.account(entry.accountID)
            let amount = entry.amounts[metric]
            return AccountRow(
                id: entry.accountID, name: account?.name ?? "Unknown Account", currency: account?.currency ?? analysis.currency,
                dividends: entry.amounts.dividends, interest: entry.amounts.interest - entry.amounts.interestCharges,
                fees: entry.amounts.fees, taxes: entry.amounts.taxes, net: entry.amounts.net,
                amount: amount, share: share(amount))
        }

        calendar = Self.makeCalendar(all: all, trailing: trailingReport, ledger: ledger, scope: scope, today: today)
    }

    /// `value / previous − 1`, undefined unless the previous value is positive (the engine's rule
    /// for `EarningsReport.yearOverYear`).
    static func growth(_ value: Int64, over previous: Int64) -> Double? {
        previous > 0 ? Double(value) / Double(previous) - 1 : nil
    }

    static func detail(of security: Security?) -> String {
        guard let security else { return "" }
        if !security.ticker.isEmpty { return security.ticker }
        if !security.isin.isEmpty { return security.isin }
        return security.wkn
    }

    // MARK: Chart

    private static func makeCharts(_ report: EarningsReport, kind: EarningsKind, ledger: Ledger) -> [EarningsGrouping: Chart] {
        let metric = kind.metric
        let months = report.months
        guard !months.isEmpty else { return [:] }
        let spansYears = months.first!.year != months.last!.year

        // Buckets: index of the bar each month belongs to, per grouping.
        var monthBucket: [EarningsGrouping: [Int]] = [:]
        var categories: [EarningsGrouping: [BarCategory]] = [:]
        categories[.month] = BarCategory.months(months.map { ($0.year, $0.month) })
        monthBucket[.month] = Array(months.indices)
        var quarterIndex: [Int] = [], yearIndex: [Int] = []
        var quarterCategories: [BarCategory] = [], yearCategories: [BarCategory] = []
        var lastQuarter = Int.min, lastYear = Int.min
        for m in months {
            let q = m.year * 4 + (m.month - 1) / 3
            if q != lastQuarter {
                lastQuarter = q
                let number = (m.month - 1) / 3 + 1
                quarterCategories.append(BarCategory(
                    id: "\(m.year)-Q\(number)", label: spansYears ? "Q\(number) \(m.year)" : "Q\(number)",
                    detail: "Q\(number) \(m.year)"))
            }
            quarterIndex.append(quarterCategories.count - 1)
            if m.year != lastYear {
                lastYear = m.year
                yearCategories.append(.year(m.year))
            }
            yearIndex.append(yearCategories.count - 1)
        }
        monthBucket[.quarter] = quarterIndex
        monthBucket[.year] = yearIndex
        categories[.quarter] = quarterCategories
        categories[.year] = yearCategories

        // Dividends per security and month — only for figures that consist of dividends.
        let attributable = kind == .dividends || kind == .earnings
        var perSecurity: [UUID: [Int64]] = [:]
        var order: [(id: UUID, total: Int64)] = []
        if attributable {
            let base = months.first!.id
            var totals: [UUID: Int64] = [:]
            for p in report.payments {
                let index = p.day.year * 12 + p.day.month - 1 - base
                guard months.indices.contains(index) else { continue }
                perSecurity[p.securityID, default: [Int64](repeating: 0, count: months.count)][index] += p.gross
                totals[p.securityID, default: 0] += p.gross
            }
            order = totals.map { ($0.key, $0.value) }.sorted {
                $0.total != $1.total ? $0.total > $1.total : $0.id.uuidString < $1.id.uuidString
            }
        }
        let trailing = report.trailingTwelveMonths(metric)

        var result: [EarningsGrouping: Chart] = [:]
        for grouping in EarningsGrouping.allCases {
            let bucket = monthBucket[grouping]!
            let count = categories[grouping]!.count
            func bucketed(_ values: [Int64]) -> [Int64] {
                var out = [Int64](repeating: 0, count: count)
                for (i, v) in values.enumerated() { out[bucket[i]] += v }
                return out
            }
            var chart = Chart()
            chart.categories = categories[grouping]!
            var amounts = [EarningsAmounts](repeating: EarningsAmounts(), count: count)
            for (i, m) in months.enumerated() { amounts[bucket[i]] += m.amounts }
            chart.amounts = amounts
            let interestNet = months.map { $0.amounts.interest - $0.amounts.interestCharges }
            if kind == .earnings {
                chart.plain = [
                    BarSeries(id: "dividends", "Dividends", values: bucketed(months.map(\.amounts.dividends)), color: EarningsKind.dividends.color),
                    BarSeries(id: "interest", "Interest", values: bucketed(interestNet), color: EarningsKind.interest.color),
                ]
            } else {
                chart.plain = [BarSeries(id: kind.rawValue, kind.title, values: bucketed(months.map { $0.amounts[metric] }), color: kind.color)]
            }
            if attributable, !order.isEmpty {
                // Identity colors are never cycled: the largest payers get their own, the rest fold.
                let slots = kind == .earnings ? 6 : 7
                var series: [BarSeries] = []
                // Orange stays reserved for interest wherever interest is in the same chart.
                let palette = kind == .earnings ? [0, 2, 3, 4, 5, 6] : Array(0..<7)
                for (i, entry) in order.prefix(slots).enumerated() {
                    series.append(BarSeries(
                        id: entry.id.uuidString, ledger.security(entry.id)?.name ?? "Unknown Security",
                        values: bucketed(perSecurity[entry.id]!), color: ChartColors.series(palette[i])))
                }
                if order.count > slots {
                    var rest = [Int64](repeating: 0, count: months.count)
                    for entry in order.dropFirst(slots) {
                        for (i, v) in perSecurity[entry.id]!.enumerated() { rest[i] += v }
                    }
                    series.append(BarSeries(id: "other", "\(order.count - slots) others", values: bucketed(rest), color: ChartColors.other))
                }
                if kind == .earnings, interestNet.contains(where: { $0 != 0 }) {
                    series.append(BarSeries(id: "interest", "Interest", values: bucketed(interestNet), color: EarningsKind.interest.color))
                }
                chart.bySecurity = series
            }
            if grouping != .year, trailing.contains(where: \.isComplete) {
                let divisor: Double = grouping == .month ? 12 : 4
                var line = [Double?](repeating: nil, count: count)
                for (i, t) in trailing.enumerated() where t.isComplete {
                    // The rolling sum at the last month of a bar, scaled to one bar's width.
                    let isLastOfBucket = i + 1 == trailing.count || bucket[i + 1] != bucket[i]
                    if isLastOfBucket { line[bucket[i]] = Double(t.value) / divisor }
                }
                chart.average = line
            }
            result[grouping] = chart
        }
        return result
    }

    // MARK: Calendar and projection

    /// Payment months per security and a deliberately simple projection: every dividend of the
    /// last twelve months is expected again twelve months later, at the same amount per share,
    /// for the shares held today.
    private static func makeCalendar(all: EarningsReport, trailing: EarningsReport, ledger: Ledger, scope: Scope, today: Day) -> Calendar {
        let basis = trailing.interval
        let firstUpcoming = today.endOfMonth.advanced(by: 1)
        let upcomingEnd = firstUpcoming.addingMonths(12).advanced(by: -1)
        var calendar = Calendar(interval: DayInterval(start: today.endOfMonth, end: upcomingEnd), basisInterval: basis)
        calendar.months = (0..<12).map { offset in
            let day = firstUpcoming.addingMonths(offset)
            return BarCategory(id: "\(day.year)-\(day.month)", label: ChartLabels.shortMonth(day.month),
                               detail: Fmt.month(year: day.year, month: day.month, long: true))
        }
        calendar.expected = [Int64](repeating: 0, count: 12)
        guard !all.payments.isEmpty else { return calendar }

        var held: [UUID: Shares] = [:]
        for position in ledger.snapshot(on: today, scope: scope).positions { held[position.securityID] = position.shares }

        struct Entry {
            var recent = [Bool](repeating: false, count: 12)
            var earlier = [Bool](repeating: false, count: 12)
            var recentMonths = Set<Int>()
            var expected = [Int64](repeating: 0, count: 12)
        }
        var entries: [UUID: Entry] = [:]
        let earlierStart = basis.start.addingMonths(-24)
        let firstUpcomingIndex = firstUpcoming.year * 12 + firstUpcoming.month - 1
        for payment in all.payments where payment.day > earlierStart && payment.day <= today {
            var entry = entries[payment.securityID] ?? Entry()
            let month = payment.day.month - 1
            if payment.day > basis.start {
                entry.recent[month] = true
                entry.recentMonths.insert(payment.day.year * 12 + month)
                if let perShare = payment.perShare, let shares = held[payment.securityID], shares.raw > 0 {
                    let slot = payment.day.year * 12 + month + 12 - firstUpcomingIndex
                    if (0..<12).contains(slot) { entry.expected[slot] += perShare.value(of: shares) }
                }
            } else {
                entry.earlier[month] = true
            }
            entries[payment.securityID] = entry
        }
        var rows: [CalendarRow] = []
        for security in ledger.securities {
            guard let entry = entries[security.id] else { continue }
            let total = entry.expected.reduce(0, +)
            rows.append(CalendarRow(
                id: security.id, name: security.name, detail: detail(of: security), recent: entry.recent,
                earlier: entry.earlier, paymentsPerYear: entry.recentMonths.count, shares: held[security.id] ?? .zero,
                expected: entry.expected, expectedTotal: total))
            for i in 0..<12 { calendar.expected[i] += entry.expected[i] }
        }
        rows.sort { a, b in
            a.expectedTotal != b.expectedTotal ? a.expectedTotal > b.expectedTotal
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        calendar.rows = rows
        calendar.expectedTotal = calendar.expected.reduce(0, +)
        return calendar
    }
}

/// Formatting helpers on top of `Fmt` for values the engine derives.
enum EarningsFormat {
    /// A dividend per share. The engine derives it (gross ÷ shares), so it rarely is a round
    /// number: four decimals are plenty.
    static func perShare(_ price: Price?, currency: CurrencyCode) -> String {
        guard let price else { return Fmt.missing }
        let step = Scale.price / 10_000
        let rounded = Price(raw: (price.raw + (price.raw >= 0 ? step / 2 : -step / 2)) / step * step)
        return Fmt.price(rounded, currency: currency)
    }

    /// A share count for table cells: at most four decimals (fractional savings-plan shares
    /// carry eight).
    static func shares(_ shares: Shares) -> String {
        let step = Scale.shares / 10_000
        return Fmt.shares(Shares(raw: (shares.raw + (shares.raw >= 0 ? step / 2 : -step / 2)) / step * step))
    }
}

// MARK: Payments (own task: filtered and sorted off the main actor)

struct PaymentRow: Identifiable, Sendable, Hashable {
    var id: UUID
    var day: Day
    var securityID: UUID
    var accountID: UUID
    var security: String
    var account: String
    var shares: Shares
    var perShare: Price?
    var gross: Int64
    var taxes: Int64
    var fees: Int64
    var net: Int64
    var yield: Double?

    var perShareSortKey: Int64 { perShare?.raw ?? Int64.min }
    var yieldSortKey: Double { yield ?? -Double.infinity }
}

struct PaymentsModel: Sendable {
    struct Query: Hashable, Sendable {
        var filter: String
        /// `year × 12 + month − 1`, or nil for every month.
        var month: Int?
        var securityID: UUID?
        var sortOrder: [KeyPathComparator<PaymentRow>]
    }

    var rows: [PaymentRow]
    var totalCount: Int
    var currency: CurrencyCode
    var gross: Int64
    var taxes: Int64
    var fees: Int64
    var net: Int64

    init(_ analysis: Analysis, query: Query) {
        let ledger = analysis.ledger
        let payments = analysis.earnings.payments
        let filter = QuickFilter(query.filter)
        var rows: [PaymentRow] = []
        rows.reserveCapacity(payments.count)
        var names: [UUID: String] = [:]
        var accounts: [UUID: String] = [:]
        var gross: Int64 = 0, taxes: Int64 = 0, fees: Int64 = 0
        for p in payments {
            if let month = query.month, p.day.year * 12 + p.day.month - 1 != month { continue }
            if let id = query.securityID, p.securityID != id { continue }
            let security = names[p.securityID] ?? {
                let name = ledger.security(p.securityID)?.name ?? "Unknown Security"
                names[p.securityID] = name
                return name
            }()
            let account = accounts[p.accountID] ?? {
                let name = ledger.account(p.accountID)?.name ?? "Unknown Account"
                accounts[p.accountID] = name
                return name
            }()
            if !filter.isEmpty, !filter.matches(security, account) { continue }
            rows.append(PaymentRow(
                id: p.transactionID, day: p.day, securityID: p.securityID, accountID: p.accountID, security: security,
                account: account, shares: p.shares, perShare: p.perShare, gross: p.gross, taxes: p.taxes, fees: p.fees,
                net: p.net, yield: p.yield))
            gross += p.gross
            taxes += p.taxes
            fees += p.fees
        }
        self.rows = rows.sorted(using: query.sortOrder)
        totalCount = payments.count
        currency = analysis.currency
        self.gross = gross
        self.taxes = taxes
        self.fees = fees
        net = gross - taxes - fees
    }
}
