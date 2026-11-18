import Foundation
import KontorEngine
import KontorModel
import Testing

@Suite struct FixedMathTests {
    @Test func marketValueMatchesModelRounding() {
        // 12.5 shares × 19.99 = 249.875 → 249.88 (half away from zero)
        #expect(FixedMath.marketValue(price: Price(19.99), shares: Shares(12.5)) == 24988)
        // 3 shares × 0.005 = 0.015 → 0.02
        #expect(FixedMath.marketValue(price: Price(0.005), shares: Shares(3)) == 2)
        // negative shares (short): −2 × 10.005 = −20.01
        #expect(FixedMath.marketValue(price: Price(10.005), shares: Shares(-2)) == -2001)

        var rng = SplitMix64(seed: 42)
        for i in 0..<20_000 {
            // Mix of realistic and extreme magnitudes on both sides of the fast-path limit (1e14).
            let pMax: Int64 = i % 7 == 0 ? 900_000_000_000_000 : 5_000_000_000_000
            let sMax: Int64 = i % 11 == 0 ? 900_000_000_000_000 : 50_000_000_000
            let p = Int64.random(in: 0...pMax, using: &rng)
            let s = Int64.random(in: (i % 13 == 0 ? -sMax : 0)...sMax, using: &rng)
            #expect(FixedMath.marketValue(priceRaw: p, sharesRaw: s) == Price(raw: p).value(of: Shares(raw: s)))
        }
        // Exactly at the half-way point and at the fast-path boundary.
        #expect(FixedMath.marketValue(priceRaw: 500_000, sharesRaw: 100_000_000) == 1) // 0.005 × 1 = 0.005 → 0.01
        #expect(FixedMath.marketValue(priceRaw: 99_999_999_999_999, sharesRaw: 99_999_999_999_999)
            == mulDiv(99_999_999_999_999, 99_999_999_999_999, 100_000_000_000_000))
    }

    @Test func conversionAndWeights() {
        #expect(FixedMath.convert(333, rate: 1.5) == 500) // 499.5 → 500
        #expect(FixedMath.convert(-333, rate: 1.5) == -500)
        #expect(FixedMath.convert(100, rate: .nan) == 0)
        #expect(FixedMath.weighted(1001, 5_000) == 501) // 500.5 → 501
        #expect(FixedMath.weighted(-1001, 5_000) == -501)
        #expect(FixedMath.weighted(777, 10_000) == 777)
        #expect(FixedMath.weighted(777, 0) == 0)
    }
}

@Suite struct CurrencyConverterTests {
    let day10 = Day(rawValue: 10), day20 = Day(rawValue: 20)

