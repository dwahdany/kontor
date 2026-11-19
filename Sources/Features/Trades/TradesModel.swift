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
enum OutcomeFilter: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
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
enum HoldingFilter: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
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

/// The holding periods after which shares count as long-term (tax rules differ by country). The
/// split is made per lot: a trade whose lots straddle the threshold is partly long-term.
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

// MARK: - Lots

/// Exact proportional arithmetic on minor units and raw share counts.
enum Proportion {
    /// `value × numerator / denominator`, rounded half away from zero, with a 128-bit intermediate
    /// product (money in minor units × raw share counts overflows `Int64`).
    static func scale(_ value: Int64, _ numerator: Int64, _ denominator: Int64) -> Int64 {
        guard value != 0, numerator > 0, denominator > 0 else { return 0 }
        let divisor = UInt64(denominator)
        let product = value.magnitude.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < divisor else { return value < 0 ? -Int64.max : Int64.max }
        var (quotient, remainder) = divisor.dividingFullWidth(product)
        if remainder >= divisor - remainder, quotient < UInt64.max { quotient += 1 }
        let magnitude = Int64(clamping: quotient)
        return value < 0 ? -magnitude : magnitude
    }
}

/// One acquisition lot of a trade together with its part of the trade's closing side.
///
/// The engine reports entry values per lot but exit value, fees and taxes per trade; all lots of a
/// trade are closed (or valued) at the same price, so those are allocated pro rata by shares. The
/// allocation is cumulative, so the lots add up to the trade exactly.
struct LotSlice: Sendable, Hashable {
    var index: Int
    var opened: Day
    /// Unweighted share count, as the engine reports it.
    var shares: Shares
    var entryValue: Int64
    var exitValue: Int64
    var fees: Int64
    var taxes: Int64
    /// Days from this lot's acquisition to the end of the trade.
    var holdingDays: Int

    func gain(isShort: Bool) -> Int64 { isShort ? entryValue - exitValue : exitValue - entryValue }
}

extension Trade {
    /// The trade's lots with exit value, fees and taxes allocated pro rata by shares.
    var slices: [LotSlice] {
        let total = lots.reduce(Int64(0)) { $0 + $1.shares.raw }
        var result: [LotSlice] = []
        result.reserveCapacity(lots.count)
        var cumulative: Int64 = 0
        var exitDone: Int64 = 0, feesDone: Int64 = 0, taxesDone: Int64 = 0
        for (index, lot) in lots.enumerated() {
            cumulative += lot.shares.raw
            let isLast = index == lots.count - 1
            // The last lot takes the remainder, so the parts always add up to the trade.
            let exitUpTo = isLast ? exitValue : Proportion.scale(exitValue, cumulative, total)
            let feesUpTo = isLast ? fees : Proportion.scale(fees, cumulative, total)
            let taxesUpTo = isLast ? taxes : Proportion.scale(taxes, cumulative, total)
            result.append(LotSlice(
                index: index, opened: lot.opened, shares: lot.shares, entryValue: lot.entryValue, exitValue: exitUpTo - exitDone,
                fees: feesUpTo - feesDone, taxes: taxesUpTo - taxesDone, holdingDays: lot.opened.distance(to: end)))
            exitDone = exitUpTo
            feesDone = feesUpTo
            taxesDone = taxesUpTo
        }
        return result
    }
}

/// Running totals over the lots of one trade that pass the lot-level filters.
struct TradePart: Sendable {
    var lotCount = 0
    var shares: Int64 = 0
    var entry: Int64 = 0
    var exit: Int64 = 0
    var fees: Int64 = 0
    var taxes: Int64 = 0
    var opened: Day?
    /// Σ shares × holding days, for the share-weighted average holding period.
    var shareDays = 0.0
    var longTermLots = 0
    var longTermShares: Int64 = 0
    var longTermGain: Int64 = 0
    var flows: [Returns.CashFlow] = []

    mutating func add(_ lot: LotSlice, isShort: Bool, thresholdDays: Int) {
        lotCount += 1
        shares += lot.shares.raw
        entry += lot.entryValue
        exit += lot.exitValue
        fees += lot.fees
        taxes += lot.taxes
        opened = opened.map { min($0, lot.opened) } ?? lot.opened
        shareDays += Double(lot.shares.raw) * Double(lot.holdingDays)
        if LongTermThreshold.isLongTerm(holdingDays: lot.holdingDays, threshold: thresholdDays) {
            longTermLots += 1
            longTermShares += lot.shares.raw
            longTermGain += lot.gain(isShort: isShort)
        }
        flows.append(.init(day: Int(lot.opened.rawValue), amount: -Double(lot.entryValue)))
    }
}

