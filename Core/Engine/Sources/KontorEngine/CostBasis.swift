import Foundation
import KontorModel

/// One tax lot of a holding. All fields are signed: a short position is a lot with negative
/// `shares` whose (negative) costs are the proceeds received for it. Amounts are *unweighted* and
/// in minor units; `…Sec` fields are in the security's currency, all others in the reporting currency.
struct Lot: Sendable {
    var shares: Int64
    /// Acquisition day (kept across security transfers).
    var day: Int32
    /// Gross cost (without fees and taxes), converted at the acquisition day's rate.
    var cost: Int64
    /// Acquisition fees; part of the cost basis.
    var fees: Int64
    /// Gross cost in the security's currency.
    var costSec: Int64
    /// Gross cost for the current reporting period: the market value at the period start for lots
    /// that existed then, otherwise equal to `cost`.
    var periodCost: Int64
    var periodCostSec: Int64
    /// Taxes paid with the opening transaction (never part of the cost basis; informational).
    var taxes: Int64 = 0

    /// Splits off `quantity` (absolute, ≤ |shares|) with a proportional part of every amount.
    /// Taking the whole lot takes the exact remainder, so parts always sum to the original.
    @inline(__always)
    mutating func split(_ quantity: Int64) -> Lot {
        let total = abs(shares)
        if quantity >= total {
            let all = self
            shares = 0; cost = 0; fees = 0; costSec = 0; periodCost = 0; periodCostSec = 0; taxes = 0
            return all
        }
        var part = self
        part.shares = shares > 0 ? quantity : -quantity
        part.cost = mulDiv(cost, quantity, total)
        part.fees = mulDiv(fees, quantity, total)
        part.costSec = mulDiv(costSec, quantity, total)
        part.periodCost = mulDiv(periodCost, quantity, total)
        part.periodCostSec = mulDiv(periodCostSec, quantity, total)
        part.taxes = mulDiv(taxes, quantity, total)
        shares -= part.shares
        cost -= part.cost
        fees -= part.fees
        costSec -= part.costSec
        periodCost -= part.periodCost
        periodCostSec -= part.periodCostSec
        taxes -= part.taxes
        return part
    }

    @inline(__always)
    mutating func merge(_ other: Lot) {
        shares += other.shares
        day = min(day, other.day)
        cost += other.cost
        fees += other.fees
        costSec += other.costSec
        periodCost += other.periodCost
        periodCostSec += other.periodCostSec
        taxes += other.taxes
    }
}

/// A (partially) closed lot: shares that were bought and later sold (or sold short and later
/// covered). Amounts are in the reporting currency, already multiplied by the scope weight.
public struct ClosedLot: Sendable, Hashable {
    public let securityID: UUID
    public let depotID: UUID
    public let shares: Shares
    /// Day the lot was opened (the original purchase day, also after depot transfers).
    public let opened: Day
    public let closed: Day
    /// True if the lot was a short position (opened by a sale, closed by a purchase).
    public let isShort: Bool
    /// Purchase cost including fees.
    public let cost: Int64
    /// Sale proceeds after fees (before taxes).
    public let proceeds: Int64
    /// Fees of opening and closing that are attributable to these shares.
    public let fees: Int64
    /// Taxes of the opening and the closing transaction attributable to these shares (not part of `gain`).
    public let taxes: Int64
    /// The closing transaction.
    public let transactionID: UUID

    /// Realized gain after fees, before taxes.
    public var gain: Int64 { proceeds - cost }
    public var holdingDays: Int { opened.distance(to: closed) }
}

/// An open tax lot. Amounts are in the reporting currency, already multiplied by the scope weight.
public struct OpenLot: Sendable, Hashable {
    public let securityID: UUID
    public let depotID: UUID
    /// Unweighted share count (negative for a short lot).
    public let shares: Shares
    public let acquired: Day
    /// Cost basis including fees (taxes excluded).
    public let cost: Int64
    /// The fee part of `cost`.
    public let fees: Int64
    /// Taxes paid on the acquisition (not part of `cost`).
    public let taxes: Int64
}

