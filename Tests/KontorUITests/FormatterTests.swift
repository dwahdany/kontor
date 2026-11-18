import Foundation
import Testing
import KontorModel
@testable import KontorUI

private let us = KontorFormatter(locale: Locale(identifier: "en_US"))
private let de = KontorFormatter(locale: Locale(identifier: "de_DE"))
private let nbsp = "\u{00A0}"

@Suite struct MoneyFormatting {
    @Test func enUS() {
        #expect(us.money(Money(minor: 123_456, currency: "USD")) == "$1,234.56")
        #expect(us.money(Money(minor: -123_456, currency: "USD")) == "-$1,234.56")
        #expect(us.money(Money(minor: 123_456, currency: "USD"), symbol: false) == "1,234.56")
        #expect(us.money(Money(minor: 5, currency: "USD")) == "$0.05")
        #expect(us.money(Money(minor: 0, currency: "USD")) == "$0.00")
        #expect(us.money(Money(minor: 100_000_000_00, currency: "EUR")) == "€100,000,000.00")
        #expect(us.money(Money(minor: 99_900, currency: "CHF")) == "CHF\(nbsp)999.00")
    }

    @Test func deDE() {
        #expect(de.money(Money(minor: 123_456, currency: "EUR")) == "1.234,56\(nbsp)€")
        #expect(de.money(Money(minor: -123_456, currency: "EUR")) == "-1.234,56\(nbsp)€")
        #expect(de.money(Money(minor: 123_456, currency: "USD")) == "1.234,56\(nbsp)$")
        #expect(de.money(Money(minor: 123_456, currency: "EUR"), symbol: false) == "1.234,56")
    }

    @Test func signed() {
        #expect(us.money(Money(minor: 1_050, currency: "USD"), signed: true) == "+$10.50")
        #expect(us.money(Money(minor: -1_050, currency: "USD"), signed: true) == "-$10.50")
        #expect(us.money(Money(minor: 0, currency: "USD"), signed: true) == "$0.00")
        #expect(de.money(Money(minor: 1_050, currency: "EUR"), signed: true) == "+10,50\(nbsp)€")
    }

    @Test func extremes() {
        #expect(us.money(minor: Int64.max) == "92,233,720,368,547,758.07")
        #expect(us.money(minor: Int64.min) == "-92,233,720,368,547,758.08")
    }

    @Test func rounded() {
        #expect(us.moneyRounded(Money(minor: 123_450, currency: "USD")) == "$1,235")
        #expect(us.moneyRounded(Money(minor: -49, currency: "USD")) == "$0")
        #expect(de.moneyRounded(Money(minor: 123_449, currency: "EUR")) == "1.234\(nbsp)€")
    }

    @Test func compact() {
        #expect(us.compactMoney(Money(minor: 95_000, currency: "USD")) == "$950")
        #expect(us.compactMoney(Money(minor: 123_456, currency: "USD")) == "$1.2K")
        #expect(us.compactMoney(Money(minor: 12_345_678, currency: "USD")) == "$123K")
        #expect(us.compactMoney(Money(minor: 123_456_789, currency: "USD")) == "$1.2M")
        #expect(us.compactMoney(Money(minor: -250_000_000_000, currency: "USD")) == "-$2.5B")
        #expect(us.compactMoney(Money(minor: 99_996_000, currency: "USD")) == "$1.0M")
        #expect(de.compactMoney(Money(minor: 123_456_789, currency: "EUR")) == "1,2\(nbsp)Mio.\(nbsp)€")
        #expect(de.compactMoney(Money(minor: 123_456, currency: "EUR")) == "1,2\(nbsp)Tsd.\(nbsp)€")
    }
}

@Suite struct NumberFormatting {
    @Test func percent() {
        #expect(us.percent(0.1234) == "12.34%")
        #expect(us.percent(0.1234, signed: true) == "+12.34%")
        #expect(us.percent(-0.05, decimals: 1) == "-5.0%")
        #expect(us.percent(0, signed: true) == "0.00%")
        #expect(us.percent(12.5, decimals: 0) == "1,250%")
        #expect(de.percent(0.1234) == "12,34\(nbsp)%")
        #expect(de.percent(-0.1234, signed: true) == "-12,34\(nbsp)%")
        #expect(us.percent(.nan) == "–")
        #expect(us.percent(.infinity) == "–")
        #expect(us.percent(basisPoints: 2_500, decimals: 1) == "25.0%")
        // Rounds half away from zero, never shows "-0.00".
        #expect(us.percent(0.00005, decimals: 2) == "0.01%")
        #expect(us.percent(-0.00001, decimals: 2) == "0.00%")
    }

