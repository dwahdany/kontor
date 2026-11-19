import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeaturePlans

// Tests of the Plans feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Plans"):
//
//     KONTOR_FEATURES=Plans swift test --scratch-path .build-plans --filter FeaturePlansTests

private let today = Day(year: 2026, month: 6, day: 30)

@MainActor private func demoStore() -> PortfolioStore {
    PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
}

private let defaultSort = [KeyPathComparator(\PlanRow.stateRank), KeyPathComparator(\PlanRow.name)]

@Suite @MainActor struct PlansFeatureTests {
    @Test func moduleRegistersItsScreen() {
        #expect(PlansFeature.module.screen == .plans)
    }

    @Test func claimsItsSheetsAndNothingElse() {
        let registry = FeatureRegistry([PlansFeature.module])
        #expect(registry.sheet(for: .newPlan) != nil)
        #expect(registry.sheet(for: .editPlan(UUID())) != nil)
        #expect(registry.sheet(for: .custom(id: PlanActions.generateSheetID)) != nil)
        #expect(registry.sheet(for: .custom(id: "allocation.rebalance")) == nil)
        #expect(registry.sheet(for: .newTransaction) == nil)
    }

    @Test func contributesPaletteCommands() {
        let store = demoStore()
        let commands = FeatureRegistry([PlansFeature.module]).commands(for: store)
        #expect(commands.contains { $0.id == "plans.generate" })
        #expect(commands.filter { $0.id.hasPrefix("plans.show.") }.count == store.file.plans.count)
    }
}

@Suite @MainActor struct PlansModelTests {
    @Test func demoPlansAreUpToDate() async throws {
        let store = demoStore()
        let plans = store.file.plans
        let query = PlansModel.Query(today: today, sortOrder: defaultSort)
        let model = try await store.compute("test.plans.model") { PlansModel($0, plans: plans, query: query) }
        #expect(model.rows.count == 2)
        #expect(model.dueCount == 0)
        #expect(model.rows.allSatisfy { $0.state == .upToDate })
        let purchase = try #require(model.rows.first { $0.kind == .purchase })
        // One execution per month since July 2017, 500 EUR each.
        #expect(purchase.executions == 108)
        #expect(purchase.total == 108 * 50_000)
        #expect(purchase.nextDue == Day(year: 2026, month: 7, day: 6))
        #expect(model.monthlyPurchases == 50_000)
        #expect(model.monthlyDeposits == 150_000)
        #expect(PlansScreen.cadence(model).hasPrefix("Buying"))
    }

    @Test func missingExecutionsMakeAPlanDue() async throws {
        let store = demoStore()
        let plan = try #require(store.file.plans.first { $0.kind == .purchase })
        store.mutate("Remove") { file in
            file.transactions.removeAll { $0.source == plan.sourceTag && $0.date >= Day(year: 2026, month: 4, day: 1) }
        }
        let plans = store.file.plans
        let query = PlansModel.Query(today: today, sortOrder: defaultSort)
        let model = try await store.compute("test.plans.model") { PlansModel($0, plans: plans, query: query) }
        #expect(model.dueCount == 3)
        #expect(model.rows.first?.id == plan.id, "plans that need attention sort first")
        #expect(model.rows.first?.state == .due(3))
        #expect(model.dueSummary == ["\(plan.name) (3)"])
    }

