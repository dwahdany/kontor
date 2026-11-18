import Foundation
import KontorModel

/// A round trip in one security and depot: shares that were acquired and later disposed of (a
/// *closed* trade), or shares still held on the report day (an *open* trade, valued at market).
///
/// Trades are derived from the tax lots of `Settings.costMethod`:
/// * **Closed:** every closing transaction (sell, outbound delivery, or the purchase that covers a
///   short position) yields one trade made of the lots it consumed — FIFO: the oldest lots first;
///   average: the pooled position.
/// * **Open:** one trade per (security, depot) with the lots still held.
///
/// Lots moved between depots by a `securityTransfer` keep their original acquisition day and cost.
/// All amounts are minor units of the reporting currency and already multiplied by the scope weight;
/// share counts are never weighted.
public struct Trade: Sendable, Hashable, Identifiable {
    /// Stable identity: the closing transaction (nil for open trades) and the holding.
    public struct ID: Sendable, Hashable {
        public let closingTransactionID: UUID?
        public let securityID: UUID
        public let depotID: UUID
    }

    /// One acquisition lot that is part of the trade.
    public struct Lot: Sendable, Hashable {
        /// Original acquisition day (the day the short sale was made for short trades).
        public let opened: Day
        public let shares: Shares
        /// The lot's part of `Trade.entryValue`.
        public let entryValue: Int64
    }

    public let securityID: UUID
    public let depotID: UUID
    /// The transaction that closed the trade; nil while the trade is open.
    public let closingTransactionID: UUID?
    /// True if the position was sold short first and covered later.
    public let isShort: Bool
    /// Number of shares (always positive).
    public let shares: Shares
    /// Day of the earliest lot.
    public let opened: Day
    /// Closing day, or the report day for open trades.
    public let end: Day
    public let isOpen: Bool
    /// Value at the opening side including fees: the purchase cost of a long trade, the net
    /// proceeds of the short sale of a short trade.
    public let entryValue: Int64
    /// Value at the closing side after fees: the net sale proceeds of a long trade, the cost of
    /// covering a short trade. For open trades the market value on the report day.
    public let exitValue: Int64
    /// Fees of opening and closing attributable to the traded shares (already included in
    /// `entryValue` / `exitValue`).
    public let fees: Int64
    /// Taxes of opening and closing attributable to the traded shares (*not* included in `gain`).
    public let taxes: Int64
    /// Internal rate of return (annual) of the trade's cash flows; equals the annualized return
    /// `(1 + return)^(365 / days) − 1` for a single lot. Short trades are treated as investing
    /// `entryValue` and receiving `entryValue + gain`. Nil for same-day trades.
    public let irr: Double?
    /// The lots making up the trade, oldest first.
    public let lots: [Lot]

    public var id: ID { ID(closingTransactionID: closingTransactionID, securityID: securityID, depotID: depotID) }
    /// Gain after fees, before taxes (unrealized for open trades).
    public var gain: Int64 { isShort ? entryValue - exitValue : exitValue - entryValue }
    public var gainAfterTaxes: Int64 { gain - taxes }
    /// `gain / entryValue`; nil without a positive entry value.
    public var returnFraction: Double? { entryValue > 0 ? Double(gain) / Double(entryValue) : nil }
    /// Days between the earliest lot and the end of the trade.
    public var holdingDays: Int { opened.distance(to: end) }
    /// `returnFraction` expressed per year: `(1 + return)^(365 / holdingDays) − 1`. Unlike `irr`
    /// this ignores that later lots were held for a shorter time. Nil for same-day trades.
    public var annualizedReturn: Double? {
        returnFraction.flatMap { Returns.annualize(total: $0, days: holdingDays) }
    }
}

