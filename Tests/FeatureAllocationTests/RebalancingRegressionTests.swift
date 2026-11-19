import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureAllocation

// Regression tests for the review findings of the Allocation feature.

private let today = Day(year: 2026, month: 6, day: 30)

@MainActor private func demoStore(_ edit: (inout PortfolioFile) -> Void = { _ in }) -> PortfolioStore {
    var file = SampleData.demoPortfolio(today: today)
    edit(&file)
    return PortfolioStore(file: file, today: today)
}

@MainActor private func rebalancing(
    _ store: PortfolioStore, _ inputs: RebalancingInputs = RebalancingInputs(), scope: Scope? = nil, taxonomy index: Int = 0
) async throws -> RebalancingModel {
    let taxonomy = store.file.taxonomies[index]
    let key = RebalancingKey(taxonomy: taxonomy.id, inputs: inputs, today: store.today)
    return try await store.analyze("allocation.rebalancing", scope: scope, interval: store.interval(for: .ytd), variant: key) {
        RebalancingModel($0, taxonomy: taxonomy, inputs: inputs, today: today)
    }
}

private func fractional(_ edit: (inout RebalancingInputs) -> Void = { _ in }) -> RebalancingInputs {
    var inputs = RebalancingInputs()
    inputs.wholeShares = false
    edit(&inputs)
    return inputs
}

// MARK: - Plan (exclusions)

@Suite struct RebalancingPlanTests {
    private let ids = (0..<6).map { _ in UUID() }
    private let a = AllocationVehicle.security(UUID()), b = AllocationVehicle.security(UUID()), c = AllocationVehicle.account(UUID())
    private let d = AllocationVehicle.security(UUID())

    /// Equity 60 (Dev 75 [a], EM 25 [b]) · Bonds 30 [d] · Cash 10 [c]
    private var taxonomy: Taxonomy {
        Taxonomy(name: "T", root: [
            Classification(id: ids[0], name: "Equity", targetWeight: 6_000, children: [
                Classification(id: ids[1], name: "Dev", targetWeight: 7_500, assignments: [a.assignmentFull]),
                Classification(id: ids[2], name: "EM", targetWeight: 2_500, assignments: [b.assignmentFull]),
            ]),
            Classification(id: ids[3], name: "Bonds", targetWeight: 3_000, assignments: [d.assignmentFull]),
            Classification(id: ids[4], name: "Cash", targetWeight: 1_000, assignments: [c.assignmentFull]),
        ])
    }

    @Test func excludingAParentClearsTheWholeSubtree() {
        let plan = RebalancingPlan(taxonomy, excludedClassifications: [ids[0]])
        #expect(plan.taxonomy.flattened.filter { [ids[0], ids[1], ids[2]].contains($0.classification.id) }.allSatisfy { $0.classification.targetWeight == nil })
        #expect(plan.taxonomy.classification(ids[3])?.targetWeight == 3_000)
        #expect(plan.frozen[ids[0]] == .excluded && plan.frozen[ids[1]] == .excluded && plan.frozen[ids[2]] == .excluded)
        #expect(!plan.isEverythingFrozen)
    }

    @Test func excludingEveryChildFreezesTheParent() {
        let plan = RebalancingPlan(taxonomy, excludedClassifications: [ids[1], ids[2]])
        #expect(plan.frozen[ids[0]] == .implied)
        #expect(plan.taxonomy.classification(ids[0])?.targetWeight == nil)
        let all = RebalancingPlan(taxonomy, excludedClassifications: [ids[0], ids[3], ids[4]])
        #expect(all.isEverythingFrozen)
    }

    @Test func excludedVehiclesArePinnedInsideTheirClassification() {
        var t = taxonomy
        t.assign(b, to: ids[1])                     // Dev now holds a and b
        let plan = RebalancingPlan(t, excludedVehicles: [a])
        let dev = plan.taxonomy.classification(ids[1])
        // The pinned vehicle stays assigned to the classification; the rest moves into a 100 % child.
        #expect(dev?.assignments.compactMap(AllocationVehicle.init) == [a])
        #expect(dev?.children.count == 1 && dev?.children.first?.targetWeight == 10_000)
        #expect(dev?.children.first?.assignments.compactMap(AllocationVehicle.init) == [b])
        #expect(plan.wrappers[dev!.children[0].id] == ids[1])
        #expect(dev?.targetWeight == 7_500)
        // Deterministic: the same plan every time (stable row ids, cache keys).
        #expect(plan == RebalancingPlan(t, excludedVehicles: [a]))
        // A classification whose only vehicle is pinned cannot move at all.
        #expect(RebalancingPlan(taxonomy, excludedVehicles: [a]).frozen[ids[1]] == .implied)
    }

