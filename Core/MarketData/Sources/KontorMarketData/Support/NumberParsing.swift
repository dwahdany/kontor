import Foundation
import KontorModel

/// The character that separates the integer from the fractional part of a number.
public enum DecimalSeparator: String, Hashable, Sendable, CaseIterable {
    case point = "."
    case comma = ","
}

/// Lenient parsing of decimal numbers as they appear in quote files: `1234.56`, `1.234,56`,
/// `1,234.56`, `1'234.56`, `82,21 €`, `1 234,5`, `1.2e3`.
public enum NumberParser {
    /// Parses `text`. With `decimal == nil` the separator is inferred from the value itself:
    /// if both `.` and `,` occur the last one is the decimal separator; a single `,` followed by
    /// exactly three digits (`1,234`) is read as a thousands separator, any other single `,` as
    /// a decimal comma.
    public static func parse(_ text: some StringProtocol, decimal: DecimalSeparator? = nil) -> Double? {
        var cleaned = [UInt8]()
        cleaned.reserveCapacity(24)
        var dots = 0, commas = 0
        for c in text.unicodeScalars {
            switch c {
            case "0"..."9", "-", "+", "e", "E":
                cleaned.append(UInt8(c.value))
            case ".":
                dots += 1
                cleaned.append(UInt8(ascii: "."))
            case ",":
                commas += 1
                cleaned.append(UInt8(ascii: ","))
            case "'", "’", "\"", "%", "_":
                continue
            case "\u{2212}": // typographic minus
                cleaned.append(UInt8(ascii: "-"))
            default:
                if c.properties.isWhitespace || c.properties.generalCategory == .currencySymbol { continue }
                return nil
            }
        }
        guard !cleaned.isEmpty else { return nil }

        let decimalByte: UInt8?
        if let decimal {
            decimalByte = decimal == .point ? UInt8(ascii: ".") : UInt8(ascii: ",")
        } else if dots > 0, commas > 0 {
            let lastDot = cleaned.lastIndex(of: UInt8(ascii: "."))!
            let lastComma = cleaned.lastIndex(of: UInt8(ascii: ","))!
            decimalByte = lastDot > lastComma ? UInt8(ascii: ".") : UInt8(ascii: ",")
        } else if commas == 1 {
            let at = cleaned.firstIndex(of: UInt8(ascii: ","))!
            let after = cleaned.count - at - 1
            let before = cleaned[..<at].filter { $0 >= 48 && $0 <= 57 }
            let looksGrouped = after == 3 && (1...3).contains(before.count) && before.first != 48
            decimalByte = looksGrouped ? nil : UInt8(ascii: ",")
        } else if dots == 1 {
            decimalByte = UInt8(ascii: ".")
        } else {
            decimalByte = nil // only grouping separators (or none at all)
        }

        var normalized = [UInt8]()
        normalized.reserveCapacity(cleaned.count)
        var seenDecimal = false
        for b in cleaned {
            if b == UInt8(ascii: ".") || b == UInt8(ascii: ",") {
                guard b == decimalByte else { continue }
                guard !seenDecimal else { return nil }
                seenDecimal = true
                normalized.append(UInt8(ascii: "."))
            } else {
                normalized.append(b)
            }
        }
        guard let value = Double(String(decoding: normalized, as: UTF8.self)), value.isFinite else { return nil }
        return value
    }
}

/// Undoes float-to-double widening.
///
/// Several APIs (Yahoo among them) serialize 32-bit floats as doubles, turning `185.64` into
/// `185.63999938964844`. If `value` is exactly representable as a `Float`, the shortest decimal
/// that round-trips through `Float` is returned, which recovers the intended quote. Other
/// values are returned unchanged.
public func cleanedQuote(_ value: Double) -> Double {
    let narrowed = Float(value)
    if narrowed.isFinite, Double(narrowed) == value, let exact = Double(narrowed.description) { return exact }
    return value
}

extension Price {
    /// Converts a quote delivered as a binary floating-point number, see ``cleanedQuote(_:)``.
    public init(quote value: Double) {
        self.init(cleanedQuote(value))
    }

    /// The largest quote a `Price` can hold (`Int64.max / 1e8`, rounded down to a safe double).
    static let largestQuote = 92_233_720_368.0

    /// Converts a quote from an untrusted source. Returns nil — instead of trapping like
    /// `Price.init(_:)` — when the value is not finite, not positive, too large for the
    /// fixed-point representation, or so small that it would be stored as zero.
    public init?(checkedQuote value: Double) {
        guard value.isFinite, value > 0, value <= Self.largestQuote else { return nil }
        let raw = (value * Double(Scale.price)).rounded()
        guard raw >= 1 else { return nil }
        self.init(raw: Int64(raw))
    }
}

/// Formats a number without a trailing ".0" ("4", "0.205").
func compactDescription(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return "\(value)"
}

/// Sorts points by day and keeps the last point of each day.
func normalized(_ points: [PricePoint]) -> [PricePoint] {
    guard points.count > 1 else { return points }
    var sorted = true
    for i in 1..<points.count where points[i].day <= points[i - 1].day {
        sorted = false
        break
    }
    if sorted { return points }
    var byDay = [Day: Price](minimumCapacity: points.count)
    for p in points { byDay[p.day] = p.price }
    return byDay.map { PricePoint(day: $0.key, price: $0.value) }.sorted { $0.day < $1.day }
}
