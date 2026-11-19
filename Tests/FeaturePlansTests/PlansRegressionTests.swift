import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeaturePlans

// Regression tests for the review findings of the Plans feature.

private let today = Day(year: 2026, month: 6, day: 30)
private let defaultSort = [KeyPathComparator(\PlanRow.stateRank), KeyPathComparator(\PlanRow.name)]

@MainActor private func demoStore() -> PortfolioStore {
    PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
}

private func deposit(_ name: String, start: Day, end: Day? = nil, account: Account? = nil, months: Int = 1) -> InvestmentPlan {
    InvestmentPlan(name: name, kind: .deposit, accountID: account?.id, amount: Money(minor: 10_000, currency: account?.currency ?? "EUR"),
                   start: start, end: end, intervalMonths: months)
}

@Suite @MainActor struct ProjectionRobustnessTests {
    /// The stepper limits plus the 50-year slider used to trap in `Int64(value.rounded())`.
    @Test func extremeOutcomesFormatWithoutTrapping() async throws {
        let store = demoStore()
        let plans = store.file.plans
        let base = try await store.compute("test.base") { ProjectionBase($0, plans: plans, today: today) }
        for (rate, spread) in [(0.5, 0.25), (5.0, 10.0), (-0.5, 0.25), (Double.infinity, Double.nan)] {
            let input = ProjectionInput(
                startValue: base.currentValue, flows: base.flows(including: Set(plans.map(\.id)), years: 50),
                annualReturn: rate, spread: spread, years: 50)
            let outcome = ProjectionOutcome(input: input, base: base)
            for point in outcome.milestones + [outcome.end] {
                for value in [point.paidIn, point.pessimistic, point.expected, point.optimistic, point.optimistic - point.paidIn] {
                    #expect(!Fmt.moneyRounded(outcome.money(value)).isEmpty)
                }
            }
        }
        let outcome = ProjectionOutcome(
            input: ProjectionInput(startValue: 30_868_268, flows: [], annualReturn: 0.5, spread: 0.25, years: 50), base: base)
        #expect(outcome.money(outcome.end.optimistic).minor == .max, "saturates instead of overflowing")
        #expect(outcome.money(-.infinity).minor == .min)
        #expect(outcome.money(.nan).minor == 0)
    }

    @Test func returnAndSpreadAreClampedToTheStepperRanges() {
        #expect(ProjectionInput.clampedReturn(1.0) == 0.5)
        #expect(ProjectionInput.clampedReturn(-3) == -0.5)
        #expect(ProjectionInput.clampedReturn(0.07) == 0.07)
        #expect(ProjectionInput.clampedReturn(.nan) == 0)
        #expect(ProjectionInput.clampedSpread(-0.02) == 0.02)
        #expect(ProjectionInput.clampedSpread(9) == 0.25)
        #expect(ProjectionInput.clampedSpread(.infinity) == 0)
    }

    @Test func absurdAmountsSaturate() async throws {
        let store = demoStore()
        let account = try #require(store.file.accounts.first { $0.currency == store.file.settings.baseCurrency })
        var huge = deposit("Huge", start: Day(year: 2026, month: 7, day: 1), account: account)
        huge.amount.minor = .max
        var second = huge
        second.id = UUID()
        store.mutate("Add") { $0.plans = [huge, second] }
        let plans = store.file.plans
        let base = try await store.compute("test.base") { ProjectionBase($0, plans: plans, today: today) }
        #expect(base.flows(including: Set(plans.map(\.id)), years: 1).allSatisfy { $0 == .max })
        let query = PlansModel.Query(today: Day(year: 2026, month: 8, day: 1), sortOrder: defaultSort)
        let model = try await store.compute("test.model") { PlansModel($0, plans: plans, query: query) }
        #expect(model.monthlyDeposits == .max)
    }