    @Test func unavailableVehiclesFreezeTheirLeaf() {
        let plan = RebalancingPlan(taxonomy, unavailable: [c])
        #expect(plan.frozen[ids[4]] == .unavailable)
        #expect(plan.taxonomy.classification(ids[4])?.assignments.isEmpty == true)
        #expect(plan.taxonomy.classification(ids[4])?.targetWeight == nil)
        // A target without anything assigned cannot be bought into either.
        var t = taxonomy
        t.unassign(d, from: ids[3])
        let empty = RebalancingPlan(t)
        #expect(empty.frozen[ids[3]] == .empty && empty.taxonomy.classification(ids[3])?.targetWeight == nil)
        #expect(!empty.isEverythingFrozen)
    }

    @Test func includingAClassificationClearsEverythingBelow() {
        var inputs = RebalancingInputs()
        inputs.excludedClassifications = [ids[1], ids[2], UUID()]
        inputs.excludedVehicles = [a, .security(UUID())]
        // Stale ids (deleted classification, vehicle that is not assigned) do not count.
        let clean = inputs.sanitized(for: taxonomy)
        #expect(clean.exclusionCount == 3)
        inputs = clean
        inputs.setIncluded(true, classification: ids[0], in: taxonomy)
        #expect(!inputs.hasExclusions)
        inputs.setIncluded(false, classification: ids[3], in: taxonomy)
        #expect(inputs.excludedClassifications == [ids[3]])
    }

    @Test func trimmingKeepsPurchasesWithinTheMoney() {
        let purchases = [
            RebalancingMath.Purchase(shares: 10, price: 1_000, amount: 10_000),
            RebalancingMath.Purchase(shares: 3, price: 25_000, amount: 75_000),
        ]
        // One cheap share closes a small gap …
        var trimmed = RebalancingMath.trim(purchases, shortfall: 800)
        #expect(trimmed.map(\.shares) == [9, 3] && trimmed.map(\.amount) == [9_000, 75_000])
        // … a large one takes expensive shares first, and never more than needed.
        trimmed = RebalancingMath.trim(purchases, shortfall: 51_500)
        #expect(purchases.reduce(0) { $0 + $1.amount } - trimmed.reduce(0) { $0 + $1.amount } >= 51_500)
        #expect(trimmed.map(\.shares) == [8, 1])
        // More than everything: all purchases go, nothing traps.
        #expect(RebalancingMath.trim(purchases, shortfall: 1_000_000).allSatisfy { $0.shares == 0 && $0.amount == 0 })
        #expect(RebalancingMath.trim(purchases, shortfall: 0) == purchases)
    }

    @Test func wholeShareSalesHaveWholeLegs() {
        let d1 = UUID(), d2 = UUID()
        let unit = Scale.shares
        let holdings = [(depot: d1, shares: 1_017 * unit + unit * 97 / 100), (depot: d2, shares: 88 * unit + unit * 3 / 100)]
        var legs = RebalancingMath.saleLegs(1_106 * unit, holdings: holdings, wholeShares: true)
        #expect(legs.map(\.shares) == [1_017 * unit, 88 * unit])          // 1 share cannot be sold whole
        legs = RebalancingMath.saleLegs(1_106 * unit, holdings: holdings, wholeShares: false)
        #expect(legs.reduce(0) { $0 + $1.shares } == 1_106 * unit)
        #expect(RebalancingMath.saleLegs(5 * unit, holdings: [], wholeShares: true).isEmpty)
    }
}

private extension AllocationVehicle {
    var assignmentFull: Classification.Assignment {
        var a = assignment
        a.weight = 10_000
        return a
    }
}

// MARK: - Model