    @Test func shares() {
        #expect(us.shares(Shares(12)) == "12")
        #expect(us.shares(Shares(0.5)) == "0.5")
        #expect(us.shares(Shares(raw: 123_456_789_000)) == "1,234.56789")
        #expect(us.shares(Shares(raw: 1)) == "0.00000001")
        #expect(us.shares(Shares(raw: -150_000_000)) == "-1.5")
        #expect(de.shares(Shares(raw: 123_456_789_000)) == "1.234,56789")
        #expect(us.shares(.zero) == "0")
        #expect(us.shares(Shares(3), signed: true) == "+3")
    }

    @Test func price() {
        #expect(us.price(Price(101.5)) == "101.50")
        #expect(us.price(Price(101.123456)) == "101.1235")
        #expect(us.price(Price(0.00001234)) == "0.00001234")
        #expect(us.price(Price(0.5)) == "0.50")
        #expect(us.price(Price(1234.5), currency: "USD") == "$1,234.50")
        #expect(de.price(Price(1234.5), currency: "EUR") == "1.234,50\(nbsp)€")
    }

    @Test func plainNumbers() {
        #expect(us.number(1234.567, decimals: 2) == "1,234.57")
        #expect(us.number(1234.567, decimals: 0) == "1,235")
        #expect(us.number(-0.5, decimals: 1, signed: true) == "-0.5")
        #expect(de.number(1234.5, decimals: 1, grouping: false) == "1234,5")
        #expect(us.integer(1_234_567) == "1,234,567")
        #expect(us.integer(-12) == "-12")
        #expect(us.rate(1.08345) == "1.0835")
    }

    @Test func indianGrouping() {
        let hi = KontorFormatter(locale: Locale(identifier: "en_IN"))
        #expect(hi.integer(12_345_678) == "1,23,45,678")
    }

    @Test func currencySymbols() {
        #expect(us.currencySymbol("EUR") == "€")
        #expect(us.currencySymbol("USD") == "$")
        #expect(de.currencySymbol("EUR") == "€")
        #expect(us.currencySymbol("BTC") == "BTC")
    }
}

@Suite struct DayFormatting {
    let day = Day(year: 2024, month: 3, day: 5)

    @Test func enUS() {
        #expect(us.day(day) == "03/05/2024")
        #expect(us.day(day, style: .medium) == "Mar 5, 2024")
        #expect(us.day(day, style: .long) == "March 5, 2024")
        #expect(us.day(day, style: .monthYear) == "March 2024")
        #expect(us.day(day, style: .shortMonthYear) == "Mar 2024")
        #expect(us.day(day, style: .dayMonth) == "Mar 5")
        #expect(us.day(day, style: .iso) == "2024-03-05")
    }

    @Test func deDE() {
        #expect(de.day(day) == "05.03.2024")
        #expect(de.day(day, style: .long) == "5. März 2024")
        #expect(de.day(day, style: .monthYear) == "März 2024")
        #expect(de.day(day, style: .iso) == "2024-03-05")
    }

    @Test func matchesFoundationForEveryMonth() {
        // The integer formatter must agree with DateFormatter for the medium style.
        for locale in ["en_US", "de_DE", "fr_FR", "en_GB", "ja_JP"] {
            let f = KontorFormatter(locale: Locale(identifier: locale))
            let df = DateFormatter()
            df.locale = Locale(identifier: locale)
            df.calendar = Calendar(identifier: .gregorian)
            df.timeZone = TimeZone(identifier: "UTC")
            df.setLocalizedDateFormatFromTemplate("yMMMd")
            for month in 1...12 {
                let d = Day(year: 2023, month: month, day: 17)
                #expect(f.day(d, style: .medium) == df.string(from: d.utcDate), "\(locale) month \(month)")
            }
        }
    }

    @Test func relative() {
        let today = Day(year: 2024, month: 3, day: 10)
        #expect(us.relativeDay(today, today: today) == "Today")
        #expect(us.relativeDay(today.advanced(by: -1), today: today) == "Yesterday")
        #expect(us.relativeDay(today.advanced(by: 1), today: today) == "Tomorrow")
        #expect(us.relativeDay(today.advanced(by: -3), today: today) == "3 days ago")
        #expect(us.relativeDay(today.advanced(by: -30), today: today) == "Feb 9, 2024")
        #expect(de.relativeDay(today, today: today) == "Heute")
    }
}