/// Event-driven replay of the ledger that maintains positions, balances and tax lots, and — once
/// `beginPeriod(at:)` was called — accumulates everything needed for a reconciling performance
/// breakdown of the period. This is the building block behind snapshots, cost bases, realized
/// gains, per-security records and (for later extensions) trades.
///
/// Cost-basis rules:
/// * Lots are kept per (security, depot). `Settings.costMethod` selects FIFO (individual lots,
///   oldest sold first) or moving average (one pooled lot per holding).
/// * Buy / deliveryIn: gross cost = amount − fees − taxes; fees are part of the cost basis, taxes
///   are not (they are reported separately).
/// * Sell / deliveryOut: gross proceeds = amount + fees + taxes; fees reduce the realized gain,
///   taxes do not.
/// * Foreign currencies: costs and proceeds are converted at the transaction day's rate.
/// * securityTransfer moves lots to the target depot with their cost and acquisition day; in the
///   target depot they queue up by acquisition day, so FIFO keeps selling the oldest shares first.
/// * Selling more than held opens a short lot (flagged with `.shortPosition`); a later purchase
///   covers it and realizes the difference.
struct LotReplay {
    let ledger: Ledger
    let scope: ResolvedScope
    let average: Bool
    var collectClosedLots = false

    private(set) var shares: [Int64]
    private(set) var balances: [Int64]
    private(set) var books: [[Lot]]
    private(set) var next = 0

    // Per holding, unweighted, since the period start.
    /// Realized gain since purchase, after fees.
    private(set) var realizedNet: [Int64]
    /// Realized gain against the period basis, before fees.
    private(set) var periodRealized: [Int64]
    /// The exchange-rate part of `periodRealized`.
    private(set) var periodRealizedFX: [Int64]

    // Per security, weighted, since the period start.
    private(set) var dividends: [Int64]
    private(set) var fees: [Int64]
    private(set) var taxes: [Int64]
    private(set) var dividendCount: [Int32]
    private(set) var lastDividend: [Int64]
    private(set) var lastDividendDay: [Int32]
    private(set) var touched: [Bool]

    // Scope level, weighted, since the period start.
    private(set) var interest: Int64 = 0
    private(set) var otherFees: Int64 = 0
    private(set) var otherTaxes: Int64 = 0
    private(set) var transferSpread: Int64 = 0
    private(set) var deposits: Int64 = 0
    private(set) var withdrawals: Int64 = 0
    private(set) var deliveriesIn: Int64 = 0
    private(set) var deliveriesOut: Int64 = 0
    private(set) var transfersIn: Int64 = 0
    private(set) var transfersOut: Int64 = 0

    /// Per account: Σ of balance changes converted at each transaction day's rate (unweighted).
    private(set) var cashTally: [Int64]
    /// Per account: converted balance at the period start (unweighted).
    private(set) var startCash: [Int64]
    private(set) var initialValue: Int64 = 0
    private(set) var closedLots: [ClosedLot] = []
    var diagnostics = DiagnosticCollector()

    init(ledger: Ledger, scope: ResolvedScope) {
        self.ledger = ledger
        self.scope = scope
        self.average = ledger.settings.costMethod == .average
        let h = ledger.holdingSecurity.count, s = ledger.securities.count, a = ledger.accounts.count
        shares = [Int64](repeating: 0, count: h)
        balances = [Int64](repeating: 0, count: a)
        books = [[Lot]](repeating: [], count: h)
        realizedNet = [Int64](repeating: 0, count: h)
        periodRealized = realizedNet
        periodRealizedFX = realizedNet
        dividends = [Int64](repeating: 0, count: s)
        fees = dividends
        taxes = dividends
        dividendCount = [Int32](repeating: 0, count: s)
        lastDividend = dividends
        lastDividendDay = [Int32](repeating: 0, count: s)
        touched = [Bool](repeating: false, count: s)
        cashTally = [Int64](repeating: 0, count: a)
        startCash = cashTally
    }

    // MARK: Driving

    /// Applies all transactions dated on or before `day`.
    mutating func advance(through day: Day) {
        let entries = ledger.entries
        while next < entries.count, entries[next].day <= day.rawValue {
            process(entries[next])
            next += 1
        }
    }

