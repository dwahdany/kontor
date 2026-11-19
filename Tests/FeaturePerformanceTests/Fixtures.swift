import Foundation
import KontorUI
@testable import FeaturePerformance

/// Small hand-made portfolios for the cases the demo portfolio does not contain.
enum Fixture {
    static let today = Day(year: 2026, month: 6, day: 30)

    static let cash = UUID(), usdCash = UUID()
    static let depotA = UUID(), depotB = UUID()
    static let quoted = UUID(), other = UUID(), unquoted = UUID(), neverPriced = UUID()

    private static func eur(_ value: Double) -> Money { Money(value, "EUR") }

    private static func prices(_ points: [(Day, Double)]) -> PriceSeries {
        PriceSeries(points.map { PricePoint(day: $0.0, price: Price($0.1)) })
    }

    /// Two depots settling against one account. "Quoted AG" is held in depot A only; its dividend
    /// and a fee are booked on the account without a depot, the way Portfolio Performance exports
    /// them. With `heldInBoth` depot B buys it too before the dividend, so the booking is ambiguous.
    static func twoDepots(heldInBoth: Bool = false) -> PortfolioFile {
        let d = { (month: Int, day: Int) in Day(year: 2025, month: month, day: day) }
        var transactions = [
            Transaction(kind: .deposit, date: d(1, 2), accountID: cash, amount: eur(50_000)),
            Transaction(kind: .buy, date: d(1, 10), accountID: cash, depotID: depotA, securityID: quoted, shares: Shares(100),
                        amount: eur(10_010), fees: 1_000),
            Transaction(kind: .buy, date: d(1, 10), accountID: cash, depotID: depotB, securityID: other, shares: Shares(50),
                        amount: eur(6_000)),
            Transaction(kind: .dividend, date: d(6, 2), accountID: cash, securityID: quoted, shares: Shares(100),
                        amount: eur(300), taxes: 10_000),
            Transaction(kind: .fee, date: d(6, 3), accountID: cash, securityID: quoted, amount: eur(25)),
            Transaction(kind: .tax, date: d(6, 4), accountID: cash, securityID: quoted, amount: eur(12)),
            Transaction(kind: .taxRefund, date: d(7, 4), accountID: cash, securityID: quoted, amount: eur(5)),
        ]
        if heldInBoth {
            transactions.append(Transaction(kind: .buy, date: d(3, 3), accountID: cash, depotID: depotB, securityID: quoted,
                                            shares: Shares(10), amount: eur(1_050)))
        }
        return PortfolioFile(
            name: "Two Depots",
            securities: [
                Security(id: quoted, name: "Quoted AG", currency: "EUR", prices: prices([(d(1, 10), 100), (d(12, 30), 104), (today, 110)])),
                Security(id: other, name: "Other SE", currency: "EUR", prices: prices([(d(1, 10), 120), (today, 126)])),
            ],
            accounts: [Account(id: cash, name: "Cash Account", currency: "EUR")],
            depots: [Depot(id: depotA, name: "Depot", referenceAccountID: cash),
                     Depot(id: depotB, name: "Second Depot", referenceAccountID: cash)],
            transactions: transactions)
    }

    /// A USD account without any exchange rate, a security without quotes (bought twice at
    /// different prices) and a security that has neither quotes nor transactions.
    static func incompleteData() -> PortfolioFile {
        let d = { (month: Int, day: Int) in Day(year: 2025, month: month, day: day) }
        return PortfolioFile(
            name: "Edge",
            securities: [
                Security(id: quoted, name: "Quoted AG", currency: "EUR", prices: prices([(d(1, 10), 100), (today, 110)])),
                Security(id: unquoted, name: "Unquoted Holding KG", currency: "EUR"),
                Security(id: neverPriced, name: "Never Priced Index", currency: "EUR"),
            ],
            accounts: [Account(id: cash, name: "Cash Account", currency: "EUR"),
                       Account(id: usdCash, name: "USD no rates", currency: "USD")],
            depots: [Depot(id: depotA, name: "Depot", referenceAccountID: cash)],
            transactions: [
                Transaction(kind: .deposit, date: d(1, 2), accountID: cash, amount: eur(50_000)),
                Transaction(kind: .deposit, date: d(1, 3), accountID: usdCash, amount: Money(5_000, "USD")),
                Transaction(kind: .buy, date: d(1, 10), accountID: cash, depotID: depotA, securityID: quoted, shares: Shares(100),
                            amount: eur(10_000)),
                Transaction(kind: .buy, date: d(2, 3), accountID: cash, depotID: depotA, securityID: unquoted, shares: Shares(100),
                            amount: eur(5_000)),
                Transaction(kind: .buy, date: d(5, 5), accountID: cash, depotID: depotA, securityID: unquoted, shares: Shares(100),
                            amount: eur(7_000)),
            ])
    }

    /// A single deposit on `day`.
    static func singleDeposit(on day: Day) -> PortfolioFile {
        PortfolioFile(name: "Deposit", accounts: [Account(id: cash, name: "Cash Account", currency: "EUR")],
                      transactions: [Transaction(kind: .deposit, date: day, accountID: cash, amount: eur(1_000))])
    }
}