@Suite struct Parsing {
    @Test func minorEnUS() {
        #expect(us.parseMinor("1,234.56") == 123_456)
        #expect(us.parseMinor("1234.56") == 123_456)
        #expect(us.parseMinor("$1,234.56") == 123_456)
        #expect(us.parseMinor("1,234") == 123_400)
        #expect(us.parseMinor("1,5") == 150) // a lone comma that cannot be grouping is a decimal comma
        #expect(us.parseMinor("12") == 1_200)
        #expect(us.parseMinor(".5") == 50)
        #expect(us.parseMinor("-3.2") == -320)
        #expect(us.parseMinor("−3.2") == -320)
        #expect(us.parseMinor("(3.20)") == -320)
        #expect(us.parseMinor(" 7 ") == 700)
        #expect(us.parseMinor("1.005") == 101)
        #expect(us.parseMinor("1.004") == 100)
        #expect(us.parseMinor("1,234,567") == 123_456_700)
    }

    @Test func minorDeDE() {
        #expect(de.parseMinor("1.234,56") == 123_456)
        #expect(de.parseMinor("1234,56") == 123_456)
        #expect(de.parseMinor("1.234,56 €") == 123_456)
        #expect(de.parseMinor("1.234") == 123_400)
        #expect(de.parseMinor("1.5") == 150) // tolerate a decimal point
        #expect(de.parseMinor("0,5") == 50)
        #expect(de.parseMinor("1.234.567") == 123_456_700)
        #expect(de.parseMinor("-1.234,5") == -123_450)
        #expect(de.parseMinor("1 234,56") == 123_456)
        #expect(de.parseMinor("1’234.56") == 123_456)
    }

    @Test func rejectsGarbage() {
        #expect(us.parseMinor("") == nil)
        #expect(us.parseMinor("abc") == nil)
        #expect(us.parseMinor("-") == nil)
        #expect(us.parseMinor("99999999999999999999999") == nil)
    }

    @Test func sharesAndPrices() {
        #expect(us.parseShares("12.5") == Shares(raw: 1_250_000_000))
        #expect(de.parseShares("0,00000001") == Shares(raw: 1))
        #expect(de.parseShares("1.234,56789") == Shares(raw: 123_456_789_000))
        #expect(us.parsePrice("101.1235") == Price(raw: 10_112_350_000))
        #expect(us.parsePercent("12.5%") == 0.125)
        #expect(de.parsePercent("12,5 %") == 0.125)
        #expect(us.parseDouble("2.5") == 2.5)
        #expect(us.parseMoney("3.50", currency: "USD") == Money(minor: 350, currency: "USD"))
    }

    @Test func roundTrips() {
        for f in [us, de] {
            for minor: Int64 in [0, 1, 99, 100, 123_456, -987_654_321, 1_000_000_00] {
                #expect(f.parseMinor(f.money(Money(minor: minor, currency: "EUR"))) == minor)
            }
            for raw: Int64 in [1, 150_000_000, 123_456_789_012, 99_999_999] {
                #expect(f.parseShares(f.shares(Shares(raw: raw))) == Shares(raw: raw))
            }
        }
    }

    @Test func days() {
        let today = Day(year: 2024, month: 6, day: 15)
        #expect(us.parseDay("2024-03-31", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(us.parseDay("20240331", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(us.parseDay("3/31/2024", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(us.parseDay("3/31/24", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(us.parseDay("3/31", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(us.parseDay("12/31/98", today: today) == Day(year: 1998, month: 12, day: 31))
        #expect(de.parseDay("31.3.2024", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(de.parseDay("31.03.24", today: today) == Day(year: 2024, month: 3, day: 31))
        #expect(de.parseDay("1.2.", today: today) == Day(year: 2024, month: 2, day: 1))
        #expect(de.parseDay("31.2.2024", today: today) == nil)
        #expect(us.parseDay("13/1/2024", today: today) == nil)
        #expect(us.parseDay("hello", today: today) == nil)
        for f in [us, de] {
            let d = Day(year: 2021, month: 11, day: 9)
            #expect(f.parseDay(f.day(d), today: today) == d)
        }
    }
}