    /// Starts a reporting period whose baseline is the end of `day`: applies everything up to
    /// `day`, re-bases every lot's period cost to its market value on `day` and clears all
    /// accumulators.
    mutating func beginPeriod(at day: Day) {
        advance(through: day)
        let d = day.rawValue
        for i in realizedNet.indices {
            realizedNet[i] = 0
            periodRealized[i] = 0
            periodRealizedFX[i] = 0
        }
        for i in dividends.indices {
            dividends[i] = 0
            fees[i] = 0
            taxes[i] = 0
            dividendCount[i] = 0
            lastDividend[i] = 0
            lastDividendDay[i] = 0
            touched[i] = false
        }
        interest = 0; otherFees = 0; otherTaxes = 0; transferSpread = 0
        deposits = 0; withdrawals = 0; deliveriesIn = 0; deliveriesOut = 0; transfersIn = 0; transfersOut = 0
        closedLots.removeAll()
        initialValue = 0

        for h in books.indices where !books[h].isEmpty {
            let s = Int(ledger.holdingSecurity[h])
            let value = ledger.value(security: s, shares: shares[h], on: d)
            var remainingShares = shares[h]
            var remainingRep = value.rep, remainingSec = value.sec
            for i in books[h].indices {
                let lotShares = books[h][i].shares
                let rep = remainingShares == 0 ? 0 : mulDiv(remainingRep, lotShares, remainingShares)
                let sec = remainingShares == 0 ? 0 : mulDiv(remainingSec, lotShares, remainingShares)
                books[h][i].periodCost = rep
                books[h][i].periodCostSec = sec
                remainingShares -= lotShares
                remainingRep -= rep
                remainingSec -= sec
            }
            initialValue += FixedMath.weighted(value.rep, scope.holdingWeight[h])
        }
        for a in balances.indices {
            cashTally[a] = 0
            startCash[a] = ledger.cashValue(account: a, balance: balances[a], on: d).rep
            initialValue += FixedMath.weighted(startCash[a], scope.accountWeight[a])
        }
    }

    // MARK: Transactions

