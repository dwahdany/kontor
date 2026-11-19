import SwiftUI
import KontorUI

// Plain, Sendable values for the Trades screen. Everything here is built off the main actor inside
// `analysisTask` / `store.analyze` from the engine's `TradeReport` (`analysis.trades`) and
// `EarningsReport`; the views only format and lay out.

/// Which list of trades a model describes.
enum TradeKind: String, Sendable, Hashable {
    case closed, open
}

/// Winners / losers filter.
enum OutcomeFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all, winners, losers

    var id: String { rawValue }

    func title(_ kind: TradeKind) -> String {
        switch self {
        case .all: "All Results"
        case .winners: kind == .closed ? "Winners" : "In Profit"
        case .losers: kind == .closed ? "Losers" : "At a Loss"
        }
    }
}

/// Long-term / short-term filter, relative to the configurable threshold.
enum HoldingFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case longTerm = "long"
    case shortTerm = "short"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Any Holding Period"
        case .longTerm: "Long-Term"
        case .shortTerm: "Short-Term"
        }
    }
}

/// The holding periods after which a trade counts as long-term (tax rules differ by country).
enum LongTermThreshold {
    static let storageKey = "trades.longTermDays"
    static let defaultDays = 365
    static let presets: [Int] = [183, 365, 730, 1826, 3652]

    static func title(days: Int) -> String {
        switch days {
        case 183: "6 months"
        case 365: "1 year"
        case 730: "2 years"
        case 1826: "5 years"
        case 3652: "10 years"
        default: Fmt.duration(days: days)
        }
    }

    /// Long-term means held for more than the threshold.
    static func isLongTerm(holdingDays: Int, threshold: Int) -> Bool { holdingDays > threshold }
}

/// One trade as a table row.
struct TradeRow: Identifiable, Sendable, Hashable {
    struct ID: Hashable, Sendable {
        var closingTransactionID: UUID?
        var securityID: UUID
        var depotID: UUID
        var isShort: Bool
    }

    let id: ID
    var security: String
    var depot: String
    var opened: Day
    /// Closing day; the valuation day for open trades.
    var end: Day
    var holdingDays: Int
    var shares: Shares
    var isOpen: Bool
    var entryValue: Int64
    var exitValue: Int64
    var fees: Int64
    var taxes: Int64
    var gain: Int64
    var returnFraction: Double?
    /// Money-weighted annual return of the trade (engine `Trade.irr`); nil for same-day trades.
    var annualized: Double?
    var lotCount: Int

    var isShort: Bool { id.isShort }
    var securityID: UUID { id.securityID }
    var closingTransactionID: UUID? { id.closingTransactionID }

    // Sort keys (optionals are not Comparable).
    var returnKey: Double { returnFraction ?? -.infinity }
    var annualizedKey: Double { annualized ?? -.infinity }

    init(_ trade: Trade, security: String, depot: String) {
        id = ID(closingTransactionID: trade.closingTransactionID, securityID: trade.securityID, depotID: trade.depotID, isShort: trade.isShort)
        self.security = security
        self.depot = depot
        opened = trade.opened
        end = trade.end
        holdingDays = trade.holdingDays
        shares = trade.shares
        isOpen = trade.isOpen
        entryValue = trade.entryValue
        exitValue = trade.exitValue
        fees = trade.fees
        taxes = trade.taxes
        gain = trade.gain
        returnFraction = trade.returnFraction
        annualized = trade.irr
        lotCount = trade.lots.count
    }
}

/// Everything the rows depend on besides the document, scope and period.
struct TradeQuery: Hashable, Sendable {
    var kind: TradeKind
    var text = ""
    var outcome = OutcomeFilter.all
    var holding = HoldingFilter.all
    var thresholdDays = LongTermThreshold.defaultDays
    /// Closing year (closed trades) or opening year (open trades).
    var year: Int?
    var securityID: UUID?
    var depotID: UUID?
    var sortOrder: [KeyPathComparator<TradeRow>]

