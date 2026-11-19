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
        /// Nil when the position cannot be valued.
        var value: Money?
    }

    /// Reporting currency of all money values.
    var currency: CurrencyCode
    var securityCurrency: CurrencyCode
    var interval: DayInterval

    // Position at the end of the period (normally today)
    var shares: Shares = .zero
    /// Nil when not held, or held but without a quote or exchange rate (see `valuationProblem`).
    var value: Money?
    var valueInSecurityCurrency: Money?
    /// Nil when a purchase could not be converted into the reporting currency (`isCostKnown`).
    var costBasis: Money?
    var purchasePrice: Price?
    /// The average purchase price in the security's own currency, when that is not the reporting currency.
    var purchasePriceInSecurityCurrency: Price?
    var unrealizedGain: Money?
    var unrealizedGainFraction: Double?
    var isValued = true
    /// Why a held position has no market value.
    var valuationProblem: ValuationProblem?
    /// False when a purchase was booked in a currency that has no rate to the reporting currency:
    /// the engine then counts it as 0, so cost basis, purchase price and gains are unknown.
    var isCostKnown = true
    /// False when a booking inside the period could not be converted (dividends, fees, proceeds).
    var arePeriodAmountsKnown = true
    var holdings: [Holding] = []

    // Reporting period
    var hasActivity = false
    var realizedGain: Int64 = 0
    var dividends: Int64 = 0
    var dividendCount = 0
    var fees: Int64 = 0
    var taxes: Int64 = 0
    var ttwror: Double?
    /// Only when the security was held during the whole period: the engine annualizes over the
    /// length of the period, which says nothing about a position that existed for a part of it.
    var ttwrorAnnualized: Double?
    var irr: Double?
    var transactionCount = 0

    var isHeld: Bool { !shares.isZero }

    /// One line for the cards when figures are missing ("No GBP → EUR exchange rate").
    var problemNote: String? {
        if let valuationProblem { return valuationProblem.message }
        if !isCostKnown || !arePeriodAmountsKnown { return "Some bookings have no exchange rate to \(currency)" }
        return nil
    }

    init(_ analysis: Analysis, securityID: UUID) {
        let ledger = analysis.ledger
        let reporting = analysis.currency
        let security = ledger.security(securityID)
        currency = reporting
        securityCurrency = security?.currency ?? reporting
        interval = analysis.interval
        let transactions = ledger.transactions(forSecurity: securityID)
        transactionCount = transactions.count
        isCostKnown = SecurityCost.isCostKnown(ledger, transactions: transactions, through: analysis.interval.end)
        arePeriodAmountsKnown = !transactions.contains {
            analysis.interval.contains($0.date) && SecurityCost.isUnconvertible($0, ledger)
        }
        if let position = analysis.snapshot.position(securityID) {
            shares = position.shares
            isValued = position.isValued
            valuationProblem = security.flatMap { ValuationProblem(position, security: $0, reportingCurrency: reporting) }
            // An unvalued position has a value of 0 in the engine — unknown, not zero.
            if position.isValued {
                value = position.value
                valueInSecurityCurrency = position.valueInSecurityCurrency
            }
            if isCostKnown {
                costBasis = position.costBasis
                purchasePrice = position.purchasePrice
                if let security, security.currency != reporting,
                   let own = SecurityCost.purchasePrice(ledger, security: security, position: position, on: analysis.interval.end) {
                    purchasePriceInSecurityCurrency = Price(own)
                }
            }
            if position.isValued, isCostKnown {
                unrealizedGain = position.unrealizedGain
                unrealizedGainFraction = position.unrealizedGainFraction
            }
            let valued = position.isValued
            holdings = position.holdings.map {
                Holding(id: $0.depotID, depot: ledger.depot($0.depotID)?.name ?? "Unknown depot", shares: $0.shares,
                        value: valued ? $0.value : nil)
            }
        }
        if let performance = analysis.security(securityID) {
            hasActivity = true
            realizedGain = performance.realizedGain
            dividends = performance.dividends
            dividendCount = performance.dividendCount
            fees = performance.fees
            taxes = performance.taxes
            // Returns computed from a value of 0 or from unconverted bookings are not returns.
            if isValued, arePeriodAmountsKnown {
                ttwror = performance.ttwror
                irr = performance.irr
                if Self.isHeldThroughout(transactions, interval: analysis.interval) {
                    ttwrorAnnualized = performance.ttwrorAnnualized
                }
            }
        }
    }

    /// Whether shares were held from the first day of `interval` to its end without a gap.
    static func isHeldThroughout(_ transactions: [Transaction], interval: DayInterval) -> Bool {
        var shares: Int64 = 0
        var started = false
        // Purchases on the first day count: the engine invests inflows at the start of the day.
        for t in transactions.sorted(by: Transaction.chronological) where t.date <= interval.end {
            if !started, t.date > interval.firstDay {
                guard shares > 0 else { return false }
                started = true
            }
            // A transfer between depots does not change the number of shares held.
            if t.kind != .securityTransfer { shares += t.kind.sharesSign * t.shares.raw }
            if started, shares <= 0 { return false }
        }
        return shares > 0
    }
}