@Suite @MainActor struct RebalancingRegressionTests {
    @Test func excludingAParentTradesNothingBelowIt() async throws {
        let store = demoStore()
        let taxonomy = store.file.taxonomies[0]
        let equity = try #require(taxonomy.root.first { $0.name == "Equity" })
        let base = try await rebalancing(store, fractional())
        let m = try await rebalancing(store, fractional { $0.excludedClassifications = [equity.id] })
        let row = try #require(m.classRows.first { $0.classificationID == equity.id })
        #expect(row.flattened.allSatisfy { $0.amount == 0 && $0.isExcluded && $0.targetShare == nil })
        #expect(row.flattened.allSatisfy { $0.resultingValue == $0.value })
        // No order for any vehicle below the excluded classification.
        let below = Set(row.flattened.compactMap(\.vehicle))
        #expect(!below.isEmpty && m.vehicleRows.filter { below.contains($0.vehicle) }.allSatisfy { $0.amount == 0 })
        #expect(m.exclusionCount == 1)
        // Targets and the drift figure stay on the base of the shares: the others share what
        // Equity leaves, so they add up to 100 % minus Equity's share and are reached exactly.
        let others = m.classRows.filter { $0.classificationID != nil && $0.classificationID != equity.id }
        let targets = others.compactMap(\.targetShare).reduce(0, +)
        #expect(abs(targets + (row.share ?? 0) - 1) < 1e-9)
        #expect((m.driftAfter ?? 1) < 0.001)
        #expect((m.driftBefore ?? 1) <= (base.driftBefore ?? 0) + 0.2 && (m.driftBefore ?? 1) < 0.25)
    }

    @Test func excludingEverythingKeepsTheTableAndTradesNothing() async throws {
        let store = demoStore()
        let taxonomy = store.file.taxonomies[0]
        var inputs = RebalancingInputs()
        inputs.amount = 500_000
        inputs.excludedClassifications = Set(taxonomy.root.map(\.id))
        let m = try await rebalancing(store, inputs)
        // Still "has targets": the table (with its checkboxes) must stay reachable.
        #expect(m.hasTargets && m.drafts.isEmpty && m.cashDraft == nil)
        #expect(m.securityBuys == 0 && m.securitySells == 0 && m.valueAfter == m.valueBefore)
        #expect(m.warnings.contains { $0.text.contains("Everything is excluded") })
    }

    @Test func excludedVehicleStaysVisibleAndUntouched() async throws {
        let store = demoStore()
        let base = try await rebalancing(store, fractional())
        let held = try #require(base.vehicleRows.first { $0.name.contains("Small Cap") && $0.value > 0 && $0.amount != 0 })
        let m = try await rebalancing(store, fractional { $0.excludedVehicles = [held.vehicle] })
        // The row is still there (so it can be checked again), greyed out, with no order …
        let rows = m.classRows.flatMap(\.flattened).filter { $0.vehicle == held.vehicle }
        #expect(!rows.isEmpty && rows.allSatisfy { $0.isExcluded && $0.amount == 0 })
        #expect(m.vehicleRows.first { $0.vehicle == held.vehicle }?.amount == 0)
        // … the classification keeps counting it, and nothing else changes shape.
        #expect(m.valueBefore == base.valueBefore)
        #expect(m.classRows.map(\.value) == base.classRows.map(\.value))
        #expect(m.classRows.flatMap(\.flattened).map(\.id) == base.classRows.flatMap(\.flattened).map(\.id))
        // The other vehicles of the classification absorb its amount: targets are still met.
        #expect((m.driftAfter ?? 1) < 0.001)

        // Pinning the largest position makes its classification's target unreachable: everything
        // else in it is sold, and the purchases shrink to what those sales really pay for.
        let largest = try #require(base.vehicleRows.filter(\.vehicle.isSecurity).max { $0.value < $1.value })
        let stuck = try await rebalancing(store, fractional { $0.excludedVehicles = [largest.vehicle] })
        #expect(stuck.residualCash == 0 && stuck.valueAfter == stuck.valueBefore)
        #expect(stuck.warnings.contains { $0.text.contains("not enough") })
        #expect(stuck.vehicleRows.first { $0.vehicle == largest.vehicle }?.amount == 0)
    }

