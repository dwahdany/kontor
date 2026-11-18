import Foundation
import KontorModel

/// Trading cost schedule of a (fictional) broker.
enum FeeModel: Sendable {
    case none
    case flat(Int64)
    /// Basis points of the order volume, clamped to `min…max` (minor units).
    case percent(bp: Int64, min: Int64, max: Int64)

    func amount(for volume: Int64) -> Int64 {
        switch self {
        case .none: return 0
        case .flat(let fee): return fee
        case .percent(let bp, let low, let high): return Swift.min(Swift.max(mulDiv(volume, bp, 10_000), low), high)
        }
    }
}

/// Builds a ledger chronologically while tracking cash balances, share positions and cost bases, so
/// that every booking is consistent with the model's conventions and nothing ever goes negative.
///
/// Entities are addressed by their index in `securities` / `accounts` / `depots`. Every booking
/// method returns whether the booking was made; a booking that cannot be afforded (or would sell
/// shares that are not there) is skipped rather than violating an invariant.
struct Ledger {
    struct SecurityRef: Sendable {
        var id: UUID
        var currency: CurrencyCode
    }
    struct AccountRef: Sendable {
        var id: UUID
        var currency: CurrencyCode
    }

    let market: MarketSimulation
    /// Currency all `rates` are quoted against.
    let base: CurrencyCode
    /// Base → currency exchange rate paths.
    let rates: [CurrencyCode: FXPath]
    let securities: [SecurityRef]
    let accounts: [AccountRef]
    let depots: [UUID]

    /// Cash per account, minor units.
    private(set) var balance: [Int64]
    /// `Shares.raw` per depot and security.
    private(set) var held: [[Int64]]
    /// Cost basis per depot and security, in the currency the position was paid in.
    private(set) var cost: [[Int64]]
    private(set) var transactions: [Transaction] = []

    private var ids: SampleRandom
    /// Sequenced ids sort in booking order; otherwise ids are random and every booking gets a time of day.
    private let sequencedIDs: Bool
    private var cursor = Day(rawValue: .min)
    private var slot = 0

    init(
        market: MarketSimulation, base: CurrencyCode, rates: [CurrencyCode: FXPath], securities: [SecurityRef],
        accounts: [AccountRef], depots: [UUID], idSeed: UInt64, sequencedIDs: Bool = false, capacity: Int = 0
    ) {
        self.market = market
        self.base = base
        self.rates = rates
        self.securities = securities
        self.accounts = accounts
        self.depots = depots
        balance = [Int64](repeating: 0, count: accounts.count)
        held = [[Int64]](repeating: [Int64](repeating: 0, count: securities.count), count: depots.count)
        cost = held
        ids = SampleRandom(seed: idSeed)
        self.sequencedIDs = sequencedIDs
        transactions.reserveCapacity(capacity)
    }

    // MARK: Conversion

    /// Converts minor units between currencies at `day`'s rate.
    func convert(_ minor: Int64, from: CurrencyCode, to: CurrencyCode, on day: Day) -> Int64 {
        if from == to { return minor }
        var value = Double(minor)
        if from != base, let path = rates[from] { value /= path.rate(on: day) }
        if to != base, let path = rates[to] { value *= path.rate(on: day) }
        return Int64(value.rounded())
    }

    // MARK: Cash bookings

    /// Books a pure cash transaction (deposit, withdrawal, interest, fee, tax, refunds …).
    @discardableResult
    mutating func cash(
        _ kind: Transaction.Kind, on day: Day, account: Int, minor: Int64, taxes: Int64 = 0, security: Int? = nil,
        note: String = "", source: String? = nil
    ) -> Bool {
        let sign = kind.cashSign
        guard minor > 0, sign != 0, sign > 0 || balance[account] >= minor else { return false }
        balance[account] += sign * minor
        transactions.append(Transaction(
            id: nextID(), kind: kind, date: day, minuteOfDay: nextMinute(day), accountID: accounts[account].id, securityID: security.map { securities[$0].id },
            amount: Money(minor: minor, currency: accounts[account].currency), taxes: taxes, note: note, source: source
        ))
        return true
    }