/// How an open trade's market value came about.
enum TradeValuation: Sendable, Hashable {
    /// Valued with a quote and, for foreign securities, an exchange rate.
    case market
    /// The security has no quotes; the engine values it with the price of its own transactions.
    case derivedPrice
    /// No price at all: the engine reports a value of 0.
    case missingPrice
    /// No exchange rate from the security's currency: the engine reports a value of 0.
    case missingRate(CurrencyCode)

    var isValued: Bool {
        switch self {
        case .market, .derivedPrice: true
        case .missingPrice, .missingRate: false
        }
    }

    /// Why the value is missing or approximate; nil for a normal market valuation.
    func explanation(reportingCurrency: CurrencyCode) -> String? {
        switch self {
        case .market: nil
        case .derivedPrice: "No quotes for this security — valued at the price of its latest transaction"
        case .missingPrice: "No price is known for this security, so it cannot be valued"
        case .missingRate(let currency): "No exchange rate \(currency) → \(reportingCurrency) in this file, so the position cannot be valued"
        }
    }
}

/// The scope's weight per security in basis points (10 000 = counted in full). Classification
/// scopes count a security partially; the engine then scales money but not share counts.
struct ScopeWeights: Sendable {
    static let full = 10_000
    private var weights: [UUID: Int]?

    init(_ scope: Scope) {
        if case .weighted(let securities, _) = scope { weights = securities } else { weights = nil }
    }

    subscript(securityID: UUID) -> Int {
        guard let weights else { return Self.full }
        return min(max(weights[securityID] ?? 0, 0), Self.full)
    }
}

// MARK: - Rows

/// One trade — or, while a lot-level filter is active, the matching lots of one trade — as a table row.
struct TradeRow: Identifiable, Sendable, Hashable {
    struct ID: Hashable, Sendable {
        var closingTransactionID: UUID?
        var securityID: UUID
        var depotID: UUID
        var isShort: Bool
    }

    enum Term: Sendable, Hashable {
        case longTerm, shortTerm, mixed
    }

    let id: ID
    var security: String
    var depot: String
    /// Acquisition day of the oldest lot.
    var opened: Day
    /// Closing day; the valuation day for open trades.
    var end: Day
    /// Share-weighted average holding period of the lots, in days (what "Held" shows and sorts by).
    var holdingDays: Int
    /// Days since the oldest lot was acquired.
    var oldestDays: Int
    /// Unweighted share count (what a sale would have to name).
    var shares: Shares
    /// Scope weight of the security in basis points.
    var weight: Int
    var isOpen: Bool
    var entryValue: Int64
    /// 0 when the trade could not be valued.
    var exitValue: Int64
    var fees: Int64
    var taxes: Int64
    /// Gain after fees, before taxes; 0 when the trade could not be valued.
    var gain: Int64
    var returnFraction: Double?
    /// Money-weighted annual return (IRR) of the cash flows; nil for same-day and unvalued trades.
    var annualized: Double?
    /// Lots in this row, and in the whole trade (they differ while a lot-level filter is active).
    var lotCount: Int
    var totalLots: Int
    /// Lots held longer than the long-term threshold, and their part of `gain`.
    var longTermLots: Int
    var longTermGain: Int64
    /// Part of `shares` in long-term lots (0…1).
    var longTermShare: Double
    var valuation: TradeValuation

    var isShort: Bool { id.isShort }
    var securityID: UUID { id.securityID }
    var closingTransactionID: UUID? { id.closingTransactionID }
    var isValued: Bool { valuation.isValued }
    /// True if the row shows only some of the trade's lots.
    var isPartial: Bool { lotCount < totalLots }
    /// Share count multiplied by the scope weight — consistent with the (weighted) money columns.
    var countedShares: Shares { Shares(raw: Proportion.scale(shares.raw, Int64(weight), Int64(ScopeWeights.full))) }

    var term: Term {
        longTermLots == 0 ? .shortTerm : longTermLots == lotCount ? .longTerm : .mixed
    }

    // Sort keys (optionals are not Comparable).
    var returnKey: Double { returnFraction ?? -.infinity }
    var annualizedKey: Double { annualized ?? -.infinity }