    private mutating func process(_ e: Entry) {
        let a = Int(e.account), h = Int(e.holding), s = Int(e.security)
        if e.rateMissing {
            diagnostics.add(.missingExchangeRate(
                from: ledger.currencies[Int(e.currency)], to: ledger.reportingCurrency))
        }
        let amount = e.amountRep, fee = e.feesRep, tax = e.taxesRep
        if a >= 0 {
            balances[a] += e.cashDelta
            cashTally[a] += e.kind.cashSign * amount
        }
        if e.counterAccount >= 0 {
            balances[Int(e.counterAccount)] += e.counterCashDelta
            cashTally[Int(e.counterAccount)] += e.counterAmountRep
        }
        if h >= 0 { shares[h] += e.sharesDelta }
        if e.counterHolding >= 0 { shares[Int(e.counterHolding)] += e.shares }

        let positionWeight = scope.positionWeight(e)
        if s >= 0, positionWeight != 0 || (e.counterHolding >= 0 && scope.holdingWeight[Int(e.counterHolding)] != 0) {
            touched[s] = true // only bookings that concern the scope make the security show up in it
        }
        let accountWeight = a >= 0 ? scope.accountWeight[a] : 0

        switch e.kind {
        case .buy, .deliveryIn:
            let gross = amount - fee - tax
            apply(
                Lot(shares: e.shares, day: e.day, cost: gross, fees: fee, costSec: e.grossSec,
                    periodCost: gross, periodCostSec: e.grossSec, taxes: tax),
                to: h, entry: e)
            fees[s] += FixedMath.weighted(fee, positionWeight)
            taxes[s] += FixedMath.weighted(tax, positionWeight)
        case .sell, .deliveryOut:
            let gross = amount + fee + tax
            apply(
                Lot(shares: -e.shares, day: e.day, cost: -gross, fees: fee, costSec: -e.grossSec,
                    periodCost: -gross, periodCostSec: -e.grossSec, taxes: tax),
                to: h, entry: e)
            fees[s] += FixedMath.weighted(fee, positionWeight)
            taxes[s] += FixedMath.weighted(tax, positionWeight)
        case .dividend:
            let gross = FixedMath.weighted(amount + fee + tax, positionWeight)
            dividends[s] += gross
            fees[s] += FixedMath.weighted(fee, positionWeight)
            taxes[s] += FixedMath.weighted(tax, positionWeight)
            if positionWeight != 0 {
                dividendCount[s] += 1
                lastDividend[s] = gross
                lastDividendDay[s] = e.day
            }
        case .interest:
            interest += FixedMath.weighted(amount + fee + tax, accountWeight)
            otherFees += FixedMath.weighted(fee, accountWeight)
            otherTaxes += FixedMath.weighted(tax, accountWeight)
        case .interestCharge:
            interest -= FixedMath.weighted(amount, accountWeight)
        case .fee:
            if s >= 0 { fees[s] += FixedMath.weighted(amount, positionWeight) }
            else { otherFees += FixedMath.weighted(amount, accountWeight) }
        case .feeRefund:
            if s >= 0 { fees[s] -= FixedMath.weighted(amount, positionWeight) }
            else { otherFees -= FixedMath.weighted(amount, accountWeight) }
        case .tax:
            if s >= 0 { taxes[s] += FixedMath.weighted(amount, positionWeight) }
            else { otherTaxes += FixedMath.weighted(amount, accountWeight) }
        case .taxRefund:
            if s >= 0 { taxes[s] -= FixedMath.weighted(amount, positionWeight) }
            else { otherTaxes -= FixedMath.weighted(amount, accountWeight) }
        case .cashTransfer:
            // A cross-currency transfer credits the target with a value that may differ from what
            // the source paid (bank spread); the difference is a currency gain/loss of the target.
            transferSpread += FixedMath.weighted(
                e.counterAmountRep - amount, scope.accountWeight[Int(e.counterAccount)])
        case .securityTransfer:
            transfer(e)
        case .deposit, .withdrawal:
            break
        }

        let legs = scope.flowLegs(e, ledger)
        let flow = legs.position + legs.account
        if flow != 0 {
            switch e.kind {
            case .deposit, .withdrawal:
                if flow > 0 { deposits += flow } else { withdrawals -= flow }
            case .deliveryIn, .deliveryOut:
                if flow > 0 { deliveriesIn += flow } else { deliveriesOut -= flow }
            default:
                if flow > 0 { transfersIn += flow } else { transfersOut -= flow }
            }
        }
    }

    /// Adds a signed piece to a holding's book: opposite-signed lots are closed first (FIFO),
    /// the remainder opens a new lot (or is pooled under the average method).
    private mutating func apply(_ piece: Lot, to h: Int, entry e: Entry, keepingAcquisitionOrder: Bool = false) {
        var p = piece
        if p.shares == 0 {
            // No shares: the value cannot be carried in a lot, so it is realized immediately.
            let empty = Lot(shares: 0, day: e.day, cost: 0, fees: 0, costSec: 0, periodCost: 0, periodCostSec: 0)
            if p.cost != 0 || p.fees != 0 || p.periodCost != 0 { realize(lot: empty, piece: p, holding: h, entry: e) }
            return
        }
        // Lots that are consumed completely are counted and dropped in one go afterwards, so a
        // sale that closes k lots costs O(k + n) instead of O(k · n).
        var consumed = 0
        while p.shares != 0, consumed < books[h].count, (books[h][consumed].shares > 0) != (p.shares > 0) {
            let first = books[h][consumed]
            let lotSize = abs(first.shares), pieceSize = abs(p.shares)
            if pieceSize >= lotSize {
                consumed += 1
                let part = p.split(lotSize)
                realize(lot: first, piece: part, holding: h, entry: e)
            } else {
                let part = books[h][consumed].split(pieceSize)
                realize(lot: part, piece: p, holding: h, entry: e)
                p.shares = 0
            }
        }
        if consumed > 0 { books[h].removeFirst(consumed) }
        guard p.shares != 0 else { return }
        if p.shares < 0, books[h].isEmpty {
            diagnostics.add(.shortPosition(
                securityID: ledger.securities[Int(ledger.holdingSecurity[h])].id,
                depotID: ledger.depots[Int(ledger.holdingDepot[h])].id, day: Day(rawValue: e.day)))
        }
        if average, !books[h].isEmpty {
            books[h][0].merge(p)
        } else if keepingAcquisitionOrder, let last = books[h].last, last.day > p.day,
                  let index = books[h].firstIndex(where: { $0.day > p.day }) {
            // A transferred lot that is older than lots already in the target depot: FIFO means
            // "oldest acquisition first", so it queues up by its acquisition day.
            books[h].insert(p, at: index)
        } else {
            books[h].append(p)
        }
    }

