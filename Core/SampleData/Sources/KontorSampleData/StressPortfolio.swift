import Foundation
import KontorModel

/// Builds large synthetic files for benchmarks: many instruments, long price histories and a dense,
/// internally consistent ledger.
enum StressBuilder {
    static func build(securities: Int, years: Int, transactions: Int, seed: UInt64, end: Day) -> PortfolioFile {
        let securityCount = max(0, securities), count = max(0, transactions)
        let start = end.addingYears(-max(1, years))

        var entityIDs = SampleRandom(seed: seed, stream: 1)
        var rng = SampleRandom(seed: seed, stream: 2)

        // Instruments: every fifth one is quoted in USD to exercise currency conversion.
        var models = [AssetModel]()
        models.reserveCapacity(securityCount)
        var refs = [Ledger.SecurityRef]()
        refs.reserveCapacity(securityCount)
        for i in 0..<securityCount {
            models.append(AssetModel(
                startPrice: rng.uniform(5, 300), annualDrift: rng.uniform(0.0, 0.07), betaEquity: rng.uniform(0.3, 1.4),
                betaBond: rng.uniform(0, 0.3), idioVol: rng.uniform(0.06, 0.30)))
            refs.append(.init(id: entityIDs.uuid(), currency: i % 5 == 4 ? "USD" : "EUR"))
        }
        let market = MarketSimulation(start: start, end: end, assets: models, seed: SampleRandom.subSeed(seed, stream: 3))
        let usd = FXPath(start: start, end: end, mean: 1.12, reversion: 0.002, dailyVol: 0.0045,
                         seed: SampleRandom.subSeed(seed, stream: 4))

        let accounts = [
            Account(id: entityIDs.uuid(), name: "Settlement Account 1", currency: "EUR", note: "Synthetic test data"),
            Account(id: entityIDs.uuid(), name: "Settlement Account 2", currency: "EUR", note: "Synthetic test data"),
        ]
        let depots = [
            Depot(id: entityIDs.uuid(), name: "Depot 1", referenceAccountID: accounts[0].id, note: "Synthetic test data"),
            Depot(id: entityIDs.uuid(), name: "Depot 2", referenceAccountID: accounts[1].id, note: "Synthetic test data"),
        ]
        var ledger = Ledger(
            market: market, base: "EUR", rates: ["USD": usd], securities: refs,
            accounts: accounts.map { .init(id: $0.id, currency: $0.currency) }, depots: depots.map(\.id),
            idSeed: SampleRandom.subSeed(seed, stream: 5), sequencedIDs: true, capacity: count
        )

        // Bookings are spread evenly over the trading days; each one is chosen at random and falls
        // back to a deposit when it cannot be made, so the requested count is always met exactly.
        let tradingOffsets = market.isTradingDay.indices.filter { market.isTradingDay[$0] }
        let fee = FeeModel.percent(bp: 25, min: 490, max: 5_990)
        /// A security near a random index that `depot` currently holds.
        func heldSecurity(_ depot: Int) -> Int? {
            guard securityCount > 0 else { return nil }
            let first = rng.int(below: securityCount)
            for probe in 0..<min(securityCount, 12) {
                let candidate = (first + probe) % securityCount
                if ledger.held[depot][candidate] > 0 { return candidate }
            }
            return nil
        }
        for i in 0..<count {
            let day = start.advanced(by: tradingOffsets[i * tradingOffsets.count / count])
            let depot = rng.int(below: 2) // depots settle against the account with the same index
            var booked = false
            if i >= 2 {
                switch rng.int(below: 100) {
                case 0..<50 where securityCount > 0:
                    booked = ledger.buy(
                        on: day, security: rng.int(below: securityCount), depot: depot, account: depot,
                        budget: Int64(rng.int(in: 500...6_000)) * 100, whole: rng.int(below: 2) == 0, fee: fee, minFill: 1)
                case 50..<70:
                    if let security = heldSecurity(depot) {
                        let position = ledger.held[depot][security]
                        let quantity = [position, position / 2, position / 4][rng.int(below: 3)]
                        booked = ledger.sell(on: day, security: security, depot: depot, account: depot,
                                             shares: max(quantity, 1), fee: fee, taxRate: 26_375)
                    }
                case 70..<86:
                    if let security = heldSecurity(depot) {
                        let cents = max(1, Int64(market.price(security, on: day).doubleValue * rng.uniform(0.2, 1.0)))
                        booked = ledger.dividend(
                            on: day, security: security, depot: depot, account: depot,
                            perShare: Price(raw: cents * (Scale.price / Scale.amount)), taxRate: 26_375)
                    }
                case 86..<90:
                    booked = ledger.cash(.withdrawal, on: day, account: depot, minor: ledger.balance[depot] / 10)
                case 90..<93:
                    booked = ledger.cash(.fee, on: day, account: depot, minor: Int64(rng.int(in: 100...2_500)))
                case 93..<96:
                    booked = ledger.cash(.interest, on: day, account: depot, minor: Int64(rng.int(in: 50...9_000)))
                case 96..<98:
                    booked = ledger.transfer(on: day, from: depot, to: 1 - depot, minor: ledger.balance[depot] / 5)
                default:
                    break
                }
            }
            if !booked {
                let amount = i < 2 ? 5_000_000 : Int64(rng.int(in: 1_000...20_000)) * 100
                ledger.cash(.deposit, on: day, account: i < 2 ? i : depot, minor: amount)
            }
        }

        var securityList = [Security]()
        securityList.reserveCapacity(securityCount)
        for i in 0..<securityCount {
            let number = String(i + 1)
            let label = String(repeating: "0", count: max(0, 4 - number.count)) + number
            securityList.append(Security(
                id: refs[i].id, name: "Synthetic Holding \(label)", currency: refs[i].currency,
                isin: ISIN.fictional(country: "XX", tag: "TEST", number: i + 1), ticker: "SYN\(label)",
                note: "Synthetic test data", prices: market.series(i)))
        }

        // Classify round-robin over the asset-class leaves.
        let leaves = ["Developed Markets", "Emerging Markets", "Bonds", "Commodities", "Real Estate", "Crypto"]
        var assignments = [String: [Classification.Assignment]]()
        for i in 0..<securityCount {
            assignments[leaves[i % leaves.count], default: []].append(.init(securityID: refs[i].id))
        }
        assignments["Cash"] = accounts.map { .init(accountID: $0.id) }
        let nextID = { entityIDs.uuid() }
        let taxonomy = Templates.taxonomy(
            name: Templates.assetClassesName, nodes: Templates.assetClasses, targets: true, assignments: assignments,
            nextID: nextID)
        let dashboard = Templates.dashboard(allocationTaxonomy: taxonomy.id, nextID: nextID)
        let watchlist = Watchlist(id: nextID(), name: "First Ten", securityIDs: refs.prefix(10).map(\.id))

        return PortfolioFile(
            name: "Stress Test (\(securityCount) securities, \(count) transactions)",
            settings: Settings(baseCurrency: "EUR", preferences: ["sampleData": "stress"]),
            securities: securityList, accounts: accounts, depots: depots, transactions: ledger.transactions,
            taxonomies: [taxonomy], watchlists: [watchlist], plans: [],
            exchangeRates: [usd.series(base: "EUR", quote: "USD")], dashboards: [dashboard]
        )
    }
}