@Suite struct FacadeAndHelpers {
    @Test func tsv() {
        let s = TSV.string(header: ["A", "B"], rows: [["1", "x\ty"], ["2", "line\nbreak"]])
        #expect(s == "A\tB\n1\tx y\n2\tline break\n")
        #expect(TSV.number(Decimal(string: "1234.5")!, locale: Locale(identifier: "de_DE")) == "1234,5")
        #expect(TSV.number(Decimal(string: "1234.5")!, locale: Locale(identifier: "en_US")) == "1234.5")
    }

    @Test func quickFilter() {
        let f = QuickFilter("vang  wor")
        #expect(f.matches("Vanguard FTSE All-World", "IE00BK5BQT80"))
        #expect(!f.matches("iShares Core MSCI World"))
        #expect(QuickFilter("").matches("anything"))
        #expect(QuickFilter("zurich").matches("Zürich Insurance"))
    }

    @Test func hexColors() {
        #expect(KontorUITestsSupport.components("#FF8000")! == [1, 128.0 / 255, 0, 1])
        #expect(KontorUITestsSupport.components("fff")! == [1, 1, 1, 1])
        #expect(KontorUITestsSupport.components("#00000080")![3] == 128.0 / 255)
        #expect(KontorUITestsSupport.components("#GGGGGG") == nil)
        #expect(KontorUITestsSupport.components("#12345") == nil)
    }

    @Test func periods() {
        let today = Day(year: 2024, month: 5, day: 20)
        #expect(ReportingPeriod.yearToDate.interval(today: today) == Day(year: 2023, month: 12, day: 31)...today)
        #expect(ReportingPeriod.trailingMonths(12).interval(today: today) == Day(year: 2023, month: 5, day: 20)...today)
        #expect(ReportingPeriod.monthToDate.interval(today: today) == Day(year: 2024, month: 4, day: 30)...today)
        #expect(ReportingPeriod.quarterToDate.interval(today: today) == Day(year: 2024, month: 3, day: 31)...today)
        #expect(ReportingPeriod.calendarYear(2022).interval(today: today) == Day(year: 2021, month: 12, day: 31)...Day(year: 2022, month: 12, day: 31))
        #expect(ReportingPeriod.calendarYear(2024).interval(today: today).upperBound == today)
        let inception = Day(year: 2019, month: 2, day: 1)
        #expect(ReportingPeriod.allTime.interval(today: today, inception: inception) == Day(year: 2019, month: 1, day: 31)...today)
        #expect(ReportingPeriod.custom(from: today, to: inception).interval(today: today) == inception...today)
        #expect(ReportingPeriod.trailingMonths(36).shortTitle == "3Y")
        #expect(ReportingPeriod.trailingMonths(6).shortTitle == "6M")
        #expect(ReportingPeriod.trailingMonths(12).title == "1 Year")
        // Codable round trip (persisted per window).
        for p in ReportingPeriod.presets + [.calendarYear(2023), .custom(from: inception, to: today), .quarterToDate] {
            let data = try! JSONEncoder().encode(p)
            #expect(try! JSONDecoder().decode(ReportingPeriod.self, from: data) == p)
        }
    }

    @Test func routes() {
        let id = UUID()
        #expect(Route(string: "holdings") == Route(.holdings))
        #expect(Route(string: "security:\(id.uuidString)") == .security(id))
        #expect(Route(string: "account:\(id.uuidString)") == .account(id))
        #expect(Route(string: "performance/security:\(id.uuidString)") == Route(.performance, focus: .security(id)))
        #expect(Route(string: "nonsense") == nil)
        #expect(Route(string: "security:not-a-uuid") == nil)
        for route in [Route(.trades), .security(id), .plan(id), Route(.dashboard, focus: .account(id))] {
            #expect(Route(string: route.stringValue) == route)
        }
    }

    @Test func screens() {
        #expect(AppScreen.allCases.count == 11)
        #expect(Set(AppScreen.allCases.compactMap { $0.shortcutKey?.character }).count == 10)
        #expect(AppScreen.Section.allCases.flatMap(\.screens).count == AppScreen.allCases.count)
    }
}

enum KontorUITestsSupport {
    static func components(_ hex: String) -> [Double]? {
        KontorUI.hexComponents(hex).map { [$0.r, $0.g, $0.b, $0.a] }
    }
}