    @Test func wholeSharesAreCashNeutral() async throws {
        let store = demoStore()
        for cash in [Int64(0), 500_000, 1_234_567] {
            var inputs = RebalancingInputs()
            inputs.amount = cash
            let m = try await rebalancing(store, inputs)
            #expect(m.residualCash >= 0)
            // "After" describes the portfolio that really exists afterwards.
            #expect(m.classRows.reduce(Int64(0)) { $0 + ($1.resultingValue ?? 0) } == m.valueBefore + cash)
            for row in m.classRows.flatMap(\.flattened) where !row.isUnassigned {
                #expect(row.resultingValue == row.value + row.amount)
                if row.classificationID != nil, !row.children.isEmpty {
                    #expect(row.children.reduce(0) { $0 + $1.amount } == row.amount)
                }
            }
            // The drafts move exactly the money the proposal shows on the cash accounts.
            let drafts = m.bookableDrafts.compactMap(\.transaction)
            let net = drafts.reduce(Int64(0)) { $0 + ($1.kind == .buy ? -$1.amount.minor : $1.amount.minor) }
            let accounts = m.vehicleRows.filter { !$0.vehicle.isSecurity }.reduce(Int64(0)) { $0 + $1.amount }
            #expect(accounts == net + cash)
            #expect(m.accounts.reduce(Int64(0)) { $0 + $1.projected(includesCash: false) - $1.balance } == net)
            #expect(drafts.allSatisfy { $0.shares.raw % Scale.shares == 0 })
        }
    }

    @Test func depotScopeStaysInsideTheDepot() async throws {
        let store = demoStore()
        let kids = try #require(store.file.depots.first { $0.name.contains("Kids") })
        let reference = try #require(kids.referenceAccountID)
        let m = try await rebalancing(store, RebalancingInputs(), scope: .depot(kids.id))
        let drafts = m.bookableDrafts.compactMap(\.transaction)
        #expect(!drafts.isEmpty && drafts.contains { $0.kind == .buy })
        #expect(drafts.allSatisfy { $0.depotID == kids.id && $0.accountID == reference })
        // Cash accounts are not part of a depot scope: no account "orders", the class is left out.
        #expect(!m.hasAccountOrders)
        let cash = try #require(m.classRows.first { $0.name == "Cash" })
        #expect(cash.isExcluded && cash.amount == 0 && cash.badge == "not in scope" && !cash.canExclude)
        #expect(m.vehicleRows.filter { !$0.vehicle.isSecurity }.allSatisfy { $0.amount == 0 })
        // The benchmark index is never bought.
        let benchmarks = Set(store.file.settings.benchmarkSecurityIDs)
        #expect(drafts.allSatisfy { !benchmarks.contains($0.securityID ?? UUID()) })
        #expect(m.residualCash >= 0)

        // Booked as proposed, the depot really moves towards the targets shown.
        store.addTransactions(drafts, actionName: "Apply Rebalancing")
        let after = try await rebalancing(store, RebalancingInputs(), scope: .depot(kids.id))
        #expect((after.driftBefore ?? 1) < (m.driftBefore ?? 0))
        #expect(abs((after.driftBefore ?? 1) - (m.driftAfter ?? 0)) < 0.01)
    }

    @Test func otherScopesGetNoProposal() async throws {
        let store = demoStore()
        let account = try #require(store.file.accounts.first)
        let taxonomy = store.file.taxonomies[0]
        let equity = try #require(taxonomy.root.first)
        let scope = try #require(taxonomy.scope(forClassification: equity.id))
        for scope in [Scope.account(account.id), scope] {
            let m = try await rebalancing(store, RebalancingInputs(), scope: scope)
            #expect(!m.isScopeSupported && m.drafts.isEmpty && m.classRows.isEmpty)
        }
    }

    @Test func draftIDsSurviveRecomputation() async throws {
        let store = demoStore()
        let a = try await rebalancing(store)
        store.mutate("Rename") { $0.name += " 2" }
        let b = try await rebalancing(store)
        #expect(!a.drafts.isEmpty && a.drafts.map(\.id) == b.drafts.map(\.id))
        #expect(Set(a.drafts.map(\.id)).count == a.drafts.count)
        #expect(a.cashDraft?.id == b.cashDraft?.id)
    }