    @Test func statesOfEndedScheduledAndBrokenPlans() async throws {
        let store = demoStore()
        let account = try #require(store.file.accounts.first)
        let ended = InvestmentPlan(name: "Ended", kind: .deposit, accountID: account.id, amount: Money(minor: 10_000, currency: account.currency),
                                   start: Day(year: 2030, month: 1, day: 1), end: Day(year: 2029, month: 1, day: 1))
        let scheduled = InvestmentPlan(name: "Scheduled", kind: .deposit, accountID: account.id, amount: Money(minor: 10_000, currency: account.currency),
                                       start: Day(year: 2027, month: 1, day: 1))
        let broken = InvestmentPlan(name: "Broken", kind: .purchase, amount: Money(minor: 10_000, currency: "EUR"), start: today)
        store.mutate("Add") { $0.plans = [ended, scheduled, broken] }
        let plans = store.file.plans
        let query = PlansModel.Query(today: today, sortOrder: defaultSort)
        let model = try await store.compute("test.plans.model") { PlansModel($0, plans: plans, query: query) }
        let states = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, $0.state) })
        #expect(states["Ended"] == .ended)
        #expect(states["Scheduled"] == .scheduled)
        #expect(states["Broken"] == .problem(PlanText.problem(.missingSecurity)))
        #expect(model.dueCount == 0)
        #expect(model.activeCount == 1)
    }

    @Test func detailLinksExecutionsAndValuesThePlanWithTheEngine() async throws {
        let store = demoStore()
        let plan = try #require(store.file.plans.first { $0.kind == .purchase })
        let rates = store.file.exchangeRates
        let detail = try await store.compute("test.plans.detail") {
            PlanDetail($0, plan: plan, today: today, exchangeRates: rates)
        }
        #expect(detail.executions == 108)
        #expect(detail.history.count == 108)
        #expect(detail.upcoming.count == PlanDetail.upcomingCount)
        #expect(detail.upcoming.first?.due == Day(year: 2026, month: 7, day: 6), "nearest date first")
        #expect(detail.history.first?.due == Day(year: 2026, month: 6, day: 5), "newest first")
        // Every history row points at a real transaction of the plan.
        for entry in detail.history {
            guard case .executed(let id) = entry.kind else { Issue.record("unexpected \(entry.kind)"); continue }
            #expect(store.transaction(id)?.source == plan.sourceTag)
        }
        #expect(detail.yearly.reduce(0) { $0 + $1.total } == detail.total.minor)

        let performance = try #require(detail.performance)
        #expect(performance.invested == 108 * 50_000)
        // The value is the engine's: shares bought through the plan × today's price.
        let shares = store.file.transactions.filter { $0.source == plan.sourceTag }.reduce(Shares.zero) { $0 + $1.shares }
        let quote = try #require(store.ledger.price(of: plan.securityID!, on: today))
        #expect(performance.shares == shares)
        #expect(abs(performance.value - quote.price.value(of: shares)) <= 1)
        #expect(performance.valueSeries.last == performance.value)
        #expect(performance.investedSeries.last == performance.invested)
        #expect(performance.valueSeries.count == performance.investedSeries.count)
        let irr = try #require(performance.irr)
        #expect(irr > -0.5 && irr < 1)
        #expect((irr > 0) == (performance.gain > 0))
    }

    @Test func skippedAndMissingDatesShowInTheTimeline() async throws {
        let store = demoStore()
        let original = try #require(store.file.plans.first { $0.kind == .purchase })
        let skippedDay = Day(year: 2026, month: 5, day: 5)
        store.mutate("Prepare") { file in
            file.transactions.removeAll { $0.source == original.sourceTag && $0.date >= Day(year: 2026, month: 5, day: 1) }
            let index = file.plans.firstIndex { $0.id == original.id }!
            PlanGeneration.skip(skippedDay, in: &file.plans[index])
            PlanGeneration.skip(Day(year: 2026, month: 8, day: 5), in: &file.plans[index])
        }
        let plan = try #require(store.plan(original.id))
        let rates = store.file.exchangeRates
        let detail = try await store.compute("test.plans.detail") {
            PlanDetail($0, plan: plan, today: today, exchangeRates: rates)
        }
        #expect(detail.missing == [Day(year: 2026, month: 6, day: 5)])
        #expect(detail.skipped == [skippedDay])
        #expect(detail.history.prefix(2).map(\.kind) == [.missing, .skipped])
        #expect(detail.state == .due(1))
        // A date skipped in advance stays visible among the upcoming ones, so it can be restored.
        #expect(detail.upcoming.map(\.kind) == [.upcoming, .skipped, .upcoming, .upcoming])
    }

    @Test func staysFastWithFiftyThousandTransactions() async throws {
        let end = Day(year: 2025, month: 12, day: 31)
        var file = SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000, endingOn: end)
        let account = try #require(file.accounts.first), depot = try #require(file.depots.first)
        file.plans = file.securities.prefix(40).enumerated().map { index, security in
            InvestmentPlan(name: "Plan \(index)", kind: .purchase, securityID: security.id, depotID: depot.id, accountID: nil,
                           amount: Money(minor: 25_000, currency: security.currency), start: Day(year: 2015, month: 1, day: 1 + index % 28))
        } + [InvestmentPlan(name: "Deposit", kind: .deposit, accountID: account.id, amount: Money(minor: 100_000, currency: account.currency),
                            start: Day(year: 2015, month: 1, day: 1))]
        let store = PortfolioStore(file: file, today: end)
        let plans = store.file.plans
        let clock = ContinuousClock()
        let proposal = try await store.compute("test.plans.proposal") { GenerationProposal($0, plans: plans, today: end) }
        #expect(proposal.items.count > 5_000)
        var outcome = GenerationOutcome()
        store.mutate("Generate Plan Transactions") { outcome = PlanGeneration.apply(proposal.items, choices: [:], to: &$0) }
        #expect(outcome.created == proposal.items.filter(\.canCreate).count)

        let updated = store.file.plans
        let query = PlansModel.Query(today: end, sortOrder: defaultSort)
        let rates = store.file.exchangeRates
        let started = clock.now
        let model = try await store.compute("test.plans.model") { PlansModel($0, plans: updated, query: query) }
        let detail = try await store.compute("test.plans.detail") { PlanDetail($0, plan: updated[0], today: end, exchangeRates: rates) }
        let base = try await store.compute("test.plans.base") { ProjectionBase($0, plans: updated, today: end) }
        let elapsed = clock.now - started
        #expect(model.rows.count == 41)
        #expect(detail.executions > 100)
        #expect(base.plans.count == 41)
        // Generous bound for a debug build on a busy machine; typically a fraction of this.
        #expect(elapsed < .seconds(5), "list + detail + projection base took \(elapsed)")
    }
}

