import SwiftUI
import KontorUI

// MARK: - Key figures

/// The key figures of one security: today's position and the performance in the window's
/// reporting period. Everything comes from the engine (`Scope.security`).
struct SecurityFigures: Sendable {
    struct Holding: Sendable, Identifiable {
        let id: UUID
        var depot: String
        var shares: Shares
        var value: Money
    }

    /// Reporting currency of all money values.
    var currency: CurrencyCode
    var securityCurrency: CurrencyCode
    var interval: DayInterval

    // Position at the end of the period (normally today)
    var shares: Shares = .zero
    var value: Money?
    var valueInSecurityCurrency: Money?
    var costBasis: Money?
    var purchasePrice: Price?
    var unrealizedGain: Money?
    var unrealizedGainFraction: Double?
    var isValued = true
    var holdings: [Holding] = []

    // Reporting period
    var hasActivity = false
    var realizedGain: Int64 = 0
    var dividends: Int64 = 0
    var dividendCount = 0
    var fees: Int64 = 0
    var taxes: Int64 = 0
    var ttwror: Double?
    var ttwrorAnnualized: Double?
    var irr: Double?
    var absolutePerformance: Int64?
    var transactionCount = 0

    var isHeld: Bool { !shares.isZero }

    init(_ analysis: Analysis, securityID: UUID) {
        let ledger = analysis.ledger
        currency = analysis.currency
        securityCurrency = ledger.security(securityID)?.currency ?? analysis.currency
        interval = analysis.interval
        transactionCount = ledger.transactions(forSecurity: securityID).count
        if let position = analysis.snapshot.position(securityID) {
            shares = position.shares
            value = position.value
            valueInSecurityCurrency = position.valueInSecurityCurrency
            costBasis = position.costBasis
            purchasePrice = position.purchasePrice
            unrealizedGain = position.unrealizedGain
            unrealizedGainFraction = position.unrealizedGainFraction
            isValued = position.isValued
            holdings = position.holdings.map {
                Holding(id: $0.depotID, depot: ledger.depot($0.depotID)?.name ?? "Unknown depot", shares: $0.shares, value: $0.value)
            }
        }
        if let performance = analysis.security(securityID) {
            hasActivity = true
            realizedGain = performance.realizedGain
            dividends = performance.dividends
            dividendCount = performance.dividendCount
            fees = performance.fees
            taxes = performance.taxes
            ttwror = performance.ttwror
            ttwrorAnnualized = performance.ttwrorAnnualized
            irr = performance.irr
            absolutePerformance = performance.absolutePerformance
        }
    }
}

// MARK: - Price chart

/// The chart's own period chips — independent of the window's reporting period
/// (`--state chart=1M|3M|6M|YTD|1Y|3Y|5Y|MAX`).
enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD"
    case oneYear = "1Y", threeYears = "3Y", fiveYears = "5Y", max = "MAX"

    var id: String { rawValue }

    var period: ReportingPeriod {
        switch self {
        case .oneMonth: .lastMonths(1)
        case .threeMonths: .lastMonths(3)
        case .sixMonths: .lastMonths(6)
        case .ytd: .ytd
        case .oneYear: .lastYears(1)
        case .threeYears: .lastYears(3)
        case .fiveYears: .lastYears(5)
        case .max: .allTime
        }
    }

    var title: String { self == .max ? "Max" : rawValue }

    /// The chart interval for a security: the period, but never starting before the first quote.
    func interval(for security: Security, today: Day) -> DayInterval {
        let first = security.prices.firstDay
        var interval = period.interval(today: today, firstTransactionDay: first)
        // The first quote is the baseline of a period that reaches back further.
        if let first, interval.start < first { interval.start = first }
        if interval.start >= interval.end { interval.start = interval.end.advanced(by: -1) }
        return interval
    }
}

/// Everything the chart depends on besides the document and its interval.
struct ChartQuery: Hashable, Sendable {
    var securityID: UUID
    var showsPurchasePrice = false
    var showsAverage50 = false
    var showsAverage200 = false
    var compareID: UUID?
}

struct SecurityChartModel: Sendable {
    struct Extreme: Sendable {
        var price: Price
        var day: Day
    }

    var interval: DayInterval
    var series: [TimeSeries] = []
    var markers: [ChartMarker] = []
    var format: ChartValueFormat
    var isComparison = false
    var currency: CurrencyCode
    /// Price change over the visible range (first to last quote shown).
    var change: Double?
    var high: Extreme?
    var low: Extreme?
    var quoteCount = 0
    /// Bookings and events in the range; with more than `markerLimit` the chart shows none (a
    /// cloud of overlapping glyphs says nothing) and the summary line says so.
    var markerCount = 0
    static let markerLimit = 120
    var markersHidden: Bool { markerCount > Self.markerLimit }
    /// Name of the comparison security, when one is shown.
    var comparisonName: String?
    /// The comparison's change over the same range.
    var comparisonChange: Double?
    /// Set when a comparison was asked for but cannot be drawn (the other security has no quotes).
    var comparisonProblem: String?

