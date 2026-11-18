import Foundation
import KontorEngine
import KontorModel
import Testing

/// A: 10 × 100 = 1 000, B: 30 × 100 = 3 000, cash 1 000 → total 5 000.
private struct AllocationFixture {
    var f = Fixture()
    let cash: UUID, depot: UUID, a: UUID, b: UUID
    let day = d("2024-06-30")

    init() {
        cash = f.account("Cash")
        depot = f.depot("Depot")
        a = f.security("A", prices: [("2024-01-01", 100)])
        b = f.security("B", prices: [("2024-01-01", 100)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 5_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: a, shares: 10, amount: 1_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: b, shares: 30, amount: 3_000)
    }
}

private func sec(_ id: UUID, _ weight: Int = 10_000) -> Classification.Assignment {
    Classification.Assignment(securityID: id, weight: weight)
}

private func acc(_ id: UUID, _ weight: Int = 10_000) -> Classification.Assignment {
    Classification.Assignment(accountID: id, weight: weight)
}

@Suite struct AllocationTests {
    @Test func treeWithWeightsTargetsAndUnassigned() {
        let x = AllocationFixture()
        let world = Classification(name: "World", targetWeight: 5_000, assignments: [sec(x.a)])
        let emerging = Classification(name: "EM", targetWeight: 5_000, assignments: [sec(x.b, 5_000)])
        let equity = Classification(name: "Equity", color: "#FF0000", targetWeight: 6_000, children: [world, emerging])
        let bonds = Classification(name: "Bonds", targetWeight: 4_000, assignments: [sec(x.b, 3_000)])
        let taxonomy = Taxonomy(name: "Asset classes", root: [equity, bonds])
        let ledger = x.f.ledger

        let al = ledger.allocation(for: taxonomy, on: x.day)
        #expect(al.totalValue == minor(5_000))
        #expect(al.classifiedValue == minor(3_400))
        #expect(al.unassignedValue == minor(1_600))
        #expect(al.targetBase == minor(3_400))
        #expect(al.overAssigned.isEmpty)
        #expect(abs(al.unassignedShare! - 0.32) < 1e-12)

        let eq = al.roots[0], bo = al.roots[1]
        #expect(eq.id == equity.id && eq.name == "Equity" && eq.color == "#FF0000" && eq.depth == 0)
        #expect(eq.value == minor(2_500) && eq.ownValue == 0)
        #expect(abs(eq.share! - 0.5) < 1e-12)
        #expect(eq.targetWeight == 6_000 && abs(eq.targetShare! - 0.6) < 1e-12)
        #expect(eq.targetValue == minor(2_040))
        #expect(eq.deltaValue == minor(460))
        #expect(abs(eq.deltaShare! - (2_500.0 / 3_400 - 0.6)) < 1e-12)
        #expect(bo.value == minor(900) && bo.targetValue == minor(1_360) && bo.deltaValue == minor(-460))

        let w = eq.children[0], em = eq.children[1]
        #expect(w.depth == 1 && w.value == minor(1_000) && em.value == minor(1_500))
        #expect(abs(w.shareOfParent! - 0.4) < 1e-12 && abs(w.share! - 0.2) < 1e-12)
        #expect(abs(w.targetShare! - 0.3) < 1e-12 && w.targetValue == minor(1_020))
        #expect(em.deltaValue == minor(480))
        #expect(em.items.count == 1)
        #expect(em.items[0].vehicle == .security(x.b) && em.items[0].name == "B")
        #expect(em.items[0].weight == 5_000 && em.items[0].value == minor(1_500))
        #expect(em.items[0].shares == Shares(30) && em.items[0].pricePerShare == 10_000)

        // Unassigned: 20 % of B and the whole cash account.
        #expect(al.unassigned.map(\.vehicle) == [.security(x.b), .account(x.cash)])
        #expect(al.unassigned.map(\.value) == [minor(600), minor(1_000)])
        #expect(al.unassigned.map(\.weight) == [2_000, 10_000])
        #expect(al.node(world.id)?.value == minor(1_000))
        #expect(al.flattened.map(\.name) == ["Equity", "World", "EM", "Bonds"])

        // Targets against the total: unassigned holdings count as deviation.
        let total = ledger.allocation(for: taxonomy, on: x.day, includeUnassignedInTargets: true)
        #expect(total.targetBase == minor(5_000))
        #expect(total.roots[0].targetValue == minor(3_000) && total.roots[0].deltaValue == minor(-500))
        #expect(total.roots[0].children[1].targetValue == minor(1_500))

        // A node without a target cuts the target chain below it.
        var loose = taxonomy
        loose.root[0].targetWeight = nil
        let cut = ledger.allocation(for: loose, on: x.day)
        #expect(cut.roots[0].targetValue == nil && cut.roots[0].children[0].targetShare == nil)
        #expect(cut.roots[1].targetValue == minor(1_360))
    }