    /// True if anything but the sort order narrows the list.
    var isFiltering: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || outcome != .all || holding != .all || year != nil
            || securityID != nil || depotID != nil
    }
}

/// A bar chart's categories and values, ready for `BarSeriesChart`.
struct BarData: Sendable {
    var categories: [BarCategory] = []
    var values: [Double] = []
    var isEmpty: Bool { categories.isEmpty }
}

/// Chart inputs derived from the filtered trades.
struct TradeCharts: Sendable {
    /// Gain per closing year (or month for short periods); for open trades per opening year.
    var byPeriod = BarData()
    var byPeriodTitle = "Realized Gain by Year"
    /// Distribution of the trades' returns (fractions).
    var returns = Histogram([], targetBins: 20)
    /// Index of the fullest bin, for pinned tooltips.
    var fullestBin: Int?
    /// Running total of realized gains by closing day (minor units); empty for open trades.
    var cumulativeDays: [Day] = []
    var cumulativeValues: [Double] = []
    /// Average return per holding-period bucket (fractions).
    var byHolding = BarData()
}

/// A filtered, sorted list of trades with its statistics.
struct TradeListModel: Sendable {
    var kind: TradeKind
    var currency: CurrencyCode
    var interval: DayInterval
    var rows: [TradeRow]
    /// Trades of the scope and period before the filters.
    var totalCount: Int
    /// Engine statistics of the filtered trades.
    var statistics: TradeStatistics
    var longTermCount: Int
    var entryTotal: Int64
    var exitTotal: Int64
    /// Years offered by the year filter (newest first), from the unfiltered trades.
    var years: [Int]
    /// Depots offered by the depot filter, from the unfiltered trades.
    var depots: [NamedID]
    var charts: TradeCharts