    @Test func aProjectionOfNothingIsEmpty() {
        #expect(ProjectionInput(startValue: 0, flows: [0, 0], annualReturn: 0.05, spread: 0.02, years: 1).isEmpty)
        #expect(ProjectionInput(startValue: 0, flows: [-100, 0], annualReturn: 0.05, spread: 0.02, years: 1).isEmpty, "withdrawing from nothing")
        #expect(!ProjectionInput(startValue: 1, flows: [], annualReturn: 0.05, spread: 0.02, years: 1).isEmpty)
        #expect(!ProjectionInput(startValue: 0, flows: [0, 100], annualReturn: 0.05, spread: 0.02, years: 1).isEmpty)
    }
}

@Suite @MainActor struct ScheduleChangeTests {
    /// Moving the execution day from the 5th to the 20th un-matches all 108 executions.
    @Test func movingTheExecutionDayKeepsHistoryByDefault() async throws {
        let store = demoStore()
        let original = try #require(store.file.plans.first { $0.kind == .purchase })
        var moved = original
        moved.start = Day(year: 2017, month: 7, day: 20)

        let impact = ScheduleImpact(store.ledger, old: original, new: moved, today: today)
        #expect(impact.newlyDue.count == 108)
        #expect(impact.unmatched == 108)
        #expect(impact.keepsHistoryByDefault)
        #expect(PlanDraft.pastDatesMessage(impact).contains("108"))

        impact.keepHistory(in: &moved)
        let status = store.ledger.planStatus(moved, through: today)
        #expect(status.missing.isEmpty, "nothing of the past comes due")
        #expect(status.nextDue == Day(year: 2026, month: 7, day: 20), "the new day applies from the next execution")
        store.updatePlan(moved)
        let plans = store.file.plans
        let proposal = try await store.compute("test.proposal") { GenerationProposal($0, plans: plans, today: today) }
        #expect(proposal.items.isEmpty)
    }

    @Test func shorteningTheIntervalKeepsHistoryToo() throws {
        let store = demoStore()
        let demo = try #require(store.file.plans.first { $0.kind == .purchase })
        var quarterly = demo
        quarterly.intervalMonths = 3
        // Keep only the executions of every third month.
        let due = Set(quarterly.dueDates(through: today))
        let kept = Set(store.ledger.planStatus(demo, through: today).executions.filter { due.contains($0.due) }.map(\.transactionID))
        store.mutate("Quarterly") { file in
            file.transactions.removeAll { $0.source == quarterly.sourceTag && !kept.contains($0.id) }
            file.plans = [quarterly]
        }
        #expect(store.ledger.planStatus(quarterly, through: today).missing.isEmpty)
        var monthly = quarterly
        monthly.intervalMonths = 1
        let impact = ScheduleImpact(store.ledger, old: quarterly, new: monthly, today: today)
        #expect(impact.newlyDue.count == 72, "two thirds of the monthly dates")
        #expect(impact.unmatched == 0)
        impact.keepHistory(in: &monthly)
        #expect(store.ledger.planStatus(monthly, through: today).missing.isEmpty)
    }

    @Test func unrelatedEditsAndPlansWithoutHistoryAreLeftAlone() throws {
        let store = demoStore()
        let original = try #require(store.file.plans.first { $0.kind == .purchase })
        var renamed = original
        renamed.name = "Other"
        renamed.amount.minor += 1
        #expect(ScheduleImpact(store.ledger, old: original, new: renamed, today: today) == ScheduleImpact())

        // Never booked anything: an earlier start is a backlog to review, as for a new plan.
        let account = try #require(store.file.accounts.first)
        let fresh = deposit("Fresh", start: Day(year: 2026, month: 6, day: 1), account: account)
        var earlier = fresh
        earlier.start = Day(year: 2026, month: 3, day: 2)
        let impact = ScheduleImpact(store.ledger, old: fresh, new: earlier, today: today)
        #expect(impact.newlyDue.count == 4, "2 Mar, 2 Apr, 4 May, 2 Jun")
        #expect(!impact.keepsHistoryByDefault)
    }

