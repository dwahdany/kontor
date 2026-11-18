import Foundation
import Testing
@testable import KontorModel

@Test func dayRoundTrip() {
    #expect(Day(year: 1970, month: 1, day: 1).rawValue == 0)
    #expect(Day(year: 2024, month: 2, day: 29).iso == "2024-02-29")
    #expect(Day(iso: "2024-02-30") == nil)
    #expect(Day(iso: "2023-12-31T10:00")?.advanced(by: 1).iso == "2024-01-01")
    for raw in stride(from: Int32(-800_000), to: 800_000, by: 997) {
        let d = Day(rawValue: raw), c = d.ymd
        #expect(Day(year: c.year, month: c.month, day: c.day) == d)
        #expect(Day(iso: d.iso) == d || c.year < 0 || c.year > 9999)
    }
    #expect(Day(year: 2024, month: 1, day: 31).addingMonths(1).iso == "2024-02-29")
    #expect(Day(year: 2024, month: 1, day: 31).addingMonths(-2).iso == "2023-11-30")
    #expect(Day(year: 2026, month: 11, day: 18).weekday == 3)
}

@Test func fixedPoint() {
    #expect(Price(123.45).value(of: Shares(10)) == 123_450)
    #expect(Price(0.00000001).value(of: Shares(1)) == 0)
    #expect(Price(minor: 123_450, per: Shares(10)) == Price(123.45))
    #expect(mulDiv(-7, 3, 2) == -11)
    #expect(mulDiv(Int64.max, Int64.max, 1) == Int64.max)
    #expect(Price(60_000).value(of: Shares(1_000_000)) == 6_000_000_000_000)
}

@Test func priceSeries() {
    var s = PriceSeries()
    let d = Day(year: 2024, month: 1, day: 10)
    s.set(Price(2), on: d.advanced(by: 2))
    s.set(Price(1), on: d)
    s.set(Price(3), on: d.advanced(by: 1))
    s.merge([PricePoint(day: d, price: Price(5)), PricePoint(day: d.advanced(by: -3), price: Price(9))])
    #expect(s.map(\.price.doubleValue) == [9, 5, 3, 2])
    #expect(s.price(on: d.advanced(by: -10)) == Price(9))
    #expect(s.price(on: d.advanced(by: -10), fallbackToFirst: false) == nil)
    #expect(s.price(on: d.advanced(by: 99)) == Price(2))
    #expect(s.points(in: d...d.advanced(by: 1)).count == 2)
}

@Test func fileRoundTrip() throws {
    var f = PortfolioFile(name: "Test")
    let acc = Account(name: "Cash", currency: "EUR")
    var sec = Security(name: "World ETF", currency: "USD", feed: QuoteFeed(provider: "yahoo", symbol: "X"))
    sec.prices.set(Price(100), on: Day(year: 2024, month: 1, day: 2))
    let depot = Depot(name: "Broker", referenceAccountID: acc.id)
    f.accounts = [acc]; f.securities = [sec]; f.depots = [depot]
    let buy = Transaction(kind: .buy, date: Day(year: 2024, month: 1, day: 2), accountID: acc.id, depotID: depot.id,
                          securityID: sec.id, shares: Shares(2), amount: Money(201, "EUR"), fees: 100)
    f.transactions = [buy]
    f.taxonomies = [Taxonomy(name: "Classes", root: [Classification(name: "Equity", assignments: [.init(securityID: sec.id)])])]
    let back = try PortfolioFile(data: f.encoded())
    #expect(back == f)
    #expect(buy.cashEffect(on: acc.id) == -20_100)
    #expect(buy.sharesEffect(on: depot.id) == Shares(2))
    #expect(buy.grossMinor == 20_000)
    #expect(try PortfolioFile(data: Data("{}".utf8)).settings.baseCurrency == "EUR")
}