    /// Moves cash between two accounts, converting at the day's rate when their currencies differ.
    @discardableResult
    mutating func transfer(on day: Day, from: Int, to: Int, minor: Int64, note: String = "") -> Bool {
        guard minor > 0, from != to, balance[from] >= minor else { return false }
        let source = accounts[from], target = accounts[to]
        let credited = convert(minor, from: source.currency, to: target.currency, on: day)
        guard credited > 0 else { return false }
        balance[from] -= minor
        balance[to] += credited
        transactions.append(Transaction(
            id: nextID(), kind: .cashTransfer, date: day, minuteOfDay: nextMinute(day), accountID: source.id, counterAccountID: target.id,
            amount: Money(minor: minor, currency: source.currency),
            counterAmount: source.currency == target.currency ? nil : Money(minor: credited, currency: target.currency),
            note: note
        ))
        return true
    }

    // MARK: Security bookings

    /// Buys `security` for (up to) `budget` — the total debit including fees — at the day's close.
    ///
    /// The order is scaled down to the cash available above `reserve`, and skipped when less than
    /// `minFill` of the budget can be afforded. `whole` restricts the order to whole shares.
    @discardableResult
    mutating func buy(
        on day: Day, security: Int, depot: Int, account: Int, budget: Int64, whole: Bool = false,
        fee: FeeModel = .none, reserve: Int64 = 0, minFill: Double = 0.4, note: String = "", source: String? = nil
    ) -> Bool {
        let available = balance[account] - reserve
        let total = min(budget, available)
        guard total > 0, Double(total) >= Double(budget) * minFill else { return false }
        let price = market.price(security, on: day)
        let securityCurrency = securities[security].currency, accountCurrency = accounts[account].currency
        let cross = securityCurrency != accountCurrency

        var fees = fee.amount(for: total)
        var shares = Shares.zero
        var grossSecurity: Int64 = 0 // in the security's currency
        var gross: Int64 = 0 // in the account's currency
        if whole {
            let oneShare = convert(price.value(of: Shares(raw: Scale.shares)), from: securityCurrency, to: accountCurrency, on: day)
            guard oneShare > 0 else { return false }
            var count = (total - fees) / oneShare
            while true {
                guard count >= 1 else { return false }
                shares = Shares(raw: count * Scale.shares)
                grossSecurity = price.value(of: shares)
                gross = convert(grossSecurity, from: securityCurrency, to: accountCurrency, on: day)
                fees = fee.amount(for: gross)
                if gross + fees <= available { break }
                count -= 1
            }
        } else {
            let net = convert(total - fees, from: accountCurrency, to: securityCurrency, on: day)
            guard net > 0 else { return false }
            shares = Shares(raw: mulDiv(net, Scale.price * Scale.shares / Scale.amount, price.raw))
            grossSecurity = price.value(of: shares)
            gross = convert(grossSecurity, from: securityCurrency, to: accountCurrency, on: day)
            guard shares.raw > 0, gross > 0, gross + fees <= balance[account] else { return false }
        }

        let amount = gross + fees
        balance[account] -= amount
        held[depot][security] += shares.raw
        cost[depot][security] += amount
        transactions.append(Transaction(
            id: nextID(), kind: .buy, date: day, minuteOfDay: nextMinute(day), accountID: accounts[account].id, depotID: depots[depot],
            securityID: securities[security].id, shares: shares, amount: Money(minor: amount, currency: accountCurrency),
            fees: fees, securityGross: cross ? Money(minor: grossSecurity, currency: securityCurrency) : nil,
            note: note, source: source
        ))
        return true
    }

    /// Sells up to `shares` of a position at the day's close. Capital gains tax of `taxRate`
    /// (in 1/100 000, e.g. 26 375 = 26.375 %) is withheld on a positive gain over the average cost.
    @discardableResult
    mutating func sell(
        on day: Day, security: Int, depot: Int, account: Int, shares requested: Int64, fee: FeeModel = .none,
        taxRate: Int64 = 0, note: String = ""
    ) -> Bool {
        let position = held[depot][security]
        let quantity = min(requested, position)
        guard quantity > 0 else { return false }
        let price = market.price(security, on: day)
        let securityCurrency = securities[security].currency, accountCurrency = accounts[account].currency
        let grossSecurity = price.value(of: Shares(raw: quantity))
        let gross = convert(grossSecurity, from: securityCurrency, to: accountCurrency, on: day)
        guard gross > 0 else { return false }
        let fees = min(fee.amount(for: gross), gross / 2)
        let basis = quantity == position ? cost[depot][security] : mulDiv(cost[depot][security], quantity, position)
        let gain = gross - fees - basis
        let taxes = gain > 0 ? mulDiv(gain, taxRate, 100_000) : 0
        let amount = gross - fees - taxes
        guard amount > 0 else { return false }

        balance[account] += amount
        held[depot][security] -= quantity
        cost[depot][security] -= basis
        transactions.append(Transaction(
            id: nextID(), kind: .sell, date: day, minuteOfDay: nextMinute(day), accountID: accounts[account].id, depotID: depots[depot],
            securityID: securities[security].id, shares: Shares(raw: quantity),
            amount: Money(minor: amount, currency: accountCurrency), fees: fees, taxes: taxes,
            securityGross: securityCurrency == accountCurrency ? nil : Money(minor: grossSecurity, currency: securityCurrency),
            note: note
        ))
        return true
    }

