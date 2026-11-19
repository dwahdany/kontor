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
        /// The twelve months up to and including today (`today − 12 months`, exclusive, … today):
        /// one window for the tile, the monthly average, the projection basis and yield on cost.
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
        /// Dividend payments (bookings of one day in several depots are one payment).
        var count: Int
        var lastDay: Day?
        /// Gross amount of the last dividend payment, all its bookings together.
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
        /// Expected gross dividends of the twelve months ahead, aligned with `Calendar.months`.
        var expected: [Int64]
        var expectedTotal: Int64
    }

    struct Calendar: Sendable {
        var rows: [CalendarRow] = []
        /// The calendar months touched by the twelve months after today: twelve on the last day
        /// of a month, otherwise thirteen (the rest of this month … the start of the same month
        /// next year).
        var months: [BarCategory] = []
        var expected: [Int64] = []
        /// `expected` folded onto calendar months (January first).
        var expectedByCalendarMonth = [Int64](repeating: 0, count: 12)
        var expectedTotal: Int64 = 0
        /// The twelve months after today.
        var interval: DayInterval
        /// The twelve months up to today, whose payments the projection repeats.
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
    /// Whether "share of the total" says anything for the month columns, the securities and the
    /// accounts (decided once per table: not when refunds or costs flip the sign of some parts).
    var matrixSharesAreMeaningful: Bool
    var securitySharesAreMeaningful: Bool
    var accountSharesAreMeaningful: Bool
    /// The scope is one cash account: the figures are what was booked on it.
    var isAccountScope: Bool
    /// Bookings of the selected interval the engine could not convert (counted as zero).
    var unconverted: UnconvertedBookings

    /// The dividend columns (payments, last dividend, per share, yield on cost) belong to
    /// figures that consist of dividends.
    var showsDividendColumns: Bool { kind == .dividends || kind == .earnings }

    init(_ analysis: Analysis, query: Query) {
        let ledger = analysis.ledger
        let scope = analysis.scope
        let kind = query.kind
        let metric = kind.metric
        let today = query.today
        let account = EarningsData.bookedAccount(of: scope)
        let report = EarningsData.make(analysis)

        self.kind = kind
        currency = analysis.currency
        self.today = today
        interval = analysis.interval
        isAccountScope = account != nil
        total = report.total
        totalValue = report.total[metric]
        monthCount = report.months.count
        unconverted = UnconvertedBookings.find(ledger: ledger, scope: scope, interval: analysis.interval)

        // Tiles: fixed calendar windows, each an engine report of its own (one cheap pass each).
        func totals(_ interval: DayInterval) -> EarningsData {
            EarningsData.make(ledger: ledger, scope: scope, interval: interval, detailed: false)
        }
        let all = analysis.interval == query.allYears ? report : totals(query.allYears)
        isEmpty = all.total.isZero && all.payments.isEmpty
        let year = today.year
        func value(_ interval: DayInterval) -> Int64 { totals(interval).total[metric] }
        func calendarYear(_ y: Int) -> DayInterval {
            DayInterval(start: Day(year: y, month: 1, day: 1).advanced(by: -1), end: Day(year: y, month: 12, day: 31))
        }
        let thisYear = value(DayInterval(start: today.startOfYear.advanced(by: -1), end: today))
        let lastYear = value(calendarYear(year - 1))
        let yearBefore = value(calendarYear(year - 2))
        let samePeriodInterval = DayInterval(start: Day(year: year - 1, month: 1, day: 1).advanced(by: -1), end: today.addingYears(-1))
        let samePeriod = value(samePeriodInterval)
        let trailingInterval = Self.trailingInterval(today: today)
        let trailingReport = totals(trailingInterval)
        let trailing = trailingReport.total[metric]
        tiles = Tiles(
            year: year, thisYear: thisYear, lastYear: lastYear,
            lastYearGrowth: EarningsRules.growth(lastYear, over: yearBefore),
            trailing: trailing, trailingInterval: trailingInterval, averagePerMonth: trailing / 12,
            samePeriodLastYear: samePeriod, samePeriodGrowth: EarningsRules.growth(thisYear, over: samePeriod),
            samePeriodInterval: samePeriodInterval)

        // Dividend payments: the bookings of one security and day are one payment.
        let withoutShares = all.payments.isEmpty ? [] : DividendGroup.bookingsWithoutShares(in: ledger)
        let groups = DividendGroup.groups(report.payments, withoutShares: withoutShares)
        paymentCount = groups.count

        // Chart
        charts = Self.makeCharts(report, kind: kind, ledger: ledger)

        // Matrix (newest year first)
        let first = analysis.interval.firstDay
        let firstMonthIndex = first.year * 12 + first.month - 1
        let lastMonthIndex = analysis.interval.end.year * 12 + analysis.interval.end.month - 1
        let startsMidYear = !(first.month == 1 && first.dayOfMonth == 1)
        let reachesBackToInception = first <= query.allYears.firstDay
        var rows: [MatrixRow] = []
        let years = report.years
        for (index, row) in years.enumerated() {
            let values = row.months.map { $0[metric] }
            let covered = (0..<12).map { m in
                let i = row.year * 12 + m
                return i >= firstMonthIndex && i <= lastMonthIndex
            }
            let isCurrent = row.year == year && analysis.interval.end >= today
            let endsMidYear = row.year == analysis.interval.end.year
                && !(analysis.interval.end.month == 12 && analysis.interval.end.dayOfMonth == 31)
            var rowGrowth = index > 0 ? EarningsRules.growth(row.total[metric], over: years[index - 1].total[metric]) : nil
            var samePeriodGrowth = false
            if index == 1, startsMidYear, !reachesBackToInception {
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

        matrixSharesAreMeaningful = EarningsRules.sharesAreMeaningful(columns)

        // By security. Yield on cost is the engine's figure for the same trailing twelve months
        // (per security it does not depend on the account a dividend was booked on).
        var yields: [UUID: Double] = [:]
        if kind == .dividends || kind == .earnings, !report.payments.isEmpty {
            let positions: Scope = account == nil ? scope : .portfolio
            for security in ledger.securityPerformance(in: trailingInterval, scope: positions) {
                if let y = security.dividendYieldOnCost, security.dividends > 0 { yields[security.securityID] = y }
            }
        }
        var lastPayment: [UUID: DividendGroup] = [:]
        var paymentCounts: [UUID: Int] = [:]
        for group in groups {
            lastPayment[group.securityID] = group
            paymentCounts[group.securityID, default: 0] += 1
        }
        let denominator = Double(totalValue)
        func share(_ amount: Int64) -> Double { denominator != 0 ? Double(amount) / denominator : 0 }
        var securityRows: [SecurityRow] = report.bySecurity.compactMap { entry in
            let amount = entry.amounts[metric]
            guard amount != 0 || (kind == .dividends && entry.dividendCount > 0) else { return nil }
            let security = ledger.security(entry.securityID)
            let last = lastPayment[entry.securityID]
            return SecurityRow(
                id: entry.securityID, securityID: entry.securityID, name: security?.name ?? "Unknown Security",
                detail: Self.detail(of: security), amount: amount, share: share(amount),
                count: paymentCounts[entry.securityID] ?? 0,
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
        securitySharesAreMeaningful = EarningsRules.sharesAreMeaningful(securityRows.lazy.map(\.amount))

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
        accountSharesAreMeaningful = EarningsRules.sharesAreMeaningful(accounts.lazy.map(\.amount))

        // Calendar: all years, independent of the selected interval. The shares a payment was made
        // for and the shares held today come from the positions — for an account scope the whole
        // portfolio's, since a cash account holds none.
        if all.payments.isEmpty {
            calendar = Self.makeCalendar(groups: [], sharesThen: nil, held: [:], securities: [], today: today)
        } else {
            let positions: Scope = account == nil ? scope : .portfolio
            var held: [UUID: Shares] = [:]
            for position in ledger.snapshot(on: today, scope: positions).positions { held[position.securityID] = position.shares }
            var sharesThen: [DividendGroup]?
            if account != nil {
                sharesThen = DividendGroup.groups(ledger.earnings(in: trailingInterval, scope: .portfolio).payments, withoutShares: withoutShares)
            }
            let allGroups = analysis.interval == query.allYears ? groups : DividendGroup.groups(all.payments, withoutShares: withoutShares)
            calendar = Self.makeCalendar(groups: allGroups, sharesThen: sharesThen, held: held, securities: ledger.securities, today: today)
        }
    }

    /// The twelve months up to and including `today`, as an engine interval (start exclusive).
    static func trailingInterval(today: Day) -> DayInterval {
        DayInterval(start: today.addingMonths(-12), end: today)
    }

    static func detail(of security: Security?) -> String {
        guard let security else { return "" }
        if !security.ticker.isEmpty { return security.ticker }
        if !security.isin.isEmpty { return security.isin }
        return security.wkn
    }

    // MARK: Chart

    private static func makeCharts(_ report: EarningsData, kind: EarningsKind, ledger: Ledger) -> [EarningsGrouping: Chart] {
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
            let base = months.first!.index
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
                    let others = order.count - slots
                    series.append(BarSeries(id: "other", others == 1 ? "1 other" : "\(others) others", values: bucketed(rest), color: ChartColors.other))
                }
                if kind == .earnings, interestNet.contains(where: { $0 != 0 }) {
                    series.append(BarSeries(id: "interest", "Interest", values: bucketed(interestNet), color: EarningsKind.interest.color))
                }
                chart.bySecurity = series
            }
            if grouping != .year, trailing.contains(where: { $0 != nil }) {
                let divisor: Double = grouping == .month ? 12 : 4
                var line = [Double?](repeating: nil, count: count)
                for (i, sum) in trailing.enumerated() {
                    guard let sum else { continue }
                    // The rolling sum at the last month of a bar, scaled to one bar's width.
                    let isLastOfBucket = i + 1 == trailing.count || bucket[i + 1] != bucket[i]
                    if isLastOfBucket { line[bucket[i]] = Double(sum) / divisor }
                }
                chart.average = line
            }
            result[grouping] = chart
        }
        return result
    }

    // MARK: Calendar and projection

    /// Payment months per security and a deliberately simple projection: every dividend payment
    /// of the last twelve months is expected again twelve months later, at the same amount per
    /// share, for the shares held today.
    ///
    /// - Parameters:
    ///   - groups: all dividend payments of the scope (bookings of one day merged), chronological.
    ///   - sharesThen: payments that state the shares each payment was made for, when `groups`
    ///     cannot (an account scope sees only the bookings on that account); nil = `groups`.
    ///   - held: shares held today per security.
    static func makeCalendar(groups: [DividendGroup], sharesThen: [DividendGroup]?, held: [UUID: Shares],
                             securities: [Security], today: Day) -> Calendar {
        let basis = trailingInterval(today: today)
        let firstUpcoming = today.advanced(by: 1)
        let lastUpcoming = today.addingMonths(12)
        let firstIndex = firstUpcoming.year * 12 + firstUpcoming.month - 1
        let lastIndex = lastUpcoming.year * 12 + lastUpcoming.month - 1
        let count = max(lastIndex - firstIndex + 1, 12)
        var calendar = Calendar(interval: DayInterval(start: today, end: lastUpcoming), basisInterval: basis)
        calendar.months = (0..<count).map { slot in
            let index = firstIndex + slot
            let year = index / 12, month = index % 12 + 1
            var detail = Fmt.month(year: year, month: month, long: true)
            // A partial month at either end says so.
            if slot == 0, firstUpcoming.dayOfMonth != 1 {
                detail += ", from \(Fmt.day(firstUpcoming, style: .dayMonth))"
            } else if slot == count - 1, count > 12 {
                detail += ", through \(Fmt.day(lastUpcoming, style: .dayMonth))"
            }
            // Thirteen months start and end in the same calendar month: the year tells them apart.
            let isEnd = slot == 0 || slot == count - 1
            let label = count > 12 && isEnd ? Fmt.month(year: year, month: month) : ChartLabels.shortMonth(month)
            return BarCategory(id: "\(year)-\(month)", label: label, detail: detail)
        }
        calendar.expected = [Int64](repeating: 0, count: count)
        guard !groups.isEmpty else { return calendar }

        struct Key: Hashable {
            var securityID: UUID
            var day: Day
        }
        var shares: [Key: Shares] = [:]
        for group in sharesThen ?? [] { shares[Key(securityID: group.securityID, day: group.day)] = group.shares }

        struct Entry {
            var recent = [Bool](repeating: false, count: 12)
            var earlier = [Bool](repeating: false, count: 12)
            var recentMonths = Set<Int>()
            var expected: [Int64]
        }
        var entries: [UUID: Entry] = [:]
        let earlierStart = basis.start.addingMonths(-24)
        for group in groups where group.day > earlierStart && group.day <= today {
            var entry = entries[group.securityID] ?? Entry(expected: [Int64](repeating: 0, count: count))
            let month = group.day.month - 1
            if group.day > basis.start {
                entry.recent[month] = true
                entry.recentMonths.insert(group.day.year * 12 + month)
                if let heldNow = held[group.securityID] {
                    let then = sharesThen == nil ? group.shares : shares[Key(securityID: group.securityID, day: group.day)] ?? .zero
                    let again = group.day.addingMonths(12)
                    let slot = min(max(again.year * 12 + again.month - 1 - firstIndex, 0), count - 1)
                    entry.expected[slot] += group.expected(for: heldNow, sharesThen: then)
                }
            } else {
                entry.earlier[month] = true
            }
            entries[group.securityID] = entry
        }
        var rows: [CalendarRow] = []
        for security in securities {
            guard let entry = entries[security.id] else { continue }
            let total = entry.expected.reduce(0, +)
            rows.append(CalendarRow(
                id: security.id, name: security.name, detail: detail(of: security), recent: entry.recent,
                earlier: entry.earlier, paymentsPerYear: entry.recentMonths.count, shares: held[security.id] ?? .zero,
                expected: entry.expected, expectedTotal: total))
            for i in 0..<count { calendar.expected[i] += entry.expected[i] }
        }
        rows.sort { a, b in
            a.expectedTotal != b.expectedTotal ? a.expectedTotal > b.expectedTotal
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        calendar.rows = rows
        for slot in 0..<count { calendar.expectedByCalendarMonth[(firstIndex + slot) % 12] += calendar.expected[slot] }
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
    /// False when there is no exchange rate for the booking's currency: its amounts are unknown
    /// in the reporting currency (the engine counts them as zero).
    var isConverted = true

    var perShareSortKey: Int64 { perShare?.raw ?? Int64.min }
    var yieldSortKey: Double { yield ?? -Double.infinity }
}

struct PaymentsModel: Sendable {
    struct Query: Hashable, Sendable {
        var filter: String
        /// `year × 12 + month − 1` of the first and last month, or nil for every month.
        var months: ClosedRange<Int>?
        var securityID: UUID?
        var sortOrder: [KeyPathComparator<PaymentRow>]
    }

    var rows: [PaymentRow]
    /// Changes whenever the set of rows changes (a selection must not outlive its rows).
    var rowsSignature: Int
    var unconverted: UnconvertedBookings
    var totalCount: Int
    var currency: CurrencyCode
    var gross: Int64
    var taxes: Int64
    var fees: Int64
    var net: Int64

    init(_ analysis: Analysis, query: Query) {
        let ledger = analysis.ledger
        // What was booked in the scope — for a cash account: on that account (see `EarningsData`).
        let payments = EarningsData.make(analysis, detailed: false).payments
        let unconverted = UnconvertedBookings.find(ledger: ledger, scope: analysis.scope, interval: analysis.interval)
        var shown = UnconvertedBookings()
        var signature = Hasher()
        let filter = QuickFilter(query.filter)
        var rows: [PaymentRow] = []
        rows.reserveCapacity(payments.count)
        var names: [UUID: String] = [:]
        var accounts: [UUID: String] = [:]
        var gross: Int64 = 0, taxes: Int64 = 0, fees: Int64 = 0
        for p in payments {
            if let months = query.months, !months.contains(p.day.year * 12 + p.day.month - 1) { continue }
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
                net: p.net, yield: p.yield, isConverted: !unconverted.transactionIDs.contains(p.transactionID)))
            if unconverted.transactionIDs.contains(p.transactionID) { shown.transactionIDs.insert(p.transactionID) }
            signature.combine(p.transactionID)
            gross += p.gross
            taxes += p.taxes
            fees += p.fees
        }
        self.rows = rows.sorted(using: query.sortOrder)
        rowsSignature = signature.finalize()
        shown.currencies = unconverted.currencies
        self.unconverted = shown
        totalCount = payments.count
        currency = analysis.currency
        self.gross = gross
        self.taxes = taxes
        self.fees = fees
        net = gross - taxes - fees
    }
}