// MARK: - Cost in the security's currency

/// Cost figures the engine does not expose: whether the cost basis is known at all, and the average
/// purchase price in the security's own currency (the engine reports it in the reporting currency).
enum SecurityCost {
    /// The booking has an amount in a currency without a rate to the reporting currency on its day;
    /// the engine leaves such amounts out (counts them as 0).
    static func isUnconvertible(_ transaction: Transaction, _ ledger: Ledger) -> Bool {
        let booked = transaction.amount.currency
        return transaction.amount.minor != 0 && booked != ledger.reportingCurrency
            && ledger.converter.rate(from: booked, to: ledger.reportingCurrency, on: transaction.date) == nil
    }

    /// False when a purchase or delivery up to `day` could not be converted into the reporting currency.
    static func isCostKnown(_ ledger: Ledger, transactions: [Transaction], through day: Day) -> Bool {
        !transactions.contains { $0.date <= day && $0.kind.sharesSign > 0 && isUnconvertible($0, ledger) }
    }

    /// Average purchase price per share (fees included) of the position open at the end of `day`,
    /// in the security's own currency — what was paid, independent of later exchange rates.
    /// `position` is the engine's position on that day. Nil when not held or not computable.
    static func purchasePrice(_ ledger: Ledger, security: Security, position: Snapshot.Position?, on day: Day) -> Double? {
        guard let position, position.shares.raw > 0 else { return nil }
        let reporting = ledger.reportingCurrency
        guard security.currency != reporting else { return position.purchasePrice?.doubleValue }
        let transactions = ledger.transactions(forSecurity: security.id)
        guard isCostKnown(ledger, transactions: transactions, through: day) else { return nil }
        if ledger.settings.costMethod == .average {
            return pooledPurchasePrice(ledger, security: security, transactions: transactions, on: day)
        }
        // FIFO: every open lot carries its cost in the reporting currency, converted at the rate of
        // its acquisition day — converting back at that same rate gives what was paid.
        var cost = 0.0, shares = 0.0
        for lot in ledger.openLots(on: day, scope: .security(security.id)) where lot.securityID == security.id {
            guard let own = ledger.converter.convert(minor: lot.cost, from: reporting, to: security.currency, on: lot.acquired) else { return nil }
            cost += Double(own) / Double(Scale.amount)
            shares += lot.shares.doubleValue
        }
        return shares > 0 ? cost / shares : nil
    }

    /// Moving-average method: one pool per depot, kept in the security's currency.
    private static func pooledPurchasePrice(_ ledger: Ledger, security: Security, transactions: [Transaction], on day: Day) -> Double? {
        var pools = [UUID: (shares: Double, cost: Double)]()
        for t in transactions.sorted(by: Transaction.chronological) where t.date <= day && !t.shares.isZero {
            guard let depot = t.depotID else { continue }
            let count = t.shares.doubleValue
            switch t.kind {
            case .buy, .deliveryIn:
                guard let cost = purchaseCost(of: t, in: security.currency, ledger) else { return nil }
                var pool = pools[depot] ?? (0, 0)
                pool.shares += count
                pool.cost += cost
                pools[depot] = pool
            case .sell, .deliveryOut, .securityTransfer:
                var pool = pools[depot] ?? (0, 0)
                let moved = pool.shares > 0 ? pool.cost * min(1, count / pool.shares) : 0
                pool.cost -= moved
                pool.shares = max(0, pool.shares - count)
                pools[depot] = pool
                if t.kind == .securityTransfer, let target = t.counterDepotID {
                    var other = pools[target] ?? (0, 0)
                    other.shares += count
                    other.cost += moved
                    pools[target] = other
                }
            default:
                break
            }
        }
        let shares = pools.values.reduce(0) { $0 + $1.shares }
        return shares > 0 ? pools.values.reduce(0) { $0 + $1.cost } / shares : nil
    }