    /// Second line of defence: dates left due although the plan's transactions sit nearby are not
    /// preselected for creation.
    @Test func generateDoesNotPreselectDatesThatAreAlreadyBookedNearby() async throws {
        let store = demoStore()
        var moved = try #require(store.file.plans.first { $0.kind == .purchase })
        moved.start = Day(year: 2017, month: 7, day: 20)
        store.updatePlan(moved)
        let plans = [moved]
        let proposal = try await store.compute("test.proposal") { GenerationProposal($0, plans: plans, today: today) }
        #expect(proposal.items.count == 108)
        #expect(proposal.items.allSatisfy { $0.bookedOn != nil && $0.defaultChoice == .skip })
        var file = store.file
        let outcome = PlanGeneration.apply(proposal.items, choices: [:], to: &file)
        #expect(outcome.created == 0 && outcome.skipped == 108)
        #expect(file.transactions.count == store.file.transactions.count, "pressing Return duplicates nothing")
    }
}

@Suite @MainActor struct PauseResumeDuplicateTests {
    @Test func aPlanThatHasNotRunCannotBePaused() {
        var future = deposit("F", start: Day(year: 2027, month: 1, day: 15))
        #expect(!PlanGeneration.canPause(future, today: today))
        #expect(PlanGeneration.pause(&future, today: today) == nil)
        #expect(future.end == nil, "no end before the first execution")
        // Started on a Saturday, looked at on the Sunday: the first execution (Monday) is still ahead.
        var weekend = deposit("W", start: Day(year: 2026, month: 6, day: 27))
        PlanGeneration.pause(&weekend, today: Day(year: 2026, month: 6, day: 28))
        #expect(weekend.end == nil)
    }

    @Test func pausingOnAWeekendAlsoStopsTheMondayExecution() {
        // Nominal Saturday 27 Jun 2026 → execution Monday 29; paused on Sunday 28.
        var plan = deposit("W", start: Day(year: 2026, month: 5, day: 27))
        let sunday = Day(year: 2026, month: 6, day: 28)
        #expect(PlanGeneration.canPause(plan, today: sunday))
        PlanGeneration.pause(&plan, today: sunday)
        #expect(plan.end == Day(year: 2026, month: 6, day: 26))
        #expect(plan.dueDates(through: today) == [Day(year: 2026, month: 5, day: 27)])
        #expect(PlanActions.isEnded(plan, today: sunday))
        PlanGeneration.resume(&plan, today: today)
        #expect(plan.dueDates(through: today) == [Day(year: 2026, month: 5, day: 27)], "the paused Monday stays skipped")
        #expect(plan.nextDueDate(after: today) == Day(year: 2026, month: 7, day: 27))
    }

    @Test func pauseReportsTheEndDateItReplaces() {
        let end = Day(year: 2026, month: 12, day: 31)
        var plan = deposit("P", start: Day(year: 2025, month: 1, day: 15), end: end)
        #expect(PlanGeneration.pause(&plan, today: today) == end)
        #expect(plan.end == today)
        var open = deposit("P", start: Day(year: 2025, month: 1, day: 15))
        #expect(PlanGeneration.pause(&open, today: today) == nil)
        #expect(open.end == today)
    }

    @Test func pausingAPlanWithAnEndDateTellsTheUser() throws {
        let store = demoStore()
        let account = try #require(store.file.accounts.first)
        let plan = deposit("Ends later", start: Day(year: 2026, month: 1, day: 15), end: Day(year: 2026, month: 12, day: 31), account: account)
        store.mutate("Add") { $0.plans = [plan] }
        PlanActions.pause(plan.id, in: store)
        #expect(store.plan(plan.id)?.end == today)
        #expect(store.toasts.last?.message?.contains(Fmt.day(Day(year: 2026, month: 12, day: 31), style: .medium)) == true)
    }