    struct NamedID: Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
    }

    init(_ analysis: Analysis, query: TradeQuery) {
        let report = analysis.trades
        let ledger = analysis.ledger
        let source = query.kind == .closed ? report.closed : report.open
        kind = query.kind
        currency = report.currency
        interval = analysis.interval
        totalCount = source.count

        let filter = QuickFilter(query.text)
        var yearSet = Set<Int>()
        var depotSet = Set<UUID>()
        var kept: [Trade] = []
        var built: [TradeRow] = []
        kept.reserveCapacity(source.count)
        built.reserveCapacity(source.count)
        var names: [UUID: (name: String, extra: String)] = [:]
        var depotNames: [UUID: String] = [:]

        for trade in source {
            let year = Self.year(of: trade, kind: query.kind)
            yearSet.insert(year)
            depotSet.insert(trade.depotID)
            if let wanted = query.year, wanted != year { continue }
            if let wanted = query.securityID, wanted != trade.securityID { continue }
            if let wanted = query.depotID, wanted != trade.depotID { continue }
            switch query.outcome {
            case .all: break
            case .winners: if trade.gain <= 0 { continue }
            case .losers: if trade.gain >= 0 { continue }
            }
            let longTerm = LongTermThreshold.isLongTerm(holdingDays: trade.holdingDays, threshold: query.thresholdDays)
            switch query.holding {
            case .all: break
            case .longTerm: if !longTerm { continue }
            case .shortTerm: if longTerm { continue }
            }
            let security: (name: String, extra: String)
            if let known = names[trade.securityID] {
                security = known
            } else {
                let s = ledger.security(trade.securityID)
                security = (s?.name ?? "Unknown Security", [s?.ticker, s?.isin, s?.wkn].compactMap { $0 }.joined(separator: " "))
                names[trade.securityID] = security
            }
            let depot: String
            if let known = depotNames[trade.depotID] {
                depot = known
            } else {
                depot = ledger.depot(trade.depotID)?.name ?? "Unknown Depot"
                depotNames[trade.depotID] = depot
            }
            if !filter.isEmpty, !filter.matches(security.name, security.extra, depot) { continue }
            kept.append(trade)
            built.append(TradeRow(trade, security: security.name, depot: depot))
        }

        statistics = TradeStatistics(kept)
        longTermCount = kept.count { LongTermThreshold.isLongTerm(holdingDays: $0.holdingDays, threshold: query.thresholdDays) }
        entryTotal = kept.reduce(0) { $0 + $1.entryValue }
        exitTotal = kept.reduce(0) { $0 + $1.exitValue }
        years = yearSet.sorted(by: >)
        depots = depotSet
            .map { NamedID(id: $0, name: ledger.depot($0)?.name ?? "Unknown Depot") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        charts = Self.charts(kept, kind: query.kind, interval: analysis.interval)
        rows = built.sorted(using: query.sortOrder)
    }

    private static func year(of trade: Trade, kind: TradeKind) -> Int {
        kind == .closed ? trade.end.year : trade.opened.year
    }

    // MARK: Charts

    /// Holding-period buckets of the "return by holding period" chart: upper bound in days (exclusive).
    static let holdingBuckets: [(label: String, detail: String, upTo: Int)] = [
        ("< 1 mo", "Held less than 1 month", 31),
        ("1–3 mo", "Held 1 to 3 months", 92),
        ("3–12 mo", "Held 3 to 12 months", 366),
        ("1–2 y", "Held 1 to 2 years", 731),
        ("2–5 y", "Held 2 to 5 years", 1827),
        ("> 5 y", "Held more than 5 years", Int.max),
    ]

    private static func charts(_ trades: [Trade], kind: TradeKind, interval: DayInterval) -> TradeCharts {
        var charts = TradeCharts()
        guard !trades.isEmpty else { return charts }

        // Gain per year — per month when everything falls into at most two calendar years of a short period.
        var perYear: [Int: Int64] = [:]
        for t in trades { perYear[year(of: t, kind: kind), default: 0] += t.gain }
        let firstYear = perYear.keys.min()!, lastYear = perYear.keys.max()!
        let monthly = kind == .closed && interval.dayCount <= 400
        if monthly {
            var perMonth: [Int: Int64] = [:]
            for t in trades { perMonth[t.end.year * 12 + t.end.month - 1, default: 0] += t.gain }
            let first = min(interval.firstDay, interval.end), last = interval.end
            let from = first.year * 12 + first.month - 1, to = last.year * 12 + last.month - 1
            let spansYears = first.year != last.year
            for key in from...max(from, to) {
                charts.byPeriod.categories.append(.month(year: key / 12, month: key % 12 + 1, showsYear: spansYears && (key % 12 == 0 || key == from)))
                charts.byPeriod.values.append(Double(perMonth[key] ?? 0))
            }
            charts.byPeriodTitle = "Realized Gain by Month"
        } else {
            for year in firstYear...lastYear {
                charts.byPeriod.categories.append(.year(year))
                charts.byPeriod.values.append(Double(perYear[year] ?? 0))
            }
            charts.byPeriodTitle = kind == .closed ? "Realized Gain by Year" : "Unrealized Gain by Year Opened"
        }

        // Distribution of returns.
        charts.returns = Histogram(trades.compactMap(\.returnFraction), targetBins: 20)
        charts.fullestBin = charts.returns.bins.max { $0.count < $1.count }?.id

        // Running total of realized gains (closed trades arrive in closing order).
        if kind == .closed {
            var total: Int64 = 0
            let start = min(interval.start, trades[0].end.advanced(by: -1))
            charts.cumulativeDays = [start]
            charts.cumulativeValues = [0]
            for t in trades.sorted(by: { $0.end < $1.end }) {
                total += t.gain
                if charts.cumulativeDays.last == t.end {
                    charts.cumulativeValues[charts.cumulativeValues.count - 1] = Double(total)
                } else {
                    charts.cumulativeDays.append(t.end)
                    charts.cumulativeValues.append(Double(total))
                }
            }
            if let last = charts.cumulativeDays.last, last < interval.end {
                charts.cumulativeDays.append(interval.end)
                charts.cumulativeValues.append(Double(total))
            }
        }

        // Average return per holding-period bucket (engine statistics per bucket).
        var buckets = [[Trade]](repeating: [], count: holdingBuckets.count)
        for t in trades {
            let index = holdingBuckets.firstIndex { t.holdingDays < $0.upTo } ?? holdingBuckets.count - 1
            buckets[index].append(t)
        }
        for (bucket, members) in zip(holdingBuckets, buckets) {
            let count = members.count
            charts.byHolding.categories.append(BarCategory(
                id: bucket.label, label: bucket.label,
                detail: "\(bucket.detail) · \(Fmt.integer(count)) \(count == 1 ? "trade" : "trades")"))
            charts.byHolding.values.append(TradeStatistics(members).averageReturn ?? 0)
        }
        return charts
    }
}