@Suite @MainActor struct PlanGenerationTests {
    private func storeWithOpenExecutions() throws -> (PortfolioStore, InvestmentPlan) {
        let store = demoStore()
        let plan = try #require(store.file.plans.first { $0.kind == .purchase })
        store.mutate("Remove") { file in
            file.transactions.removeAll { $0.source == plan.sourceTag && $0.date >= Day(year: 2026, month: 4, day: 1) }
        }
        return (store, plan)
    }

    @Test func proposalListsEveryOpenExecutionWithItsPrice() async throws {
        let (store, plan) = try storeWithOpenExecutions()
        let plans = store.file.plans
        let proposal = try await store.compute("test.proposal") { GenerationProposal($0, plans: plans, today: today) }
        #expect(proposal.problems.isEmpty)
        #expect(proposal.items.map(\.due) == [Day(year: 2026, month: 4, day: 6), Day(year: 2026, month: 5, day: 5), Day(year: 2026, month: 6, day: 5)])
        for item in proposal.items {
            let transaction = try #require(item.transaction)
            #expect(item.planID == plan.id)
            #expect(item.defaultChoice == .create)
            #expect(item.warning == nil)
            // shares × price = amount − fees, to the cent.
            let price = try #require(item.price)
            #expect(abs(price.value(of: transaction.shares) - (plan.amount.minor - plan.fees)) <= 1)
            #expect(transaction.source == plan.sourceTag)
        }
    }

