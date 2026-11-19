import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureAllocation

// Tests of the Allocation feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Allocation"):
//
//     KONTOR_FEATURES=Allocation swift test --scratch-path .build-allocation --filter FeatureAllocationTests

private let today = Day(year: 2026, month: 6, day: 30)

@MainActor private func demoStore() -> PortfolioStore {
    PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
}

@Suite @MainActor struct AllocationFeatureTests {
    @Test func moduleRegistersItsScreen() {
        #expect(AllocationFeature.module.screen == .allocation)
    }

    @Test func sessionIsSharedPerStore() {
        let a = demoStore(), b = demoStore()
        #expect(AllocationSession.session(for: a) === AllocationSession.session(for: a))
        #expect(AllocationSession.session(for: a) !== AllocationSession.session(for: b))
    }
}

@Suite struct TaxonomyEditingTests {
    private func sample() -> (Taxonomy, [UUID]) {
        let ids = (0..<5).map { _ in UUID() }
        let taxonomy = Taxonomy(name: "T", root: [
            Classification(id: ids[0], name: "A", targetWeight: 6_000, children: [
                Classification(id: ids[1], name: "A1"),
                Classification(id: ids[2], name: "A2"),
            ]),
            Classification(id: ids[3], name: "B", targetWeight: 3_000),
            Classification(id: ids[4], name: "C"),
        ])
        return (taxonomy, ids)
    }

    @Test func apportionIsExact() {
        #expect(apportion(10_000, weights: [1, 1, 1]) == [3_334, 3_333, 3_333])
        #expect(apportion(10_000, weights: [6_000, 3_000]).reduce(0, +) == 10_000)
        #expect(apportion(100, weights: [0, 0]) == [0, 0])
    }

    @Test func indentOutdentAndShift() {
        var (t, ids) = sample()
        #expect(!t.canIndent(ids[0]))
        let r1 = t.indent(ids[3])                       // B becomes the last child of A
        #expect(r1)
        #expect(t.classification(ids[0])?.children.map(\.id) == [ids[1], ids[2], ids[3]])
        let r2 = t.outdent(ids[3])                      // … and back, right after A
        #expect(r2)
        #expect(t.root.map(\.id) == [ids[0], ids[3], ids[4]])
        let r3 = t.shift(ids[4], by: -1)
        #expect(r3)
        #expect(t.root.map(\.id) == [ids[0], ids[4], ids[3]])
        let r4 = t.shift(ids[0], by: -1)
        #expect(!r4)
    }

    @Test func moveRefusesCycles() {
        var (t, ids) = sample()
        let r5 = t.move(ids[0], toParent: ids[1])      // into its own child
        #expect(!r5)
        let r6 = t.move(ids[0], toParent: ids[0])
        #expect(!r6)
        let r7 = t.move(ids[1], toParent: nil)
        #expect(r7)
        #expect(t.root.last?.id == ids[1])
        #expect(t.classificationCount == 5)
    }

    @Test func targetValidationAndFixes() {
        var (t, _) = sample()
        var status = t.targetStatus(ofParent: nil)
        #expect(status.sum == 9_000 && status.targeted == 2 && !status.isComplete && status.remainder == 1_000)
        t.distributeRemainder(ofParent: nil)            // C (no target) receives the missing 10 %
        #expect(t.root.map(\.targetWeight) == [6_000, 3_000, 1_000])
        #expect(t.targetStatus(ofParent: nil).isComplete)

        (t, _) = sample()
        t.normalizeTargets(ofParent: nil)               // 60 : 30 scaled to 100 %
        #expect(t.root.map(\.targetWeight) == [6_667, 3_333, 0])
        status = t.targetStatus(ofParent: nil)
        #expect(status.isComplete)

        t.equalizeTargets(ofParent: nil)
        #expect(t.root.compactMap(\.targetWeight).reduce(0, +) == 10_000)
        t.clearTargets(ofParent: nil)
        #expect(!t.hasTargets)
        // A group without any target needs no fixing.
        #expect(t.targetStatus(ofParent: nil).isComplete)
    }

    @Test func liveOverridesCountInTheStatus() {
        let (t, ids) = sample()
        let status = t.targetStatus(ofParent: nil, overrides: [ids[4]: 1_000])
        #expect(status.isComplete)
    }

