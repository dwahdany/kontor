import Foundation
import KontorModel
import Testing
@testable import KontorSampleData

@Suite struct StarterPortfolioTests {
    @Test func isMinimalAndValid() throws {
        let file = SampleData.starterPortfolio(name: "My Portfolio", baseCurrency: "CHF")
        #expect(file.name == "My Portfolio")
        #expect(file.settings.baseCurrency == "CHF")
        #expect(file.accounts.count == 1 && file.accounts[0].currency == "CHF")
        #expect(file.depots.count == 1 && file.depots[0].referenceAccountID == file.accounts[0].id)
        #expect(file.securities.isEmpty && file.transactions.isEmpty && file.plans.isEmpty && file.exchangeRates.isEmpty)
        #expect(file.taxonomies.map(\.name) == ["Asset Classes", "Regions"])
        let nodes = file.taxonomies.flatMap { Audit.allClassifications($0.root) }
        #expect(nodes.count == 13)
        #expect(nodes.allSatisfy { $0.assignments.isEmpty && $0.targetWeight == nil })
        #expect(file.dashboards.count == 1 && file.dashboards[0].widgets.count >= 6)
        #expect(Audit.violations(in: file, today: Day(year: 2026, month: 1, day: 1), expectFullCoverage: false).isEmpty)
        #expect(try PortfolioFile(data: file.encoded()) == file)
    }

    @Test func newFilesGetFreshIDs() {
        let a = SampleData.starterPortfolio(name: "A", baseCurrency: "EUR")
        let b = SampleData.starterPortfolio(name: "A", baseCurrency: "EUR")
        #expect(a.accounts[0].id != b.accounts[0].id)
        #expect(a.taxonomies[0].id != b.taxonomies[0].id)
    }
}

@Suite struct StressPortfolioTests {
    @Test func isConsistentAndExact() throws {
        let file = SampleData.stressPortfolio(securities: 40, years: 6, transactions: 5_000, seed: 3)
        #expect(file.securities.count == 40)
        #expect(file.transactions.count == 5_000)
        let violations = Audit.violations(in: file, today: SampleData.stressEndDay)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        #expect(file.transactions.sorted(by: Transaction.chronological) == file.transactions)
        let kinds = Set(file.transactions.map(\.kind))
        #expect(kinds.isSuperset(of: [.buy, .sell, .dividend, .deposit, .withdrawal, .fee, .interest, .cashTransfer]))
        #expect(file.transactions.contains { $0.securityGross?.currency == "USD" })
        #expect(file.securities.allSatisfy { ISIN.isValid($0.isin) && $0.prices.count > 1_500 })
        #expect(file.securities[0].prices.lastDay == SampleData.stressEndDay)
        #expect(try PortfolioFile(data: file.encoded()) == file)
    }

    @Test func isDeterministic() {
        let a = SampleData.stressPortfolio(securities: 10, years: 2, transactions: 800, seed: 9)
        #expect(a == SampleData.stressPortfolio(securities: 10, years: 2, transactions: 800, seed: 9))
        #expect(a != SampleData.stressPortfolio(securities: 10, years: 2, transactions: 800, seed: 10))
    }

    @Test(arguments: [(0, 1, 0), (0, 3, 50), (1, 1, 1), (3, 0, 2_000), (5, 2, 20_000)])
    func handlesEdgeSizes(securities: Int, years: Int, transactions: Int) {
        let file = SampleData.stressPortfolio(securities: securities, years: years, transactions: transactions)
        #expect(file.securities.count == securities)
        #expect(file.transactions.count == transactions)
        let violations = Audit.violations(in: file, today: SampleData.stressEndDay)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }
}

@Suite struct BuildingBlockTests {
    @Test func isinCheckDigitsMatchKnownValues() {
        // Published identifiers, used only to verify the algorithm.
        #expect(ISIN.checkDigit(for: "US037833100") == 5)
        #expect(ISIN.checkDigit(for: "DE000BAY001") == 7)
        #expect(ISIN.checkDigit(for: "GB000263494") == 6)
        #expect(ISIN.isValid("US0378331005"))
        #expect(!ISIN.isValid("US0378331006"))
        #expect(!ISIN.isValid("US037833100"))
        #expect(ISIN.checkDigit(for: "us037833100") == nil)
        #expect(ISIN.fictional(country: "IE", number: 11).hasPrefix("IEDEMO00011"))
    }

    @Test func generatorMatchesReferenceVectors() {
        // SplitMix64 reference output for seed 1234567.
        var mixer = SplitMix64(state: 1_234_567)
        #expect(mixer.next() == 6_457_827_717_110_365_317)
        #expect(mixer.next() == 3_203_168_211_198_807_973)
        var a = SampleRandom(seed: 99), b = SampleRandom(seed: 99), c = SampleRandom(seed: 100)
        let first = (0..<8).map { _ in a.next() }
        #expect(first == (0..<8).map { _ in b.next() })
        #expect(first != (0..<8).map { _ in c.next() })
        var s1 = SampleRandom(seed: 5, stream: 1), s2 = SampleRandom(seed: 5, stream: 2)
        #expect(s1.next() != s2.next())
    }