    @Test func withdrawalIsLimitedToWhatCanBeRaised() async throws {
        let store = demoStore()
        var inputs = RebalancingInputs()
        inputs.direction = .withdraw
        inputs.amount = 50_000_000                       // far more than the portfolio is worth
        var m = try await rebalancing(store, inputs)
        let withdrawal = try #require(m.cashDraft)
        #expect(withdrawal.kind == .withdrawal && withdrawal.amount.minor <= m.valueBefore)
        #expect(withdrawal.amount.minor == m.valueBefore - m.valueAfter)
        #expect(m.warnings.contains { $0.level == .warning && $0.text.contains("can be raised") })
        #expect(m.unraisedCash == 50_000_000 - withdrawal.amount.minor)
        // Whole shares on: every leg is whole, also when a sale is spread over two depots.
        #expect(m.bookableDrafts.allSatisfy { ($0.shares?.raw ?? 0) % Scale.shares == 0 })

        inputs.amount = 1_000_000                        // an ordinary withdrawal is booked in full
        m = try await rebalancing(store, inputs)
        #expect(m.cashDraft?.amount.minor == 1_000_000)
        #expect(m.valueAfter == m.valueBefore - 1_000_000)
        // Whole-share rounding of the sales is no reason to withdraw less: the cash accounts cover it.
        inputs.buyOnly = true                            // "sell only"
        inputs.amount = 3_000_000
        let sellOnly = try await rebalancing(store, inputs)
        #expect(sellOnly.cashDraft?.amount.minor == 3_000_000 && sellOnly.unraisedCash == 0)
        #expect(sellOnly.securityBuys == 0 && sellOnly.valueAfter == sellOnly.valueBefore - 3_000_000)
        // Every account's projected balance follows the selection in the review sheet.
        let account = try #require(m.accounts.first { $0.cashEffect != 0 })
        #expect(account.projected(includesCash: true) == account.projected(includesCash: false) - 1_000_000)
        let first = try #require(account.effects.first)
        #expect(account.projected(skipping: [first.key], includesCash: false) == account.projected(includesCash: false) - first.value)
    }

    @Test func allTabsUseTheClassifiedBase() async throws {
        // The savings account and one of the bond funds are not assigned: a good part of the
        // portfolio is unassigned, yet every classification still has something to trade.
        let store = demoStore { file in
            let savings = file.accounts.first { $0.name.contains("Savings") }!
            let bonds = file.securities.first { $0.name.contains("Corporate Bond") }!
            file.taxonomies[0].removeAssignments(of: .account(savings.id))
            file.taxonomies[0].removeAssignments(of: .security(bonds.id))
        }
        let taxonomy = store.file.taxonomies[0]
        let allocation = try await store.analyze("allocation.model", variant: store.allocationKey(for: taxonomy)) { AllocationModel($0, taxonomy: taxonomy) }
        let m = try await rebalancing(store, fractional())
        #expect(allocation.unassignedValue > 0 && m.unassignedValue == allocation.unassignedValue)
        #expect(m.valueBefore == allocation.classifiedValue)
        let unassigned = try #require(m.classRows.last)
        #expect(unassigned.isUnassigned && unassigned.value == allocation.unassignedValue && unassigned.amount == 0)
        for row in allocation.rows {
            guard let id = row.classificationID, let proposal = m.classRows.first(where: { $0.classificationID == id }) else { continue }
            // Same share, same target, and "x above target" on tab 1 is exactly what tab 3 sells.
            #expect(row.share == proposal.share)
            #expect(abs((row.targetShare ?? -1) - (proposal.targetShare ?? -2)) < 1e-9)
            #expect(abs((row.deltaValue ?? 0) + proposal.amount) <= 2)
            if let share = row.share, let target = row.targetShare, let delta = row.deltaShare {
                #expect(abs(share - target - delta) < 1e-9)
            }
        }
        #expect(abs(allocation.rows.compactMap(\.share).reduce(0, +) - 1) < 1e-9)

        // A class that has a target but nothing to buy does not make the proposal sell for cash.
        store.mutate("Empty a class") { file in
            let gold = file.securities.first { $0.name.contains("Gold") }!
            file.taxonomies[0].removeAssignments(of: .security(gold.id))
        }
        let emptied = try await rebalancing(store, fractional())
        let commodities = try #require(emptied.classRows.first { $0.name == "Commodities" })
        #expect(commodities.isExcluded && commodities.badge == "nothing assigned" && commodities.targetShare == nil)
        #expect(emptied.residualCash == 0 && (emptied.driftAfter ?? 1) < 0.001)
        #expect(emptied.warnings.contains { $0.text.contains("nothing is assigned") })

        // By Security uses the same base as By Classification.
        #expect(abs(m.vehicleRows.compactMap(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(m.vehicleRows.reduce(0) { $0 + $1.value } == m.valueBefore)
    }