    @Test func applyCreatesSkipsAndLeavesOpenInOneStep() async throws {
        let (store, plan) = try storeWithOpenExecutions()
        let plans = store.file.plans
        let proposal = try await store.compute("test.proposal") { GenerationProposal($0, plans: plans, today: today) }
        let items = proposal.items
        let choices: [GenerationItem.ID: GenerationChoice] = [items[1].id: .skip, items[2].id: .later]
        let before = store.file
        var outcome = GenerationOutcome()
        store.mutate("Generate Plan Transactions") { outcome = PlanGeneration.apply(items, choices: choices, to: &$0) }
        #expect(outcome == GenerationOutcome(created: 1, skipped: 1))
        #expect(store.file.transactions.count == before.transactions.count + 1)
        #expect(store.plan(plan.id)?.skippedDates == [items[1].due])

        let updated = try #require(store.plan(plan.id))
        let status = store.ledger.planStatus(updated, through: today)
        #expect(status.missing == [items[2].due], "the date left for later is still due")
        #expect(status.skipped == [items[1].due])

        // Applying the same proposal again changes nothing (ids are deterministic).
        var again = store.file
        #expect(PlanGeneration.apply(items, choices: choices, to: &again) == GenerationOutcome())
        #expect(again == store.file)
    }

    @Test func executionsWithoutAPriceCannotBeCreated() async throws {
        let store = demoStore()
        let depot = try #require(store.file.depots.first)
        let unpriced = Security(name: "Unpriced", currency: "EUR")
        let plan = InvestmentPlan(name: "Unpriced plan", kind: .purchase, securityID: unpriced.id, depotID: depot.id,
                                  accountID: depot.referenceAccountID, amount: Money(minor: 10_000, currency: "EUR"),
                                  start: Day(year: 2026, month: 6, day: 1))
        store.mutate("Add") { file in
            file.securities.append(unpriced)
            file.plans = [plan]
        }
        let plans = store.file.plans
        let proposal = try await store.compute("test.proposal") { GenerationProposal($0, plans: plans, today: today) }
        let item = try #require(proposal.items.first)
        #expect(proposal.items.count == 1)
        #expect(!item.canCreate)
        #expect(item.defaultChoice == .later)
        #expect(item.warning == PlanText.problem(.noPrice, security: "Unpriced"))
        var file = store.file
        // Asking to create it anyway does nothing; skipping records the date.
        #expect(PlanGeneration.apply([item], choices: [item.id: .create], to: &file) == GenerationOutcome())
        #expect(PlanGeneration.apply([item], choices: [item.id: .skip], to: &file) == GenerationOutcome(created: 0, skipped: 1))
        #expect(file.plans[0].skippedDates == [Day(year: 2026, month: 6, day: 1)])
    }

    @Test func misconfiguredPlansAreReportedNotGenerated() async throws {
        let store = demoStore()
        let broken = InvestmentPlan(name: "Broken", kind: .deposit, amount: Money(minor: 10_000, currency: "EUR"),
                                    start: Day(year: 2026, month: 1, day: 1))
        store.mutate("Add") { $0.plans = [broken] }
        let plans = store.file.plans
        let proposal = try await store.compute("test.proposal") { GenerationProposal($0, plans: plans, today: today) }
        #expect(proposal.items.isEmpty)
        #expect(proposal.problems.map(\.id) == [broken.id])
    }

    @Test func skipAndRestoreAreInverse() {
        var plan = InvestmentPlan(name: "P", kind: .deposit, amount: Money(minor: 1, currency: "EUR"), start: Day(year: 2026, month: 1, day: 3))
        // 3 Jan 2026 is a Saturday: the execution moves to Monday the 5th.
        #expect(plan.dueDates(through: today).first == Day(year: 2026, month: 1, day: 5))
        #expect(PlanGeneration.skip(Day(year: 2026, month: 1, day: 5), in: &plan))
        #expect(!PlanGeneration.skip(Day(year: 2026, month: 1, day: 5), in: &plan), "already skipped")
        #expect(plan.dueDates(through: today).first == Day(year: 2026, month: 2, day: 3))
        #expect(PlanGeneration.restore(Day(year: 2026, month: 1, day: 5), in: &plan))
        #expect(plan.skippedDates == nil)
        // A nominal weekend day stored by another tool is restored through its Monday execution too.
        plan.skippedDates = [Day(year: 2026, month: 1, day: 3)]
        #expect(plan.isSkipped(Day(year: 2026, month: 1, day: 5)))
        #expect(PlanGeneration.restore(Day(year: 2026, month: 1, day: 5), in: &plan))
        #expect(plan.skippedDates == nil)
    }