    @Test func generatorDistributionsAreSane() {
        var rng = SampleRandom(seed: 2024)
        var sum = 0.0, squares = 0.0, uniformSum = 0.0
        var buckets = [Int](repeating: 0, count: 10)
        let n = 200_000
        for _ in 0..<n {
            let g = rng.gaussian()
            sum += g
            squares += g * g
            let u = rng.unit()
            #expect(u >= 0 && u < 1)
            uniformSum += u
            buckets[rng.int(below: 10)] += 1
        }
        #expect(abs(sum / Double(n)) < 0.01)
        #expect(abs(squares / Double(n) - 1) < 0.02)
        #expect(abs(uniformSum / Double(n) - 0.5) < 0.005)
        #expect(buckets.allSatisfy { abs($0 - n / 10) < n / 200 })
        #expect((0..<1_000).allSatisfy { _ in (3...7).contains(rng.int(in: 3...7)) })
    }

    @Test func uuidsCarryVersionAndVariantBits() {
        var rng = SampleRandom(seed: 1)
        var seen = Set<UUID>()
        var previous = ""
        for i in 0..<2_000 {
            let random = rng.uuid()
            #expect(random.uuid.6 >> 4 == 4 && random.uuid.8 >> 6 == 0b10)
            let sequenced = rng.sequencedUUID(UInt64(i))
            #expect(sequenced.uuid.6 >> 4 == 7 && sequenced.uuid.8 >> 6 == 0b10)
            #expect(sequenced.uuidString > previous)
            previous = sequenced.uuidString
            #expect(seen.insert(random).inserted && seen.insert(sequenced).inserted)
        }
    }

    @Test func anchoredPathsPassThroughTheirAnchors() {
        let start = Day(year: 2020, month: 1, day: 1), end = Day(year: 2022, month: 12, day: 30)
        var model = AssetModel(startPrice: 100, betaEquity: 1, idioVol: 0.3)
        model.anchors = [(201, 0.5), (600, -0.25), (start.distance(to: end), 0.1)]
        let market = MarketSimulation(start: start, end: end, assets: [model], seed: 11)
        func level(_ offset: Int) -> Double { log(market.price(0, on: start.advanced(by: offset)).doubleValue / 100) }
        #expect(abs(level(201) - 0.5) < 0.001)
        #expect(abs(level(600) + 0.25) < 0.001)
        #expect(abs(level(start.distance(to: end)) - 0.1) < 0.001)
        #expect(market.series(0).count == 773) // trading days 2020-01-01…2022-12-30, counted independently with python
        #expect(market.series(0, through: 9).lastDay! <= start.advanced(by: 9))
    }

    @Test func assetsAreCorrelatedThroughTheSharedFactor() {
        let start = Day(year: 2015, month: 1, day: 1), end = Day(year: 2024, month: 12, day: 31)
        let equity = AssetModel(startPrice: 50, betaEquity: 1, idioVol: 0.05)
        let bond = AssetModel(startPrice: 100, betaBond: 1, idioVol: 0.01)
        let market = MarketSimulation(start: start, end: end, assets: [equity, equity, bond], seed: 5)
        func returns(_ asset: Int) -> [Double] {
            let v = market.series(asset).values
            return (1..<v.count).map { log(Double(v[$0]) / Double(v[$0 - 1])) }
        }
        func correlation(_ x: [Double], _ y: [Double]) -> Double {
            let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in x.indices {
                sxy += (x[i] - mx) * (y[i] - my)
                sxx += (x[i] - mx) * (x[i] - mx)
                syy += (y[i] - my) * (y[i] - my)
            }
            return sxy / (sxx * syy).squareRoot()
        }
        #expect(correlation(returns(0), returns(1)) > 0.8)
        #expect(abs(correlation(returns(0), returns(2))) < 0.5)
        let equityVol = (returns(0).map { $0 * $0 }.reduce(0, +) / Double(returns(0).count) * 252).squareRoot()
        #expect(equityVol > 0.10 && equityVol < 0.30)
    }
}

@Suite(.serialized) struct PerformanceTests {
    /// Best-of-n wall time in seconds.
    func measure(_ runs: Int, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<runs {
            let d = clock.measure(body)
            best = min(best, Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
        }
        return best
    }

    // Targets are < 50 ms and < 1 s in release builds; debug builds get generous headroom.
    #if DEBUG
    static let demoBudget = 1.5, stressBudget = 20.0
    #else
    static let demoBudget = 0.05, stressBudget = 1.0
    #endif

    @Test func demoPortfolioIsFast() {
        var count = 0
        let seconds = measure(5) { count = SampleData.demoPortfolio(today: Day(year: 2026, month: 11, day: 18)).transactions.count }
        print("demoPortfolio: \(seconds * 1000) ms, \(count) transactions")
        #expect(seconds < Self.demoBudget)
    }

    @Test func stressPortfolioIsFast() {
        var file = PortfolioFile()
        let seconds = measure(2) { file = SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000) }
        print("stressPortfolio: \(seconds * 1000) ms")
        #expect(seconds < Self.stressBudget)
        #expect(file.securities.count == 200 && file.transactions.count == 50_000)
        #expect(file.securities.map(\.prices.count).reduce(0, +) > 1_200_000)
    }
}
