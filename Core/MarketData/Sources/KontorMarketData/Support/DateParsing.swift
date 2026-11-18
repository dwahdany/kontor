import Foundation
import KontorModel

/// A simple date pattern made of `yyyy`, `yy`, `MM`, `M`, `MMM` (month name), `dd`, `d` and
/// literal characters, e.g. `dd.MM.yyyy`, `yyyyMMdd` or `d-MMM-yy`. Letters are case-insensitive
/// (`DD/MM/YYYY` works too).
///
/// Only the date matters: once year, month and day have been read, parsing stops, so whatever
/// follows in the text (a time, a zone) is ignored — and so is a time part in the pattern
/// itself. `yyyy-MM-dd'T'HH:mm:ss` and `dd.MM.yyyy HH:mm` therefore work as expected, even
/// though `mm` would otherwise be read as a month.
public struct DatePattern: Hashable, Sendable {
    enum Element: Hashable, Sendable {
        case year4, year2, month2, month1, monthName, day2, day1
        case literal(Unicode.Scalar)

        var isNumeric: Bool {
            switch self {
            case .literal, .monthName: return false
            default: return true
            }
        }
    }

    let elements: [Element]
    /// Number of leading elements needed to read the date (up to its last year/month/day field).
    private let dateLength: Int

    /// Returns nil unless the pattern contains a year, a month and a day.
    public init?(_ pattern: String) {
        var elements = [Element]()
        let scalars = Array(pattern.unicodeScalars)
        var i = 0
        var hasYear = false, hasMonth = false, hasDay = false
        var dateLength = 0
        while i < scalars.count {
            let c = scalars[i]
            let lower = Character(c).lowercased()
            if lower == "y" || lower == "m" || lower == "d" {
                // The date is complete: what follows is a time part ("HH:mm" — minutes, not a
                // second month), which is of no interest.
                if hasYear, hasMonth, hasDay { break }
                var n = 1
                while i + n < scalars.count, Character(scalars[i + n]).lowercased() == lower { n += 1 }
                i += n
                switch (lower, n) {
                case ("y", 2) where !hasYear: elements.append(.year2); hasYear = true
                case ("y", 4) where !hasYear: elements.append(.year4); hasYear = true
                case ("m", 1) where !hasMonth: elements.append(.month1); hasMonth = true
                case ("m", 2) where !hasMonth: elements.append(.month2); hasMonth = true
                case ("m", 3) where !hasMonth, ("m", 4) where !hasMonth: elements.append(.monthName); hasMonth = true
                case ("d", 1) where !hasDay: elements.append(.day1); hasDay = true
                case ("d", 2) where !hasDay: elements.append(.day2); hasDay = true
                default: return nil // unknown field width, or the same field twice
                }
                dateLength = elements.count
            } else {
                if c != "'" { elements.append(.literal(c)) }
                i += 1
            }
        }
        guard hasYear, hasMonth, hasDay else { return nil }
        self.elements = elements
        self.dateLength = dateLength
    }

    /// Parses the beginning of `text` according to the pattern.
    public func parse(_ text: some StringProtocol) -> Day? {
        let s = Array(text.unicodeScalars)
        var i = 0
        while i < s.count, s[i].properties.isWhitespace || s[i] == "\"" { i += 1 }
        var year = 0, month = 0, day = 0
        func number(maxDigits: Int, exact: Bool) -> Int? {
            var v = 0, n = 0
            while n < maxDigits, i < s.count, let d = s[i].asciiDigit {
                v = v * 10 + d
                n += 1
                i += 1
            }
            return n == 0 || (exact && n != maxDigits) ? nil : v
        }
        for (index, element) in elements.prefix(dateLength).enumerated() {
            // Fields that touch the next numeric field ("yyyyMMdd") need their full width;
            // delimited fields may drop leading zeros ("1.2.2024" for dd.MM.yyyy).
            let adjacent = index + 1 < elements.count && elements[index + 1].isNumeric
            switch element {
            case .year4:
                guard let v = number(maxDigits: 4, exact: true) else { return nil }
                year = v
            case .year2:
                guard let v = number(maxDigits: 2, exact: true) else { return nil }
                year = DayParser.expandTwoDigitYear(v)
            case .month2, .month1:
                guard let v = number(maxDigits: 2, exact: adjacent) else { return nil }
                month = v
            case .day2, .day1:
                guard let v = number(maxDigits: 2, exact: adjacent) else { return nil }
                day = v
            case .monthName:
                let start = i
                while i < s.count, s[i].properties.isAlphabetic { i += 1 }
                guard let m = DayParser.month(named: s[start..<i]) else { return nil }
                month = m
                if i < s.count, s[i] == "." { i += 1 }
            case .literal(let c):
                guard i < s.count, s[i] == c else { return nil }
                i += 1
            }
        }
        return DayParser.validDay(year, month, day)
    }