    var isEmpty: Bool { quoteCount == 0 }

    init(_ analysis: Analysis, query: ChartQuery) {
        let ledger = analysis.ledger
        interval = analysis.interval
        guard let security = ledger.security(query.securityID) else {
            currency = analysis.currency
            format = .price(analysis.currency)
            return
        }
        currency = security.currency
        format = .price(security.currency)
        let prices = security.prices

        // Quotes inside the interval (the baseline day included).
        var lower = 0, upper = prices.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if prices.days[mid] < interval.start.rawValue { lower = mid + 1 } else { upper = mid }
        }
        let end = (prices.index(onOrBefore: interval.end) ?? -1) + 1
        let range = lower < end ? lower..<end : lower..<lower
        quoteCount = range.count
        guard !range.isEmpty else { return }

        let days = range.map { Day(rawValue: prices.days[$0]) }
        let scale = Double(Scale.price)
        let closes = range.map { Double(prices.values[$0]) / scale }
        if let first = closes.first, let last = closes.last, first > 0, closes.count > 1 { change = last / first - 1 }
        var hi = range.lowerBound, lo = range.lowerBound
        for i in range {
            if prices.values[i] > prices.values[hi] { hi = i }
            if prices.values[i] < prices.values[lo] { lo = i }
        }
        high = Extreme(price: prices[hi].price, day: prices[hi].day)
        low = Extreme(price: prices[lo].price, day: prices[lo].day)

        let transactions = ledger.transactions(forSecurity: security.id).filter { interval.contains($0.date) || $0.date == interval.start }
        markers = ChartMarker.markers(for: transactions)
        for event in security.events where event.kind != .dividend && (interval.contains(event.day) || event.day == interval.start) {
            let label = event.kind == .split ? "Split \(event.detail)" : event.detail
            markers.append(ChartMarker(.event, id: event.id.uuidString, day: event.day, label: label))
        }
        markerCount = markers.count
        if markersHidden { markers = [] }

        // Comparison: both rebased to 0 % at the start of the range, each in its own currency.
        if let compareID = query.compareID, compareID != security.id, let other = ledger.security(compareID),
           let own = ledger.benchmark(securityID: security.id, in: interval, basis: .securityCurrency),
           let reference = ledger.benchmark(securityID: compareID, in: interval, basis: .securityCurrency) {
            isComparison = true
            format = .percent(decimals: 2, signed: true)
            comparisonName = other.name
            comparisonChange = reference.total
            change = own.total
            series = [
                TimeSeries(id: "price", security.name, start: interval.start, values: own.cumulative),
                TimeSeries(id: "compare", other.name, start: interval.start, values: reference.cumulative,
                           color: ChartColors.comparison, dashed: true),
            ]
            return
        }

        if let compareID = query.compareID, compareID != security.id, let other = ledger.security(compareID) {
            comparisonProblem = "“\(other.name)” has no quotes to compare with."
        }

        series = [TimeSeries(id: "price", "Price", days: days, values: closes, style: .area)]
        if query.showsAverage50, let average = Self.movingAverage(prices, window: 50, range: range) {
            series.append(TimeSeries(id: "ma50", "50-day average", days: average.days, values: average.values, color: ChartColors.series(1)))
        }
        if query.showsAverage200, let average = Self.movingAverage(prices, window: 200, range: range) {
            series.append(TimeSeries(id: "ma200", "200-day average", days: average.days, values: average.values, color: ChartColors.series(2)))
        }
        if query.showsPurchasePrice, let position = analysis.snapshot.position(security.id), let purchase = position.purchasePrice {
            // The engine reports the average purchase price in the reporting currency; the chart is
            // in the security's currency, so translate it at the rate of the last day shown.
            let rate = ledger.converter.rate(from: analysis.currency, to: security.currency, on: interval.end)
            if let rate, let first = days.first, let last = days.last, first < last {
                let level = purchase.doubleValue * rate
                series.append(TimeSeries(id: "purchase", "Purchase price", days: [first, last], values: [level, level],
                                         style: .step, color: ChartColors.comparison, dashed: true))
            }
        }
    }

    /// Simple moving average of the last `window` quotes, for every quote in `range` that has
    /// enough history (earlier quotes outside the visible range count towards the average).
    static func movingAverage(_ prices: PriceSeries, window: Int, range: Range<Int>) -> (days: [Day], values: [Double])? {
        guard window > 0, range.upperBound >= window else { return nil }
        let first = max(range.lowerBound, window - 1)
        guard first < range.upperBound else { return nil }
        let scale = Double(Scale.price)
        var sum = 0.0
        for i in (first - window + 1)...first { sum += Double(prices.values[i]) }
        var days = [Day](), values = [Double]()
        days.reserveCapacity(range.upperBound - first)
        values.reserveCapacity(range.upperBound - first)
        for i in first..<range.upperBound {
            if i > first { sum += Double(prices.values[i]) - Double(prices.values[i - window]) }
            days.append(Day(rawValue: prices.days[i]))
            values.append(sum / Double(window) / scale)
        }
        return (days, values)
    }
}