    @Test func assignSplitAndUnassign() {
        var (t, ids) = sample()
        let fund = AllocationVehicle.security(UUID())
        #expect(t.unassignedWeight(of: fund) == 10_000)
        t.assign(fund, to: ids[3], weight: 6_000)
        #expect(t.unassignedWeight(of: fund) == 4_000)
        t.assign(fund, to: ids[4])                      // the remaining 40 %
        #expect(t.assignments(of: fund).map(\.weight) == [6_000, 4_000])
        t.assign(fund, to: ids[1])                      // nothing left → moved completely
        #expect(t.assignments(of: fund).map(\.classification) == [ids[1]])
        #expect(t.assignedWeight(of: fund) == 10_000)

        t.setSplit(of: fund, parts: [(ids[3], 5_000), (ids[4], 2_500), (ids[3], 2_500), (ids[1], 0)])
        #expect(t.assignments(of: fund).map(\.weight) == [7_500, 2_500])   // merged, zero dropped
        t.moveAssignment(of: fund, from: ids[4], to: ids[2])
        #expect(t.classification(ids[2])?.assignments.first?.weight == 2_500)
        t.unassign(fund, from: ids[3])
        #expect(t.assignedWeight(of: fund) == 2_500)

        // Deleting a classification drops its assignments: the vehicle is unassigned again.
        t.remove([ids[0]])
        #expect(t.assignedWeight(of: fund) == 0)
    }

    @Test func vehicleTokensRoundTrip() {
        let vehicles: [AllocationVehicle] = [.security(UUID()), .account(UUID())]
        for vehicle in vehicles { #expect(AllocationVehicle(token: vehicle.token) == vehicle) }
        #expect(AllocationVehicle(token: "x:123") == nil)
    }

    @Test func templates() {
        let file = SampleData.demoPortfolio(today: today)
        let assets = TaxonomyTemplate.assetClasses.make(in: file)
        #expect(assets.name == "Asset Classes 2")       // the demo already has "Asset Classes"
        #expect(assets.targetStatus(ofParent: nil).isComplete)
        for node in assets.root where !node.children.isEmpty {
            #expect(assets.targetStatus(ofParent: node.id).isComplete)
        }
        let currency = TaxonomyTemplate.currency.make(in: file)
        #expect(currency.root.first?.name == file.settings.baseCurrency)
        // Every security and account is assigned exactly once, at 100 %.
        #expect(currency.assignedWeights.count == file.securities.count + file.accounts.count)
        #expect(currency.assignedWeights.values.allSatisfy { $0 == 10_000 })
        #expect(TaxonomyTemplate.empty.make(in: file).root.isEmpty)
        let copy = assets.duplicated(named: "Copy")
        #expect(copy.id != assets.id && Set(copy.flattened.map(\.classification.id)).isDisjoint(with: assets.flattened.map(\.classification.id)))
    }

    @Test func inputsSurviveThePayload() {
        var inputs = RebalancingInputs()
        inputs.amount = 123_456
        inputs.direction = .withdraw
        inputs.buyOnly = true
        inputs.wholeShares = false
        inputs.excludedClassifications = [UUID()]
        inputs.excludedVehicles = [.security(UUID()), .account(UUID())]
        #expect(RebalancingInputs(payload: inputs.payload) == inputs)
        #expect(inputs.cash == -123_456)
        #expect(inputs.options.mode == .noSales)
    }
}

@Suite @MainActor struct AllocationModelTests {
    @Test func demoAllocationAddsUp() async throws {
        let store = demoStore()
        let taxonomy = try #require(store.file.taxonomies.first)
        let model = try await store.analyze("allocation.model", variant: taxonomy.id) { AllocationModel($0, taxonomy: taxonomy) }
        #expect(model.hasValue && model.hasTargets)
        #expect(model.rows.reduce(0) { $0 + $1.value } == model.totalValue)
        #expect(model.classifiedValue + model.unassignedValue == model.totalValue)
        for row in model.rows.flatMap(\.flattened) {
            // A classification's value is the sum of what is below it.
            if !row.children.isEmpty { #expect(row.children.reduce(0) { $0 + $1.value } == row.value) }
            // actual − target = Δ on every targeted line.
            if let share = row.share, let target = row.targetShare, let delta = row.deltaShare {
                #expect(abs(share - target - delta) < 1e-9)
            }
        }
        let shares = model.rows.compactMap(\.share).reduce(0, +)
        #expect(abs(shares - 1) < 1e-9)
        #expect(model.slices.reduce(0) { $0 + $1.value } == Double(model.totalValue))
        #expect(!model.tsv().isEmpty)
    }

    @Test func returnsOnlyForTheWholePortfolio() async throws {
        let store = demoStore()
        let taxonomy = try #require(store.file.taxonomies.first)
        let all = try await store.analyze("allocation.returns", variant: taxonomy.id) { ClassificationReturns($0, taxonomy: taxonomy) }
        #expect(all.isAvailable && all.ttwror.count == taxonomy.classificationCount)
        let depot = try #require(store.file.depots.first)
        let narrowed = try await store.analyze("allocation.returns", scope: .depot(depot.id), variant: taxonomy.id) {
            ClassificationReturns($0, taxonomy: taxonomy)
        }
        #expect(!narrowed.isAvailable && narrowed.ttwror.isEmpty)
    }
}

@Suite @MainActor struct RebalancingModelTests {
    private func model(_ store: PortfolioStore, _ inputs: RebalancingInputs) async throws -> RebalancingModel {
        let taxonomy = try #require(store.file.taxonomies.first)
        let key = RebalancingKey(taxonomy: taxonomy.id, inputs: inputs, today: store.today)
        return try await store.analyze("allocation.rebalancing", interval: store.interval(for: .ytd), variant: key) {
            RebalancingModel($0, taxonomy: taxonomy, inputs: inputs, today: today)
        }
    }