/// Aggregate figures over a set of trades.
public struct TradeStatistics: Sendable, Hashable {
    public let count: Int
    /// Trades with a positive / negative gain (the rest broke even).
    public let winners: Int
    public let losers: Int
    /// `winners / count`; nil without trades.
    public let winRate: Double?
    /// Σ gain (after fees, before taxes).
    public let totalGain: Int64
    /// Σ gain of the winners.
    public let grossProfit: Int64
    /// Σ |gain| of the losers (positive number).
    public let grossLoss: Int64
    /// Mean gain of the winners, in minor units.
    public let averageGain: Double?
    /// Mean loss of the losers as a positive number, in minor units.
    public let averageLoss: Double?
    /// Mean of `Trade.returnFraction`.
    public let averageReturn: Double?
    public let averageHoldingDays: Double?
    /// `grossProfit / grossLoss`; nil if there are no losses.
    public let profitFactor: Double?
    public let totalFees: Int64
    public let totalTaxes: Int64

    public init(_ trades: some Sequence<Trade>) {
        var count = 0, winners = 0, losers = 0, returns = 0
        var total: Int64 = 0, profit: Int64 = 0, loss: Int64 = 0, fees: Int64 = 0, taxes: Int64 = 0
        var returnSum = 0.0, days = 0
        for t in trades {
            count += 1
            let gain = t.gain
            total += gain
            if gain > 0 {
                winners += 1
                profit += gain
            } else if gain < 0 {
                losers += 1
                loss -= gain
            }
            if let r = t.returnFraction {
                returnSum += r
                returns += 1
            }
            days += t.holdingDays
            fees += t.fees
            taxes += t.taxes
        }
        self.count = count
        self.winners = winners
        self.losers = losers
        winRate = count > 0 ? Double(winners) / Double(count) : nil
        totalGain = total
        grossProfit = profit
        grossLoss = loss
        averageGain = winners > 0 ? Double(profit) / Double(winners) : nil
        averageLoss = losers > 0 ? Double(loss) / Double(losers) : nil
        averageReturn = returns > 0 ? returnSum / Double(returns) : nil
        averageHoldingDays = count > 0 ? Double(days) / Double(count) : nil
        profitFactor = loss > 0 ? Double(profit) / Double(loss) : nil
        totalFees = fees
        totalTaxes = taxes
    }
}

/// Closed and open trades of a scope.
public struct TradeReport: Sendable {
    /// The day open trades are valued on.
    public let day: Day
    public let currency: CurrencyCode
    /// Closed trades in chronological order of the closing transaction.
    public let closed: [Trade]
    /// Open trades in the order of `Ledger.securities`.
    public let open: [Trade]
    /// Statistics of the closed trades.
    public let statistics: TradeStatistics
    public let diagnostics: [EngineDiagnostic]

    /// Closed followed by open trades of one security.
    public func trades(for securityID: UUID) -> [Trade] {
        closed.filter { $0.securityID == securityID } + open.filter { $0.securityID == securityID }
    }
}