    @Test func identityDirectAndInverse() {
        let c = CurrencyConverter(
            series: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [10, 20], rates: [1.10, 1.25])],
            baseCurrency: "EUR")
        #expect(c.rate(from: "EUR", to: "EUR", on: day10) == 1)
        #expect(c.rate(from: "XXX", to: "XXX", on: day10) == 1)
        #expect(c.rate(from: "EUR", to: "USD", on: day10) == 1.10)
        #expect(c.rate(from: "USD", to: "EUR", on: day20) == 1 / 1.25)
        // 110.00 USD / 1.10 = 100.00 EUR; 100.00 EUR × 1.25 = 125.00 USD
        #expect(c.convert(minor: 11_000, from: "USD", to: "EUR", on: day10) == 10_000)
        #expect(c.convert(Money(100, "EUR"), to: "USD", on: day20) == Money(125, "USD"))
    }

    @Test func lastKnownRateSemantics() {
        let c = CurrencyConverter(
            series: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [10, 20], rates: [1.10, 1.25])],
            baseCurrency: "EUR")
        #expect(c.rate(from: "EUR", to: "USD", on: Day(rawValue: 5)) == 1.10) // before the series: first rate
        #expect(c.rate(from: "EUR", to: "USD", on: Day(rawValue: 15)) == 1.10) // gap: last known
        #expect(c.rate(from: "EUR", to: "USD", on: Day(rawValue: 19)) == 1.10)
        #expect(c.rate(from: "EUR", to: "USD", on: Day(rawValue: 20)) == 1.25)
        #expect(c.rate(from: "EUR", to: "USD", on: Day(rawValue: 999)) == 1.25)
    }

    @Test func triangulationViaBaseEURAndUSD() {
        // Via the base currency (EUR): GBP → USD = (1 / 0.85) × 1.10
        let viaBase = CurrencyConverter(
            series: [
                ExchangeRateSeries(base: "EUR", quote: "USD", days: [10], rates: [1.10]),
                ExchangeRateSeries(base: "EUR", quote: "GBP", days: [10], rates: [0.85]),
            ], baseCurrency: "EUR")
        #expect(viaBase.rate(from: "GBP", to: "USD", on: day10) == (1 / 0.85) * 1.10)
        #expect(viaBase.path(from: "GBP", to: "USD")?.legCount == 2)
        // 85.00 GBP → 100 EUR → 110.00 USD
        #expect(viaBase.convert(minor: 8_500, from: "GBP", to: "USD", on: day10) == 11_000)

        // Base CHF has no series at all; USD is the common pivot: JPY → CAD = (1 / 150) × 1.35
        let viaUSD = CurrencyConverter(
            series: [
                ExchangeRateSeries(base: "USD", quote: "JPY", days: [10], rates: [150]),
                ExchangeRateSeries(base: "USD", quote: "CAD", days: [10], rates: [1.35]),
            ], baseCurrency: "CHF")
        #expect(viaUSD.rate(from: "JPY", to: "CAD", on: day10) == (1.0 / 150) * 1.35)

        // EUR pivot with a non-EUR base: SEK → NOK through EUR/SEK and NOK/EUR (inverse leg)
        let viaEUR = CurrencyConverter(
            series: [
                ExchangeRateSeries(base: "EUR", quote: "SEK", days: [10], rates: [11.0]),
                ExchangeRateSeries(base: "NOK", quote: "EUR", days: [10], rates: [0.09]),
            ], baseCurrency: "USD")
        #expect(viaEUR.rate(from: "SEK", to: "NOK", on: day10) == (1 / 11.0) * (1 / 0.09))
    }

    @Test func missingRatesAreReportedNotFatal() {
        let c = CurrencyConverter(
            series: [
                ExchangeRateSeries(base: "EUR", quote: "USD", days: [10], rates: [1.10]),
                ExchangeRateSeries(base: "EUR", quote: "BAD", days: [10, 11], rates: [0, .nan]), // unusable
                ExchangeRateSeries(base: "EUR", quote: "NIL"), // empty
            ], baseCurrency: "EUR")
        #expect(c.rate(from: "JPY", to: "EUR", on: day10) == nil)
        #expect(c.convert(minor: 100, from: "JPY", to: "EUR", on: day10) == nil)
        #expect(c.rate(from: "BAD", to: "EUR", on: day10) == nil)
        #expect(c.rate(from: "NIL", to: "EUR", on: day10) == nil)
        #expect(!c.canConvert(from: "JPY", to: "USD"))
        #expect(c.pairs.count == 1)
    }

    @Test func dailyRatesEqualPointLookups() {
        let c = CurrencyConverter(
            series: [
                ExchangeRateSeries(base: "EUR", quote: "USD", days: [10, 12, 13, 20], rates: [1.10, 1.12, 1.08, 1.25]),
                ExchangeRateSeries(base: "EUR", quote: "GBP", days: [11, 18], rates: [0.85, 0.9]),
                // Unsorted input and a duplicate pair are merged (later wins).
                ExchangeRateSeries(base: "EUR", quote: "GBP", days: [25, 18], rates: [0.95, 0.91]),
            ], baseCurrency: "EUR")
        for (from, to) in [("EUR", "USD"), ("USD", "EUR"), ("GBP", "USD"), ("USD", "GBP")] {
            let path = c.path(from: from, to: to)!
            let dense = c.dailyRates(along: path, from: Day(rawValue: 5), count: 30)
            for i in 0..<30 {
                #expect(dense[i] == c.rate(along: path, on: Day(rawValue: Int32(5 + i))))
            }
        }
        #expect(c.rate(from: "EUR", to: "GBP", on: Day(rawValue: 18)) == 0.91)
        #expect(c.rate(from: "EUR", to: "GBP", on: Day(rawValue: 30)) == 0.95)
    }
}