    @Test func duplicateKeepsTheDayOfTheMonth() {
        // The demo plan's rhythm: the 5th of each month since 2017.
        var plan = deposit("ETF", start: Day(year: 2017, month: 7, day: 5), end: Day(year: 2030, month: 1, day: 1))
        plan.skippedDates = [Day(year: 2026, month: 7, day: 6)]
        let copy = PlanGeneration.duplicate(plan, today: today)
        #expect(copy.id != plan.id)
        #expect(copy.name == "ETF Copy")
        #expect(copy.start == Day(year: 2026, month: 7, day: 5), "next date of the original rhythm, not the 1st")
        #expect(copy.end == nil && copy.skippedDates == nil)
        #expect(copy.dueDates(through: today).isEmpty, "no backlog")

        // The 31st: February would clamp to the 28th — the copy waits for a month that has a 31st.
        let last = deposit("31", start: Day(year: 2025, month: 1, day: 31))
        #expect(PlanGeneration.duplicate(last, today: Day(year: 2026, month: 2, day: 10)).start == Day(year: 2026, month: 3, day: 31))
        // A plan that has not started keeps its start.
        let future = deposit("F", start: Day(year: 2027, month: 3, day: 9))
        #expect(PlanGeneration.duplicate(future, today: today).start == future.start)
        // Quarterly keeps its months.
        let quarterly = deposit("Q", start: Day(year: 2025, month: 2, day: 10), months: 3)
        #expect(PlanGeneration.duplicate(quarterly, today: today).start == Day(year: 2026, month: 8, day: 10))
    }
}

@Suite @MainActor struct GenerateRegressionTests {
    /// A generated transaction moved by more than a week leaves its date open; the engine then
    /// proposes the same deterministic id again. That used to be a silent no-op.
    @Test func aMovedExecutionIsRecognisedAndSettled() async throws {
        let store = demoStore()
        let plan = try #require(store.file.plans.first { $0.kind == .purchase })
        store.mutate("Remove") { file in
            file.transactions.removeAll { $0.source == plan.sourceTag && $0.date >= Day(year: 2026, month: 6, day: 1) }
        }
        let plans = store.file.plans
        let first = try await store.compute("test.p1") { GenerationProposal($0, plans: plans, today: today) }
        store.mutate("Generate") { PlanGeneration.apply(first.items, choices: [:], to: &$0) }
        let id = try #require(first.items.first?.transaction?.id)
        let movedTo = Day(year: 2026, month: 6, day: 20)
        store.mutate("Move") { file in
            let index = file.transactions.firstIndex { $0.id == id }!
            file.transactions[index].date = movedTo
        }
        #expect(store.ledger.planStatus(plan, through: today).missing == [Day(year: 2026, month: 6, day: 5)])

        let second = try await store.compute("test.p2") { GenerationProposal($0, plans: plans, today: today) }
        let item = try #require(second.items.first)
        #expect(second.items.count == 1)
        #expect(item.bookedOn == movedTo)
        #expect(item.defaultChoice == .skip)
        #expect(item.warning == GenerationProposal.bookedNote(movedTo))
        #expect(item.transaction?.id != id, "a second booking, if insisted on, gets its own id")

        // Default: the date is settled, nothing is added twice.
        var settled = store.file
        #expect(PlanGeneration.apply(second.items, choices: [:], to: &settled) == GenerationOutcome(created: 0, skipped: 1))
        #expect(Ledger(settled).planStatus(settled.plans.first { $0.id == plan.id }!, through: today).missing.isEmpty)
        // Insisting on Create works and is counted.
        var doubled = store.file
        #expect(PlanGeneration.apply(second.items, choices: [item.id: .create], to: &doubled) == GenerationOutcome(created: 1, skipped: 0))
        #expect(doubled.transactions.count == store.file.transactions.count + 1)
    }

    @Test func aStaleProposalReportsWhatWasAlreadyBooked() async throws {
        let store = demoStore()
        let plan = try #require(store.file.plans.first { $0.kind == .purchase })
        store.mutate("Remove") { file in
            file.transactions.removeAll { $0.source == plan.sourceTag && $0.date >= Day(year: 2026, month: 5, day: 1) }
        }
        let plans = store.file.plans
        let proposal = try await store.compute("test.p") { GenerationProposal($0, plans: plans, today: today) }
        var file = store.file
        #expect(PlanGeneration.apply(proposal.items, choices: [:], to: &file) == GenerationOutcome(created: 2, skipped: 0))
        let again = PlanGeneration.apply(proposal.items, choices: [:], to: &file)
        #expect(again == GenerationOutcome(created: 0, skipped: 0, alreadyBooked: 2))
        #expect(again.isEmpty)
    }

