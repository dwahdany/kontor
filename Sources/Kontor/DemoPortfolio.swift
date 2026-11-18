import Foundation
import KontorModel

/// A small, deterministic demo portfolio for the welcome window and screenshots.
///
/// Temporary: `KontorSampleData` will replace this. Everything is isolated behind `make(today:)`.
enum DemoPortfolio {
    static func make(today: Day = .today) -> PortfolioFile {
        var rng = SplitMix64(seed: 0x4B4F_4E54_4F52)
        // Entity ids come from their own generator so they are identical on every run — screenshots
        // can address entities with `--route security:<uuid>`.
        var ids = SplitMix64(seed: 0x1D5_C0FFEE)
        let start = today.addingYears(-4).startOfMonth

        // Securities with synthetic but plausible random-walk histories.
        struct Spec {
            let name: String, isin: String, ticker: String, currency: String
            let startPrice: Double, drift: Double, volatility: Double
        }
        let specs = [
            Spec(name: "Global Equity Index ETF", isin: "IE00DEMO0001", ticker: "GLEQ", currency: "EUR", startPrice: 78, drift: 0.085, volatility: 0.15),
            Spec(name: "Emerging Markets ETF", isin: "IE00DEMO0002", ticker: "EMMA", currency: "EUR", startPrice: 26, drift: 0.045, volatility: 0.19),
            Spec(name: "Euro Government Bonds ETF", isin: "LU00DEMO0003", ticker: "EGOV", currency: "EUR", startPrice: 128, drift: 0.012, volatility: 0.05),
            Spec(name: "Northwind Software Inc.", isin: "US00DEMO0004", ticker: "NWSW", currency: "USD", startPrice: 142, drift: 0.16, volatility: 0.31),
            Spec(name: "Helvetia Pharma AG", isin: "CH00DEMO0005", ticker: "HEPH", currency: "CHF", startPrice: 265, drift: 0.05, volatility: 0.17),
            Spec(name: "Physical Gold ETC", isin: "DE00DEMO0006", ticker: "AURM", currency: "EUR", startPrice: 49, drift: 0.09, volatility: 0.13),
        ]
        var securities = specs.map { spec -> Security in
            var points = [PricePoint]()
            var price = spec.startPrice
            let dailyDrift = spec.drift / 252, dailyVol = spec.volatility / 252.0.squareRoot()
            for day in stride(from: start, through: today, by: 1) where !day.isWeekend {
                price *= exp(dailyDrift - dailyVol * dailyVol / 2 + dailyVol * rng.nextGaussian())
                points.append(PricePoint(day: day, price: Price((price * 100).rounded() / 100)))
            }
            return Security(
                id: ids.nextUUID(), name: spec.name, currency: spec.currency, isin: spec.isin, ticker: spec.ticker,
                feed: .manual, prices: PriceSeries(points)
            )
        }
        var benchmark = Security(id: ids.nextUUID(), name: "World Index (Benchmark)", currency: "EUR", ticker: "WLDX", note: "Benchmark only")
        do {
            var points = [PricePoint]()
            var level = 2_900.0
            for day in stride(from: start, through: today, by: 1) where !day.isWeekend {
                level *= exp(0.075 / 252 + 0.14 / 252.0.squareRoot() * rng.nextGaussian())
                points.append(PricePoint(day: day, price: Price((level * 100).rounded() / 100)))
            }
            benchmark.prices = PriceSeries(points)
        }

        let checking = Account(id: ids.nextUUID(), name: "Broker Cash", currency: "EUR")
        let savings = Account(id: ids.nextUUID(), name: "Savings", currency: "EUR", note: "Emergency fund")
        let usd = Account(id: ids.nextUUID(), name: "USD Cash", currency: "USD")
        let depot = Depot(id: ids.nextUUID(), name: "Main Depot", referenceAccountID: checking.id)
        let legacy = Depot(id: ids.nextUUID(), name: "Old Broker", referenceAccountID: checking.id, isRetired: true)

        var transactions = [Transaction]()
        func eur(_ value: Double) -> Money { Money(value, "EUR") }
        transactions.append(Transaction(id: ids.nextUUID(), kind: .deposit, date: start, accountID: checking.id, amount: eur(25_000), note: "Opening balance"))
        transactions.append(Transaction(id: ids.nextUUID(), kind: .deposit, date: start, accountID: savings.id, amount: eur(12_000)))
        transactions.append(Transaction(id: ids.nextUUID(), kind: .deposit, date: start.advanced(by: 3), accountID: usd.id, amount: Money(6_000, "USD")))

        // Monthly salary savings + a savings plan into the two equity ETFs, quarterly bonds/gold.
        var month = start
        var index = 0
        while month <= today {
            let payday = month.advanced(by: 1)
            if payday <= today {
                transactions.append(Transaction(id: ids.nextUUID(), kind: .deposit, date: payday, accountID: checking.id, amount: eur(1_200), note: "Monthly savings"))
            }
            let buyDay = month.advanced(by: 4)
            if buyDay <= today {
                for (securityIndex, budget) in [(0, 700.0), (1, 200.0)] + (index % 3 == 0 ? [(2, 600.0), (5, 300.0)] : []) {
                    guard let price = securities[securityIndex].prices.price(on: buyDay) else { continue }
                    let fee = 1.5
                    let shares = Shares(((budget - fee) / price.doubleValue * 1_000).rounded() / 1_000)
                    let gross = price.value(of: shares)
                    transactions.append(Transaction(
                        id: ids.nextUUID(), kind: .buy, date: buyDay, accountID: checking.id, depotID: depot.id,
                        securityID: securities[securityIndex].id, shares: shares,
                        amount: Money(minor: gross + 150, currency: "EUR"), fees: 150, source: "plan"
                    ))
                }
            }
            if index % 3 == 2 {
                let day = month.advanced(by: 14)
                if day <= today {
                    let gross = Int64(2_400 + index * 55)
                    let tax = gross * 26 / 100
                    transactions.append(Transaction(
                        id: ids.nextUUID(), kind: .dividend, date: day, accountID: checking.id, securityID: securities[0].id,
                        amount: Money(minor: gross - tax, currency: "EUR"), taxes: tax
                    ))
                }
            }
            if index % 12 == 11 {
                let day = month.endOfMonth
                if day <= today {
                    transactions.append(Transaction(id: ids.nextUUID(), kind: .interest, date: day, accountID: savings.id, amount: eur(180 + Double(index))))
                }
            }
            month = month.addingMonths(1)
            index += 1
        }

        // A few single-stock trades, including a realised gain.
        func trade(_ kind: Transaction.Kind, _ securityIndex: Int, monthsAfterStart: Int, shares: Double, account: Account) {
            let day = start.addingMonths(monthsAfterStart).advanced(by: 9)
            guard day <= today, let price = securities[securityIndex].prices.price(on: day) else { return }
            let s = Shares(shares)
            let gross = price.value(of: s)
            let fee: Int64 = 490
            transactions.append(Transaction(
                id: ids.nextUUID(), kind: kind, date: day, accountID: account.id, depotID: depot.id, securityID: securities[securityIndex].id,
                shares: s, amount: Money(minor: kind == .buy ? gross + fee : gross - fee, currency: account.currency), fees: fee
            ))
        }
        trade(.buy, 3, monthsAfterStart: 2, shares: 20, account: usd)
        trade(.buy, 4, monthsAfterStart: 5, shares: 12, account: checking)
        trade(.sell, 3, monthsAfterStart: 26, shares: 8, account: usd)
        trade(.buy, 3, monthsAfterStart: 34, shares: 5, account: usd)
        transactions.sort(by: Transaction.chronological)

        func rates(_ base: String, _ level: Double) -> ExchangeRateSeries {
            var days = [Int32](), values = [Double]()
            var rate = level
            for day in stride(from: start, through: today, by: 1) where !day.isWeekend {
                rate *= exp(0.06 / 252.0.squareRoot() * rng.nextGaussian())
                days.append(day.rawValue)
                values.append((rate * 10_000).rounded() / 10_000)
            }
            return ExchangeRateSeries(base: "EUR", quote: base, days: days, rates: values)
        }

        let assetClasses = Taxonomy(id: ids.nextUUID(), name: "Asset Classes", root: [
            Classification(id: ids.nextUUID(), name: "Equity", color: "#2A78D6", targetWeight: 6_500, children: [
                Classification(id: ids.nextUUID(), name: "Developed Markets", color: "#2A78D6", targetWeight: 7_500, assignments: [
                    .init(securityID: securities[0].id), .init(securityID: securities[3].id), .init(securityID: securities[4].id),
                ]),
                Classification(id: ids.nextUUID(), name: "Emerging Markets", color: "#6250D6", targetWeight: 2_500, assignments: [.init(securityID: securities[1].id)]),
            ]),
            Classification(id: ids.nextUUID(), name: "Bonds", color: "#1BAF7A", targetWeight: 2_000, assignments: [.init(securityID: securities[2].id)]),
            Classification(id: ids.nextUUID(), name: "Commodities", color: "#EDA100", targetWeight: 500, assignments: [.init(securityID: securities[5].id)]),
            Classification(id: ids.nextUUID(), name: "Cash", color: "#9A9AA0", targetWeight: 1_000, assignments: [
                .init(accountID: checking.id), .init(accountID: savings.id), .init(accountID: usd.id),
            ]),
        ])

        securities.append(benchmark)
        var file = PortfolioFile(name: "Demo Portfolio")
        file.settings = Settings(baseCurrency: "EUR", costMethod: .fifo, benchmarkSecurityIDs: [benchmark.id], riskFreeRate: 0.02)
        file.securities = securities
        file.accounts = [checking, savings, usd]
        file.depots = [depot, legacy]
        file.transactions = transactions
        file.taxonomies = [assetClasses]
        file.watchlists = [Watchlist(id: ids.nextUUID(), name: "Watchlist", securityIDs: [securities[3].id, securities[4].id])]
        file.plans = [
            InvestmentPlan(id: ids.nextUUID(), name: "Global ETF savings plan", securityID: securities[0].id, depotID: depot.id, accountID: checking.id, amount: eur(700), fees: 150, start: start.advanced(by: 4)),
            InvestmentPlan(id: ids.nextUUID(), name: "Emerging Markets savings plan", securityID: securities[1].id, depotID: depot.id, accountID: checking.id, amount: eur(200), fees: 150, start: start.advanced(by: 4)),
            InvestmentPlan(id: ids.nextUUID(), name: "Monthly savings", kind: .deposit, accountID: checking.id, amount: eur(1_200), start: start.advanced(by: 1)),
        ]
        file.exchangeRates = [rates("USD", 1.09), rates("CHF", 0.96)]
        return file
    }
}

/// Small deterministic PRNG so the demo looks identical on every launch.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A deterministic (version 4 formatted) UUID.
    mutating func nextUUID() -> UUID {
        let a = next(), b = next()
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: a >> UInt64(shift))) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: b >> UInt64(shift))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Uniform in (0, 1).
    mutating func nextUnit() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }

    /// Standard normal (Box–Muller).
    mutating func nextGaussian() -> Double {
        let u1 = nextUnit(), u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
