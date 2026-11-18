import Foundation
import KontorModel
import Testing
@testable import KontorSampleData

private let referenceDay = Day(year: 2026, month: 11, day: 18)

@Suite struct DemoPortfolioTests {
    let file = SampleData.demoPortfolio(today: referenceDay, seed: 42)

    func security(_ index: Int) -> Security { file.securities[index] }

    @Test func isConsistent() {
        let violations = Audit.violations(in: file, today: referenceDay)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test func isDeterministic() {
        #expect(SampleData.demoPortfolio(today: referenceDay, seed: 42) == file)
        let other = SampleData.demoPortfolio(today: referenceDay, seed: 43)
        #expect(other != file)
        #expect(other.securities.map(\.id) != file.securities.map(\.id))
        #expect(other.securities[0].prices != file.securities[0].prices)
        #expect(other.transactions.map(\.id) != file.transactions.map(\.id))
    }

    @Test func entityIDsAreStableAcrossDays() {
        let later = SampleData.demoPortfolio(today: referenceDay.advanced(by: 40), seed: 42)
        #expect(later.securities.map(\.id) == file.securities.map(\.id))
        #expect(later.accounts.map(\.id) == file.accounts.map(\.id))
        #expect(later.taxonomies.map(\.id) == file.taxonomies.map(\.id))
        #expect(later.plans.map(\.id) == file.plans.map(\.id))
    }

    @Test func idsAreWellFormedUUIDs() {
        for id in file.securities.map(\.id) + file.transactions.prefix(50).map(\.id) {
            let bytes = id.uuid
            #expect(bytes.6 >> 4 == 4)
            #expect(bytes.8 >> 6 == 0b10)
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try file.encoded()
        #expect(try PortfolioFile(data: data) == file)
        #expect(try PortfolioFile(data: file.encoded(pretty: true)) == file)
    }

    @Test(arguments: [
        Day(year: 2015, month: 1, day: 1), Day(year: 2016, month: 2, day: 29), Day(year: 2019, month: 6, day: 15),
        Day(year: 2020, month: 3, day: 1), Day(year: 2024, month: 12, day: 31), Day(year: 2026, month: 11, day: 22),
        Day(year: 2028, month: 2, day: 29), Day(year: 2031, month: 7, day: 4), Day(year: 2036, month: 10, day: 31),
        Day(year: 2040, month: 12, day: 31),
    ])
    func worksForAnyToday(today: Day) throws {
        let file = SampleData.demoPortfolio(today: today, seed: 7)
        let violations = Audit.violations(in: file, today: today)
        #expect(violations.isEmpty, "\(today): \(violations.joined(separator: "\n"))")
        #expect((500...700).contains(file.transactions.count), "\(file.transactions.count) transactions")
        #expect(file.securities[DemoBuilder.S.crypto].prices.lastDay == today)
        #expect(file.transactions.map(\.date).max()! > today.advanced(by: -35))
        try expectStory(in: file)
    }

    @Test func holdsForManySeeds() throws {
        for seed in UInt64(0)..<25 {
            let today = referenceDay.advanced(by: Int(seed) * 37)
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let violations = Audit.violations(in: file, today: today)
            #expect(violations.isEmpty, "seed \(seed): \(violations.joined(separator: "\n"))")
            #expect((500...700).contains(file.transactions.count), "seed \(seed): \(file.transactions.count) transactions")
            try expectStory(in: file)
        }
    }

    /// The scripted highlights must be present whatever the seed.
    func expectStory(in file: PortfolioFile) throws {
        let kinds = Set(file.transactions.map(\.kind))
        let expected: Set<Transaction.Kind> = [
            .buy, .sell, .deliveryIn, .deposit, .withdrawal, .dividend, .interest, .fee, .feeRefund, .tax, .taxRefund,
            .cashTransfer, .securityTransfer,
        ]
        #expect(kinds.isSuperset(of: expected), "missing \(expected.subtracting(kinds))")

        // Realized results per sale against the average cost in the transaction currency.
        var shares = [UUID: Int64](), cost = [UUID: Int64]()
        var gains = [(security: UUID, gain: Int64, complete: Bool)]()
        for tx in file.transactions.sorted(by: Transaction.chronological) {
            guard let id = tx.securityID else { continue }
            switch tx.kind {
            case .buy, .deliveryIn:
                shares[id, default: 0] += tx.shares.raw
                cost[id, default: 0] += tx.grossMinor
            case .sell:
                let basis = mulDiv(cost[id] ?? 0, tx.shares.raw, shares[id] ?? 1)
                shares[id, default: 0] -= tx.shares.raw
                cost[id, default: 0] -= basis
                gains.append((id, tx.grossMinor - basis, shares[id] == 0))
            default: break
            }
        }
        let quillon = file.securities[DemoBuilder.S.quillon].id, solvane = file.securities[DemoBuilder.S.solvane].id
        let partialGain = try #require(gains.first { $0.security == quillon })
        #expect(partialGain.gain > 0 && !partialGain.complete)
        let exit = try #require(gains.first { $0.security == solvane })
        #expect(exit.gain < 0 && exit.complete)
        #expect(partialGain.gain > 0 && partialGain.gain > -exit.gain / 10)

        // Taxes withheld on the winning sale, none on the losing one.
        let sells = file.transactions.filter { $0.kind == .sell }
        #expect(sells.count >= 4)
        #expect(sells.first { $0.securityID == quillon }!.taxes > 0)
        #expect(sells.first { $0.securityID == solvane }!.taxes == 0)

        // Retired security: fully sold, flagged, and no longer quoted.
        let holdings = Audit.holdings(file)
        #expect(holdings[solvane] == 0)
        #expect(file.securities.filter(\.isRetired).map(\.id) == [solvane])
        // Everything else that is not a benchmark is still held.
        let benchmarks = Set(file.settings.benchmarkSecurityIDs)
        #expect(benchmarks.count == 2)
        for security in file.securities where security.id != solvane {
            if benchmarks.contains(security.id) {
                #expect(holdings[security.id] == nil, "benchmark \(security.name) must not be held")
            } else {
                #expect((holdings[security.id] ?? 0) > 0, "\(security.name) should be held")
            }
        }
        for (_, balance) in Audit.balances(file) { #expect(balance > 0) }
    }

    @Test func hasExpectedShape() {
        #expect(file.name == "Demo Portfolio")
        #expect(file.settings.baseCurrency == "EUR")
        #expect(file.securities.count == 16)
        #expect(Set(file.securities.map(\.currency)) == ["EUR", "USD", "GBP"])
        #expect(file.accounts.map(\.currency) == ["EUR", "EUR", "USD"])
        #expect(file.depots.count == 2)
        #expect(Set(file.depots.compactMap(\.referenceAccountID)).count == 2)
        #expect(file.watchlists.count == 2)
        #expect(file.exchangeRates.map(\.quote) == ["USD", "GBP"])
        #expect(file.exchangeRates.allSatisfy { $0.base == "EUR" })
        #expect(file.taxonomies.map(\.name) == ["Asset Classes", "Regions", "Investment Type"])
        #expect(file.securities.filter { $0.feed != nil }.allSatisfy { $0.feed?.provider == "manual" })
        #expect(file.securities.filter { $0.feed != nil }.count >= 3)
        #expect(file.securities.filter { $0.attributes["TER"] != nil }.count >= 6)
        #expect(file.securities.allSatisfy { $0.note.contains("Demo data") })
        #expect(file.accounts.allSatisfy { $0.note.contains("Demo data") })
        #expect((500...700).contains(file.transactions.count), "\(file.transactions.count) transactions")
    }

    @Test func isinsAreFictionalAndValid() {
        let isins = file.securities.map(\.isin).filter { !$0.isEmpty }
        #expect(isins.count == 13)
        #expect(Set(isins).count == isins.count)
        for isin in isins {
            #expect(ISIN.isValid(isin), "\(isin)")
            #expect(isin.contains("DEMO"))
        }
    }

    @Test func priceHistoryIsPlausible() {
        let start = referenceDay.addingYears(-9).startOfMonth
        for (index, security) in file.securities.enumerated() {
            let prices = security.prices
            #expect(prices.firstDay! <= start.advanced(by: 2))
            if index == DemoBuilder.S.crypto {
                #expect(prices.count == start.distance(to: referenceDay) + 1)
                #expect(prices.contains { $0.day.isWeekend })
            } else {
                #expect(!prices.contains { $0.day.isWeekend }, "\(security.name) quoted on a weekend")
                if !security.isRetired { #expect(prices.count > 2_300) }
            }
            // No absurd single-day moves outside crypto.
            if index != DemoBuilder.S.crypto {
                for i in 1..<prices.count {
                    let ratio = Double(prices.values[i]) / Double(prices.values[i - 1])
                    #expect(ratio > 0.7 && ratio < 1.4, "\(security.name) jumped \(ratio) on \(prices[i].day)")
                }
            }
        }
        // The global equity path has a real drawdown and still ends well above its start.
        let global = security(DemoBuilder.S.global).prices
        var peak = 0.0, drawdown = 0.0
        for v in global.values {
            peak = max(peak, Double(v))
            drawdown = max(drawdown, 1 - Double(v) / peak)
        }
        #expect(drawdown > 0.2 && drawdown < 0.6)
        #expect(Double(global.values.last!) / Double(global.values.first!) > 1.5)
        // Rates stay in a realistic corridor.
        #expect(file.exchangeRates[0].rates.allSatisfy { $0 > 0.85 && $0 < 1.5 })
        #expect(file.exchangeRates[1].rates.allSatisfy { $0 > 0.65 && $0 < 1.1 })
    }

    @Test func plansHavePastExecutionsInTheLedger() throws {
        #expect(file.plans.map(\.kind) == [.purchase, .deposit])
        for plan in file.plans {
            let executions = file.transactions.filter { $0.source == "plan:\(plan.id.uuidString)" }
            #expect(executions.count >= 100, "\(plan.name): \(executions.count)")
            #expect(executions.allSatisfy { $0.amount == plan.amount && $0.accountID == plan.accountID })
            // The plan keeps its nominal day; executions roll forward to the next trading day.
            #expect(executions.map(\.date).min() == ReferenceCalendar.tradingDay(onOrAfter: plan.start))
            #expect(Set(executions.map { $0.date.year * 12 + $0.date.month }).count == executions.count)
            switch plan.kind {
            case .purchase:
                #expect(executions.allSatisfy {
                    $0.kind == .buy && $0.fees == plan.fees && $0.securityID == plan.securityID && $0.depotID == plan.depotID
                })
                #expect(executions.contains { $0.shares.raw % Scale.shares != 0 })
            default:
                #expect(executions.allSatisfy { $0.kind == .deposit })
            }
        }
    }

    @Test func dividendsAreNetOfWithholdingTax() {
        let dividends = file.transactions.filter { $0.kind == .dividend }
        #expect(dividends.count > 100)
        #expect(dividends.allSatisfy { $0.taxes > 0 && $0.shares.raw > 0 })
        let payers = Set(dividends.compactMap(\.securityID))
        #expect(payers.count == 8)
        // Both depots receive distributions after the security transfer.
        #expect(Set(dividends.compactMap(\.depotID)).count == 2)
        // Foreign-currency payers carry the gross in the security's currency.
        let wexcombe = security(DemoBuilder.S.wexcombe).id
        #expect(dividends.filter { $0.securityID == wexcombe }.allSatisfy { $0.securityGross?.currency == "GBP" && $0.amount.currency == "EUR" })
        // Every payment is announced as a security event.
        for id in payers {
            let events = file.security(id)!.events.filter { $0.kind == .dividend }
            #expect(Set(events.map(\.day)) == Set(dividends.filter { $0.securityID == id }.map(\.date)))
        }
    }

    @Test func foreignCurrencyFlowsFollowTheConventions() throws {
        let usd = file.accounts[DemoBuilder.A.usd].id
        let exchanges = file.transactions.filter { $0.kind == .cashTransfer && $0.counterAmount != nil }
        #expect(exchanges.count >= 3)
        let first = try #require(exchanges.first)
        #expect(first.counterAccountID == usd && first.amount.currency == "EUR" && first.counterAmount?.currency == "USD")
        let rate = try #require(file.exchangeRates[0].rate(on: first.date))
        #expect(first.counterAmount?.minor == Int64((Double(first.amount.minor) * rate).rounded()))
        // US stocks are paid from the USD account without conversion …
        let quillonBuys = file.transactions.filter { $0.kind == .buy && $0.securityID == security(DemoBuilder.S.quillon).id }
        #expect(quillonBuys.count == 2)
        #expect(quillonBuys.allSatisfy { $0.accountID == usd && $0.securityGross == nil && $0.fees > 0 })
        // … the GBP stock from the EUR account with the GBP gross attached.
        let wexcombeBuys = file.transactions.filter { $0.kind == .buy && $0.securityID == security(DemoBuilder.S.wexcombe).id }
        #expect(!wexcombeBuys.isEmpty)
        #expect(wexcombeBuys.allSatisfy { $0.amount.currency == "EUR" && $0.securityGross?.currency == "GBP" })
    }

    @Test func taxonomiesDriveRebalancing() throws {
        let assetClasses = try #require(file.taxonomies.first)
        #expect(assetClasses.root.map(\.name) == ["Equity", "Bonds", "Commodities", "Real Estate", "Crypto", "Cash"])
        #expect(assetClasses.root.compactMap(\.targetWeight).reduce(0, +) == 10_000)
        #expect(assetClasses.root[0].children.compactMap(\.targetWeight).reduce(0, +) == 10_000)
        let colors = file.taxonomies.flatMap { Audit.allClassifications($0.root).map(\.color) }
        #expect(colors.allSatisfy { $0.count == 7 && $0.hasPrefix("#") && UInt32($0.dropFirst(), radix: 16) != nil })
        for taxonomy in file.taxonomies { #expect(Set(taxonomy.root.map(\.color)).count == taxonomy.root.count) }
        // Regions use weighted multi-assignments.
        let regions = file.taxonomies[1]
        let global = security(DemoBuilder.S.global).id
        let split = regions.root.flatMap(\.assignments).filter { $0.securityID == global }
        #expect(split.count >= 3 && split.map(\.weight).reduce(0, +) == 10_000)

        // Actual root allocation (in EUR) deviates visibly from the targets.
        let holdings = Audit.holdings(file), balances = Audit.balances(file)
        let rates = Dictionary(uniqueKeysWithValues: file.exchangeRates.map { ($0.quote, $0.rate(on: referenceDay)!) })
        func eur(_ minor: Int64, _ currency: String) -> Double { Double(minor) / (rates[currency] ?? 1) }
        func value(_ node: Classification) -> Double {
            var total = node.children.map(value).reduce(0, +)
            for a in node.assignments {
                if let id = a.securityID, let s = file.security(id), let shares = holdings[id], let price = s.prices.latest?.price {
                    total += eur(price.value(of: Shares(raw: shares)), s.currency) * Double(a.weight) / 10_000
                } else if let id = a.accountID, let account = file.account(id) {
                    total += eur(balances[id] ?? 0, account.currency) * Double(a.weight) / 10_000
                }
            }
            return total
        }
        let values = assetClasses.root.map(value)
        let total = values.reduce(0, +)
        #expect(total > 20_000_000 && total < 45_000_000, "net worth \(total / 100) EUR")
        #expect(values.allSatisfy { $0 > 0 })
        let deviations = zip(values, assetClasses.root).map { abs($0 / total - Double($1.targetWeight!) / 10_000) }
        #expect(deviations.max()! > 0.04, "max deviation \(deviations.max()!)")
    }

    @Test func dashboardUsesGenericWidgetKinds() throws {
        let dashboard = try #require(file.dashboards.first)
        let kinds = Set(dashboard.widgets.map(\.kind))
        #expect(kinds.isSuperset(of: ["total-value", "performance-chart", "allocation", "earnings", "top-movers", "ttwror", "irr", "max-drawdown"]))
        #expect(dashboard.widgets.allSatisfy { (1...4).contains($0.span) })
        let allocation = try #require(dashboard.widgets.first { $0.kind == "allocation" })
        #expect(allocation.config["taxonomy"] == file.taxonomies[0].id.uuidString)
    }

    @Test func ledgerIsStoredInChronologicalOrder() {
        #expect(file.transactions.sorted(by: Transaction.chronological) == file.transactions)
        #expect(file.transactions.allSatisfy { !$0.date.isWeekend && $0.minuteOfDay != nil })
    }
}