    /// Books the gain of closing `lot` with the equally sized, opposite-signed `piece`.
    private mutating func realize(lot: Lot, piece: Lot, holding h: Int, entry e: Entry) {
        let gross = -(lot.cost + piece.cost)
        let lotFees = lot.fees + piece.fees
        realizedNet[h] += gross - lotFees
        let periodGross = -(lot.periodCost + piece.periodCost)
        periodRealized[h] += periodGross
        let s = Int(ledger.holdingSecurity[h])
        let currency = ledger.securityCurrency[s]
        if currency != 0 {
            let rate = ledger.rateToReporting(currency, on: e.day)
            if !rate.isNaN {
                let periodGrossSec = -(lot.periodCostSec + piece.periodCostSec)
                periodRealizedFX[h] += periodGross - FixedMath.convert(periodGrossSec, rate: rate)
            }
        }
        if collectClosedLots {
            let w = scope.holdingWeight[h]
            guard w != 0, lot.shares != 0 else { return }
            let long = lot.shares > 0
            let cost = long ? lot.cost + lot.fees : piece.cost + piece.fees
            let proceeds = long ? -piece.cost - piece.fees : -lot.cost - lot.fees
            closedLots.append(ClosedLot(
                securityID: ledger.securities[s].id, depotID: ledger.depots[Int(ledger.holdingDepot[h])].id,
                shares: Shares(raw: abs(lot.shares)), opened: Day(rawValue: lot.day), closed: Day(rawValue: e.day),
                isShort: !long, cost: FixedMath.weighted(cost, w), proceeds: FixedMath.weighted(proceeds, w),
                fees: FixedMath.weighted(lotFees, w), taxes: FixedMath.weighted(lot.taxes + piece.taxes, w),
                transactionID: ledger.transactions[Int(e.transaction)].id))
        }
    }

    /// Moves lots between depots, keeping cost and acquisition day. If the two holdings carry
    /// different scope weights the shares cross the scope boundary at market value: the period gain
    /// up to the transfer is realized on the source and the target starts at market value (the
    /// since-purchase cost basis is unaffected).
    private mutating func transfer(_ e: Entry) {
        var from = Int(e.holding), to = Int(e.counterHolding)
        var quantity = e.shares
        if quantity < 0 {
            swap(&from, &to)
            quantity = -quantity
        }
        guard from != to, quantity > 0 else { return }
        let s = Int(e.security)
        let total = quantity
        var pieces: [Lot] = []
        var moved = 0
        while quantity > 0, moved < books[from].count, books[from][moved].shares > 0 {
            let first = books[from][moved]
            if first.shares <= quantity {
                pieces.append(first)
                quantity -= first.shares
                moved += 1
            } else {
                pieces.append(books[from][moved].split(quantity))
                quantity = 0
            }
        }
        if moved > 0 { books[from].removeFirst(moved) }
        let rebase = scope.holdingWeight[from] != scope.holdingWeight[to]
        var market: (sec: Int64, rep: Int64) = (0, 0)
        if rebase || quantity > 0 {
            let value = ledger.value(security: s, shares: total, on: e.day)
            market = (value.sec, value.rep)
        }
        if quantity > 0 {
            // More shares transferred than held: the shortfall leaves a short lot behind and
            // arrives at market value.
            let rep = mulDiv(market.rep, quantity, total), sec = mulDiv(market.sec, quantity, total)
            apply(
                Lot(shares: -quantity, day: e.day, cost: -rep, fees: 0, costSec: -sec, periodCost: -rep, periodCostSec: -sec),
                to: from, entry: e)
            pieces.append(Lot(shares: quantity, day: e.day, cost: rep, fees: 0, costSec: sec, periodCost: rep, periodCostSec: sec))
        }
        if rebase {
            let currency = ledger.securityCurrency[s]
            let rate = ledger.rateToReporting(currency, on: e.day)
            var remainingShares = total, remainingRep = market.rep, remainingSec = market.sec
            for i in pieces.indices {
                let rep = mulDiv(remainingRep, pieces[i].shares, remainingShares)
                let sec = mulDiv(remainingSec, pieces[i].shares, remainingShares)
                remainingShares -= pieces[i].shares
                remainingRep -= rep
                remainingSec -= sec
                let gain = rep - pieces[i].periodCost
                periodRealized[from] += gain
                if currency != 0, !rate.isNaN {
                    periodRealizedFX[from] += gain - FixedMath.convert(sec - pieces[i].periodCostSec, rate: rate)
                }
                pieces[i].periodCost = rep
                pieces[i].periodCostSec = sec
            }
        }
        for piece in pieces { apply(piece, to: to, entry: e, keepingAcquisitionOrder: true) }
    }

