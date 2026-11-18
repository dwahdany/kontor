import Foundation

/// ISO-4217 currency code ("EUR", "USD"). Crypto tickers ("BTC") are allowed as well.
public typealias CurrencyCode = String

/// Fixed-point scales. All monetary numbers in the model are integers:
/// * money amounts: minor units, 1/100 (for *every* currency)
/// * share counts:  1/100_000_000
/// * prices/quotes: 1/100_000_000
public enum Scale {
    public static let amount: Int64 = 100
    public static let shares: Int64 = 100_000_000
    public static let price: Int64 = 100_000_000
}

/// `a * b / d`, computed with a 128-bit intermediate, rounded half away from zero.
public func mulDiv(_ a: Int64, _ b: Int64, _ d: Int64) -> Int64 {
    precondition(d != 0)
    let negative = ((a < 0) != (b < 0)) != (d < 0)
    let (hi, lo) = a.magnitude.multipliedFullWidth(by: b.magnitude)
    let dm = d.magnitude
    guard hi < dm else { return negative ? Int64.min : Int64.max }
    let (q, r) = dm.dividingFullWidth((hi, lo))
    let rounded = r >= dm - r ? q &+ 1 : q
    guard rounded <= UInt64(Int64.max) else { return negative ? Int64.min : Int64.max }
    return negative ? -Int64(rounded) : Int64(rounded)
}

/// An amount of money in minor units (1/100) of `currency`.
public struct Money: Hashable, Codable, Sendable, CustomStringConvertible {
    public var minor: Int64
    public var currency: CurrencyCode

    public init(minor: Int64, currency: CurrencyCode) {
        self.minor = minor
        self.currency = currency
    }
    public init(_ value: Double, _ currency: CurrencyCode) {
        self.init(minor: Int64((value * Double(Scale.amount)).rounded()), currency: currency)
    }
    public static func zero(_ currency: CurrencyCode) -> Money { Money(minor: 0, currency: currency) }

    public var doubleValue: Double { Double(minor) / Double(Scale.amount) }
    public var decimalValue: Decimal { Decimal(minor) / Decimal(Scale.amount) }
    public var isZero: Bool { minor == 0 }
    public var description: String { "\(decimalValue) \(currency)" }

    public static prefix func - (a: Money) -> Money { Money(minor: -a.minor, currency: a.currency) }
    /// Adds two amounts. Traps in debug builds if the currencies differ.
    public static func + (a: Money, b: Money) -> Money {
        assert(a.currency == b.currency, "currency mismatch")
        return Money(minor: a.minor + b.minor, currency: a.currency)
    }
    public static func - (a: Money, b: Money) -> Money {
        assert(a.currency == b.currency, "currency mismatch")
        return Money(minor: a.minor - b.minor, currency: a.currency)
    }
}

/// A number of shares/units, fixed-point with 8 decimals.
public struct Shares: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var raw: Int64
    public init(raw: Int64) { self.raw = raw }
    public init(_ value: Double) { raw = Int64((value * Double(Scale.shares)).rounded()) }
    public static let zero = Shares(raw: 0)

    public var doubleValue: Double { Double(raw) / Double(Scale.shares) }
    public var decimalValue: Decimal { Decimal(raw) / Decimal(Scale.shares) }
    public var isZero: Bool { raw == 0 }
    public var description: String { "\(decimalValue)" }

    public static func < (a: Shares, b: Shares) -> Bool { a.raw < b.raw }
    public static prefix func - (a: Shares) -> Shares { Shares(raw: -a.raw) }
    public static func + (a: Shares, b: Shares) -> Shares { Shares(raw: a.raw + b.raw) }
    public static func - (a: Shares, b: Shares) -> Shares { Shares(raw: a.raw - b.raw) }
    public static func += (a: inout Shares, b: Shares) { a.raw += b.raw }
    public static func -= (a: inout Shares, b: Shares) { a.raw -= b.raw }

    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(Int64.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// A price per share, fixed-point with 8 decimals. The currency is implied by context (the security).
public struct Price: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var raw: Int64
    public init(raw: Int64) { self.raw = raw }
    public init(_ value: Double) { raw = Int64((value * Double(Scale.price)).rounded()) }
    public static let zero = Price(raw: 0)

    public var doubleValue: Double { Double(raw) / Double(Scale.price) }
    public var decimalValue: Decimal { Decimal(raw) / Decimal(Scale.price) }
    public var description: String { "\(decimalValue)" }

    public static func < (a: Price, b: Price) -> Bool { a.raw < b.raw }

    /// Market value of `shares` at this price, in minor units (1/100), rounded half away from zero.
    public func value(of shares: Shares) -> Int64 {
        mulDiv(raw, shares.raw, Scale.price * Scale.shares / Scale.amount)
    }

    /// The price implied by paying `minor` (1/100 units) for `shares`. Returns nil for zero shares.
    public init?(minor: Int64, per shares: Shares) {
        guard shares.raw != 0 else { return nil }
        raw = mulDiv(minor, Scale.price * Scale.shares / Scale.amount, shares.raw)
    }

    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(Int64.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}
