import Foundation
import KontorModel

/// The app-wide formatting facade. All functions are thread-safe, allocation-light and safe to call
/// per table cell.
///
/// ```swift
/// Fmt.money(position.value)                    // "$12,345.67"
/// Fmt.money(position.gain, signed: true)       // "+$1,204.10"
/// Fmt.compactMoney(total)                      // "$1.2M"
/// Fmt.percent(0.0734, signed: true)            // "+7.34%"
/// Fmt.shares(position.shares)                  // "12.5"
/// Fmt.day(tx.date)                             // "03/31/2024"
/// Fmt.parseMinor("1.234,56")                   // 123456
/// ```
public enum Fmt {
    private static let storage = Storage()

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var formatter = KontorFormatter(locale: .current)
        func get() -> KontorFormatter {
            lock.lock()
            defer { lock.unlock() }
            return formatter
        }
        func set(_ f: KontorFormatter) {
            lock.lock()
            formatter = f
            lock.unlock()
        }
    }

    /// The formatter behind the static functions (the user's current locale by default).
    public static var current: KontorFormatter {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    /// Switches the app-wide locale (e.g. after `NSLocale.currentLocaleDidChangeNotification`).
    public static func setLocale(_ locale: Locale) { storage.set(KontorFormatter(locale: locale)) }

    public static let missing = KontorFormatter.missing

    // MARK: Formatting

    public static func money(_ money: Money, symbol: Bool = true, signed: Bool = false) -> String {
        current.money(money, symbol: symbol, signed: signed)
    }
    public static func money(minor: Int64, currency: CurrencyCode? = nil, signed: Bool = false) -> String {
        current.money(minor: minor, currency: currency, signed: signed)
    }
    public static func moneyRounded(_ money: Money, symbol: Bool = true, signed: Bool = false) -> String {
        current.moneyRounded(money, symbol: symbol, signed: signed)
    }
    public static func compactMoney(_ money: Money, symbol: Bool = true) -> String {
        current.compactMoney(money, symbol: symbol)
    }
    public static func percent(_ fraction: Double, decimals: Int = 2, signed: Bool = false) -> String {
        current.percent(fraction, decimals: decimals, signed: signed)
    }
    public static func percent(basisPoints: Int, decimals: Int = 2) -> String {
        current.percent(basisPoints: basisPoints, decimals: decimals)
    }
    public static func number(_ value: Double, decimals: Int = 2, signed: Bool = false, grouping: Bool = true) -> String {
        current.number(value, decimals: decimals, signed: signed, grouping: grouping)
    }
    public static func integer(_ value: Int) -> String { current.integer(value) }
    public static func shares(_ shares: Shares, signed: Bool = false, maxDecimals: Int = 8) -> String {
        current.shares(shares, signed: signed, maxDecimals: maxDecimals)
    }
    public static func time(minuteOfDay: Int) -> String { current.time(minuteOfDay: minuteOfDay) }
    public static func bytes(_ count: Int) -> String { current.bytes(count) }
    public static func price(_ price: Price, currency: CurrencyCode? = nil, maxDecimals: Int? = nil) -> String {
        current.price(price, currency: currency, maxDecimals: maxDecimals)
    }
    public static func rate(_ rate: Double) -> String { current.rate(rate) }
    public static func currencySymbol(_ code: CurrencyCode) -> String { current.currencySymbol(code) }
    public static func day(_ day: Day, style: KontorFormatter.DayStyle = .short) -> String {
        current.day(day, style: style)
    }
    public static func relativeDay(_ day: Day, today: Day = .today) -> String {
        current.relativeDay(day, today: today)
    }

    // MARK: Parsing

    public static func parseMinor(_ text: String) -> Int64? { current.parseMinor(text) }
    public static func parseMoney(_ text: String, currency: CurrencyCode) -> Money? {
        current.parseMoney(text, currency: currency)
    }
    public static func parseShares(_ text: String) -> Shares? { current.parseShares(text) }
    public static func parsePrice(_ text: String) -> Price? { current.parsePrice(text) }
    public static func parsePercent(_ text: String) -> Double? { current.parsePercent(text) }
    public static func parseDouble(_ text: String) -> Double? { current.parseDouble(text) }
    public static func parseDay(_ text: String, today: Day = .today) -> Day? { current.parseDay(text, today: today) }
}