    /// Books shares arriving from outside the portfolio (gift, transfer from another broker) at market value.
    @discardableResult
    mutating func deliverIn(on day: Day, security: Int, depot: Int, shares: Int64, note: String = "") -> Bool {
        let value = market.price(security, on: day).value(of: Shares(raw: shares))
        guard shares > 0, value > 0 else { return false }
        held[depot][security] += shares
        cost[depot][security] += value
        transactions.append(Transaction(
            id: nextID(), kind: .deliveryIn, date: day, minuteOfDay: nextMinute(day), depotID: depots[depot], securityID: securities[security].id,
            shares: Shares(raw: shares), amount: Money(minor: value, currency: securities[security].currency), note: note
        ))
        return true
    }

    /// Moves up to `shares` of a position to another depot (cost basis travels along).
    @discardableResult
    mutating func transferSecurity(on day: Day, security: Int, from: Int, to: Int, shares requested: Int64, note: String = "") -> Bool {
        let position = held[from][security]
        let quantity = min(requested, position)
        guard quantity > 0, from != to else { return false }
        let value = market.price(security, on: day).value(of: Shares(raw: quantity))
        let basis = quantity == position ? cost[from][security] : mulDiv(cost[from][security], quantity, position)
        held[from][security] -= quantity
        held[to][security] += quantity
        cost[from][security] -= basis
        cost[to][security] += basis
        transactions.append(Transaction(
            id: nextID(), kind: .securityTransfer, date: day, minuteOfDay: nextMinute(day), depotID: depots[from], counterDepotID: depots[to],
            securityID: securities[security].id, shares: Shares(raw: quantity),
            amount: Money(minor: value, currency: securities[security].currency), note: note
        ))
        return true
    }

    /// Pays a dividend of `perShare` (a per-share amount in the security's currency, price-scaled) on
    /// the shares currently held in `depot`, net of `taxRate` (1/100 000) withholding tax.
    @discardableResult
    mutating func dividend(
        on day: Day, security: Int, depot: Int, account: Int, perShare: Price, taxRate: Int64, note: String = ""
    ) -> Bool {
        let position = held[depot][security]
        guard position > 0 else { return false }
        let securityCurrency = securities[security].currency, accountCurrency = accounts[account].currency
        let grossSecurity = perShare.value(of: Shares(raw: position))
        let gross = convert(grossSecurity, from: securityCurrency, to: accountCurrency, on: day)
        let taxes = mulDiv(gross, taxRate, 100_000)
        let amount = gross - taxes
        guard amount > 0 else { return false }
        balance[account] += amount
        transactions.append(Transaction(
            id: nextID(), kind: .dividend, date: day, minuteOfDay: nextMinute(day), accountID: accounts[account].id, depotID: depots[depot],
            securityID: securities[security].id, shares: Shares(raw: position),
            amount: Money(minor: amount, currency: accountCurrency), taxes: taxes,
            securityGross: securityCurrency == accountCurrency ? nil : Money(minor: grossSecurity, currency: securityCurrency),
            note: note
        ))
        return true
    }

    // MARK: Internals

    private mutating func nextID() -> UUID {
        sequencedIDs ? ids.sequencedUUID(UInt64(transactions.count)) : ids.uuid()
    }

    /// 08:00, 08:17, … — strictly increasing within a day so the booking order is unambiguous.
    /// Sequenced ids already sort in booking order and need no time of day.
    private mutating func nextMinute(_ day: Day) -> Int? {
        guard !sequencedIDs else { return nil }
        if day != cursor {
            cursor = day
            slot = 0
        }
        defer { slot += 1 }
        return min(8 * 60 + slot * 17, 1439)
    }
}
