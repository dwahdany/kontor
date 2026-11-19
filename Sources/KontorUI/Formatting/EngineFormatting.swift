import Foundation
import KontorModel
import KontorEngine

// Formatting for values that come out of the engine: optional fractions, basis points, holding
// periods, intervals, ratios — and display names for the model's enums.

extension KontorFormatter {
    /// An optional fraction as a percentage; nil (undefined: no IRR, no volatility yet) → "–".
    public func percent(_ fraction: Double?, decimals: Int = 2, signed: Bool = false) -> String {
        fraction.map { percent($0, decimals: decimals, signed: signed) } ?? Self.missing
    }

    /// A difference between two percentages in percentage points: `0.0125` → "+1.25 pp".
    /// (5 % → 6.25 % is +1.25 pp, not +1.25 %.)
    public func percentagePoints(_ fractionDelta: Double?, decimals: Int = 2) -> String {
        guard let fractionDelta, fractionDelta.isFinite else { return Self.missing }
        return number(fractionDelta * 100, decimals: decimals, signed: true) + "\u{00A0}pp"
    }

    /// Basis points as such: `25` → "25 bp", signed: "+25 bp". (For percent use `percent(basisPoints:)`.)
    public func basisPoints(_ value: Int, signed: Bool = false) -> String {
        (signed && value > 0 ? "+" : "") + integer(value) + "\u{00A0}bp"
    }

    /// A fraction expressed in basis points: `0.0025` → "25 bp".
    public func basisPoints(fraction: Double?, signed: Bool = false) -> String {
        guard let fraction, fraction.isFinite, abs(fraction) < 1e12 else { return Self.missing }
        return basisPoints(Int((fraction * 10_000).rounded()), signed: signed)
    }

    /// A unitless ratio (Sharpe ratio, profit factor); nil → "–".
    public func ratio(_ value: Double?, decimals: Int = 2) -> String {
        value.map { number($0, decimals: decimals) } ?? Self.missing
    }

    /// A multiple: `1.5` → "1.5×".
    public func multiple(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return Self.missing }
        return number(value, decimals: decimals) + "×"
    }

    /// An optional number; nil → "–".
    public func number(_ value: Double?, decimals: Int = 2, signed: Bool = false) -> String {
        value.map { number($0, decimals: decimals, signed: signed) } ?? Self.missing
    }

    /// Optional money; nil → "–".
    public func money(_ money: Money?, symbol: Bool = true, signed: Bool = false) -> String {
        money.map { self.money($0, symbol: symbol, signed: signed) } ?? Self.missing
    }

    /// Compact money from minor units: `compactMoney(minor: 123_456_789, currency: "USD")` → "$1.2M".
    public func compactMoney(minor: Int64, currency: CurrencyCode, symbol: Bool = true) -> String {
        compactMoney(Money(minor: minor, currency: currency), symbol: symbol)
    }

    public enum DurationStyle: Sendable {
        /// "12 days", "5 months", "2.4 years"
        case full
        /// "12d", "5mo", "2.4y" — table cells
        case compact
    }

    /// A holding period or other span given in days: under two months in days, under two years in
    /// months, above in years with one decimal.
    public func duration(days: Int?, style: DurationStyle = .full) -> String {
        guard let days else { return Self.missing }
        let magnitude = abs(days)
        let sign = days < 0 ? "−" : ""
        switch magnitude {
        case 0..<60:
            return sign + (style == .compact ? "\(magnitude)d" : magnitude == 1 ? "1 day" : "\(magnitude) days")
        case 60..<730:
            let months = Int((Double(magnitude) / 30.4375).rounded())
            return sign + (style == .compact ? "\(months)mo" : "\(months) months")
        default:
            let years = number(Double(magnitude) / 365.25, decimals: 1)
            return sign + (style == .compact ? "\(years)y" : "\(years) years")
        }
    }

    /// A span in years (e.g. `DayInterval.years`): "2.4 years".
    public func duration(years: Double?, style: DurationStyle = .full) -> String {
        guard let years, years.isFinite, abs(years) < 1e6 else { return Self.missing }
        return duration(days: Int((years * 365.25).rounded()), style: style)
    }

    /// The days an interval covers, as the user reads them: "Jan 1, 2024 – Jun 30, 2024"
    /// (`interval.firstDay … interval.end`; the baseline day itself is not part of the period).
    public func interval(_ interval: DayInterval, style: DayStyle = .medium) -> String {
        "\(day(min(interval.firstDay, interval.end), style: style)) – \(day(interval.end, style: style))"
    }

    /// A calendar month: "Mar 2024" / "March 2024".
    public func month(year: Int, month: Int, long: Bool = false) -> String {
        day(Day(year: year, month: min(max(month, 1), 12), day: 1), style: long ? .monthYear : .shortMonthYear)
    }
}