    /// A row for the lots collected in `part` (all lots of `trade`, or those passing the lot filters).
    init(_ trade: Trade, part: TradePart, security: String, depot: String, weight: Int = ScopeWeights.full, valuation: TradeValuation = .market) {
        id = ID(closingTransactionID: trade.closingTransactionID, securityID: trade.securityID, depotID: trade.depotID, isShort: trade.isShort)
        self.security = security
        self.depot = depot
        self.weight = weight
        self.valuation = valuation
        let isWhole = part.lotCount == trade.lots.count
        opened = part.opened ?? trade.opened
        end = trade.end
        oldestDays = opened.distance(to: trade.end)
        holdingDays = part.shares > 0 ? Int((part.shareDays / Double(part.shares)).rounded()) : oldestDays
        shares = isWhole ? trade.shares : Shares(raw: part.shares)
        isOpen = trade.isOpen
        entryValue = part.entry
        fees = part.fees
        taxes = part.taxes
        lotCount = part.lotCount
        totalLots = trade.lots.count
        longTermLots = part.longTermLots
        longTermShare = part.shares > 0 ? Double(part.longTermShares) / Double(part.shares) : 0
        if valuation.isValued {
            exitValue = part.exit
            gain = trade.isShort ? part.entry - part.exit : part.exit - part.entry
            returnFraction = part.entry > 0 ? Double(gain) / Double(part.entry) : nil
            longTermGain = part.longTermGain
            if isWhole {
                annualized = trade.irr
            } else {
                // Same convention as the engine: a short trade "invests" its entry value and gets it back plus the gain.
                var flows = part.flows
                flows.append(.init(day: Int(trade.end.rawValue), amount: Double(trade.isShort ? 2 * part.entry - part.exit : part.exit)))
                annualized = Returns.irr(flows)
            }
        } else {
            exitValue = 0
            gain = 0
            returnFraction = nil
            longTermGain = 0
            annualized = nil
        }
    }

    /// A row for the whole trade.
    init(_ trade: Trade, security: String, depot: String, thresholdDays: Int = LongTermThreshold.defaultDays, weight: Int = ScopeWeights.full,
         valuation: TradeValuation = .market) {
        var part = TradePart()
        for lot in trade.slices { part.add(lot, isShort: trade.isShort, thresholdDays: thresholdDays) }
        self.init(trade, part: part, security: security, depot: depot, weight: weight, valuation: valuation)
    }
}

/// Aggregate figures of the listed rows. Mirrors the engine's `TradeStatistics` (and equals it for
/// whole, valued trades), but also works for rows that show only some lots of a trade, leaves out
/// rows that could not be valued, and splits the gain by holding period per lot.
struct TradeFigures: Sendable, Hashable {
    /// All rows, including those without a valuation.
    var count = 0
    /// Rows with a valuation — the base of every gain figure.
    var valued = 0
    var winners = 0
    var losers = 0
    var totalGain: Int64 = 0
    var grossProfit: Int64 = 0
    /// Σ |gain| of the losers (positive).
    var grossLoss: Int64 = 0
    var totalFees: Int64 = 0
    var totalTaxes: Int64 = 0
    /// Part of `totalGain` earned by lots held longer than the long-term threshold.
    var longTermGain: Int64 = 0
    /// Entry and exit value of the long trades; short trades have proceeds and a liability there.
    var longEntry: Int64 = 0
    var longExit: Int64 = 0
    var shortCount = 0
    private var returnSum = 0.0
    private var returnCount = 0
    private var holdingDaySum = 0

    init(_ rows: some Sequence<TradeRow>) {
        for row in rows {
            count += 1
            totalFees += row.fees
            totalTaxes += row.taxes
            holdingDaySum += row.holdingDays
            if row.isShort { shortCount += 1 }
            guard row.isValued else { continue }
            valued += 1
            totalGain += row.gain
            longTermGain += row.longTermGain
            if row.gain > 0 {
                winners += 1
                grossProfit += row.gain
            } else if row.gain < 0 {
                losers += 1
                grossLoss -= row.gain
            }
            if let value = row.returnFraction {
                returnSum += value
                returnCount += 1
            }
            if !row.isShort {
                longEntry += row.entryValue
                longExit += row.exitValue
            }
        }
    }

    var unvalued: Int { count - valued }
    var shortTermGain: Int64 { totalGain - longTermGain }
    var winRate: Double? { valued > 0 ? Double(winners) / Double(valued) : nil }
    var averageGain: Double? { winners > 0 ? Double(grossProfit) / Double(winners) : nil }
    var averageLoss: Double? { losers > 0 ? Double(grossLoss) / Double(losers) : nil }
    var averageReturn: Double? { returnCount > 0 ? returnSum / Double(returnCount) : nil }
    /// Mean of the rows' share-weighted holding periods.
    var averageHoldingDays: Double? { count > 0 ? Double(holdingDaySum) / Double(count) : nil }
    var profitFactor: Double? { grossLoss > 0 ? Double(grossProfit) / Double(grossLoss) : nil }
}

/// Everything the rows depend on besides the document, scope and period.
struct TradeQuery: Hashable, Sendable {
    var kind: TradeKind
    var text = ""
    var outcome = OutcomeFilter.all
    /// Lot-level: keeps the lots on that side of the threshold (a trade can appear with part of its lots).
    var holding = HoldingFilter.all
    var thresholdDays = LongTermThreshold.defaultDays
    /// Closed trades: the closing year. Open trades: the purchase year of the lots (lot-level).
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
    /// Gain per closing year (or month for short periods); for open trades per purchase year of the lots.
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

/// Something about the data the user should know before trusting the figures.
struct TradeNotice: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case notValued, derivedPrices, excludedAmounts
    }

    var kind: Kind
    var message: String
    /// The securities concerned, for "Show" links.
    var securities: [TradeListModel.NamedID] = []
    var id: Kind { kind }
    var isWarning: Bool { kind != .derivedPrices }
}