    /// Formats a day (month names in English, three letters).
    public func format(_ day: Day) -> String {
        let c = day.ymd
        var out = ""
        func pad(_ v: Int, _ n: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, n - s.count)) + s
        }
        for element in elements {
            switch element {
            case .year4: out += pad(c.year, 4)
            case .year2: out += pad(c.year % 100, 2)
            case .month2: out += pad(c.month, 2)
            case .month1: out += String(c.month)
            case .monthName: out += DayParser.englishMonths[c.month - 1]
            case .day2: out += pad(c.day, 2)
            case .day1: out += String(c.day)
            case .literal(let s): out.unicodeScalars.append(s)
            }
        }
        return out
    }
}

/// How the dates of a generic feed are written.
public enum DateFormat: Hashable, Sendable {
    /// Detect per value: ISO dates, `dd.MM.yyyy`, `MM/dd/yyyy`, month names, `yyyyMMdd`, Unix
    /// timestamps in seconds or milliseconds.
    case auto
    case unixSeconds
    case unixMilliseconds
    case pattern(DatePattern)

    /// Interprets a feed option: empty or `auto`, `unix`, `unix-ms`, or a ``DatePattern``.
    public init?(option: String?) {
        let text = (option ?? "").trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "", "auto": self = .auto
        case "unix", "unix-s", "epoch": self = .unixSeconds
        case "unix-ms", "unixms", "epoch-ms": self = .unixMilliseconds
        default:
            guard let pattern = DatePattern(text) else { return nil }
            self = .pattern(pattern)
        }
    }

    /// Parses a textual date. `order` resolves `01/02/2024`-style ambiguity in `.auto` mode.
    public func parse(_ text: some StringProtocol, order: DayParser.NumericOrder? = nil) -> Day? {
        switch self {
        case .auto: return DayParser.parse(text, order: order)
        case .pattern(let pattern): return pattern.parse(text)
        case .unixSeconds, .unixMilliseconds:
            guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return parse(number: v)
        }
    }

    /// Interprets a numeric date (JSON number).
    public func parse(number: Double) -> Day? {
        switch self {
        case .auto: return DayParser.day(fromNumber: number)
        case .unixSeconds: return DayParser.day(unixSeconds: number)
        case .unixMilliseconds: return DayParser.day(unixSeconds: number / 1000)
        case .pattern(let pattern):
            guard number == number.rounded(), abs(number) < 1e15 else { return nil }
            return pattern.parse(String(Int64(number)))
        }
    }
}

/// Lenient parsing of calendar days from the many notations found in quote files.
public enum DayParser {
    /// Reading order of all-numeric dates whose year comes last.
    public enum NumericOrder: Hashable, Sendable { case dayFirst, monthFirst }

    static let englishMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Parses a date in any supported notation:
    /// `2024-01-31` (optionally followed by a time), `2024/01/31`, `20240131`, `31.01.2024`,
    /// `31.01.24`, `31-01-2024`, `01/31/2024`, `31 Jan 2024`, `Jan 31, 2024`, `31-Jan-24`,
    /// `31. Januar 2024`, and Unix timestamps (9–11 digits: seconds, 12–14 digits: milliseconds).
    ///
    /// - Parameter order: how to read `a/b/yyyy` when both `a` and `b` could be a month. Defaults
    ///   to month-first for `/` and day-first for every other separator.
    public static func parse(_ text: some StringProtocol, order: NumericOrder? = nil) -> Day? {
        if let iso = Day(iso: text) { return iso }
        guard let c = components(of: text) else { return nil }
        switch c {
        case .resolved(let day): return day
        case .ambiguous(let a, let b, let year, let separator):
            let dayFirst = (order ?? (separator == "/" ? .monthFirst : .dayFirst)) == .dayFirst
            return validDay(year, dayFirst ? b : a, dayFirst ? a : b)
                // Fall back to the only reading that yields a valid date.
                ?? validDay(year, dayFirst ? a : b, dayFirst ? b : a)
        }
    }

    /// Looks at sample values of one column and reports the order of ambiguous numeric dates, or
    /// nil if the samples give no evidence (or are not of that shape).
    public static func detectOrder(_ samples: some Sequence<String>) -> NumericOrder? {
        for sample in samples {
            guard case .ambiguous(let a, let b, _, _)? = components(of: sample) else { continue }
            if a > 12, b <= 12 { return .dayFirst }
            if b > 12, a <= 12 { return .monthFirst }
        }
        return nil
    }