    @Test func extraTransactionsFarFromAnyDateDoNotSettleIt() {
        let plan = deposit("P", start: Day(year: 2026, month: 1, day: 5))
        let due = Day(year: 2026, month: 6, day: 5)
        func status(_ transactions: [Transaction]) -> [Day: Day] {
            var file = PortfolioFile()
            file.plans = [plan]
            file.transactions = transactions
            return GenerationProposal.bookedElsewhere(
                plan: plan, status: Ledger(file).planStatus(plan, through: today), executions: transactions)
        }
        func tagged(_ day: Day) -> Transaction {
            Transaction(kind: .deposit, date: day, amount: plan.amount, source: plan.sourceTag)
        }
        #expect(GenerationProposal.nearbyDays(intervalMonths: 1) == 18)
        // 15 days off the June date (matched by nothing within the engine's 7 days) → that execution.
        #expect(status([tagged(Day(year: 2026, month: 6, day: 20))])[due] == Day(year: 2026, month: 6, day: 20))
        // One transaction settles one date only.
        #expect(status([tagged(Day(year: 2026, month: 5, day: 20))]).count == 1)
        // Matched executions are not candidates.
        #expect(status([tagged(due)])[due] == nil)
    }

    @Test func sharesCanBeCorrectedBeforeBooking() async throws {
        let store = demoStore()
        let plan = try #require(store.file.plans.first { $0.kind == .purchase })
        store.mutate("Remove") { file in
            file.transactions.removeAll { $0.source == plan.sourceTag && $0.date >= Day(year: 2026, month: 6, day: 1) }
        }
        let plans = store.file.plans
        let proposal = try await store.compute("test.p") { GenerationProposal($0, plans: plans, today: today) }
        let item = try #require(proposal.items.first)
        let proposed = try #require(item.transaction)
        #expect(item.hasShares)
        let actual = Shares(raw: 3 * Scale.shares)
        #expect(item.impliedPrice(shares: nil) == item.price)
        #expect(item.impliedPrice(shares: .zero) == item.price, "an empty field means: as proposed")
        #expect(item.impliedPrice(shares: actual) == Price(minor: proposed.amount.minor - proposed.fees, per: actual))

        var file = store.file
        PlanGeneration.apply([item], choices: [:], shares: [item.id: actual], to: &file)
        let booked = try #require(file.transactions.first { $0.id == proposed.id })
        #expect(booked.shares == actual)
        #expect(booked.amount == proposed.amount, "the plan's amount is what was paid")
        #expect(booked.source == plan.sourceTag)
        // Zero and deposits fall back to the proposal.
        #expect(item.transaction(shares: .zero) == proposed)
        let cash = GenerationItem(id: "d", planID: UUID(), planName: "D", kind: .deposit, due: today,
                                  transaction: Transaction(kind: .deposit, date: today, amount: Money(minor: 1, currency: "EUR")),
                                  amount: Money(minor: 1, currency: "EUR"))
        #expect(!cash.hasShares)
        #expect(cash.transaction(shares: actual)?.shares.isZero == true)
    }

