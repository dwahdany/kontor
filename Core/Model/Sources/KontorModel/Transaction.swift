import Foundation

/// One entry of the unified ledger. Every booking — cash or securities — is a single `Transaction`.
///
/// Conventions (all magnitudes are stored **non-negative**; the direction follows from `kind`):
///
/// | kind             | cash account (`accountID`)        | depot (`depotID`)     | meaning of `amount`                                  |
/// |------------------|-----------------------------------|-----------------------|------------------------------------------------------|
/// | buy              | − amount                          | + shares              | total paid = gross + fees + taxes                    |
/// | sell             | + amount                          | − shares              | net proceeds = gross − fees − taxes                  |
/// | deliveryIn       | —                                 | + shares              | value of delivered shares incl. fees + taxes (cost)  |
/// | deliveryOut      | —                                 | − shares              | value of removed shares net of fees + taxes          |
/// | deposit          | + amount                          | —                     |                                                      |
/// | withdrawal       | − amount                          | —                     |                                                      |
/// | dividend         | + amount                          | — (`shares` is info)  | net received = gross − fees − taxes                  |
/// | interest         | + amount                          | —                     | net received = gross − taxes                         |
/// | interestCharge   | − amount                          | —                     |                                                      |
/// | fee              | − amount                          | —                     | `securityID` optional                                |
/// | feeRefund        | + amount                          | —                     |                                                      |
/// | tax              | − amount                          | —                     | `securityID` optional                                |
/// | taxRefund        | + amount                          | —                     |                                                      |
/// | cashTransfer     | − amount; counterAccount + (counterAmount ?? amount) | —  |                                                      |
/// | securityTransfer | —                                 | − shares; counterDepot + shares | market value at transfer (informational)   |
///
/// `amount`, `fees` and `taxes` share one currency (`amount.currency`): it MUST equal the currency of
/// `accountID` for cash-affecting kinds; for `deliveryIn`/`deliveryOut`/`securityTransfer` (no account) any
/// currency is allowed (typically the security's). `fees`/`taxes` are *included* in `amount` as described above — they are a
/// breakdown, never additional cash movements.
public struct Transaction: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case buy, sell, deliveryIn, deliveryOut
        case deposit, withdrawal
        case dividend, interest, interestCharge
        case fee, feeRefund, tax, taxRefund
        case cashTransfer, securityTransfer
    }

    public var id: UUID
    public var kind: Kind
    public var date: Day
    /// Optional time of day in minutes after midnight (orders same-day transactions).
    public var minuteOfDay: Int?
    public var accountID: UUID?
    public var depotID: UUID?
    /// Target account of a `cashTransfer`.
    public var counterAccountID: UUID?
    /// Target depot of a `securityTransfer`.
    public var counterDepotID: UUID?
    public var securityID: UUID?
    public var shares: Shares
    public var amount: Money
    /// Fees in minor units of `amount.currency` (≥ 0).
    public var fees: Int64
    /// Taxes in minor units of `amount.currency` (≥ 0).
    public var taxes: Int64
    /// `cashTransfer` between accounts of different currencies: the amount credited to the target account.
    public var counterAmount: Money?
    /// When the security is quoted in another currency than `amount`: the gross value in the security's currency.
    public var securityGross: Money?
    public var note: String
    /// Dividends: the ex-dividend day, if known.
    public var exDate: Day?
    /// Origin of the entry, e.g. "csv-import", "pp-import", "plan:<uuid>".
    public var source: String?

    public init(
        id: UUID = UUID(), kind: Kind, date: Day, minuteOfDay: Int? = nil, accountID: UUID? = nil,
        depotID: UUID? = nil, counterAccountID: UUID? = nil, counterDepotID: UUID? = nil,
        securityID: UUID? = nil, shares: Shares = .zero, amount: Money, fees: Int64 = 0, taxes: Int64 = 0,
        counterAmount: Money? = nil, securityGross: Money? = nil, note: String = "", source: String? = nil,
        exDate: Day? = nil
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.minuteOfDay = minuteOfDay
        self.accountID = accountID
        self.depotID = depotID
        self.counterAccountID = counterAccountID
        self.counterDepotID = counterDepotID
        self.securityID = securityID
        self.shares = shares
        self.amount = amount
        self.fees = fees
        self.taxes = taxes
        self.counterAmount = counterAmount
        self.securityGross = securityGross
        self.note = note
        self.source = source
        self.exDate = exDate
    }
}

extension Transaction.Kind {
    /// +1 if the kind credits `accountID`, −1 if it debits it, 0 if it does not touch cash.
    public var cashSign: Int64 {
        switch self {
        case .sell, .deposit, .dividend, .interest, .feeRefund, .taxRefund: return 1
        case .buy, .withdrawal, .interestCharge, .fee, .tax, .cashTransfer: return -1
        case .deliveryIn, .deliveryOut, .securityTransfer: return 0
        }
    }

    /// +1 if the kind adds shares to `depotID`, −1 if it removes them, 0 if it does not touch holdings.
    public var sharesSign: Int64 {
        switch self {
        case .buy, .deliveryIn: return 1
        case .sell, .deliveryOut, .securityTransfer: return -1
        default: return 0
        }
    }

    /// Whether this kind requires a security (`fee`, `tax` and refunds may optionally carry one).
    public var requiresSecurity: Bool {
        switch self {
        case .buy, .sell, .deliveryIn, .deliveryOut, .dividend, .securityTransfer: return true
        default: return false
        }
    }
    public var requiresAccount: Bool { cashSign != 0 }
    public var requiresDepot: Bool { sharesSign != 0 }

    /// Money entering or leaving the portfolio as a whole (external cash flows for performance measurement).
    public var isExternalFlow: Bool {
        switch self {
        case .deposit, .withdrawal, .deliveryIn, .deliveryOut: return true
        default: return false
        }
    }
}

extension Transaction {
    /// Signed change of the cash balance of `account` in minor units of that account's currency.
    public func cashEffect(on account: UUID) -> Int64 {
        var effect: Int64 = 0
        if accountID == account { effect += kind.cashSign * amount.minor }
        if kind == .cashTransfer, counterAccountID == account { effect += (counterAmount ?? amount).minor }
        return effect
    }

    /// Signed change of the share position of this transaction's security in `depot`.
    public func sharesEffect(on depot: UUID) -> Shares {
        var effect: Int64 = 0
        if depotID == depot { effect += kind.sharesSign * shares.raw }
        if kind == .securityTransfer, counterDepotID == depot { effect += shares.raw }
        return Shares(raw: effect)
    }

    /// Value before fees and taxes, in minor units of `amount.currency`.
    public var grossMinor: Int64 {
        switch kind {
        case .buy, .deliveryIn: return amount.minor - fees - taxes
        case .sell, .deliveryOut, .dividend, .interest: return amount.minor + fees + taxes
        default: return amount.minor
        }
    }

    /// Gross price per share in `amount.currency`, for kinds that move shares.
    public var grossPrice: Price? {
        guard kind.sharesSign != 0 || kind == .dividend else { return nil }
        return Price(minor: grossMinor, per: shares)
    }

    /// Stable chronological ordering: date, then time of day (untimed first), then id.
    public static func chronological(_ a: Transaction, _ b: Transaction) -> Bool {
        if a.date != b.date { return a.date < b.date }
        let ta = a.minuteOfDay ?? -1, tb = b.minuteOfDay ?? -1
        if ta != tb { return ta < tb }
        return withUnsafeBytes(of: a.id.uuid) { x in
            withUnsafeBytes(of: b.id.uuid) { y in x.lexicographicallyPrecedes(y) }
        }
    }
}