    /// What a purchase cost in `currency`: gross value plus fees, without taxes (the engine's cost basis).
    private static func purchaseCost(of t: Transaction, in currency: CurrencyCode, _ ledger: Ledger) -> Double? {
        let booked = t.amount.currency
        if let gross = t.securityGross, gross.currency == currency {
            guard let fees = ledger.converter.convert(minor: t.fees, from: booked, to: currency, on: t.date) else { return nil }
            return Double(gross.minor + fees) / Double(Scale.amount)
        }
        guard let cost = ledger.converter.convert(minor: t.amount.minor - t.taxes, from: booked, to: currency, on: t.date) else { return nil }
        return Double(cost) / Double(Scale.amount)
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

    /// The day the chart ends: today — or the last quote when the quotes have ended (a retired
    /// security, or one whose quotes are stale), so that the chart shows the quotes there are
    /// instead of an empty period. The list's sparkline follows the same rule.
    static func anchor(for security: Security, today: Day) -> Day {
        guard let last = security.prices.lastDay, last < today else { return today }
        return security.isRetired || last.distance(to: today) > SecurityListModel.staleAfterDays ? last : today
    }

    /// The chart interval for a security: the period up to the anchor day, but never starting
    /// before the first quote.
    func interval(for security: Security, today: Day) -> DayInterval {
        let first = security.prices.firstDay
        var interval = period.interval(today: Self.anchor(for: security, today: today), firstTransactionDay: first)
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
    /// Price change over the range: from the last close on or before its start (the first quote
    /// when there is none) to the last quote shown — the list and the comparison measure the same way.
    var change: Double?
    var high: Extreme?
    var low: Extreme?
    /// Quotes dated inside the range.
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

        // Quotes inside the interval.
        var lower = 0, upper = prices.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if prices.days[mid] < interval.start.rawValue { lower = mid + 1 } else { upper = mid }
        }
        let end = (prices.index(onOrBefore: interval.end) ?? -1) + 1
        let range = lower < end ? lower..<end : lower..<lower
        quoteCount = range.count
        guard !range.isEmpty else { return }

        var days = range.map { Day(rawValue: prices.days[$0]) }
        let scale = Double(Scale.price)
        var closes = range.map { Double(prices.values[$0]) / scale }
        // The baseline is the last close on or before the start of the range. When the range starts
        // on a day without a quote (a weekend, a holiday), that close is carried to the start day,
        // so the line begins at the left edge and the change is measured from it.
        var firstIndex = range.lowerBound
        if days[0] > interval.start, lower > 0 {
            firstIndex = lower - 1
            days.insert(interval.start, at: 0)
            closes.insert(Double(prices.values[firstIndex]) / scale, at: 0)
        }
        if let first = closes.first, let last = closes.last, first > 0, closes.count > 1 { change = last / first - 1 }
        var hi = firstIndex, lo = firstIndex
        for i in firstIndex..<range.upperBound {
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
            comparisonName = other.displayName
            comparisonChange = reference.total
            change = own.total
            series = [
                TimeSeries(id: "price", security.displayName, start: interval.start, values: own.cumulative),
                TimeSeries(id: "compare", other.displayName, start: interval.start, values: reference.cumulative,
                           color: ChartColors.comparison, dashed: true),
            ]
            return
        }

        if let compareID = query.compareID, compareID != security.id, let other = ledger.security(compareID) {
            comparisonProblem = "“\(other.displayName)” has no quotes to compare with."
        }

        series = [TimeSeries(id: "price", "Price", days: days, values: closes, style: .area)]
        if query.showsAverage50, let average = Self.movingAverage(prices, window: 50, range: range) {
            series.append(TimeSeries(id: "ma50", "50-day average", days: average.days, values: average.values, color: ChartColors.series(1)))
        }
        if query.showsAverage200, let average = Self.movingAverage(prices, window: 200, range: range) {
            series.append(TimeSeries(id: "ma200", "200-day average", days: average.days, values: average.values, color: ChartColors.series(2)))
        }
        // The chart is in the security's currency, so the line is what was paid per share in that
        // currency — it only moves when shares are bought or sold, not with the exchange rate.
        if query.showsPurchasePrice, let first = days.first, let last = days.last, first < last,
           let level = SecurityCost.purchasePrice(ledger, security: security, position: analysis.snapshot.position(security.id), on: interval.end) {
            series.append(TimeSeries(id: "purchase", "Purchase price", days: [first, last], values: [level, level],
                                     style: .step, color: ChartColors.comparison, dashed: true))
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
    /// Gross price per share in `priceCurrency`: the security's currency when the booking records
    /// its value there (comparable with the quotes), else the booking's currency.
    var price: Price?
    var priceCurrency: CurrencyCode
    /// The same price in the booking's currency, when that differs from `priceCurrency`.
    var bookedPrice: Price?
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
            var price = t.shares.isZero ? nil : t.grossPrice
            var priceCurrency = t.amount.currency
            var bookedPrice: Price?
            if price != nil, let gross = t.securityGross, gross.currency != t.amount.currency,
               let own = Price(minor: gross.minor, per: t.shares) {
                bookedPrice = price
                price = own
                priceCurrency = gross.currency
            }
            return SecurityTransactionRow(
                id: t.id, date: t.date, kind: t.kind, shares: t.shares, price: price, priceCurrency: priceCurrency,
                bookedPrice: bookedPrice, amount: t.amount, fees: t.fees, taxes: t.taxes,
                place: place.joined(separator: " "), note: t.note)
        }
    }
}