    @Test func summaryKeepsDepositsWithdrawalsAndPurchasesApart() {
        func item(_ id: String, _ kind: InvestmentPlan.Kind, _ minor: Int64, _ currency: CurrencyCode = "EUR") -> GenerationItem {
            let amount = Money(minor: minor, currency: currency)
            let transaction = Transaction(kind: kind == .deposit ? .deposit : kind == .withdrawal ? .withdrawal : .buy, date: today, amount: amount)
            return GenerationItem(id: id, planID: UUID(), planName: id, kind: kind, due: today, transaction: transaction, amount: amount)
        }
        let items = [item("a", .purchase, 50_000), item("b", .deposit, 150_000), item("c", .deposit, 150_000),
                     item("d", .withdrawal, 20_000), item("e", .purchase, 10_000, "USD"), item("f", .purchase, 50_000)]
        let summary = GenerateSheet.Summary(items: items) { $0.id == "f" ? .skip : .create }
        #expect(summary.created == 5 && summary.skipped == 1)
        #expect(summary.groups.map(\.kind) == [.deposit, .withdrawal, .purchase, .purchase])
        #expect(summary.groups.map(\.total) == [300_000, 20_000, 50_000, 10_000])
        #expect(summary.text == "Adding 2 deposits (\(Fmt.money(minor: 300_000, currency: "EUR"))), 1 withdrawal (\(Fmt.money(minor: 20_000, currency: "EUR"))), "
            + "1 purchase (\(Fmt.money(minor: 50_000, currency: "EUR"))), 1 purchase (\(Fmt.money(minor: 10_000, currency: "USD"))) · 1 skipped")
        #expect(!summary.text.contains(Fmt.money(minor: 370_000, currency: "EUR")), "no sum across kinds")
    }
}

@Suite @MainActor struct PlansListRegressionTests {
    @Test func aPlanStartingBeyondSixIntervalsStillShowsItsDates() async throws {
        let store = demoStore()
        let account = try #require(store.file.accounts.first)
        let far = deposit("Far future", start: Day(year: 2027, month: 3, day: 1), account: account)
        let rates = store.file.exchangeRates
        let detail = try await store.compute("test.detail") { PlanDetail($0, plan: far, today: today, exchangeRates: rates) }
        #expect(detail.nextDue == Day(year: 2027, month: 3, day: 1))
        #expect(detail.upcoming.count == PlanDetail.upcomingCount)
        #expect(detail.upcoming.first?.due == detail.nextDue)
    }

    @Test func perMonthCountsOnlyPlansThatRunToday() async throws {
        let store = demoStore()
        let account = try #require(store.file.accounts.first { $0.currency == store.file.settings.baseCurrency })
        let far = deposit("Far future", start: Day(year: 2027, month: 3, day: 1), account: account)
        var payout = deposit("Payout", start: Day(year: 2026, month: 8, day: 1), account: account)
        payout.kind = .withdrawal
        store.mutate("Add") { $0.plans += [far, payout] }
        let plans = store.file.plans
        let query = PlansModel.Query(today: today, sortOrder: defaultSort)
        let model = try await store.compute("test.model") { PlansModel($0, plans: plans, query: query) }
        #expect(model.monthlyDeposits == 150_000, "the plan starting in 2027 deposits nothing yet")
        #expect(model.monthlyWithdrawals == 0)
        #expect(model.monthlyPurchases == 50_000)
        #expect(model.activeCount == 4)
        #expect(!PlansScreen.cadence(model).contains("withdrawing"))
    }

    @Test func plansWithoutAnExchangeRateAreMentionedNotDropped() async throws {
        let store = demoStore()
        let odd = Account(name: "Odd", currency: "XTS")
        let plan = InvestmentPlan(name: "Odd deposit", kind: .deposit, accountID: odd.id, amount: Money(minor: 10_000, currency: "XTS"),
                                  start: Day(year: 2026, month: 1, day: 1))
        store.mutate("Add") { file in
            file.accounts.append(odd)
            file.plans.append(plan)
        }
        let plans = store.file.plans
        let query = PlansModel.Query(today: today, sortOrder: defaultSort)
        let model = try await store.compute("test.model") { PlansModel($0, plans: plans, query: query) }
        #expect(model.unconvertedCount == 1)
        #expect(model.monthlyDeposits == 150_000)
        #expect(PlansScreen.cadence(model).hasSuffix("1 plan not included (no exchange rate to \(model.currency))"))
        var none = PlansModel()
        none.activeCount = 1
        #expect(PlansScreen.cadence(none) == "No plan is running yet")
    }