/// A filtered, sorted list of trades with its statistics.
struct TradeListModel: Sendable {
    var kind: TradeKind
    var currency: CurrencyCode
    var interval: DayInterval
    var rows: [TradeRow]
    /// Changes whenever the identity or order of `rows` changes (stable within one launch).
    var rowsToken: Int
    /// Trades of the scope and period before the filters.
    var totalCount: Int
    /// Statistics of the filtered rows.
    var figures: TradeFigures
    /// Years offered by the year filter (newest first), from the unfiltered trades: closing years
    /// for closed trades, purchase years of the lots for open trades.
    var years: [Int]
    /// Depots offered by the depot filter, from the unfiltered trades.
    var depots: [NamedID]
    var charts: TradeCharts
    /// Data problems of the unfiltered trades (missing prices or exchange rates).
    var notices: [TradeNotice]
    /// True if the scope counts securities partially (a classification scope).
    var hasWeightedRows: Bool
    /// The lots behind each row; only collected for the CSV export.
    var lots: [TradeRow.ID: [LotSlice]] = [:]

    struct NamedID: Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
    }

    private struct SecurityInfo {
        var name: String
        var extra: String
        var weight: Int
        var valuation: TradeValuation
    }

    init(_ analysis: Analysis, query: TradeQuery, collectsLots: Bool = false) {
        let report = analysis.trades
        let ledger = analysis.ledger
        let source = query.kind == .closed ? report.closed : report.open
        let isOpen = query.kind == .open
        let weights = ScopeWeights(analysis.scope)
        kind = query.kind
        currency = report.currency
        interval = analysis.interval
        totalCount = source.count

        let unpriced = Set(report.diagnostics.compactMap { diagnostic -> UUID? in
            if case .missingPrice(let id) = diagnostic { id } else { nil }
        })
        let filter = QuickFilter(query.text)
        var yearSet = Set<Int>()
        var depotSet = Set<UUID>()
        var built: [TradeRow] = []
        built.reserveCapacity(source.count)
        var infos: [UUID: SecurityInfo] = [:]
        var depotNames: [UUID: String] = [:]
        var notValued: [UUID] = [], derived: [UUID] = []
        var openGainByYear: [Int: Int64] = [:]
        var weighted = false

        for trade in source {
            let info: SecurityInfo
            if let known = infos[trade.securityID] {
                info = known
            } else {
                let s = ledger.security(trade.securityID)
                var valuation = TradeValuation.market
                if isOpen, let s {
                    // The engine values such positions at 0 and only says so in its diagnostics.
                    if unpriced.contains(s.id) || ledger.price(of: s.id, on: report.day) == nil {
                        valuation = .missingPrice
                    } else if !ledger.converter.canConvert(from: s.currency, to: report.currency) {
                        valuation = .missingRate(s.currency)
                    } else if s.prices.isEmpty {
                        valuation = .derivedPrice
                    }
                    if !valuation.isValued { notValued.append(s.id) } else if valuation == .derivedPrice { derived.append(s.id) }
                }
                info = SecurityInfo(
                    name: s?.name ?? "Unknown Security", extra: [s?.ticker, s?.isin, s?.wkn].compactMap { $0 }.joined(separator: " "),
                    weight: weights[trade.securityID], valuation: valuation)
                infos[trade.securityID] = info
            }
            if info.weight != ScopeWeights.full { weighted = true }
            depotSet.insert(trade.depotID)
            if isOpen {
                for lot in trade.lots { yearSet.insert(lot.opened.year) }
            } else {
                yearSet.insert(trade.end.year)
                if let wanted = query.year, wanted != trade.end.year { continue }
            }
            if let wanted = query.securityID, wanted != trade.securityID { continue }
            if let wanted = query.depotID, wanted != trade.depotID { continue }
            let depot: String
            if let known = depotNames[trade.depotID] {
                depot = known
            } else {
                depot = ledger.depot(trade.depotID)?.name ?? "Unknown Depot"
                depotNames[trade.depotID] = depot
            }
            if !filter.isEmpty, !filter.matches(info.name, info.extra, depot) { continue }

            // Lot-level filters: the holding period, and for open trades the purchase year.
            let lotYear = isOpen ? query.year : nil
            var part = TradePart()
            var included: [LotSlice] = []
            for lot in trade.slices {
                if let lotYear, lot.opened.year != lotYear { continue }
                let isLong = LongTermThreshold.isLongTerm(holdingDays: lot.holdingDays, threshold: query.thresholdDays)
                switch query.holding {
                case .all: break
                case .longTerm: if !isLong { continue }
                case .shortTerm: if isLong { continue }
                }
                part.add(lot, isShort: trade.isShort, thresholdDays: query.thresholdDays)
                if isOpen || collectsLots { included.append(lot) }
            }
            guard part.lotCount > 0 else { continue }
            let row = TradeRow(trade, part: part, security: info.name, depot: depot, weight: info.weight, valuation: info.valuation)
            switch query.outcome {
            case .all: break
            case .winners: if !row.isValued || row.gain <= 0 { continue }
            case .losers: if !row.isValued || row.gain >= 0 { continue }
            }
            if isOpen, row.isValued {
                for lot in included { openGainByYear[lot.opened.year, default: 0] += lot.gain(isShort: trade.isShort) }
            }
            if collectsLots { lots[row.id] = included }
            built.append(row)
        }

        figures = TradeFigures(built)
        years = yearSet.sorted(by: >)
        depots = depotSet
            .map { NamedID(id: $0, name: ledger.depot($0)?.name ?? "Unknown Depot") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        charts = Self.charts(built, kind: query.kind, interval: analysis.interval, openGainByYear: openGainByYear)
        hasWeightedRows = weighted
        rows = built.sorted(using: query.sortOrder)
        var hasher = Hasher()
        for row in rows { hasher.combine(row.id) }
        rowsToken = hasher.finalize()

        func named(_ ids: [UUID]) -> [NamedID] {
            ids.map { NamedID(id: $0, name: infos[$0]?.name ?? "Unknown Security") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var notices: [TradeNotice] = []
        if !notValued.isEmpty {
            let reasons = Set(notValued.compactMap { infos[$0]?.valuation }).map { valuation -> String in
                if case .missingRate(let from) = valuation { "no exchange rate \(from) → \(report.currency)" } else { "no price" }
            }.sorted().joined(separator: ", ")
            notices.append(TradeNotice(
                kind: .notValued,
                message: "\(notValued.count == 1 ? "1 position" : "\(Fmt.integer(notValued.count)) positions") could not be valued (\(reasons)). Value, gain and return are not shown and the statistics leave \(notValued.count == 1 ? "it" : "them") out.",
                securities: named(notValued)))
        }
        if !derived.isEmpty {
            notices.append(TradeNotice(
                kind: .derivedPrices,
                message: "\(derived.count == 1 ? "1 position has" : "\(Fmt.integer(derived.count)) positions have") no quotes and \(derived.count == 1 ? "is" : "are") valued at the price of the latest transaction.",
                securities: named(derived)))
        }
        // Closed trades: purchases or sales booked in a currency without an exchange rate are left out
        // of the amounts by the engine. (The diagnostic alone does not say whose — it is also raised
        // for open positions — so look at the transactions of the traded securities.)
        let hasMissingRate = report.diagnostics.contains { if case .missingExchangeRate = $0 { true } else { false } }
        if !isOpen, hasMissingRate {
            var currencies = Set<CurrencyCode>()
            var affected: [UUID] = []
            for id in infos.keys {
                let missing = Set(ledger.transactions(forSecurity: id).map(\.amount.currency))
                    .filter { !ledger.converter.canConvert(from: $0, to: report.currency) }
                if !missing.isEmpty {
                    currencies.formUnion(missing)
                    affected.append(id)
                }
            }
            if !affected.isEmpty {
                notices.append(TradeNotice(
                    kind: .excludedAmounts,
                    message: "No exchange rate \(currencies.sorted().map { "\($0) → \(report.currency)" }.joined(separator: ", ")): amounts booked in \(currencies.count == 1 ? "that currency" : "those currencies") are missing from the results of \(affected.count == 1 ? "1 security" : "\(Fmt.integer(affected.count)) securities").",
                    securities: named(affected)))
            }
        }
        self.notices = notices
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

    private static func charts(_ rows: [TradeRow], kind: TradeKind, interval: DayInterval, openGainByYear: [Int: Int64]) -> TradeCharts {
        var charts = TradeCharts()
        let valued = rows.filter(\.isValued)
        guard !valued.isEmpty else { return charts }

        // Gain per year. Closed trades: by closing year — per month when the period is short. Open
        // trades: by the year each lot was bought, so a savings plan is spread over its years.
        var perYear: [Int: Int64] = [:]
        if kind == .closed {
            for row in valued { perYear[row.end.year, default: 0] += row.gain }
        } else {
            perYear = openGainByYear
        }
        let monthly = kind == .closed && interval.dayCount <= 400
        if monthly {
            var perMonth: [Int: Int64] = [:]
            for row in valued { perMonth[row.end.year * 12 + row.end.month - 1, default: 0] += row.gain }
            let first = min(interval.firstDay, interval.end), last = interval.end
            let from = first.year * 12 + first.month - 1, to = last.year * 12 + last.month - 1
            let spansYears = first.year != last.year
            for key in from...max(from, to) {
                charts.byPeriod.categories.append(.month(year: key / 12, month: key % 12 + 1, showsYear: spansYears && (key % 12 == 0 || key == from)))
                charts.byPeriod.values.append(Double(perMonth[key] ?? 0))
            }
            charts.byPeriodTitle = "Realized Gain by Month"
        } else if let firstYear = perYear.keys.min(), let lastYear = perYear.keys.max() {
            for year in firstYear...lastYear {
                charts.byPeriod.categories.append(.year(year))
                charts.byPeriod.values.append(Double(perYear[year] ?? 0))
            }
            charts.byPeriodTitle = kind == .closed ? "Realized Gain by Year" : "Unrealized Gain by Purchase Year"
        }

        // Distribution of returns.
        charts.returns = Histogram(valued.compactMap(\.returnFraction), targetBins: 20)
        charts.fullestBin = charts.returns.bins.max { $0.count < $1.count }?.id

        // Running total of realized gains.
        if kind == .closed {
            let ordered = valued.sorted { $0.end < $1.end }
            var total: Int64 = 0
            let start = min(interval.start, ordered[0].end.advanced(by: -1))
            charts.cumulativeDays = [start]
            charts.cumulativeValues = [0]
            for row in ordered {
                total += row.gain
                if charts.cumulativeDays.last == row.end {
                    charts.cumulativeValues[charts.cumulativeValues.count - 1] = Double(total)
                } else {
                    charts.cumulativeDays.append(row.end)
                    charts.cumulativeValues.append(Double(total))
                }
            }
            if let last = charts.cumulativeDays.last, last < interval.end {
                charts.cumulativeDays.append(interval.end)
                charts.cumulativeValues.append(Double(total))
            }
        }

        // Average return per holding-period bucket (share-weighted holding period of each row).
        var sums = [Double](repeating: 0, count: holdingBuckets.count)
        var returnCounts = [Int](repeating: 0, count: holdingBuckets.count)
        var members = [Int](repeating: 0, count: holdingBuckets.count)
        for row in valued {
            let index = holdingBuckets.firstIndex { row.holdingDays < $0.upTo } ?? holdingBuckets.count - 1
            members[index] += 1
            if let value = row.returnFraction {
                sums[index] += value
                returnCounts[index] += 1
            }
        }
        for (index, bucket) in holdingBuckets.enumerated() {
            let count = members[index]
            charts.byHolding.categories.append(BarCategory(
                id: bucket.label, label: bucket.label,
                detail: "\(bucket.detail) · \(Fmt.integer(count)) \(count == 1 ? "trade" : "trades")"))
            charts.byHolding.values.append(returnCounts[index] > 0 ? sums[index] / Double(returnCounts[index]) : 0)
        }
        return charts
    }
}

// MARK: - Trade details (inspector)

/// What the inspector shows.
enum TradeFocus: Hashable, Sendable {
    /// The trade closed by a transaction.
    case closing(UUID)
    /// The open trades of a security — in one depot if the selected row names it, in every depot
    /// for a deep link that only names the security.
    case open(securityID: UUID, depotID: UUID?)

    /// `Route.Focus` cannot name a depot, so the screen also shares the selected row. The row only
    /// counts while the route focus still points at its security.
    static func resolve(_ focus: Route.Focus?, selectedRow: TradeRow.ID?) -> TradeFocus? {
        switch focus {
        case .transaction(let id):
            return .closing(id)
        case .security(let id):
            if let selectedRow, selectedRow.closingTransactionID == nil, selectedRow.securityID == id {
                return .open(securityID: id, depotID: selectedRow.depotID)
            }
            return .open(securityID: id, depotID: nil)
        default:
            return nil
        }
    }
}

/// One trade with its matched lots.
struct TradeDetail: Sendable, Identifiable {
    struct Lot: Sendable, Identifiable {
        var id: Int
        var opened: Day
        /// Shares counted in the scope (share count × scope weight).
        var shares: Shares
        var entryValue: Int64
        /// Entry value per counted share in the reporting currency.
        var entryPrice: Price?
        /// Days from this lot's acquisition to the end of the trade.
        var holdingDays: Int
        /// The transaction that acquired the lot, if it can be told apart.
        var transactionID: UUID?
    }

    /// The whole trade.
    var row: TradeRow
    var currency: CurrencyCode
    var lots: [Lot]
    var gainAfterTaxes: Int64
    /// `Trade.annualizedReturn`: the simple return expressed per year.
    var simpleAnnualized: Double?
    var id: TradeRow.ID { row.id }

    init(_ trade: Trade, ledger: Ledger, currency: CurrencyCode, thresholdDays: Int, weight: Int, valuation: TradeValuation) {
        row = TradeRow(
            trade, security: ledger.security(trade.securityID)?.name ?? "Unknown Security",
            depot: ledger.depot(trade.depotID)?.name ?? "Unknown Depot", thresholdDays: thresholdDays, weight: weight, valuation: valuation)
        self.currency = currency
        gainAfterTaxes = row.gain - trade.taxes
        simpleAnnualized = valuation.isValued ? trade.annualizedReturn : nil

        // The transactions that can have opened a lot, by day. Lots moved between depots keep their
        // acquisition day, so the search covers the security in every depot.
        var openings: [Day: [Transaction]] = [:]
        for transaction in ledger.transactions(forSecurity: trade.securityID) {
            let opens: Bool = switch transaction.kind {
            case .buy, .deliveryIn: !trade.isShort
            case .sell, .deliveryOut: trade.isShort
            default: false
            }
            if opens { openings[transaction.date, default: []].append(transaction) }
        }
        lots = trade.lots.enumerated().map { index, lot in
            let counted = Shares(raw: Proportion.scale(lot.shares.raw, Int64(weight), Int64(ScopeWeights.full)))
            let candidates = openings[lot.opened] ?? []
            let sameSize = candidates.filter { $0.shares == lot.shares }
            let transaction = candidates.count == 1 ? candidates[0] : sameSize.count == 1 ? sameSize[0] : nil
            return Lot(
                id: index, opened: lot.opened, shares: counted, entryValue: lot.entryValue,
                entryPrice: Price(minor: lot.entryValue, per: counted), holdingDays: lot.opened.distance(to: trade.end),
                transactionID: transaction?.id)
        }
    }

    /// The trades a focus refers to.
    static func details(_ analysis: Analysis, focus: TradeFocus, thresholdDays: Int = LongTermThreshold.defaultDays) -> [TradeDetail] {
        let report = analysis.trades
        let ledger = analysis.ledger
        let weights = ScopeWeights(analysis.scope)
        let matches: [Trade]
        switch focus {
        case .closing(let id):
            matches = report.closed.filter { $0.closingTransactionID == id }
        case .open(let securityID, let depotID):
            matches = report.open.filter { $0.securityID == securityID && (depotID == nil || $0.depotID == depotID) }
        }
        return matches.map { trade in
            var valuation = TradeValuation.market
            if trade.isOpen, let s = ledger.security(trade.securityID) {
                if ledger.price(of: s.id, on: report.day) == nil {
                    valuation = .missingPrice
                } else if !ledger.converter.canConvert(from: s.currency, to: report.currency) {
                    valuation = .missingRate(s.currency)
                } else if s.prices.isEmpty {
                    valuation = .derivedPrice
                }
            }
            return TradeDetail(
                trade, ledger: ledger, currency: report.currency, thresholdDays: thresholdDays, weight: weights[trade.securityID],
                valuation: valuation)
        }
    }
}

// MARK: - Actions on open trades

enum TradeActions {
    /// What closing a position today means.
    enum Close: Equatable, Sendable {
        case sell(Shares)
        /// Buy back a short position.
        case cover(Shares)
        /// Nothing is held today (the list may show an earlier day).
        case nothingHeld

        var isCover: Bool {
            if case .cover = self { true } else { false }
        }

        var title: String { isCover ? "Cover…" : "Sell…" }
    }

    /// Shares of a security in a depot at the end of `day` (negative: short), from the ledger's
    /// valid transactions. Open trades are listed as of the end of the reporting period, which may
    /// lie in the past — a new transaction has to start from what is held today.
    static func holding(_ ledger: Ledger, securityID: UUID, depotID: UUID, on day: Day) -> Shares {
        var shares = Shares.zero
        for transaction in ledger.transactions(forSecurity: securityID) where transaction.date <= day {
            shares += transaction.sharesEffect(on: depotID)
        }
        return shares
    }

    static func close(_ ledger: Ledger, securityID: UUID, depotID: UUID, today: Day) -> Close {
        let held = holding(ledger, securityID: securityID, depotID: depotID, on: today)
        return held.raw > 0 ? .sell(held) : held.raw < 0 ? .cover(-held) : .nothingHeld
    }

    /// The prefilled editor for closing the position, or nil if nothing is held today.
    static func closePrefill(_ close: Close, securityID: UUID, depotID: UUID, today: Day) -> TransactionPrefill? {
        switch close {
        case .sell(let shares): TransactionPrefill(kind: .sell, date: today, securityID: securityID, depotID: depotID, shares: shares)
        case .cover(let shares): TransactionPrefill(kind: .buy, date: today, securityID: securityID, depotID: depotID, shares: shares)
        case .nothingHeld: nil
        }
    }
}

// MARK: - Tax years

/// One calendar year of the tax-year summary. All amounts in minor units of the reporting currency.
struct TaxYearRow: Identifiable, Sendable, Hashable {
    /// The year; 0 for the totals row.
    var id: Int
    var isTotal = false
    /// The running year: its figures only cover the year so far.
    var isPartial = false
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

    /// Machine-readable label (exports).
    var label: String { isTotal ? "Total" : String(id) }
    /// Label for the table: the running year is marked as year to date.
    var displayLabel: String { isPartial ? "\(id) YTD" : label }
}

struct TaxYearsModel: Sendable {
    var currency: CurrencyCode
    /// Newest year first; no totals row.
    var years: [TaxYearRow]
    var total: TaxYearRow
    /// Currencies of bookings that could not be converted; the engine leaves such amounts out.
    var unconvertedCurrencies: [CurrencyCode] = []

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
        // Amounts without an exchange rate count as 0 in the engine; say so instead of showing short totals.
        let ledger = analysis.ledger
        var checked: [CurrencyCode: Bool] = [currency: true]
        for transaction in ledger.transactions {
            let code = transaction.amount.currency
            if checked[code] == nil { checked[code] = ledger.converter.canConvert(from: code, to: currency) }
        }
        unconvertedCurrencies = checked.filter { !$0.value }.keys.sorted()

        // The year the period ends in is still running unless the period ends on its last day.
        let end = analysis.interval.end
        if end < Day(year: end.year, month: 12, day: 31) { byYear[end.year]?.isPartial = true }
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
        return CSV.text(lines)
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
}

/// RFC 4180 text.
enum CSV {
    static func text(_ lines: [[String]]) -> String {
        lines.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacing("\"", with: "\"\"") + "\""
    }
}

// MARK: - Export of trades

enum TradeExport {
    /// The rows as TSV in the user's number format, for pasting into a spreadsheet. Figures that
    /// could not be determined (no valuation) stay empty.
    static func tsv(_ rows: [TradeRow], kind: TradeKind, currency: CurrencyCode) -> String {
        func amount(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: currency).decimalValue) }
        func fraction(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return TSV.number(Decimal(value))
        }
        let header = [
            "Security", "Depot", "Direction", "Opened", kind == .closed ? "Closed" : "Valued", "Avg. Days Held", "Lots", "Shares",
            kind == .closed ? "Entry Value" : "Cost", kind == .closed ? "Exit Value" : "Market Value", "Fees", "Taxes",
            "Gain", "Long-Term Gain", "Return", "Return per Year", "Currency",
        ]
        return TSV.string(header: header, rows: rows.map { row in
            [row.security, row.depot, row.isShort ? "Short" : "Long", row.opened.iso, row.end.iso, String(row.holdingDays), String(row.lotCount),
             TSV.number(row.countedShares.decimalValue), amount(row.entryValue), row.isValued ? amount(row.exitValue) : "", amount(row.fees),
             amount(row.taxes), row.isValued ? amount(row.gain) : "", row.isValued ? amount(row.longTermGain) : "",
             fraction(row.returnFraction), fraction(row.annualized), currency]
        })
    }

    static let csvHeader = [
        "Security", "ISIN", "Depot", "Direction", "Status", "Lot", "Lots", "Acquired", "Closed or Valued", "Days Held", "Term", "Shares",
        "Entry Value", "Exit Value", "Fees", "Taxes", "Gain", "Currency",
    ]

    /// The listed trades as CSV with one line per lot (RFC 4180, "." decimal separator) — the
    /// per-sale evidence behind the realized results. `model` must have been built with `collectsLots`.
    /// Exit value, fees and taxes of a trade are spread over its lots pro rata by shares.
    static func csv(_ model: TradeListModel, ledger: Ledger, thresholdDays: Int) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        func amount(_ minor: Int64) -> String { TSV.number(Money(minor: minor, currency: model.currency).decimalValue, locale: posix) }
        var lines = [csvHeader]
        for row in model.rows {
            let isin = ledger.security(row.securityID)?.isin ?? ""
            let lots = model.lots[row.id] ?? []
            for (number, lot) in lots.enumerated() {
                let shares = Shares(raw: Proportion.scale(lot.shares.raw, Int64(row.weight), Int64(ScopeWeights.full)))
                let isLong = LongTermThreshold.isLongTerm(holdingDays: lot.holdingDays, threshold: thresholdDays)
                lines.append([
                    row.security, isin, row.depot, row.isShort ? "Short" : "Long", row.isOpen ? "Open" : "Closed", String(number + 1),
                    String(lots.count), lot.opened.iso, row.end.iso, String(lot.holdingDays), isLong ? "Long-term" : "Short-term",
                    TSV.number(shares.decimalValue, locale: posix), amount(lot.entryValue), row.isValued ? amount(lot.exitValue) : "",
                    amount(lot.fees), amount(lot.taxes), row.isValued ? amount(lot.gain(isShort: row.isShort)) : "", model.currency,
                ])
            }
        }
        return CSV.text(lines)
    }
}