// MARK: - Trade details (inspector)

/// One trade with its matched lots.
struct TradeDetail: Sendable, Identifiable {
    struct Lot: Sendable, Identifiable {
        var id: Int
        var opened: Day
        var shares: Shares
        var entryValue: Int64
        /// Entry value per share in the reporting currency.
        var entryPrice: Price?
        /// Days from this lot's acquisition to the end of the trade.
        var holdingDays: Int
    }

    var row: TradeRow
    var currency: CurrencyCode
    var lots: [Lot]
    var gainAfterTaxes: Int64
    /// `Trade.annualizedReturn`: the simple return expressed per year.
    var simpleAnnualized: Double?
    var id: TradeRow.ID { row.id }

    init(_ trade: Trade, ledger: Ledger, currency: CurrencyCode) {
        row = TradeRow(
            trade, security: ledger.security(trade.securityID)?.name ?? "Unknown Security",
            depot: ledger.depot(trade.depotID)?.name ?? "Unknown Depot")
        self.currency = currency
        gainAfterTaxes = trade.gainAfterTaxes
        simpleAnnualized = trade.annualizedReturn
        lots = trade.lots.enumerated().map { index, lot in
            Lot(id: index, opened: lot.opened, shares: lot.shares, entryValue: lot.entryValue,
                entryPrice: Price(minor: lot.entryValue, per: lot.shares), holdingDays: lot.opened.distance(to: trade.end))
        }
    }

    /// The trades a focus refers to: the trade closed by a transaction, or the open trades of a security.
    static func details(_ analysis: Analysis, focus: TradeFocus) -> [TradeDetail] {
        let report = analysis.trades
        let matches: [Trade]
        switch focus {
        case .closing(let id): matches = report.closed.filter { $0.closingTransactionID == id }
        case .open(let securityID): matches = report.open.filter { $0.securityID == securityID }
        }
        return matches.map { TradeDetail($0, ledger: analysis.ledger, currency: report.currency) }
    }
}

/// What the inspector shows, derived from `store.route.focus`.
enum TradeFocus: Hashable, Sendable {
    case closing(UUID)
    case open(securityID: UUID)
}

// MARK: - Tax years

/// One calendar year of the tax-year summary. All amounts in minor units of the reporting currency.
struct TaxYearRow: Identifiable, Sendable, Hashable {
    /// The year; 0 for the totals row.
    var id: Int
    var isTotal = false
    var trades = 0
    /// Σ gain of the winning trades closed in the year (after trading fees, before taxes).
    var gains: Int64 = 0
    /// Σ loss of the losing trades (negative).
    var losses: Int64 = 0
    /// gains + losses.
    var net: Int64 = 0
    var dividends: Int64 = 0
    /// Interest received minus interest charged.
    var interest: Int64 = 0
    /// All fees booked in the year (including trading fees, which `net` already contains).
    var fees: Int64 = 0
    /// All taxes booked in the year, net of refunds.
    var taxes: Int64 = 0

    var label: String { isTotal ? "Total" : String(id) }
}

struct TaxYearsModel: Sendable {
    var currency: CurrencyCode
    /// Newest year first; no totals row.
    var years: [TaxYearRow]
    var total: TaxYearRow

    var isEmpty: Bool { years.isEmpty }

