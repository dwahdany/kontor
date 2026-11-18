import Foundation
import KontorModel

/// Expands placeholders in user-supplied feed URLs.
///
/// | placeholder  | replaced by                                  |
/// |--------------|----------------------------------------------|
/// | `{TICKER}`   | the security's ticker symbol                 |
/// | `{ISIN}`     | the ISIN                                     |
/// | `{WKN}`      | the WKN                                      |
/// | `{CURRENCY}` | the security's currency code                 |
/// | `{FROM}`     | first requested day, `yyyy-MM-dd`            |
/// | `{TO}`       | last requested day, `yyyy-MM-dd`             |
///
/// Dates accept a format after a colon: `{FROM:unix}` (seconds, start of day UTC), `{TO:unix}`
/// (end of day UTC), `{FROM:unix-ms}`, or any pattern of `yyyy yy MM M dd d` and literals such
/// as `{FROM:yyyyMMdd}` or `{TO:dd.MM.yyyy}`. Placeholder names are case-insensitive, values are
/// percent-encoded, unknown placeholders are left untouched.
public enum URLTemplate {
    /// The values available to a template.
    public struct Context: Hashable, Sendable {
        public var ticker: String
        public var isin: String
        public var wkn: String
        public var currency: String
        public var from: Day
        public var to: Day

        public init(ticker: String = "", isin: String = "", wkn: String = "", currency: String = "", from: Day, to: Day) {
            self.ticker = ticker
            self.isin = isin
            self.wkn = wkn
            self.currency = currency
            self.from = from
            self.to = to
        }
    }

    /// The names of all supported placeholders (for UI hints).
    public static let placeholders = ["TICKER", "ISIN", "WKN", "CURRENCY", "FROM", "TO"]

    /// Expands the template into a string.
    public static func expand(_ template: String, _ context: Context) -> String {
        guard template.contains("{") else { return template }
        var out = ""
        out.reserveCapacity(template.count + 32)
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let token = rest[rest.index(after: open)..<close]
            if let value = value(for: token, context) {
                out += value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// Expands the template and validates that the result is an http(s) URL.
    public static func url(_ template: String, _ context: Context) throws -> URL {
        let expanded = expand(template.trimmingCharacters(in: .whitespacesAndNewlines), context)
        guard let url = URL(string: expanded) ?? URL(string: expanded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil
        else { throw MarketDataError.invalidURL(expanded) }
        return url
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func value(for token: Substring, _ c: Context) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].uppercased()
        let format = parts.count > 1 ? String(parts[1]) : nil
        switch name {
        case "TICKER": return format == nil ? c.ticker : nil
        case "ISIN": return format == nil ? c.isin : nil
        case "WKN": return format == nil ? c.wkn : nil
        case "CURRENCY": return format == nil ? c.currency : nil
        case "FROM": return formatted(c.from, format, endOfDay: false)
        case "TO": return formatted(c.to, format, endOfDay: true)
        default: return nil
        }
    }

    private static func formatted(_ day: Day, _ format: String?, endOfDay: Bool) -> String? {
        guard let format else { return day.iso }
        let seconds = Int64(day.rawValue) * 86_400 + (endOfDay ? 86_399 : 0)
        switch format.lowercased() {
        case "unix": return String(seconds)
        case "unix-ms", "unixms": return String(seconds * 1000 + (endOfDay ? 999 : 0))
        default: return DatePattern(format)?.format(day)
        }
    }
}