    @Test func classificationScopeRebasesTargets() async throws {
        let store = demoStore()
        let taxonomy = store.file.taxonomies[0]
        let equity = try #require(taxonomy.root.first { $0.name == "Equity" })
        store.scopeSelection = .classification(taxonomy: taxonomy.id, id: equity.id)
        let key = store.allocationKey(for: taxonomy)
        #expect(key.scopeRoot == equity.id)
        let model = try await store.analyze("allocation.model", variant: key) { AllocationModel($0, taxonomy: taxonomy, scopeRoot: key.scopeRoot) }
        #expect(model.scopeRootName == "Equity")
        let row = try #require(model.rows.first { $0.classificationID == equity.id })
        // The scoped classification is the whole scope: 100 % of 100 %, no "40 pp above target".
        #expect(row.targetShare == 1 && abs(row.deltaShare ?? 1) < 1e-9)
        // Below it the stored targets apply as they are; outside it there is nothing to compare.
        for child in row.children where child.classificationID != nil {
            let stored = try #require(equity.children.first { $0.id == child.classificationID })
            #expect(child.targetShare == stored.targetWeight.map { Double($0) / 10_000 })
        }
        #expect(model.rows.filter { $0.classificationID != equity.id }.allSatisfy { $0.targetShare == nil && $0.deltaValue == nil })
        // A classification of another taxonomy keeps the ordinary targets.
        #expect(store.allocationKey(for: store.file.taxonomies[1]).scopeRoot == nil)
    }
}

// MARK: - Session, editing

@Suite @MainActor struct AllocationSessionTests {
    @Test func inputsAreKeptPerTaxonomy() {
        let session = AllocationSession()
        let a = UUID(), b = UUID()
        var inputs = RebalancingInputs()
        inputs.amount = 5_000
        inputs.excludedClassifications = [UUID()]
        session.setInputs(inputs, for: a)
        #expect(session.inputs(for: a) == inputs)
        #expect(session.inputs(for: b) == RebalancingInputs())
    }

    @Test func deepLinksShowTheAllocationTab() {
        let store = demoStore()
        let session = AllocationSession()
        let taxonomy = store.file.taxonomies[1]
        let node = taxonomy.root[0]
        for tab in [AllocationSession.Tab.edit, .rebalancing] {
            session.tab = tab
            session.taxonomyID = store.file.taxonomies[0].id
            // A classification this screen did not select itself: select its taxonomy, show it.
            let external = session.adopt(route: .classification(taxonomy: taxonomy.id, id: node.id), in: store.file)
            #expect(external && session.tab == .allocation && session.taxonomyID == taxonomy.id)
            session.adopt(route: nil, in: store.file)
        }
        // The screen's own selection is not a deep link: the tab stays.
        session.tab = .edit
        session.setFocus(.classification(taxonomy: taxonomy.id, id: node.id), in: store)
        #expect(!session.adopt(route: store.route.focus, in: store.file) && session.tab == .edit)
        // A taxonomy link selects the taxonomy and keeps the tab.
        session.adopt(route: .taxonomy(store.file.taxonomies[0].id), in: store.file)
        #expect(session.tab == .edit && session.taxonomyID == store.file.taxonomies[0].id)
    }

    @Test func zeroWeightRemovesTheAssignment() {
        let a = UUID()
        var t = Taxonomy(name: "T", root: [Classification(id: a, name: "A")])
        let v = AllocationVehicle.security(UUID())
        t.assign(v, to: a)
        t.setWeight(2_500, of: v, in: a)
        #expect(t.assignedWeight(of: v) == 2_500)
        t.setWeight(0, of: v, in: a)
        #expect(t.classification(a)?.assignments.isEmpty == true && t.assignedWeights[v] == nil)
    }

    @Test func normalizeLeavesUntargetedSiblingsAlone() {
        let a = UUID(), b = UUID()
        var t = Taxonomy(name: "T", root: [Classification(id: a, name: "A", targetWeight: 5_000), Classification(id: b, name: "B")])
        t.normalizeTargets(ofParent: nil)
        #expect(t.root.map(\.targetWeight) == [10_000, nil])
        // That state is valid — no warning row — while 50 % + "no target" is not.
        #expect(t.targetStatus(ofParent: nil).isValid)
        t.root[0].targetWeight = 5_000
        #expect(!t.targetStatus(ofParent: nil).isValid)
    }

    @Test func templateSummaryMatchesItsTargets() {
        let file = SampleData.demoPortfolio(today: today)
        let targets = TaxonomyTemplate.assetClasses.make(in: file).root.compactMap(\.targetWeight).map { String($0 / 100) }
        #expect(TaxonomyTemplate.assetClasses.summary.contains(targets.joined(separator: " / ")))
    }
}