// MARK: - Tab models

/// One stored quote (Historical Prices tab). The id is the day.
struct QuoteRow: Identifiable, Sendable, Hashable {
    var id: Int32 { day.rawValue }
    var day: Day
    var price: Price
    /// Change against the previous quote.
    var change: Double?

    /// Newest first.
    static func rows(of security: Security?) -> [QuoteRow] {
        guard let prices = security?.prices, !prices.isEmpty else { return [] }
        var rows = [QuoteRow]()
        rows.reserveCapacity(prices.count)
        for i in stride(from: prices.count - 1, through: 0, by: -1) {
            let previous = i > 0 ? prices.values[i - 1] : 0
            rows.append(QuoteRow(
                day: Day(rawValue: prices.days[i]), price: Price(raw: prices.values[i]),
                change: previous > 0 ? Double(prices.values[i]) / Double(previous) - 1 : nil))
        }
        return rows
    }
}

/// One booking of the security (Transactions tab).
struct SecurityTransactionRow: Identifiable, Sendable, Hashable {
    let id: UUID
    var date: Day
    var kind: Transaction.Kind
    var shares: Shares
    /// Gross price per share in the booking's currency.
    var price: Price?
    var amount: Money
    var fees: Int64
    var taxes: Int64
    var place: String
    var note: String

    var kindTitle: String { kind.title }
    /// Signed share movement: + in, − out, 0 for dividends and other cash bookings.
    var signedShares: Int64 { kind == .securityTransfer ? 0 : kind.sharesSign * shares.raw }

    /// Newest first.
    static func rows(_ ledger: Ledger, securityID: UUID) -> [SecurityTransactionRow] {
        ledger.transactions(forSecurity: securityID).reversed().map { t in
            var place = [String]()
            if let depot = t.depotID.flatMap({ ledger.depot($0)?.name }) { place.append(depot) }
            if let target = t.counterDepotID.flatMap({ ledger.depot($0)?.name }) { place.append("→ " + target) }
            if place.isEmpty, let account = t.accountID.flatMap({ ledger.account($0)?.name }) { place.append(account) }
            return SecurityTransactionRow(
                id: t.id, date: t.date, kind: t.kind, shares: t.shares, price: t.shares.isZero ? nil : t.grossPrice,
                amount: t.amount, fees: t.fees, taxes: t.taxes, place: place.joined(separator: " "), note: t.note)
        }
    }
}

// MARK: - Stock split preview

struct SplitQuery: Hashable, Sendable {
    var securityID: UUID
    var day: Day
    var newShares: Int
    var oldShares: Int
}

/// What applying a split would change — computed with the engine's `StockSplit`, nothing is modified.
struct SplitPreview: Sendable {
    struct Sample: Sendable, Identifiable {
        let id: UUID
        var date: Day
        var kind: Transaction.Kind
        var before: Shares
        var after: Shares
    }

    var isValid = false
    var isRecorded = false
    var ratio = ""
    var adjustedPrices = 0
    var adjustedTransactions = 0
    var samples: [Sample] = []
    /// The quote right before the split day, before and after the adjustment.
    var priceBefore: Price?
    var priceAfter: Price?
    var currency: CurrencyCode = ""

    init(_ ledger: Ledger, query: SplitQuery) {
        guard let security = ledger.security(query.securityID),
              let split = StockSplit(securityID: query.securityID, day: query.day, newShares: query.newShares, oldShares: query.oldShares)
        else { return }
        isValid = true
        ratio = split.ratio
        currency = security.currency
        isRecorded = split.isRecorded(in: security)
        let transactions = ledger.transactions(forSecurity: security.id)
        let result = split.apply(to: security, transactions: transactions)
        adjustedPrices = result.adjustedPriceCount
        adjustedTransactions = result.adjustedTransactionIDs.count
        let adjusted = Set(result.adjustedTransactionIDs)
        let after = Dictionary(result.transactions.map { ($0.id, $0.shares) }, uniquingKeysWith: { first, _ in first })
        samples = transactions.reversed().filter { adjusted.contains($0.id) }.prefix(5).map {
            Sample(id: $0.id, date: $0.date, kind: $0.kind, before: $0.shares, after: after[$0.id] ?? $0.shares)
        }
        if let index = security.prices.index(onOrBefore: query.day.advanced(by: -1)) {
            priceBefore = security.prices[index].price
            priceAfter = result.security.prices.point(onOrBefore: query.day.advanced(by: -1))?.price
        }
    }
}
