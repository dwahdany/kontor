import Foundation
import KontorModel

/// A concrete reporting interval.
///
/// Convention (same as Portfolio Performance): the valuation at the **end of `start`** is the
/// baseline, and the interval covers the days `start + 1 … end`. Transactions dated `start` are part
/// of the baseline, not of the period. The calendar year 2024 is therefore
/// `DayInterval(start: 2023-12-31, end: 2024-12-31)`.
public struct DayInterval: Hashable, Sendable, Codable, CustomStringConvertible {
    public var start: Day
    public var end: Day

    /// Creates an interval; a reversed pair is swapped.
    public init(start: Day, end: Day) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// Number of days covered (`end − start`); daily series have `dayCount + 1` points.
    public var dayCount: Int { start.distance(to: end) }
    /// Length in years (365-day basis), as used for annualization.
    public var years: Double { Double(dayCount) / 365 }
    /// The first day whose transactions belong to the period.
    public var firstDay: Day { start.advanced(by: 1) }
    public func contains(_ day: Day) -> Bool { day > start && day <= end }
    public var description: String { "\(start)…\(end)" }
}

/// A user-facing reporting period that resolves to a `DayInterval` relative to "today".
public enum ReportingPeriod: Hashable, Sendable, Codable {
    /// From the end of last year until today.
    case ytd
    /// From the end of last month until today.
    case monthToDate
    /// From the end of the last calendar quarter until today.
    case quarterToDate
    case lastDays(Int)
    case lastMonths(Int)
    case lastYears(Int)
    /// A calendar year (ends today if the year is still running).
    case year(Int)
    /// From the day before the first transaction until today.
    case allTime
    /// An explicit interval: baseline at the end of `from`, through `to`.
    case custom(from: Day, to: Day)

    /// Periods offered by default in pickers.
    public static let presets: [ReportingPeriod] = [
        .ytd, .lastMonths(1), .lastMonths(3), .lastMonths(6), .lastYears(1), .lastYears(3), .lastYears(5), .allTime,
    ]

    /// Resolves the period. `firstTransactionDay` is only needed for `.allTime`.
    public func interval(today: Day, firstTransactionDay: Day?) -> DayInterval {
        switch self {
        case .ytd:
            return DayInterval(start: today.startOfYear.advanced(by: -1), end: today)
        case .monthToDate:
            return DayInterval(start: today.startOfMonth.advanced(by: -1), end: today)
        case .quarterToDate:
            let c = today.ymd
            let quarterStart = Day(year: c.year, month: (c.month - 1) / 3 * 3 + 1, day: 1)
            return DayInterval(start: quarterStart.advanced(by: -1), end: today)
        case .lastDays(let n):
            return DayInterval(start: today.advanced(by: -max(n, 0)), end: today)
        case .lastMonths(let n):
            return DayInterval(start: today.addingMonths(-max(n, 0)), end: today)
        case .lastYears(let n):
            return DayInterval(start: today.addingYears(-max(n, 0)), end: today)
        case .year(let y):
            let start = Day(year: y - 1, month: 12, day: 31)
            let end = Day(year: y, month: 12, day: 31)
            return DayInterval(start: start, end: today > start && today < end ? today : end)
        case .allTime:
            let first = min(firstTransactionDay ?? today, today)
            return DayInterval(start: first.advanced(by: -1), end: today)
        case .custom(let from, let to):
            return DayInterval(start: from, end: to)
        }
    }

    /// Resolves the period against a ledger (`.allTime` starts the day before its first transaction).
    public func interval(today: Day = .today, ledger: Ledger) -> DayInterval {
        interval(today: today, firstTransactionDay: ledger.firstTransactionDay)
    }

    /// A short human-readable (English) title, e.g. "Year to date", "Last 3 months", "2023".
    public var title: String {
        func plural(_ n: Int, _ unit: String) -> String { n == 1 ? "Last \(unit)" : "Last \(n) \(unit)s" }
        switch self {
        case .ytd: return "Year to date"
        case .monthToDate: return "Month to date"
        case .quarterToDate: return "Quarter to date"
        case .lastDays(let n): return plural(n, "day")
        case .lastMonths(let n): return plural(n, "month")
        case .lastYears(let n): return plural(n, "year")
        case .year(let y): return String(y)
        case .allTime: return "All time"
        case .custom(let from, let to): return "\(from.iso) – \(to.iso)"
        }
    }

    /// A compact label for segmented controls, e.g. "YTD", "3M", "1Y", "Max".
    public var shortTitle: String {
        switch self {
        case .ytd: return "YTD"
        case .monthToDate: return "MTD"
        case .quarterToDate: return "QTD"
        case .lastDays(let n): return "\(n)D"
        case .lastMonths(let n): return "\(n)M"
        case .lastYears(let n): return "\(n)Y"
        case .year(let y): return String(y)
        case .allTime: return "Max"
        case .custom: return "Custom"
        }
    }
}