    @Test func cashIsFullyAccountedFor() async throws {
        let store = demoStore()
        for (amount, buyOnly, whole) in [(Int64(1_000_000), false, true), (1_000_000, true, false), (0, false, false), (250_000, true, true)] {
            var inputs = RebalancingInputs()
            inputs.amount = amount
            inputs.buyOnly = buyOnly
            inputs.wholeShares = whole
            let m = try await model(store, inputs)
            #expect(m.securityBuys - m.securitySells + m.accountChange + m.residualCash == inputs.cash)
            #expect(m.vehicleRows.reduce(0) { $0 + $1.amount } == inputs.cash - m.residualCash)
            if buyOnly {
                #expect(m.securitySells == 0)
                #expect(m.vehicleRows.allSatisfy { $0.amount >= 0 })
            }
            // Fractional buy-and-sell reaches the targets (the split index fund aside).
            if !buyOnly, !whole { #expect((m.driftAfter ?? 1) < 0.001) }
        }
    }

    @Test func draftsMirrorTheSecurityOrders() async throws {
        let store = demoStore()
        var inputs = RebalancingInputs()
        inputs.amount = 1_000_000
        let m = try await model(store, inputs)
        let drafts = m.bookableDrafts.compactMap(\.transaction)
        #expect(!drafts.isEmpty)
        #expect(drafts.allSatisfy { $0.date == today && $0.shares.raw > 0 && $0.amount.minor > 0 && $0.depotID != nil && $0.accountID != nil })
        // Whole shares only.
        #expect(drafts.allSatisfy { $0.shares.raw % Scale.shares == 0 })
        // Every amount is in the currency of the account it settles against.
        for t in drafts {
            #expect(store.account(t.accountID)?.currency == t.amount.currency)
        }
        let before = store.file.transactions.count
        store.addTransactions(drafts, actionName: "Apply Rebalancing")
        #expect(store.file.transactions.count == before + drafts.count)

        // Booked as proposed, the allocation is now much closer to its targets.
        let after = try await model(store, RebalancingInputs())
        #expect((after.driftBefore ?? 1) < (m.driftBefore ?? 0))
    }

    @Test func exclusionsLeaveThingsUntouched() async throws {
        let store = demoStore()
        let taxonomy = try #require(store.file.taxonomies.first)
        let bonds = try #require(taxonomy.root.first { $0.name == "Bonds" })
        var inputs = RebalancingInputs()
        inputs.wholeShares = false
        inputs.excludedClassifications = [bonds.id]
        var m = try await model(store, inputs)
        let row = try #require(m.classRows.first { $0.classificationID == bonds.id })
        #expect(row.isExcluded && row.amount == 0 && row.resultingValue == row.value)

        let held = try #require(m.vehicleRows.first { $0.vehicle.isSecurity && $0.value > 0 })
        inputs.excludedClassifications = []
        inputs.excludedVehicles = [held.vehicle]
        m = try await model(store, inputs)
        let excluded = try #require(m.vehicleRows.first { $0.vehicle == held.vehicle })
        #expect(excluded.isExcluded && excluded.amount == 0)
        #expect(!m.drafts.contains { $0.securityName == held.name })
    }
}