    @Test func pauseEndsThePlanAndResumeSkipsThePause() {
        var plan = InvestmentPlan(name: "P", kind: .deposit, amount: Money(minor: 1, currency: "EUR"), start: Day(year: 2025, month: 1, day: 15))
        let pausedOn = Day(year: 2025, month: 6, day: 30)
        PlanGeneration.pause(&plan, today: pausedOn)
        #expect(plan.end == pausedOn)
        #expect(PlanActions.isEnded(plan, today: pausedOn))
        let dueWhilePaused = plan.dueDates(through: today)
        #expect(dueWhilePaused.last == Day(year: 2025, month: 6, day: 16))

        PlanGeneration.resume(&plan, today: today)
        #expect(plan.end == nil)
        #expect(plan.dueDates(through: today) == dueWhilePaused, "nothing from the pause comes due")
        #expect(plan.skippedDates?.count == 12)
        #expect(plan.nextDueDate(after: today) == Day(year: 2026, month: 7, day: 15))
    }
}

@Suite struct PlanProjectionTests {
    @Test func zeroReturnIsJustTheContributions() {
        let input = ProjectionInput(startValue: 1_000_00, flows: Array(repeating: 100_00, count: 24), annualReturn: 0, spread: 0, years: 2)
        let result = PlanProjection.project(input)
        #expect(result.months == 24)
        #expect(result.expected == result.contributions)
        #expect(result.pessimistic == result.expected)
        #expect(result.contributions[0] == 1_000_00)
        #expect(result.contributions[24] == 1_000_00 + 24 * 100_00)
    }

    @Test func aLumpSumCompoundsToTheAnnualRate() {
        let input = ProjectionInput(startValue: 10_000_00, flows: [], annualReturn: 0.07, spread: 0.02, years: 10)
        let result = PlanProjection.project(input)
        #expect(abs(result.expected[12] - 10_000_00 * 1.07) < 0.01)
        #expect(abs(result.expected[120] - 10_000_00 * pow(1.07, 10)) < 0.01)
        #expect(abs(result.pessimistic[120] - 10_000_00 * pow(1.05, 10)) < 0.01)
        #expect(abs(result.optimistic[120] - 10_000_00 * pow(1.09, 10)) < 0.01)
        #expect(result.contributions.allSatisfy { $0 == 10_000_00 })
    }

    @Test func monthlyContributionsMatchTheAnnuityFormula() {
        // Future value of an annuity paid at the end of each month: P × ((1+i)^n − 1) / i.
        let rate = 0.05, payment = 500_00.0, months = 240
        let input = ProjectionInput(startValue: 0, flows: Array(repeating: 500_00, count: months), annualReturn: rate, spread: 0.02, years: 20)
        let result = PlanProjection.project(input)
        let i = pow(1 + rate, 1.0 / 12) - 1
        let expected = payment * (pow(1 + i, Double(months)) - 1) / i
        #expect(abs(result.expected[months] - expected) < 1)
        #expect(result.contributions[months] == payment * Double(months))
    }

    @Test func scenariosAreOrderedAndStartTogether() {
        let input = ProjectionInput(startValue: 5_000_00, flows: Array(repeating: 250_00, count: 360), annualReturn: 0.05, spread: 0.02, years: 30)
        let result = PlanProjection.project(input)
        #expect(result.pessimistic[0] == result.optimistic[0])
        for month in 1...360 {
            #expect(result.pessimistic[month] < result.expected[month])
            #expect(result.expected[month] < result.optimistic[month])
        }
        #expect(result.depletedMonth == nil)
    }