    /// Interprets a number as `yyyyMMdd`, Unix milliseconds or Unix seconds (in that order of
    /// plausibility).
    public static func day(fromNumber n: Double) -> Day? {
        guard n.isFinite else { return nil }
        if n == n.rounded(), n >= 19_000_101, n <= 22_001_231 {
            let v = Int(n)
            if let day = validDay(v / 10_000, v / 100 % 100, v % 100) { return day }
        }
        return day(unixSeconds: abs(n) >= 1e11 ? n / 1000 : n)
    }

    /// The UTC day containing the given Unix time.
    public static func day(unixSeconds s: Double) -> Day? {
        guard s.isFinite, abs(s) < 1e11 else { return nil }
        return Day(rawValue: Int32((s / 86_400).rounded(.down)))
    }

    static func expandTwoDigitYear(_ v: Int) -> Int { v < 70 ? 2000 + v : 1900 + v }

    static func validDay(_ year: Int, _ month: Int, _ day: Int) -> Day? {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
              day <= Day.daysInMonth(year: year, month: month) else { return nil }
        return Day(year: year, month: month, day: day)
    }

    /// Month number for an English or German month name or abbreviation.
    static func month(named scalars: some Collection<Unicode.Scalar>) -> Int? {
        guard scalars.count >= 3 else { return nil }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: scalars.prefix(3))
        switch String(name).lowercased() {
        case "jan": return 1
        case "feb": return 2
        case "mar", "mär", "mrz": return 3
        case "apr": return 4
        case "may", "mai": return 5
        case "jun": return 6
        case "jul": return 7
        case "aug": return 8
        case "sep": return 9
        case "oct", "okt": return 10
        case "nov": return 11
        case "dec", "dez": return 12
        default: return nil
        }
    }

    private enum Components {
        case resolved(Day)
        case ambiguous(Int, Int, year: Int, separator: Unicode.Scalar)
    }

    private enum Token {
        case number(Int, digits: Int)
        case month(Int)
    }

    private static func components(of text: some StringProtocol) -> Components? {
        var tokens = [Token]()
        tokens.reserveCapacity(3)
        var separator: Unicode.Scalar = " "
        var it = text.unicodeScalars.makeIterator()
        var pending = it.next()
        while let c = pending, tokens.count < 3 {
            if let d = c.asciiDigit {
                var value = d, digits = 1
                pending = it.next()
                while let n = pending, let d = n.asciiDigit {
                    if digits < 18 { value = value * 10 + d }
                    digits += 1
                    pending = it.next()
                }
                tokens.append(.number(value, digits: digits))
            } else if c.properties.isAlphabetic {
                var word = [c]
                pending = it.next()
                while let n = pending, n.properties.isAlphabetic {
                    word.append(n)
                    pending = it.next()
                }
                if let m = month(named: word) {
                    tokens.append(.month(m))
                } else if !tokens.isEmpty {
                    break // e.g. the "T" of an ISO time: the date part is over
                }
            } else {
                if tokens.count == 1, c == "/" || c == "." || c == "-" { separator = c }
                pending = it.next()
            }
        }

        if tokens.count == 1, case .number(let value, let digits) = tokens[0] {
            switch digits {
            case 8: return validDay(value / 10_000, value / 100 % 100, value % 100).map(Components.resolved)
            case 9...11: return day(unixSeconds: Double(value)).map(Components.resolved)
            case 12...14: return day(unixSeconds: Double(value) / 1000).map(Components.resolved)
            default: return nil
            }
        }
        guard tokens.count == 3 else { return nil }
        func year(_ value: Int, _ digits: Int) -> Int? {
            switch digits {
            case 4: return value
            case 2: return expandTwoDigitYear(value)
            default: return nil
            }
        }
        switch (tokens[0], tokens[1], tokens[2]) {
        case (.number(let y, 4), .number(let m, _), .number(let d, _)),
             (.number(let y, 4), .month(let m), .number(let d, _)):
            return validDay(y, m, d).map(Components.resolved)
        case (.number(let d, _), .month(let m), .number(let y, let digits)),
             (.month(let m), .number(let d, _), .number(let y, let digits)):
            return year(y, digits).flatMap { validDay($0, m, d) }.map(Components.resolved)
        case (.number(let a, _), .number(let b, _), .number(let y, let digits)):
            return year(y, digits).map { .ambiguous(a, b, year: $0, separator: separator) }
        default:
            return nil
        }
    }
}

extension Unicode.Scalar {
    /// 0…9 for ASCII digits.
    var asciiDigit: Int? {
        value >= 48 && value <= 57 ? Int(value - 48) : nil
    }
}