    @Test func overAssignedVehiclesAreNormalizedAndEmptyItemsListed() {
        var x = AllocationFixture()
        let other = x.f.security("Not held", prices: [("2024-01-01", 12.5)])
        let ghost = UUID()
        let one = Classification(name: "One", assignments: [sec(x.a, 8_000), sec(other), sec(ghost)])
        let two = Classification(name: "Two", assignments: [sec(x.a, 6_000), acc(x.cash, 2_500)])
        let taxonomy = Taxonomy(name: "T", root: [one, two])
        let al = x.f.ledger.allocation(for: taxonomy, on: x.day)
        #expect(al.overAssigned == [.security(x.a)])
        // 1 000 split 8 : 6.
        #expect(al.roots[0].items[0].value == minor(571.43) && al.roots[0].items[0].weight == 5_714)
        #expect(al.roots[1].items[0].value == minor(428.57) && al.roots[1].items[0].weight == 4_286)
        // The security that is not held is listed with a price, the unknown id is dropped.
        #expect(al.roots[0].items.count == 2)
        #expect(al.roots[0].items[1].value == 0 && al.roots[0].items[1].shares == .zero)
        #expect(al.roots[0].items[1].pricePerShare == 1_250)
        #expect(al.roots[1].items[1].value == minor(250))
        #expect(al.unassigned.map(\.value) == [minor(3_000), minor(750)])
        #expect(al.classifiedValue + al.unassignedValue == minor(5_000))
    }

    @Test func classificationScopeAndPerformance() {
        var x = AllocationFixture()
        x.f.file.securities[0].prices.set(Price(110), on: d("2024-03-01"))
        x.f.file.securities[1].prices.set(Price(90), on: d("2024-03-01"))
        let child = Classification(name: "Child", assignments: [sec(x.b, 5_000)])
        let parent = Classification(name: "Parent", children: [child], assignments: [sec(x.a)])
        let taxonomy = Taxonomy(name: "T", root: [parent])
        #expect(taxonomy.scope(forClassification: child.id) == .weighted(securities: [x.b: 5_000], accounts: [:]))
        #expect(taxonomy.scope(forClassification: parent.id)
            == .weighted(securities: [x.a: 10_000, x.b: 5_000], accounts: [:]))
        #expect(taxonomy.scope(forClassification: parent.id, includingChildren: false)
            == .weighted(securities: [x.a: 10_000], accounts: [:]))
        #expect(taxonomy.scope(forClassification: UUID()) == nil)
        #expect(taxonomy.classification(child.id)?.name == "Child")