// MARK: - Stock split preview

/// Which half of the history a split rewrites. Quotes from an automatic feed are usually
/// split-adjusted already, while the transactions were entered on the old basis — then only the
/// share counts must change (and the other way round for hand-entered quotes).
struct SplitAdjustments: Hashable, Sendable {
    var quotes = true
    var shares = true
}

extension PortfolioFile {
    /// A copy with `split` applied and its event recorded, rewriting only the selected halves of
    /// the history. Nil if the security does not exist.
    func applying(_ split: StockSplit, adjusting: SplitAdjustments, eventID: UUID = UUID()) -> PortfolioFile? {
        guard let index = securities.firstIndex(where: { $0.id == split.securityID }),
              var copy = applying(split, eventID: eventID) else { return nil }
        if !adjusting.quotes { copy.securities[index].prices = securities[index].prices }
        if !adjusting.shares { copy.transactions = transactions }
        return copy
    }
}

struct SplitQuery: Hashable, Sendable {
    var securityID: UUID
    var day: Day
    var newShares: Int
    var oldShares: Int
    var adjusting = SplitAdjustments()
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
        if query.adjusting.quotes { adjustedPrices = result.adjustedPriceCount }
        if query.adjusting.shares {
            adjustedTransactions = result.adjustedTransactionIDs.count
            let adjusted = Set(result.adjustedTransactionIDs)
            let after = Dictionary(result.transactions.map { ($0.id, $0.shares) }, uniquingKeysWith: { first, _ in first })
            samples = transactions.reversed().filter { adjusted.contains($0.id) }.prefix(5).map {
                Sample(id: $0.id, date: $0.date, kind: $0.kind, before: $0.shares, after: after[$0.id] ?? $0.shares)
            }
        }
        if query.adjusting.quotes, let index = security.prices.index(onOrBefore: query.day.advanced(by: -1)) {
            priceBefore = security.prices[index].price
            priceAfter = result.security.prices.point(onOrBefore: query.day.advanced(by: -1))?.price
        }
    }
}