extension Ledger {
    /// Trades of `scope`: positions closed after `closedAfter` (nil = ever) up to and including
    /// `day`, and the positions still open at the end of `day` valued at that day's prices.
    ///
    /// One replay of the ledger (≈ 0.3 ms per 5 000 transactions).
    public func trades(on day: Day, closedAfter start: Day? = nil, scope: Scope = .portfolio) -> TradeReport {
        let resolved = ResolvedScope(scope, ledger: self)
        var replay = LotReplay(ledger: self, scope: resolved)
        // Nothing closed on or before `start` is reported (an empty or reversed range reports no closed trades).
        if let start { replay.advance(through: min(start, day)) }
        replay.collectClosedLots = true
        replay.advance(through: day)

        // Closed: consecutive lots closed by the same transaction in the same holding form one trade.
        var closed: [Trade] = []
        let lots = replay.closedLots
        var i = 0
        while i < lots.count {
            let first = lots[i]
            var j = i + 1
            while j < lots.count, lots[j].transactionID == first.transactionID, lots[j].depotID == first.depotID,
                  lots[j].securityID == first.securityID, lots[j].isShort == first.isShort { j += 1 }
            var shares: Int64 = 0, entry: Int64 = 0, exit: Int64 = 0, fees: Int64 = 0, taxes: Int64 = 0
            var opened = first.opened
            var parts: [Trade.Lot] = []
            var flows: [Returns.CashFlow] = []
            parts.reserveCapacity(j - i)
            for lot in lots[i..<j] {
                let lotEntry = lot.isShort ? lot.proceeds : lot.cost
                shares += lot.shares.raw
                entry += lotEntry
                exit += lot.isShort ? lot.cost : lot.proceeds
                fees += lot.fees
                taxes += lot.taxes
                opened = min(opened, lot.opened)
                parts.append(Trade.Lot(opened: lot.opened, shares: lot.shares, entryValue: lotEntry))
                flows.append(.init(day: Int(lot.opened.rawValue), amount: -Double(lotEntry)))
            }
            // A short trade "invests" its entry value and gets it back plus the gain.
            flows.append(.init(day: Int(first.closed.rawValue), amount: Double(first.isShort ? 2 * entry - exit : exit)))
            closed.append(Trade(
                securityID: first.securityID, depotID: first.depotID, closingTransactionID: first.transactionID,
                isShort: first.isShort, shares: Shares(raw: shares), opened: opened, end: first.closed, isOpen: false,
                entryValue: entry, exitValue: exit, fees: fees, taxes: taxes, irr: Returns.irr(flows), lots: parts))
            i = j
        }

        // Open: one trade per holding, in ledger order.
        var diagnostics = replay.diagnostics
        var open: [Trade] = []
        let order = holdingSecurity.indices
            .filter { resolved.holdingWeight[$0] != 0 && !replay.books[$0].isEmpty }
            .sorted { (holdingSecurity[$0], holdingDepot[$0]) < (holdingSecurity[$1], holdingDepot[$1]) }
        for h in order {
            let w = resolved.holdingWeight[h]
            let s = Int(holdingSecurity[h])
            let book = replay.books[h]
            let short = book[0].shares < 0
            var shares: Int64 = 0, entry: Int64 = 0, fees: Int64 = 0, taxes: Int64 = 0
            var opened = book[0].day
            var parts: [Trade.Lot] = []
            var flows: [Returns.CashFlow] = []
            for lot in book where lot.shares != 0 {
                // Long: cost + fees. Short: gross proceeds (−cost) − fees.
                let lotEntry = FixedMath.weighted(short ? -lot.cost - lot.fees : lot.cost + lot.fees, w)
                shares += lot.shares
                entry += lotEntry
                fees += FixedMath.weighted(lot.fees, w)
                taxes += FixedMath.weighted(lot.taxes, w)
                opened = min(opened, lot.day)
                parts.append(Trade.Lot(
                    opened: Day(rawValue: lot.day), shares: Shares(raw: abs(lot.shares)), entryValue: lotEntry))
                flows.append(.init(day: Int(lot.day), amount: -Double(lotEntry)))
            }
            guard shares != 0 else { continue }
            let value = self.value(security: s, shares: shares, on: day.rawValue)
            if !value.valued {
                diagnostics.add(value.priceIndex < 0
                    ? .missingPrice(securityID: securities[s].id)
                    : .missingExchangeRate(from: securities[s].currency, to: reportingCurrency))
            }
            let market = FixedMath.weighted(value.rep, w)
            let exit = short ? -market : market
            flows.append(.init(day: Int(day.rawValue), amount: Double(short ? 2 * entry - exit : exit)))
            open.append(Trade(
                securityID: securities[s].id, depotID: depots[Int(holdingDepot[h])].id, closingTransactionID: nil,
                isShort: short, shares: Shares(raw: abs(shares)), opened: Day(rawValue: opened), end: day, isOpen: true,
                entryValue: entry, exitValue: exit, fees: fees, taxes: taxes, irr: Returns.irr(flows), lots: parts))
        }

        return TradeReport(
            day: day, currency: reportingCurrency, closed: closed, open: open,
            statistics: TradeStatistics(closed), diagnostics: diagnostics.items)
    }
}