@Suite struct LedgerTests {
    @Test func emptyFile() {
        let ledger = Ledger(PortfolioFile())
        #expect(ledger.transactions.isEmpty)
        #expect(ledger.firstTransactionDay == nil)
        let snapshot = ledger.snapshot(on: d("2024-01-01"))
        #expect(snapshot.totalValue == Money.zero("EUR"))
        #expect(snapshot.positions.isEmpty && snapshot.cash.isEmpty)
        let interval = DayInterval(start: d("2023-12-31"), end: d("2024-12-31"))
        let report = ledger.performance(in: interval)
        #expect(report.valuation.count == 367)
        #expect(report.valuation.values.allSatisfy { $0 == 0 })
        #expect(report.ttwror == 0)
        #expect(report.irr == nil)
        #expect(report.securities.isEmpty)
        #expect(report.breakdown.finalValue == 0 && report.breakdown.roundingResidue == 0)
        #expect(report.risk.maxDrawdown == nil && report.risk.volatility == 0 && report.risk.sharpeRatio == nil)
        // Zero-length interval.
        let point = ledger.performance(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-01")))
        #expect(point.valuation.count == 1 && point.ttwror == 0 && point.ttwrorAnnualized == nil)
    }

    @Test func chronologicalOrderAndGrouping() {
        let file = makeRandomPortfolio(RandomPortfolioOptions(seed: 7, transactions: 600))
        let ledger = Ledger(file)
        #expect(ledger.transactions.count == file.transactions.count)
        #expect(ledger.transactions.map(\.id) == file.transactions.sorted(by: Transaction.chronological).map(\.id))
        #expect(ledger.firstTransactionDay == ledger.transactions.first?.date)
        #expect(ledger.lastTransactionDay == ledger.transactions.last?.date)

        for s in file.securities {
            let expected = ledger.transactions.filter { $0.securityID == s.id }.map(\.id)
            #expect(ledger.transactions(forSecurity: s.id).map(\.id) == expected)
            #expect(ledger.security(s.id) == s)
        }
        for a in file.accounts {
            let expected = ledger.transactions
                .filter { $0.kind.requiresAccount && ($0.accountID == a.id || $0.counterAccountID == a.id) }.map(\.id)
            #expect(ledger.transactions(forAccount: a.id).map(\.id) == expected)
        }
        for depot in file.depots {
            let expected = ledger.transactions
                .filter { $0.depotID == depot.id || ($0.kind == .securityTransfer && $0.counterDepotID == depot.id) }
                .map(\.id)
            #expect(ledger.transactions(forDepot: depot.id).map(\.id) == expected)
        }
        #expect(ledger.account(UUID()) == nil)
        #expect(ledger.securityIndex(file.securities[3].id) == 3)
    }

    @Test func invalidTransactionsAreSkippedAndReported() {
        var f = Fixture()
        let account = f.account("Cash")
        let depot = f.depot("Depot")
        let stock = f.security("Stock", prices: [("2024-01-02", 10)])
        f.add(.deposit, "2024-01-01", account: account, amount: 100)
        let noAccount = f.add(.deposit, "2024-01-01", amount: 50)
        let unknownSecurity = f.add(.buy, "2024-01-02", account: account, depot: depot, security: UUID(), shares: 1, amount: 10)
        let noDepot = f.add(.buy, "2024-01-02", account: account, security: stock, shares: 1, amount: 10)
        let noTarget = f.add(.cashTransfer, "2024-01-02", account: account, amount: 10)
        let ledger = f.ledger
        #expect(ledger.transactions.count == 5)
        #expect(ledger.snapshot(on: d("2024-01-03")).totalValue.minor == 10_000)
        let flagged = Set(ledger.diagnostics.compactMap { diagnostic -> UUID? in
            if case .invalidTransaction(let id, _) = diagnostic { return id }
            return nil
        })
        #expect(flagged == [noAccount, unknownSecurity, noDepot, noTarget])
    }

    @Test func effectivePrices() {
        var f = Fixture()
        let account = f.account("Cash")
        let depot = f.depot("Depot")
        let quoted = f.security("Quoted", prices: [("2024-01-10", 10), ("2024-01-12", 12)])
        let unquoted = f.security("Unquoted")
        let unknown = f.security("No data")
        // 4 shares for 100.00 + 2.00 fees → derived price 25.00
        f.add(.buy, "2024-01-05", account: account, depot: depot, security: unquoted, shares: 4, amount: 102, fees: 2)
        // 2 shares sold for 59.00 + 1.00 fees = 60.00 gross → derived price 30.00
        f.add(.sell, "2024-01-08", account: account, depot: depot, security: unquoted, shares: 2, amount: 59, fees: 1)
        f.add(.deliveryIn, "2024-01-05", depot: depot, security: unknown, shares: 3, amount: 0)
        let ledger = f.ledger

        #expect(ledger.price(of: quoted, on: d("2024-01-01"))?.price == Price(10)) // before the series: first quote
        #expect(ledger.price(of: quoted, on: d("2024-01-11")) == PricePoint(day: d("2024-01-10"), price: Price(10)))
        #expect(ledger.price(of: quoted, on: d("2024-02-01"))?.price == Price(12))
        #expect(ledger.price(of: unquoted, on: d("2024-01-06"))?.price == Price(25))
        #expect(ledger.price(of: unquoted, on: d("2024-01-09"))?.price == Price(30))
        #expect(ledger.price(of: unknown, on: d("2024-01-09")) == nil)
        #expect(ledger.diagnostics.contains(.pricesDerivedFromTransactions(securityID: unquoted)))

        // No quotes at all: the position is listed but valued at zero and flagged.
        let snapshot = ledger.snapshot(on: d("2024-01-09"))
        let position = snapshot.position(unknown)
        #expect(position?.shares == Shares(3))
        #expect(position?.isValued == false && position?.value.minor == 0 && position?.price == nil)
        #expect(snapshot.diagnostics.contains(.missingPrice(securityID: unknown)))
        // 2 remaining shares × 30.00 = 60.00; cash −102 + 59 = −43.00
        #expect(snapshot.position(unquoted)?.value.minor == 6_000)
        #expect(snapshot.totalValue.minor == 6_000 - 4_300)
        let series = ledger.valuation(in: DayInterval(start: d("2024-01-01"), end: d("2024-01-09")))
        #expect(series.diagnostics.contains(.missingPrice(securityID: unknown)))
        #expect(series.finalValue == 1_700)
    }

    @Test func ledgerBuildIsFast() {
        let file = makeRandomPortfolio(RandomPortfolioOptions(seed: 3, securities: 40, days: 3_650, transactions: 10_000))
        var count = 0
        let ms = bestMilliseconds { count = Ledger(file).transactions.count }
        print("[benchmark] Ledger build, \(count) transactions (shuffled input): \(String(format: "%.2f", ms)) ms")
        #if DEBUG
        #expect(ms < 2_000)
        #else
        #expect(ms < 40)
        #endif
    }
}