    init(_ analysis: Analysis) {
        currency = analysis.currency
        var byYear: [Int: TaxYearRow] = [:]

        // Realized gains and losses: engine statistics of the trades closed in each calendar year.
        let closed = analysis.trades.closed
        for (year, trades) in Dictionary(grouping: closed, by: { $0.end.year }) {
            let stats = TradeStatistics(trades)
            var row = TaxYearRow(id: year)
            row.trades = stats.count
            row.gains = stats.grossProfit
            row.losses = -stats.grossLoss
            row.net = stats.totalGain
            byYear[year] = row
        }
        // Dividends, interest, fees and taxes: the engine's earnings report.
        let earnings = analysis.earnings
        for year in earnings.years where !year.total.isZero {
            var row = byYear[year.year] ?? TaxYearRow(id: year.year)
            row.dividends = year.total.dividends
            row.interest = year.total.interest - year.total.interestCharges
            row.fees = year.total.fees
            row.taxes = year.total.taxes
            byYear[year.year] = row
        }
        years = byYear.values.sorted { $0.id > $1.id }

        let stats = TradeStatistics(closed)
        var sum = TaxYearRow(id: 0, isTotal: true)
        sum.trades = stats.count
        sum.gains = stats.grossProfit
        sum.losses = -stats.grossLoss
        sum.net = stats.totalGain
        sum.dividends = earnings.total.dividends
        sum.interest = earnings.total.interest - earnings.total.interestCharges
        sum.fees = earnings.total.fees
        sum.taxes = earnings.total.taxes
        total = sum
    }

    /// The summary as CSV (RFC 4180, "." decimal separator, ISO currency code column) — oldest year first.
    func csv() -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        func amount(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: currency).decimalValue, locale: posix) }
        var lines = [["Year", "Closed Trades", "Realized Gains", "Realized Losses", "Net Realized", "Dividends", "Interest", "Fees", "Taxes Paid", "Currency"]]
        for row in years.reversed() + [total] {
            lines.append([
                row.label, String(row.trades), amount(row.gains), amount(row.losses), amount(row.net), amount(row.dividends),
                amount(row.interest), amount(row.fees), amount(row.taxes), currency,
            ])
        }
        return lines.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// The summary as TSV in the user's number format, for pasting into a spreadsheet.
    func tsv() -> String {
        func amount(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: currency).decimalValue) }
        return TSV.string(
            header: ["Year", "Closed Trades", "Realized Gains", "Realized Losses", "Net Realized", "Dividends", "Interest", "Fees", "Taxes Paid", "Currency"],
            rows: (years.reversed() + [total]).map { row in
                [row.label, String(row.trades), amount(row.gains), amount(row.losses), amount(row.net), amount(row.dividends),
                 amount(row.interest), amount(row.fees), amount(row.taxes), currency]
            })
    }

    private static func csvField(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacing("\"", with: "\"\"") + "\""
    }
}

// MARK: - Clipboard export of trades

enum TradeExport {
    static func tsv(_ rows: [TradeRow], kind: TradeKind, currency: CurrencyCode) -> String {
        func amount(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: currency).decimalValue) }
        func fraction(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return TSV.number(Decimal(value))
        }
        let header = [
            "Security", "Depot", "Direction", "Opened", kind == .closed ? "Closed" : "Valued", "Days Held", "Shares",
            kind == .closed ? "Entry Value" : "Cost", kind == .closed ? "Exit Value" : "Market Value", "Fees", "Taxes",
            "Gain", "Return", "Return p.a.", "Currency",
        ]
        return TSV.string(header: header, rows: rows.map { row in
            [row.security, row.depot, row.isShort ? "Short" : "Long", row.opened.iso, row.end.iso, String(row.holdingDays),
             TSV.number(row.shares.decimalValue), amount(row.entryValue), amount(row.exitValue), amount(row.fees), amount(row.taxes),
             amount(row.gain), fraction(row.returnFraction), fraction(row.annualized), currency]
        })
    }
}