    @Test func withdrawalsDepleteButNeverGoNegative() {
        let input = ProjectionInput(startValue: 10_000_00, flows: Array(repeating: -1_000_00, count: 24), annualReturn: 0.03, spread: 0.01, years: 2)
        let result = PlanProjection.project(input)
        #expect(result.expected.allSatisfy { $0 >= 0 })
        #expect(result.expected.last == 0)
        #expect(result.depletedMonth == 11)
        #expect(result.contributions[24] == Double(10_000_00 - 24 * 1_000_00), "the paid-in line shows the nominal balance")
    }

    @Test func extremeInputsStayFinite() {
        let input = ProjectionInput(startValue: 1_000_00, flows: [], annualReturn: -5, spread: 10, years: 50)
        let result = PlanProjection.project(input)
        let all = result.pessimistic + result.expected + result.optimistic
        #expect(all.allSatisfy { $0.isFinite })
        #expect(PlanProjection.project(ProjectionInput(startValue: 1, flows: [], annualReturn: 0.05, spread: 0, years: 0)).expected == [1])
    }

    @Test func monthIndexAssignsDatesToTheMonthTheyFallIn() {
        let today = Day(year: 2026, month: 6, day: 30)
        #expect(PlanProjection.monthIndex(of: today, today: today) == nil)
        #expect(PlanProjection.monthIndex(of: Day(year: 2026, month: 7, day: 1), today: today) == 1)
        #expect(PlanProjection.monthIndex(of: Day(year: 2026, month: 7, day: 30), today: today) == 1)
        #expect(PlanProjection.monthIndex(of: Day(year: 2026, month: 7, day: 31), today: today) == 2)
        #expect(PlanProjection.monthIndex(of: Day(year: 2027, month: 6, day: 30), today: today) == 12)
        #expect(PlanProjection.monthIndex(of: Day(year: 2027, month: 7, day: 1), today: today) == 13)
    }
}

@Suite @MainActor struct ProjectionBaseTests {
    @Test func demoContributionsAreNewMoneyOnly() async throws {
        let store = demoStore()
        let plans = store.file.plans
        let base = try await store.compute("test.base") { ProjectionBase($0, plans: plans, today: today) }
        #expect(base.currentValue == store.ledger.snapshot(on: today).totalValue.minor)
        let deposit = try #require(base.plans.first { $0.kind == .deposit })
        let purchase = try #require(base.plans.first { $0.kind == .purchase })
        #expect(purchase.isInternal && !deposit.isInternal)
        #expect(base.defaultSelection == [deposit.id], "the purchase is paid from cash that the deposit already counts")
        let flows = base.flows(including: base.defaultSelection, years: 20)
        #expect(flows.count == 240)
        #expect(flows.allSatisfy { $0 == 150_000 }, "one deposit in every month")
        #expect(base.flows(including: [deposit.id, purchase.id], years: 1).reduce(0, +) == 12 * 200_000)
    }

    @Test func purchasesCountWhenTheyAreTheOnlyPlansAndEndedPlansDoNot() async throws {
        let store = demoStore()
        store.mutate("Edit") { file in
            file.plans.removeAll { $0.kind != .purchase }
            var quarterly = file.plans[0]
            quarterly.id = UUID()
            quarterly.intervalMonths = 3
            quarterly.start = Day(year: 2026, month: 8, day: 3)
            quarterly.end = Day(year: 2027, month: 3, day: 1)
            file.plans.append(quarterly)
            var ended = file.plans[0]
            ended.id = UUID()
            ended.end = Day(year: 2020, month: 1, day: 1)
            file.plans.append(ended)
        }
        let plans = store.file.plans
        let base = try await store.compute("test.base") { ProjectionBase($0, plans: plans, today: today) }
        #expect(base.defaultSelection == [plans[0].id, plans[1].id])
        #expect(!base.plans[2].isActive)
        // Quarterly from 3 Aug 2026 until 1 Mar 2027: Aug, Nov, Feb → months 2, 5, 8.
        let quarterly = base.plans[1].flows
        #expect(quarterly.enumerated().filter { $0.element != 0 }.map { $0.offset + 1 } == [2, 5, 8])
        #expect(quarterly.reduce(0, +) == 3 * 50_000)
    }
}

