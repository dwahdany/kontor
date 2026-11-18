import Foundation
import KontorModel

/// Order of the components in numeric dates.
public enum CSVDateOrder: String, Hashable, Sendable, Codable, CaseIterable {
    /// 2024-03-31, 2024/03/31, 20240331
    case yearMonthDay
    /// 31.03.2024, 31/03/2024, 31-03-24
    case dayMonthYear
    /// 03/31/2024
    case monthDayYear
}

/// Tolerant parsers for the number and date notations found in broker and bank exports.
public enum CSVValueParser {
    // MARK: Numbers

    /// Parses a decimal number into a fixed-point integer scaled by 10^`digits`.
    ///
    /// Understands grouping separators (`1.234,56`, `1,234.56`, `1 234,56`, `1'234.56`), currency symbols
    /// and codes (`€ 12,50`, `12.50 USD`), percent signs, negative numbers written as `-5`, `5-`, `−5` or `(5)`,
    /// and scientific notation.
    /// - Parameter decimalSeparator: `"."` or `","`; the other one is treated as a grouping separator.
    /// - Returns: nil if the text is empty or not a number.
    public static func decimal(_ text: String, decimalSeparator: Character = ".", digits: Int) -> Int64? {
        var negative = false
        var cleaned = [UInt8]()
        cleaned.reserveCapacity(text.utf8.count)
        var sawDigit = false
        var exponent = false
        let decimal: UInt8 = decimalSeparator == "," ? 44 : 46
        let scalars = Array(text.unicodeScalars)
        func isDigit(_ index: Int) -> Bool { index < scalars.count && scalars[index].value >= 48 && scalars[index].value <= 57 }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "0"..."9":
                sawDigit = true
                cleaned.append(UInt8(scalar.value))
            case ".", ",":
                if UInt8(scalar.value) == decimal { cleaned.append(46) } // grouping separators are dropped
            case "-", "\u{2212}", "\u{2013}":
                negative.toggle()
            case "(":
                negative = true
            case "e", "E":
                // An exponent only if digits follow ("1.5E-3", "2e5"); otherwise a letter ("12.50 EUR", "5 each").
                guard sawDigit, !exponent, cleaned.last != nil else { break }
                let signed = index < scalars.count && (scalars[index] == "-" || scalars[index] == "+" || scalars[index] == "\u{2212}")
                guard isDigit(signed ? index + 1 : index) else { break }
                cleaned.append(101)
                exponent = true
                if signed {
                    if scalars[index] != "+" { cleaned.append(45) }
                    index += 1
                }
            default:
                break // currency symbols, letters, spaces, apostrophes, plus and percent signs
            }
        }
        guard sawDigit else { return nil }
        if exponent {
            guard let value = Double(String(decoding: cleaned, as: UTF8.self)), value.isFinite else { return nil }
            let scaled = (value * Double(FixedDecimal.pow10[digits])).rounded()
            guard abs(scaled) < 9.2e18 else { return nil }
            return negative ? -Int64(scaled) : Int64(scaled)
        }
        guard let value = FixedDecimal.parse(utf8: cleaned[...], digits: digits) else { return nil }
        return negative ? -value : value
    }

    /// `Unicode.Scalar.Properties.isAlphabetic` with a fast path for ASCII (the property lookup is
    /// expensive and these scanners run over every cell of a file).
    @inline(__always)
    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 128 { return (value >= 65 && value <= 90) || (value >= 97 && value <= 122) }
        return scalar.properties.isAlphabetic
    }

    /// Whether the cell looks like a number at all (digits plus separators, signs and currency decoration).
    static func looksNumeric(_ text: String) -> Bool {
        var digits = 0, letters = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 48, scalar.value <= 57 { digits += 1 } else if isLetter(scalar) { letters += 1 } else if scalar == ":" || scalar == "/" { return false }
        }
        return digits > 0 && letters <= 3
    }

    /// Whether the cell contains a `.` or `,` at all — the precondition for any separator evidence.
    @inline(__always)
    static func hasSeparator(_ text: String) -> Bool {
        for byte in text.utf8 where byte == 46 || byte == 44 { return true }
        return false
    }

    /// Whether the cell contains at least two dots — the only shape in which a date ("02.01.2024")
    /// and a number with grouping ("1.234.567") can be confused.
    static func hasRepeatedDot(_ text: String) -> Bool {
        var dots = 0
        for byte in text.utf8 where byte == 46 {
            dots += 1
            if dots == 2 { return true }
        }
        return false
    }

    /// Evidence about the decimal separator from a single numeric cell.
    enum SeparatorEvidence { case comma, dot, ambiguousComma, ambiguousDot, none }

    static func separatorEvidence(_ text: String) -> SeparatorEvidence {
        var dots = 0, commas = 0
        var lastSeparator: Unicode.Scalar?
        var digitsAfterLast = 0, digitsBeforeFirst = 0
        var seenSeparator = false
        var leadingZero = false
        var firstDigit = true
        for scalar in text.unicodeScalars {
            if scalar == "." || scalar == "," {
                if scalar == "." { dots += 1 } else { commas += 1 }
                lastSeparator = scalar
                digitsAfterLast = 0
                seenSeparator = true
            } else if scalar.value >= 48, scalar.value <= 57 {
                if firstDigit { leadingZero = scalar == "0"; firstDigit = false }
                if seenSeparator { digitsAfterLast += 1 } else { digitsBeforeFirst += 1 }
            }
        }
        // No digits after the separator: not a decimal notation at all ("0700.HK", "7203.T", "5,-").
        guard let last = lastSeparator, digitsAfterLast > 0 else { return .none }
        if dots > 0, commas > 0 { return last == "," ? .comma : .dot } // the last separator is the decimal one
        let count = max(dots, commas)
        if count > 1 { return last == "," ? .dot : .comma } // repeated separator = grouping
        // A single separator: grouping needs exactly three digits after it and 1–3 non-zero-led digits before.
        let couldBeGrouping = digitsAfterLast == 3 && digitsBeforeFirst >= 1 && digitsBeforeFirst <= 3 && !(leadingZero)
        if couldBeGrouping { return last == "," ? .ambiguousComma : .ambiguousDot }
        return last == "," ? .comma : .dot
    }

    // MARK: Dates

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "mär": 3, "mrz": 3, "apr": 4, "may": 5, "mai": 5, "jun": 6, "jul": 7, "aug": 8,
        "sep": 9, "oct": 10, "okt": 10, "nov": 11, "dec": 12, "dez": 12,
    ]

    struct DateTokens {
        /// Numeric components in order of appearance (value, number of digits).
        var numbers: [(value: Int, digits: Int)] = []
        /// Month given by name, and its position among the numeric components.
        var namedMonth: (month: Int, position: Int)?
        var isPM = false
        var isAM = false
        /// First separator between date components.
        var separator: Unicode.Scalar?
    }

    static func tokenize(_ text: String) -> DateTokens? {
        var tokens = DateTokens()
        var number = 0, digits = 0
        var word = ""
        func flushWord(_ tokens: inout DateTokens) {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            if lower == "pm" { tokens.isPM = true } else if lower == "am" { tokens.isAM = true } else if lower.count >= 3, let month = months[String(lower.prefix(3))] {
                if tokens.namedMonth == nil { tokens.namedMonth = (month, tokens.numbers.count) }
            }
            word = ""
        }
        for scalar in text.unicodeScalars {
            if scalar.value >= 48, scalar.value <= 57 {
                flushWord(&tokens)
                guard digits < 9 else { return nil }
                number = number * 10 + Int(scalar.value - 48)
                digits += 1
            } else {
                if digits > 0 {
                    tokens.numbers.append((number, digits))
                    number = 0
                    digits = 0
                    if tokens.separator == nil, scalar == "." || scalar == "/" || scalar == "-" { tokens.separator = scalar }
                }
                if isLetter(scalar) { word.unicodeScalars.append(scalar) } else { flushWord(&tokens) }
            }
        }
        if digits > 0 { tokens.numbers.append((number, digits)) }
        flushWord(&tokens)
        return tokens.numbers.isEmpty ? nil : tokens
    }

    /// Whether the cell is a plausible date under at least one component order.
    static func looksLikeDate(_ text: String) -> Bool {
        guard text.utf8.count >= 6, text.utf8.count <= 40, let tokens = tokenize(text) else { return false }
        if tokens.namedMonth == nil {
            if tokens.numbers.count == 1 {
                guard tokens.numbers[0].digits == 8, (1900...2200).contains(tokens.numbers[0].value / 10_000) else { return false }
            } else if tokens.numbers.count < 3 || tokens.separator == nil {
                return false
            }
        }
        return CSVDateOrder.allCases.contains { date(text, order: $0) != nil }
    }

    private static func fullYear(_ value: Int, digits: Int) -> Int {
        digits <= 2 ? (value < 70 ? 2000 + value : 1900 + value) : value
    }

    /// Parses a date with optional time of day.
    ///
    /// Accepts numeric dates in the given `order` (any of `. / - space` as separators, 2- or 4-digit
    /// years; a leading 4-digit number always means year-month-day), compact `yyyyMMdd`, ISO-8601 date-times
    /// and dates with English or German month names (`5 Jan 2024`, `Jan 5, 2024`, `5. Januar 2024`).
    /// - Returns: the day and, if a time other than midnight is present, the minute of the day.
    public static func date(_ text: String, order: CSVDateOrder = .yearMonthDay) -> (day: Day, minuteOfDay: Int?)? {
        guard let tokens = tokenize(text) else { return nil }
        return date(tokens, order: order)
    }

    /// `date(_:order:)` on an already tokenized cell (lets callers try several orders without re-scanning the text).
    static func date(_ tokens: DateTokens, order: CSVDateOrder) -> (day: Day, minuteOfDay: Int?)? {
        var numbers = tokens.numbers
        var year = 0, month = 0, dayOfMonth = 0
        var consumed = 3
        if let named = tokens.namedMonth {
            guard numbers.count >= 2 else { return nil }
            month = named.month
            let a = numbers[0], b = numbers[1]
            if a.digits == 4 || a.value > 31 {
                year = fullYear(a.value, digits: a.digits); dayOfMonth = b.value
            } else {
                dayOfMonth = a.value; year = fullYear(b.value, digits: b.digits)
            }
            consumed = 2
        } else if numbers.count >= 1, numbers[0].digits == 8 {
            let value = numbers[0].value
            year = value / 10_000; month = value / 100 % 100; dayOfMonth = value % 100
            consumed = 1
        } else if numbers.count >= 1, numbers[0].digits == 14 || numbers[0].digits == 12 {
            return nil
        } else {
            guard numbers.count >= 3 else { return nil }
            let a = numbers[0], b = numbers[1], c = numbers[2]
            if a.digits == 4 {
                year = a.value; month = b.value; dayOfMonth = c.value
            } else {
                switch order {
                case .yearMonthDay: year = fullYear(a.value, digits: a.digits); month = b.value; dayOfMonth = c.value
                case .dayMonthYear: dayOfMonth = a.value; month = b.value; year = fullYear(c.value, digits: c.digits)
                case .monthDayYear: month = a.value; dayOfMonth = b.value; year = fullYear(c.value, digits: c.digits)
                }
            }
        }
        guard (1...12).contains(month), year >= 1000, year <= 9999, dayOfMonth >= 1, dayOfMonth <= Day.daysInMonth(year: year, month: month) else { return nil }
        numbers.removeFirst(consumed)
        var minute: Int?
        if numbers.count >= 2 {
            var hour = numbers[0].value
            let minutes = numbers[1].value
            if tokens.isPM, hour < 12 { hour += 12 }
            if tokens.isAM, hour == 12 { hour = 0 }
            if hour < 24, minutes < 60, hour * 60 + minutes > 0 { minute = hour * 60 + minutes }
        }
        return (Day(year: year, month: month, day: dayOfMonth), minute)
    }

    /// Parses a time of day (`14:05`, `14:05:33`, `2:05 PM`, `1405`) into minutes after midnight.
    public static func time(_ text: String) -> Int? {
        guard let tokens = tokenize(text) else { return nil }
        var hour: Int, minute: Int
        if tokens.numbers.count == 1, tokens.numbers[0].digits == 4 || tokens.numbers[0].digits == 6 {
            let value = tokens.numbers[0].digits == 6 ? tokens.numbers[0].value / 100 : tokens.numbers[0].value
            hour = value / 100; minute = value % 100
        } else if tokens.numbers.count >= 2 {
            hour = tokens.numbers[0].value; minute = tokens.numbers[1].value
        } else {
            return nil
        }
        if tokens.isPM, hour < 12 { hour += 12 }
        if tokens.isAM, hour == 12 { hour = 0 }
        guard hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }
}