    @Test func aPlanThatCannotRunHasNoNextDateOrUpcomingRows() async throws {
        let store = demoStore()
        let broken = deposit("Broken deposit", start: Day(year: 2026, month: 7, day: 1))
        store.mutate("Add") { $0.plans = [broken] }
        let plans = store.file.plans
        let query = PlansModel.Query(today: today, sortOrder: defaultSort)
        let model = try await store.compute("test.model") { PlansModel($0, plans: plans, query: query) }
        #expect(model.rows.first?.nextDue == nil)
        let rates = store.file.exchangeRates
        let detail = try await store.compute("test.detail") { PlanDetail($0, plan: broken, today: today, exchangeRates: rates) }
        #expect(detail.problem != nil)
        #expect(detail.nextDue == nil)
        #expect(detail.upcoming.isEmpty)
    }
}

@Suite @MainActor struct PlanValidationTests {
    /// The validation mirrors the engine's plan problems, so the inspector can tell a plan that
    /// cannot run without a pass over the ledger.
    @Test func validationMirrorsTheEnginesProblems() throws {
        let store = demoStore()
        let purchase = try #require(store.file.plans.first { $0.kind == .purchase })
        func message(_ plan: InvestmentPlan) -> String? {
            PlanDraft(plan).validate(
                security: store.security(plan.securityID), depot: store.depot(plan.depotID), account: store.account(plan.accountID),
                currency: plan.amount.currency)
        }
        #expect(message(purchase) == nil)
        var orphaned = purchase
        orphaned.accountID = UUID()
        #expect(message(orphaned) != nil)
        #expect(store.ledger.planStatus(orphaned, through: today).problem == .missingAccount)
        var foreign = purchase
        foreign.amount.currency = "USD"
        #expect(message(foreign) != nil)
        #expect(store.ledger.planStatus(foreign, through: today).problem == .currencyMismatch(expected: "EUR"))
        #expect(message(deposit("No account", start: today)) == "Choose the account.")
    }
}

@Suite @MainActor struct KeptHistoryTimelineTests {
    /// After "apply from the next execution" the old executions are shown against the new
    /// schedule — booked, on their own day — not as 108 skipped dates next to 108 stray bookings.
    @Test func historyKeptAfterAScheduleChangeReadsAsBooked() async throws {
        let store = demoStore()
        let original = try #require(store.file.plans.first { $0.kind == .purchase })
        var moved = original
        moved.start = Day(year: 2017, month: 7, day: 20)
        ScheduleImpact(store.ledger, old: original, new: moved, today: today).keepHistory(in: &moved)
        store.updatePlan(moved)
        let rates = store.file.exchangeRates
        let kept = moved
        let detail = try await store.compute("test.detail") { PlanDetail($0, plan: kept, today: today, exchangeRates: rates) }
        #expect(detail.state == .upToDate)
        #expect(detail.skipped.isEmpty)
        #expect(detail.history.count == 108)
        let newest = try #require(detail.history.first)
        #expect(newest.due == Day(year: 2026, month: 6, day: 22), "the new schedule's date (20 Jun 2026 is a Saturday)")
        #expect(newest.booked == Day(year: 2026, month: 6, day: 5))
        #expect(detail.history.allSatisfy { if case .executed = $0.kind { true } else { false } })
        // A date the user really skipped (nothing booked near it) still shows as skipped.
        var skippedOne = original
        store.mutate("Remove June") { file in
            file.transactions.removeAll { $0.source == original.sourceTag && $0.date >= Day(year: 2026, month: 6, day: 1) }
        }
        PlanGeneration.skip(Day(year: 2026, month: 6, day: 5), in: &skippedOne)
        let skipping = skippedOne
        let other = try await store.compute("test.detail2") { PlanDetail($0, plan: skipping, today: today, exchangeRates: rates) }
        #expect(other.skipped == [Day(year: 2026, month: 6, day: 5)])
    }
}
