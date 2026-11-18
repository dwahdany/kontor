import Foundation

/// A calendar day (proleptic Gregorian, no time zone). Stored as days since 1970-01-01.
/// Encoded in JSON as an ISO-8601 string ("2024-03-31").
public struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, Strideable {
    public var rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public init(year: Int, month: Int, day: Int) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        rawValue = Int32(era * 146_097 + doe - 719_468)
    }

    /// Parses "YYYY-MM-DD" (anything after the 10th character, e.g. a time part, is ignored).
    public init?(iso: some StringProtocol) {
        let u = Array(iso.utf8.prefix(10))
        guard u.count == 10, u[4] == 45, u[7] == 45 else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for c in u[r] {
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10),
              (1...12).contains(m), d >= 1, d <= Day.daysInMonth(year: y, month: m) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var ymd: (year: Int, month: Int, day: Int) {
        let z = Int(rawValue) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    public var year: Int { ymd.year }
    public var month: Int { ymd.month }
    public var dayOfMonth: Int { ymd.day }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var weekday: Int { ((Int(rawValue) % 7) + 7 + 3) % 7 + 1 }
    public var isWeekend: Bool { weekday >= 6 }

    public var iso: String {
        let c = ymd
        func pad(_ v: Int, _ n: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, n - s.count)) + s
        }
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
    }
    public var description: String { iso }

    public static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // MARK: Arithmetic

    public func distance(to other: Day) -> Int { Int(other.rawValue) - Int(rawValue) }
    public func advanced(by n: Int) -> Day { Day(rawValue: rawValue + Int32(n)) }
    public static func < (a: Day, b: Day) -> Bool { a.rawValue < b.rawValue }

    /// Adds calendar months, clamping the day of month (Jan 31 + 1 month = Feb 28/29).
    public func addingMonths(_ n: Int) -> Day {
        let c = ymd
        let total = c.year * 12 + (c.month - 1) + n
        let y = Int((Double(total) / 12).rounded(.down))
        let m = total - y * 12 + 1
        return Day(year: y, month: m, day: min(c.day, Day.daysInMonth(year: y, month: m)))
    }
    public func addingYears(_ n: Int) -> Day { addingMonths(n * 12) }

    public var startOfMonth: Day { let c = ymd; return Day(year: c.year, month: c.month, day: 1) }
    public var endOfMonth: Day {
        let c = ymd
        return Day(year: c.year, month: c.month, day: Day.daysInMonth(year: c.year, month: c.month))
    }
    public var startOfYear: Day { Day(year: year, month: 1, day: 1) }
    public var endOfYear: Day { Day(year: year, month: 12, day: 31) }

    // MARK: Foundation bridging

    /// The day containing `date` in the given time zone.
    public init(date: Date, timeZone: TimeZone = .current) {
        let seconds = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        rawValue = Int32((seconds / 86_400).rounded(.down))
    }

    /// Midnight UTC at the start of this day.
    public var utcDate: Date { Date(timeIntervalSince1970: Double(rawValue) * 86_400) }

    /// Midnight at the start of this day in the given time zone.
    public func date(in timeZone: TimeZone = .current) -> Date {
        let utc = utcDate
        return utc.addingTimeInterval(-Double(timeZone.secondsFromGMT(for: utc)))
    }

    public static var today: Day { Day(date: Date()) }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let d = Day(iso: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid day: \(s)")
        }
        self = d
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}