extension Fmt {
    public static func percent(_ fraction: Double?, decimals: Int = 2, signed: Bool = false) -> String {
        current.percent(fraction, decimals: decimals, signed: signed)
    }
    public static func percentagePoints(_ fractionDelta: Double?, decimals: Int = 2) -> String {
        current.percentagePoints(fractionDelta, decimals: decimals)
    }
    public static func basisPoints(_ value: Int, signed: Bool = false) -> String { current.basisPoints(value, signed: signed) }
    public static func basisPoints(fraction: Double?, signed: Bool = false) -> String {
        current.basisPoints(fraction: fraction, signed: signed)
    }
    public static func ratio(_ value: Double?, decimals: Int = 2) -> String { current.ratio(value, decimals: decimals) }
    public static func multiple(_ value: Double?, decimals: Int = 1) -> String { current.multiple(value, decimals: decimals) }
    public static func number(_ value: Double?, decimals: Int = 2, signed: Bool = false) -> String {
        current.number(value, decimals: decimals, signed: signed)
    }
    public static func money(_ money: Money?, symbol: Bool = true, signed: Bool = false) -> String {
        current.money(money, symbol: symbol, signed: signed)
    }
    public static func compactMoney(minor: Int64, currency: CurrencyCode, symbol: Bool = true) -> String {
        current.compactMoney(minor: minor, currency: currency, symbol: symbol)
    }
    public static func duration(days: Int?, style: KontorFormatter.DurationStyle = .full) -> String {
        current.duration(days: days, style: style)
    }
    public static func duration(years: Double?, style: KontorFormatter.DurationStyle = .full) -> String {
        current.duration(years: years, style: style)
    }
    public static func interval(_ interval: DayInterval, style: KontorFormatter.DayStyle = .medium) -> String {
        current.interval(interval, style: style)
    }
    public static func month(year: Int, month: Int, long: Bool = false) -> String {
        current.month(year: year, month: month, long: long)
    }
}

// MARK: Display names

extension Transaction.Kind {
    /// "Buy", "Delivery (Inbound)", "Interest Charge", …
    public var title: String {
        switch self {
        case .buy: "Buy"
        case .sell: "Sell"
        case .deliveryIn: "Delivery (Inbound)"
        case .deliveryOut: "Delivery (Outbound)"
        case .deposit: "Deposit"
        case .withdrawal: "Withdrawal"
        case .dividend: "Dividend"
        case .interest: "Interest"
        case .interestCharge: "Interest Charge"
        case .fee: "Fee"
        case .feeRefund: "Fee Refund"
        case .tax: "Tax"
        case .taxRefund: "Tax Refund"
        case .cashTransfer: "Cash Transfer"
        case .securityTransfer: "Security Transfer"
        }
    }

    /// SF Symbol for lists and menus.
    public var symbol: String {
        switch self {
        case .buy: "arrow.down.left.circle"
        case .sell: "arrow.up.right.circle"
        case .deliveryIn: "tray.and.arrow.down"
        case .deliveryOut: "tray.and.arrow.up"
        case .deposit: "plus.circle"
        case .withdrawal: "minus.circle"
        case .dividend: "banknote"
        case .interest: "percent"
        case .interestCharge: "percent"
        case .fee: "scissors"
        case .feeRefund: "arrow.uturn.backward.circle"
        case .tax: "building.columns"
        case .taxRefund: "arrow.uturn.backward.circle"
        case .cashTransfer: "arrow.left.arrow.right"
        case .securityTransfer: "arrow.left.arrow.right.square"
        }
    }

    /// Kinds in the order editors and filters list them.
    public static let menuOrder: [Transaction.Kind] = [
        .buy, .sell, .dividend, .deposit, .withdrawal, .interest, .interestCharge, .fee, .feeRefund, .tax, .taxRefund,
        .cashTransfer, .securityTransfer, .deliveryIn, .deliveryOut,
    ]
}

extension InvestmentPlan.Kind {
    public var title: String {
        switch self {
        case .purchase: "Purchase"
        case .deposit: "Deposit"
        case .withdrawal: "Withdrawal"
        }
    }
}

extension CostMethod {
    public var title: String {
        switch self {
        case .fifo: "First In, First Out (FIFO)"
        case .average: "Moving Average"
        }
    }

    public var shortTitle: String {
        switch self {
        case .fifo: "FIFO"
        case .average: "Average"
        }
    }
}

extension ReportingPeriod {
    /// Text form for scene storage and `--period`: `1M 3M 6M YTD MTD QTD 1Y 3Y 5Y 10Y ALL`, `30D`,
    /// a year (`2024`) or a range (`2024-01-01..2024-06-30`).
    public init?(code: String) {
        let text = code.trimmingCharacters(in: .whitespaces).uppercased()
        switch text {
        case "YTD": self = .ytd
        case "MTD": self = .monthToDate
        case "QTD": self = .quarterToDate
        case "ALL", "MAX": self = .allTime
        default:
            if let range = text.range(of: "..") {
                guard let from = Day(iso: text[..<range.lowerBound]), let to = Day(iso: text[range.upperBound...]) else { return nil }
                self = .custom(from: from, to: to)
            } else if let year = Int(text) {
                guard (1900...2200).contains(year) else { return nil }
                self = .year(year)
            } else if let unit = text.last, let count = Int(text.dropLast()), count > 0, count < 10_000 {
                switch unit {
                case "D": self = .lastDays(count)
                case "M": self = .lastMonths(count)
                case "Y": self = .lastYears(count)
                default: return nil
                }
            } else {
                return nil
            }
        }
    }

    /// The inverse of `init(code:)`.
    public var code: String {
        switch self {
        case .ytd: "YTD"
        case .monthToDate: "MTD"
        case .quarterToDate: "QTD"
        case .lastDays(let n): "\(n)D"
        case .lastMonths(let n): "\(n)M"
        case .lastYears(let n): "\(n)Y"
        case .year(let y): String(y)
        case .allTime: "ALL"
        case .custom(let from, let to): "\(from.iso)..\(to.iso)"
        }
    }
}