@Suite @MainActor struct PlanDraftTests {
    @Test func newPlanDefaultsToFirstDepotItsAccountAndNextMonth() {
        let store = demoStore()
        let draft = PlanDraft(prefill: PlanPrefill(), file: store.file, today: today)
        let depot = store.file.depots[0]
        #expect(draft.kind == .purchase)
        #expect(draft.depotID == depot.id)
        #expect(draft.accountID == depot.referenceAccountID)
        #expect(draft.start == Day(year: 2026, month: 7, day: 1))
        #expect(draft.intervalMonths == 1)
        #expect(draft.validate(security: nil, depot: depot, account: store.account(draft.accountID)) == "Choose the security to buy.")
    }

    @Test func prefillWins() {
        let store = demoStore()
        let security = store.file.securities[3], depot = store.file.depots[1], account = store.file.accounts[2]
        let prefill = PlanPrefill(kind: .purchase, securityID: security.id, depotID: depot.id, accountID: account.id,
                                  amount: Money(minor: 12_345, currency: account.currency), start: Day(year: 2027, month: 2, day: 10))
        let draft = PlanDraft(prefill: prefill, file: store.file, today: today)
        #expect(draft.securityID == security.id && draft.depotID == depot.id && draft.accountID == account.id)
        #expect(draft.amountMinor == 12_345)
        #expect(draft.start == Day(year: 2027, month: 2, day: 10))
        #expect(draft.validate(security: security, depot: depot, account: account) == nil)
        #expect(draft.suggestedName(security: security.name) == "\(security.name) Savings Plan")
    }

    @Test func aValidDraftIsAPlanTheEngineAccepts() {
        let store = demoStore()
        let security = store.file.securities[0], depot = store.file.depots[0]
        var draft = PlanDraft(prefill: PlanPrefill(securityID: security.id), file: store.file, today: today)
        draft.amountMinor = 20_000
        draft.fees = 20_000
        #expect(draft.validate(security: security, depot: depot, account: store.account(draft.accountID)) == "The fees must be smaller than the amount.")
        draft.fees = 100
        #expect(draft.validate(security: security, depot: depot, account: store.account(draft.accountID)) == nil)
        let plan = draft.plan(currency: "EUR")
        #expect(store.ledger.planStatus(plan, through: today).problem == nil)

        var deposit = draft
        deposit.kind = .deposit
        let saved = deposit.plan(currency: "EUR")
        #expect(saved.securityID == nil && saved.depotID == nil && saved.fees == 0, "a deposit keeps no purchase leftovers")
    }

    @Test func previewShowsTheNextDatesAndTheBacklog() {
        var draft = PlanDraft()
        draft.amountMinor = 10_000
        draft.start = Day(year: 2026, month: 3, day: 14)   // a Saturday
        draft.intervalMonths = 3
        let preview = draft.preview(today: today, currency: "EUR")
        #expect(preview.dates == [Day(year: 2026, month: 9, day: 14), Day(year: 2026, month: 12, day: 14),
                                  Day(year: 2027, month: 3, day: 15), Day(year: 2027, month: 6, day: 14)])
        #expect(preview.movedFromWeekend, "14 Mar 2027 is a Sunday")
        #expect(preview.backlog == 2)
        #expect(preview.firstBacklog == Day(year: 2026, month: 3, day: 16))
        #expect(!preview.isEnded)

        draft.end = Day(year: 2026, month: 6, day: 1)
        #expect(draft.preview(today: today, currency: "EUR").dates.isEmpty)
        #expect(draft.preview(today: today, currency: "EUR").isEnded)
    }
}
