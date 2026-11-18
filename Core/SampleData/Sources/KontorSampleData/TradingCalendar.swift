import KontorModel

/// The trading calendar of the fictional exchange all sample instruments are listed on: Monday to
/// Friday, closed on New Year's Day, Good Friday, Easter Monday, Christmas Day and Boxing Day.
///
/// Sample quotes, exchange-rate fixings and transactions only ever fall on trading days (crypto
/// assets are quoted every day), so generated files have the same gaps real market data has.
enum TradingCalendar {
    /// Easter Sunday of a Gregorian year (anonymous Gregorian algorithm, "Computus").
    static func easterSunday(year: Int) -> Day {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return Day(year: year, month: month, day: day)
    }

    /// The exchange holidays of a year, ascending (they may fall on weekends).
    static func holidays(year: Int) -> [Day] {
        let easter = easterSunday(year: year)
        return [
            Day(year: year, month: 1, day: 1), easter.advanced(by: -2), easter.advanced(by: 1),
            Day(year: year, month: 12, day: 25), Day(year: year, month: 12, day: 26),
        ]
    }

    /// Whether the exchange is closed on `day` although it is a weekday.
    static func isHoliday(_ day: Day) -> Bool {
        holidays(year: day.year).contains(day)
    }

    /// Whether the exchange is open on `day`.
    static func isTradingDay(_ day: Day) -> Bool { !day.isWeekend && !isHoliday(day) }

    /// The first trading day on or after `day`.
    static func tradingDay(onOrAfter day: Day) -> Day {
        var day = day
        while !isTradingDay(day) { day = day.advanced(by: 1) }
        return day
    }

    /// `isTradingDay` for `count` consecutive days starting at `start`, in a single pass.
    static func tradingDays(from start: Day, count: Int) -> [Bool] {
        var open = [Bool](repeating: true, count: max(count, 0))
        guard count > 0 else { return open }
        var weekday = start.weekday
        for i in 0..<count {
            open[i] = weekday < 6
            weekday = weekday == 7 ? 1 : weekday + 1
        }
        let last = start.advanced(by: count - 1)
        for year in start.year...last.year {
            for holiday in holidays(year: year) {
                let offset = start.distance(to: holiday)
                if offset >= 0, offset < count { open[offset] = false }
            }
        }
        return open
    }
}