        let ledger = x.f.ledger
        let interval = DayInterval(start: d("2024-01-31"), end: d("2024-06-30"))
        let all = ledger.classificationPerformance(of: taxonomy, in: interval)
        #expect(all.map(\.classificationID) == [parent.id, child.id])
        // Child: half of B, 1 500 → 1 350.
        #expect(all[1].initialValue == minor(1_500) && all[1].finalValue == minor(1_350))
        #expect(abs(all[1].ttwror + 0.1) < 1e-12)
        #expect(all[1].absolutePerformance == minor(-150))
        // Parent: A (1 000 → 1 100) plus half of B.
        #expect(all[0].initialValue == minor(2_500) && all[0].finalValue == minor(2_450))
        #expect(abs(all[0].ttwror + 0.02) < 1e-12)
        #expect(all[0].irr! < 0)
        // The same numbers as the equivalent single-security scope.
        let direct = ledger.performance(in: interval, scope: .security(x.b))
        #expect(abs(direct.ttwror - all[1].ttwror) < 1e-12)
        #expect(ledger.classificationPerformance(UUID(), of: taxonomy, in: interval) == nil)
    }

    /// A random taxonomy: nested classifications, fractional weights, vehicles assigned several
    /// times (also beyond 100 %) and some not at all.
    static func randomTaxonomy(_ file: PortfolioFile, seed: UInt64) -> Taxonomy {
        var rng = SplitMix64(seed: seed &* 7_919)
        func node(_ depth: Int) -> Classification {
            var c = Classification(name: "C\(rng.int(0...9_999))", targetWeight: rng.chance(0.7) ? rng.int(0...10_000) : nil)
            for s in file.securities where rng.chance(0.25) {
                c.assignments.append(sec(s.id, [10_000, 5_000, 3_333, 2_500, 1][rng.int(0...4)]))
            }
            for a in file.accounts where rng.chance(0.2) { c.assignments.append(acc(a.id, rng.int(0...10_000))) }
            if depth < 2 { for _ in 0..<rng.int(0...3) { c.children.append(node(depth + 1)) } }
            return c
        }
        return Taxonomy(name: "Random", root: (0..<rng.int(2...4)).map { _ in node(0) })
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func treeAddsUpToThePortfolio(seed: UInt64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0
        o.allowShort = seed % 4 == 3
        let file = makeRandomPortfolio(o)
        let ledger = Ledger(file)
        let taxonomy = Self.randomTaxonomy(file, seed: seed)
        for offset in [150, 420, o.days - 1] {
            let day = o.start.advanced(by: offset)
            for scope in [Scope.portfolio, .depot(file.depots[0].id, account: file.accounts[0].id)] {
                let snapshot = ledger.snapshot(on: day, scope: scope)
                let al = ledger.allocation(for: taxonomy, on: day, scope: scope)
                #expect(al.totalValue == snapshot.totalValue.minor)
                #expect(al.roots.reduce(0) { $0 + $1.value } == al.classifiedValue)
                #expect(al.classifiedValue + al.unassignedValue == al.totalValue)
                #expect(al.unassigned.reduce(0) { $0 + $1.value } == al.unassignedValue)
                var perVehicle: [AllocationVehicle: Int64] = [:]
                for item in al.unassigned { perVehicle[item.vehicle, default: 0] += item.value }
                for node in al.flattened {
                    #expect(node.value == node.items.reduce(0) { $0 + $1.value } + node.children.reduce(0) { $0 + $1.value })
                    #expect(node.ownValue == node.items.reduce(0) { $0 + $1.value })
                    for item in node.items { perVehicle[item.vehicle, default: 0] += item.value }
                }
                // Every vehicle is distributed completely and exactly.
                for p in snapshot.positions { #expect(perVehicle[.security(p.securityID)] ?? 0 == p.value.minor) }
                for c in snapshot.cash { #expect(perVehicle[.account(c.accountID)] ?? 0 == c.value.minor) }
            }
        }
    }
}

@Suite struct RebalancingTests {
    /// X holds A (50 × 100 = 5 000, target 60 %), Y holds B (50 × 100 = 5 000, target 40 %).
    private func twoClasses(priceA: Double = 100, priceB: Double = 100) -> (ledger: Ledger, taxonomy: Taxonomy, a: UUID, b: UUID) {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let a = f.security("A", prices: [("2024-01-01", priceA)])
        let b = f.security("B", prices: [("2024-01-01", priceB)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 10_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: a, shares: 5_000 / priceA, amount: 5_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: b, shares: 5_000 / priceB, amount: 5_000)
        let taxonomy = Taxonomy(name: "T", root: [
            Classification(name: "X", targetWeight: 6_000, assignments: [sec(a)]),
            Classification(name: "Y", targetWeight: 4_000, assignments: [sec(b)]),
        ])
        return (f.ledger, taxonomy, a, b)
    }

    private let day = d("2024-06-30")

    @Test func buyAndSellReachesTargets() {
        let (ledger, taxonomy, a, b) = twoClasses()
        let p = ledger.rebalancing(for: taxonomy, on: day)
        #expect(p.orders.map(\.vehicle) == [.security(a), .security(b)])
        #expect(p.orders.map(\.amount) == [minor(1_000), minor(-1_000)])
        #expect(p.orders[0].shares == Shares(10) && p.orders[1].shares == Shares(-10))
        #expect(p.orders[0].isBuy && !p.orders[1].isBuy)
        #expect(p.totalBuys == minor(1_000) && p.totalSells == minor(1_000) && p.residualCash == 0)
        #expect(p.nodes.map(\.resultingValue) == [minor(6_000), minor(4_000)])
        #expect(abs(p.nodes[0].resultingShare! - 0.6) < 1e-12)
        #expect(p.nodes[0].targetShare == 0.6 && p.nodes[0].amount == minor(1_000))
        #expect(p.nodes[0].items[0].amount == minor(1_000))
        #expect(p.valueBefore == minor(10_000) && p.valueAfter == minor(10_000))
        #expect(p.warnings.isEmpty)

        // With 2 000 of new cash: 12 000 → 7 200 / 4 800.
        let invest = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(2_000)))
        #expect(invest.orders.map(\.amount) == [minor(2_200), minor(-200)])
        #expect(invest.valueAfter == minor(12_000) && invest.residualCash == 0)
        // Taking 2 000 out: 8 000 → 4 800 / 3 200.
        let withdraw = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(-2_000)))
        #expect(withdraw.orders.map(\.amount) == [minor(-200), minor(-1_800)])
    }

    @Test func buyOnlyWaterFilling() {
        let (ledger, taxonomy, _, _) = twoClasses()
        // 2 000 are not enough to lift X to the level of Y: everything goes to X.
        let small = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(2_000), mode: .noSales))
        #expect(small.orders.map(\.amount) == [minor(2_000)])
        #expect(small.nodes.map(\.resultingValue) == [minor(7_000), minor(5_000)])
        // 5 000 reach the targets exactly: 9 000 / 6 000.
        let large = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(5_000), mode: .noSales))
        #expect(large.orders.map(\.amount) == [minor(4_000), minor(1_000)])
        #expect(abs(large.nodes[0].resultingShare! - 0.6) < 1e-12)
        // Nothing to invest, nothing to do.
        #expect(ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(mode: .noSales)).orders.isEmpty)
        // Withdrawal: only sales, from the most overweight class first. 8 000 → 4 800 / 3 200.
        let out = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(-2_000), mode: .noSales))
        #expect(out.orders.map(\.amount) == [minor(-200), minor(-1_800)])
        let little = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(-500), mode: .noSales))
        #expect(little.orders.map(\.amount) == [minor(-500)])
        #expect(little.orders[0].name == "B")
        // More than everything: sell all, report the rest.
        let tooMuch = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(cash: minor(-12_000), mode: .noSales))
        #expect(tooMuch.totalSells == minor(10_000) && tooMuch.residualCash == minor(-2_000))
        #expect(tooMuch.warnings.contains(.insufficientHoldings(classification: nil)))
    }

    @Test func wholeShares() {
        let (ledger, taxonomy, _, _) = twoClasses(priceA: 312.5, priceB: 80)
        let options = RebalancingOptions(cash: minor(5_000), mode: .noSales, wholeShares: true)
        let p = ledger.rebalancing(for: taxonomy, on: day, options: options)
        // Ideal: 4 000 → 12.8 shares of A → 12 (3 750); 1 000 → 12.5 shares of B → 12 (960).
        #expect(p.orders.map(\.shares) == [Shares(12), Shares(12)])
        #expect(p.orders.map(\.amount) == [minor(3_750), minor(960)])
        #expect(p.orders[0].pricePerShare == 31_250)
        #expect(p.residualCash == minor(290))
        #expect(p.nodes.map(\.amount) == [minor(4_000), minor(1_000)]) // the ideal amounts
        #expect(p.nodes.map(\.resultingValue) == [minor(8_750), minor(5_960)])
        // Selling rounds towards zero as well.
        let sell = ledger.rebalancing(for: taxonomy, on: day, options: RebalancingOptions(wholeShares: true))
        #expect(sell.orders.map(\.shares) == [Shares(3), Shares(-12)])
        #expect(sell.residualCash == minor(960 - 937.5))
    }

    @Test func nestedTargetsEmptyClassesAndWarnings() {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let a = f.security("A", prices: [("2024-01-01", 100)])
        let n1 = f.security("New 1", prices: [("2024-01-01", 50)])
        let n2 = f.security("New 2", prices: [("2024-01-01", 20)])
        let unpriced = f.security("Unpriced")
        f.add(.deposit, "2024-01-02", account: cash, amount: 10_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: a, shares: 60, amount: 6_000)
        // Equity 80 % { Core 75 % [A], Satellite 25 % [New 1, New 2] }, Cash 20 % [account], Empty (no target).
        let core = Classification(name: "Core", targetWeight: 7_500, assignments: [sec(a)])
        let satellite = Classification(name: "Satellite", targetWeight: 2_500, assignments: [sec(n1), sec(n2)])
        let equity = Classification(name: "Equity", targetWeight: 8_000, children: [core, satellite])
        let liquidity = Classification(name: "Cash", targetWeight: 2_000, assignments: [acc(cash)])
        let taxonomy = Taxonomy(name: "T", root: [equity, liquidity])
        let ledger = f.ledger

        // 10 000: equity 8 000 (core 6 000, satellite 2 000 split equally), cash 2 000.
        let p = ledger.rebalancing(for: taxonomy, on: d("2024-06-30"))
        #expect(p.orders.map(\.vehicle) == [.security(n1), .security(n2), .account(cash)])
        #expect(p.orders.map(\.amount) == [minor(1_000), minor(1_000), minor(-2_000)])
        #expect(p.orders.map(\.shares) == [Shares(20), Shares(50), nil])
        #expect(p.node(satellite.id)?.targetShare == 0.2)
        #expect(p.node(satellite.id)?.resultingValue == minor(2_000))
        #expect(p.node(core.id)?.amount == 0)
        #expect(p.flattened.map(\.name) == ["Equity", "Core", "Satellite", "Cash"])
        #expect(p.warnings.isEmpty)

        // Targets that do not sum to 100 % are normalized; classes without vehicles are reported.
        var odd = taxonomy
        odd.root[0].children[1].assignments = []
        odd.root[1].targetWeight = 4_000 // 80 : 40 → 2/3 : 1/3
        let q = ledger.rebalancing(for: odd, on: d("2024-06-30"), options: RebalancingOptions(cash: minor(2_000)))
        #expect(q.warnings.contains(.targetsNormalized(parent: nil, sum: 12_000)))
        #expect(q.warnings.contains(.noVehicles(classification: satellite.id)))
        // 12 000 → equity 8 000 (core 6 000, satellite 2 000 unplaceable), cash 4 000 (unchanged).
        #expect(q.orders.isEmpty && q.residualCash == minor(2_000))
        #expect(abs(q.node(equity.id)!.targetShare! - 2.0 / 3.0) < 1e-12)

        // No targets at all: new money is spread in proportion to current values.
        var none = taxonomy
        none.root[0].targetWeight = nil
        none.root[1].targetWeight = nil
        none.root[0].children[0].targetWeight = nil
        none.root[0].children[1].targetWeight = nil
        let r = ledger.rebalancing(for: none, on: d("2024-06-30"), options: RebalancingOptions(cash: minor(1_000)))
        #expect(r.orders.map(\.amount) == [minor(600), minor(400)])
        #expect(r.warnings.contains(.noTargets(parent: nil)))

        // A security without a price gets an order without a share count.
        let single = Taxonomy(name: "S", root: [Classification(name: "Only", targetWeight: 10_000, assignments: [sec(unpriced)])])
        let s = ledger.rebalancing(for: single, on: d("2024-06-30"), options: RebalancingOptions(cash: minor(500), wholeShares: true))
        #expect(s.orders.count == 1 && s.orders[0].shares == nil && s.orders[0].amount == minor(500))
        #expect(s.warnings.contains(.missingPrice(securityID: unpriced)))
    }

    @Test func splitAssignmentsAreReportedHonestly() {
        var f = Fixture()
        let cash = f.account("Cash"), depot = f.depot("Depot")
        let mixed = f.security("Mixed fund", prices: [("2024-01-01", 100)])
        f.add(.deposit, "2024-01-02", account: cash, amount: 10_000)
        f.add(.buy, "2024-01-03", account: cash, depot: depot, security: mixed, shares: 100, amount: 10_000)
        // The fund is 50 % stocks, 30 % bonds, 20 % unassigned; the targets want 80 : 20.
        let taxonomy = Taxonomy(name: "T", root: [
            Classification(name: "Stocks", targetWeight: 8_000, assignments: [sec(mixed, 5_000)]),
            Classification(name: "Bonds", targetWeight: 2_000, assignments: [sec(mixed, 3_000)]),
        ])
        let p = f.ledger.rebalancing(for: taxonomy, on: d("2024-06-30"), options: RebalancingOptions(cash: minor(1_000)))
        // Stocks +2 200 and bonds −1 200 net to one order of +1 000, which raises both buckets pro rata.
        #expect(p.nodes.map(\.amount) == [minor(2_200), minor(-1_200)])
        #expect(p.orders.map(\.amount) == [minor(1_000)])
        #expect(p.nodes.map(\.resultingValue) == [minor(5_500), minor(3_300)])
        #expect(p.warnings == [.sharedVehicle(.security(mixed))])
        #expect(p.residualCash == 0)
    }

    /// Every security in exactly one of four classes at 100 %, random targets summing to 100 %.
    private func randomSetup(_ seed: UInt64) -> (allocation: TaxonomyAllocation, weights: [Int], rng: SplitMix64) {
        var o = RandomPortfolioOptions(seed: seed)
        o.multiCurrency = seed % 2 == 0
        o.securities = 9
        let file = makeRandomPortfolio(o)
        var rng = SplitMix64(seed: seed &* 31)
        let cuts = [rng.int(500...3_000), rng.int(3_500...6_000), rng.int(6_500...9_500)]
        let weights = [cuts[0], cuts[1] - cuts[0], cuts[2] - cuts[1], 10_000 - cuts[2]]
        var classes = weights.enumerated().map { Classification(name: "Class \($0.offset)", targetWeight: $0.element) }
        for (i, s) in file.securities.enumerated() { classes[i % 4].assignments.append(sec(s.id)) }
        let taxonomy = Taxonomy(name: "Random", root: classes)
        let ledger = Ledger(file)
        return (ledger.allocation(for: taxonomy, on: o.start.advanced(by: o.days - 1)), weights, rng)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func proposalsReachTargetsAndSpendExactlyTheCash(seed: UInt64) {
        var (allocation, weights, rng) = randomSetup(seed)
        let classified = allocation.classifiedValue
        #expect(classified > 0)
        for cash in [0, Int64(rng.int(1...5_000_000)), -Int64(rng.int(1...Int(classified / 2)))] {
            // Buy and sell: every class lands on its target, the orders net to the cash.
            let full = allocation.rebalancing(RebalancingOptions(cash: cash))
            #expect(full.orders.reduce(0) { $0 + $1.amount } == cash)
            #expect(full.totalBuys - full.totalSells == cash && full.residualCash == 0)
            #expect(full.valueAfter == classified + cash)
            for (i, node) in full.nodes.enumerated() {
                let target = Double(classified + cash) * Double(weights[i]) / 10_000
                #expect(abs(Double(node.resultingValue) - target) <= 1)
                #expect(node.resultingValue == node.value + node.amount)
                #expect(node.items.reduce(0) { $0 + $1.amount } == node.amount)
                for item in node.items { #expect(item.value + item.amount >= 0) } // never sells more than held
            }

            // No sales: nothing against the direction of the cash, same total.
            let oneWay = allocation.rebalancing(RebalancingOptions(cash: cash, mode: .noSales))
            #expect(oneWay.orders.reduce(0) { $0 + $1.amount } == cash)
            #expect(oneWay.residualCash == 0)
            for order in oneWay.orders { #expect(cash >= 0 ? order.amount > 0 : order.amount < 0) }
            for node in oneWay.nodes { #expect(cash >= 0 ? node.amount >= 0 : node.amount <= 0) }
            // Water filling is optimal: whoever received money ends at the same value / target
            // ratio, and nobody who received nothing sits below that level.
            if cash > 0 {
                let ratio = oneWay.nodes.indices.map { Double(oneWay.nodes[$0].resultingValue) / Double(weights[$0]) }
                let funded = oneWay.nodes.indices.filter { oneWay.nodes[$0].amount > 0 }
                let level = funded.map { ratio[$0] }.max()!
                for i in funded { #expect(abs(ratio[i] - level) * Double(weights[i]) <= 2) }
                for i in oneWay.nodes.indices where oneWay.nodes[i].amount == 0 {
                    #expect(ratio[i] >= level - 2 / Double(weights[i]))
                }
                // It never ends further from the targets than the full rebalancing allows.
                #expect(oneWay.totalSells == 0)
            }

            // Whole shares: never exceeds the ideal order, the rest stays as residual cash.
            let rounded = allocation.rebalancing(RebalancingOptions(cash: cash, mode: .noSales, wholeShares: true))
            #expect(rounded.orders.reduce(0) { $0 + $1.amount } + rounded.residualCash == cash)
            #expect(cash >= 0 ? rounded.residualCash >= 0 : rounded.residualCash <= 0)
            for order in rounded.orders {
                #expect(order.shares!.raw % Scale.shares == 0)
                let ideal = oneWay.orders.first { $0.vehicle == order.vehicle }!
                #expect(abs(order.amount) <= abs(ideal.amount))
                #expect(abs(ideal.amount - order.amount) <= Int64(order.pricePerShare!.rounded(.up)) + 1)
            }
        }
    }
}