    // MARK: Reading state

    struct HoldingState {
        var shares: Int64 = 0
        /// Unweighted market value in the security's / the reporting currency.
        var valueSec: Int64 = 0
        var value: Int64 = 0
        var priceIndex = -1
        var valued = false
        /// Σ lot cost + fees (cost basis since purchase).
        var cost: Int64 = 0
        var fees: Int64 = 0
        var periodCost: Int64 = 0
        var periodCostSec: Int64 = 0
    }

    /// State of a holding valued on `day` (which should be the day the replay was advanced to).
    func holdingState(_ h: Int, on day: Int32) -> HoldingState {
        var state = HoldingState()
        state.shares = shares[h]
        for lot in books[h] {
            state.cost += lot.cost + lot.fees
            state.fees += lot.fees
            state.periodCost += lot.periodCost
            state.periodCostSec += lot.periodCostSec
        }
        if shares[h] != 0 {
            let v = ledger.value(security: Int(ledger.holdingSecurity[h]), shares: shares[h], on: day)
            state.valueSec = v.sec
            state.value = v.rep
            state.priceIndex = v.priceIndex
            state.valued = v.valued
        }
        return state
    }

    /// Open lots of all in-scope holdings (weighted costs).
    func openLots() -> [OpenLot] {
        var out: [OpenLot] = []
        for h in books.indices {
            let w = scope.holdingWeight[h]
            guard w != 0 else { continue }
            let securityID = ledger.securities[Int(ledger.holdingSecurity[h])].id
            let depotID = ledger.depots[Int(ledger.holdingDepot[h])].id
            for lot in books[h] {
                out.append(OpenLot(
                    securityID: securityID, depotID: depotID, shares: Shares(raw: lot.shares),
                    acquired: Day(rawValue: lot.day), cost: FixedMath.weighted(lot.cost + lot.fees, w),
                    fees: FixedMath.weighted(lot.fees, w), taxes: FixedMath.weighted(lot.taxes, w)))
            }
        }
        return out
    }
}

extension Ledger {
    /// Open tax lots at the end of `day` for the holdings in `scope`, per `Settings.costMethod`
    /// (FIFO: one lot per purchase; average: one pooled lot per security and depot).
    public func openLots(on day: Day, scope: Scope = .portfolio) -> [OpenLot] {
        var replay = LotReplay(ledger: self, scope: ResolvedScope(scope, ledger: self))
        replay.advance(through: day)
        return replay.openLots()
    }

    /// Lots closed within `interval` (or ever, up to `through`, if `interval` is nil), in
    /// chronological order of the closing transaction. The basis for trade lists and tax reports.
    public func closedLots(in interval: DayInterval? = nil, through day: Day? = nil, scope: Scope = .portfolio) -> [ClosedLot] {
        var replay = LotReplay(ledger: self, scope: ResolvedScope(scope, ledger: self))
        if let interval {
            replay.advance(through: interval.start)
            replay.collectClosedLots = true
            replay.advance(through: interval.end)
        } else {
            replay.collectClosedLots = true
            replay.advance(through: day ?? lastTransactionDay ?? Day(rawValue: 0))
        }
        return replay.closedLots
    }
}
