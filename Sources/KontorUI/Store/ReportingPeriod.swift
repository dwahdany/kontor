import Foundation
import KontorModel

/// The reporting period type used across the UI.
///
/// This alias is the seam towards the calculation engine: once `KontorEngine` ships its own period
/// type, only this line (and a small adapter) changes — features keep writing `ReportingPeriod`.
public typealias ReportingPeriod = UIReportingPeriod

/// The globally selected reporting period ("show me the last year").
public enum UIReportingPeriod: Hashable, Codable, Sendable {
    /// The last `months` months up to today (1M, 3M, 6M, 1Y = 12, 3Y = 36, …).
    case trailingMonths(Int)
    case monthToDate
    case quarterToDate
    case yearToDate
    /// A full calendar year (clamped to today for the running year).
    case calendarYear(Int)
    /// From the first transaction until today.
    case allTime
    case custom(from: Day, to: Day)

    /// Presets offered by the period picker, in display order.
    public static let presets: [UIReportingPeriod] = [
        .trailingMonths(1), .trailingMonths(3), .trailingMonths(6), .yearToDate,
        .trailingMonths(12), .trailingMonths(36), .trailingMonths(60), .allTime,
    ]

    /// Compact label for toolbars and chips: `1M`, `YTD`, `3Y`, `2023`, `All`.
    public var shortTitle: String {
        switch self {
        case .trailingMonths(let m): m % 12 == 0 ? "\(m / 12)Y" : "\(m)M"
        case .monthToDate: "MTD"
        case .quarterToDate: "QTD"
        case .yearToDate: "YTD"
        case .calendarYear(let y): String(y)
        case .allTime: "All"
        case .custom: "Custom"
        }
    }

    /// Menu label: `1 Month`, `Year to Date`, `All Time`.
    public var title: String {
        switch self {
        case .trailingMonths(let m):
            if m % 12 == 0 { return m == 12 ? "1 Year" : "\(m / 12) Years" }
            return m == 1 ? "1 Month" : "\(m) Months"
        case .monthToDate: return "Month to Date"
        case .quarterToDate: return "Quarter to Date"
        case .yearToDate: return "Year to Date"
        case .calendarYear(let y): return String(y)
        case .allTime: return "All Time"
        case .custom(let from, let to): return "\(Fmt.day(from)) – \(Fmt.day(to))"
        }
    }

    /// The concrete interval. `start` is the *reference day* whose closing value opens the period
    /// (e.g. Dec 31 for YTD), `end` the last day included.
    ///
    /// - Parameter inception: the first day with data (first transaction); bounds `.allTime`.
    public func interval(today: Day, inception: Day? = nil) -> ClosedRange<Day> {
        let range: (Day, Day)
        switch self {
        case .trailingMonths(let m): range = (today.addingMonths(-m), today)
        case .monthToDate: range = (today.startOfMonth.advanced(by: -1), today)
        case .quarterToDate:
            let c = today.ymd
            let quarterStart = Day(year: c.year, month: (c.month - 1) / 3 * 3 + 1, day: 1)
            range = (quarterStart.advanced(by: -1), today)
        case .yearToDate: range = (today.startOfYear.advanced(by: -1), today)
        case .calendarYear(let y):
            range = (Day(year: y - 1, month: 12, day: 31), min(Day(year: y, month: 12, day: 31), today))
        case .allTime: range = ((inception ?? today.addingYears(-1)).advanced(by: -1), today)
        case .custom(let from, let to): range = (from, to)
        }
        return min(range.0, range.1)...max(range.0, range.1)
    }
}
