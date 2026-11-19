import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeaturePerformance

/// Regression tests for the findings of the independent review.
@Suite @MainActor struct PerformanceReviewTests {
    static let today = Fixture.today

    private func store(_ file: PortfolioFile, _ period: ReportingPeriod = .allTime) -> PortfolioStore {
        let store = PortfolioStore(file: file, today: Self.today)
        store.period = period
        return store
    }

    private func demoStore(_ period: ReportingPeriod = .allTime) -> PortfolioStore {
        store(SampleData.demoPortfolio(today: Self.today), period)
    }

    private func detail(_ line: StatementLine, in store: PortfolioStore) async throws -> LineDetail {
        let query = LineDetailQuery(line: line, sortOrder: [KeyPathComparator(\ContributionRow.date)])
        return try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
    }

    // MARK: Depot-less bookings

    /// A dividend, fee or tax booked without a depot belongs to the depot that holds the security —
    /// the drill-down must list it there and nowhere else, like the engine's line.
    @Test func depotLessBookingsFollowTheHoldingDepot() async throws {
        for heldInBoth in [false, true] {
            let store = store(Fixture.twoDepots(heldInBoth: heldInBoth))
            for depot in [Fixture.depotA, Fixture.depotB] {
                store.scopeSelection = .depot(depot)
                let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
                #expect(statement.reconciliationGap == 0)
                for line in [StatementLine.dividends, .fees, .taxes, .transfersIn, .transfersOut] {
                    let detail = try await detail(line, in: store)
                    let listed = detail.transactions.reduce(0) { $0 + $1.amount.minor }
                    #expect(listed == statement.amount(line),
                            "\(line) of \(depot == Fixture.depotA ? "A" : "B"), held in both: \(heldInBoth): \(listed) vs \(statement.amount(line))")
                }
            }
        }
    }

    @Test func attributionReplaysHoldingsLikeTheEngine() {
        var file = Fixture.twoDepots()
        let orphan = Transaction(kind: .dividend, date: Day(year: 2025, month: 8, day: 1), accountID: Fixture.cash,
                                 securityID: UUID(), amount: Money(10, "EUR"))
        file.transactions.append(orphan)
        // After a complete sale the depot the security was last moved in keeps its bookings.
        let sale = Transaction(kind: .sell, date: Day(year: 2025, month: 9, day: 1), accountID: Fixture.cash, depotID: Fixture.depotA,
                               securityID: Fixture.quoted, shares: Shares(100), amount: Money(10_400, "EUR"))
        let late = Transaction(kind: .dividend, date: Day(year: 2025, month: 10, day: 1), accountID: Fixture.cash,
                               securityID: Fixture.quoted, amount: Money(20, "EUR"))
        file.transactions += [sale, late]
        let attribution = PositionAttribution(Ledger(file))
        #expect(attribution.skipped == [orphan.id])
        let dividend = file.transactions.first { $0.kind == .dividend }!
        #expect(attribution.position(of: dividend) == .depot(Fixture.depotA))
        #expect(attribution.position(of: late) == .depot(Fixture.depotA))
        #expect(attribution.position(of: sale) == .depot(Fixture.depotA))
        #expect(!attribution.isPosition(of: late, in: [Fixture.depotB]))

        let both = Fixture.twoDepots(heldInBoth: true)
        let ambiguous = PositionAttribution(Ledger(both))
        let shared = both.transactions.first { $0.kind == .dividend }!
        #expect(ambiguous.position(of: shared) == .anyDepot(of: Fixture.quoted))
        #expect(ambiguous.isPosition(of: shared, in: [Fixture.depotA]) && ambiguous.isPosition(of: shared, in: [Fixture.depotB]))
    }

    /// Transactions the engine ignores are not listed behind a line either.
    @Test func ignoredTransactionsAreNotListed() async throws {
        var file = Fixture.twoDepots()
        file.transactions.append(Transaction(kind: .deposit, date: Day(year: 2025, month: 8, day: 1), accountID: UUID(),
                                             amount: Money(999, "EUR")))
        let store = store(file)
        let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
        let deposits = try await detail(.deposits, in: store)
        #expect(deposits.transactions.reduce(0) { $0 + $1.amount.minor } == statement.amount(.deposits))
        let overview = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(overview.warnings.contains { $0.kind == .ignoredTransactions })
    }

    /// A fee that names a security the file does not contain is an account fee for the engine.
    @Test func feesOfUnknownSecuritiesFollowTheirAccount() async throws {
        var file = Fixture.twoDepots()
        file.transactions.append(Transaction(kind: .fee, date: Day(year: 2025, month: 8, day: 1), accountID: Fixture.cash,
                                             securityID: UUID(), amount: Money(7, "EUR")))
        let store = store(file)
        for selection in [ScopeSelection.portfolio, .account(Fixture.cash), .depot(Fixture.depotA)] {
            store.scopeSelection = selection
            let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
            for line in [StatementLine.fees, .transfersIn, .transfersOut] {
                let detail = try await detail(line, in: store)
                #expect(detail.transactions.reduce(0) { $0 + $1.amount.minor } == statement.amount(line), "\(line) in \(selection)")
            }
        }
    }

    // MARK: Engine diagnostics

    @Test func incompleteDataIsReported() async throws {
        let store = store(Fixture.incompleteData())
        let model = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        let rate = try #require(model.warnings.first { $0.kind == .missingExchangeRate })
        #expect(rate.message.contains("USD") && rate.message.contains("EUR"))
        #expect(rate.message.contains(Fmt.money(minor: 500_000, currency: "USD")))
        let derived = try #require(model.warnings.first { $0.kind == .derivedPrices })
        #expect(derived.message.contains("Unquoted Holding KG"))
        // A security nobody holds is nobody's problem here.
        #expect(!model.warnings.contains { $0.message.contains("Never Priced") })

        let query = SecuritiesQuery(filter: "", sortOrder: [KeyPathComparator(\SecurityRow.name)])
        let securities = try await store.analyze("test.securities", variant: query) { SecuritiesModel($0, query: query) }
        #expect(securities.rows.first { $0.id == Fixture.unquoted }?.priceIssue == .derived)
        #expect(securities.rows.first { $0.id == Fixture.quoted }?.priceIssue == nil)

        // The EUR account on its own is complete.
        store.scopeSelection = .account(Fixture.cash)
        let account = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(account.warnings.isEmpty)

        // An amount without a rate is listed, but flagged as not part of the line.
        store.scopeSelection = .portfolio
        let deposits = try await detail(.deposits, in: store)
        #expect(deposits.transactions.count == 2)
        #expect(deposits.unconvertedCount == 1)
    }

    @Test func theDemoPortfolioHasNoWarnings() async throws {
        let model = try await demoStore().analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(model.warnings.isEmpty)
        #expect(DataWarning.list(["A", "B", "C", "D"]) == "A, B and 2 more")
    }

    // MARK: Partial calendar units

    @Test func calendarCoverageKnowsCompleteUnits() {
        let first = Day(year: 2019, month: 3, day: 15)
        // 1 July 2025 … 30 June 2026 of a portfolio that started in 2019.
        let year = CalendarCoverage(interval: DayInterval(start: Day(year: 2025, month: 6, day: 30), end: Self.today), firstTransactionDay: first)
        #expect(!year.isComplete(year: 2025) && !year.isComplete(year: 2026))
        #expect(year.isComplete(year: 2025, month: 7) && year.isComplete(year: 2026, month: 6))
        #expect(year.months(of: 2025) == 7...12 && year.months(of: 2026) == 1...6)
        // Mid-month edges cut both edge months.
        let mid = CalendarCoverage(interval: DayInterval(start: Day(year: 2025, month: 6, day: 14), end: Day(year: 2025, month: 9, day: 10)),
                                   firstTransactionDay: first)
        #expect(!mid.isComplete(year: 2025, month: 6) && mid.isComplete(year: 2025, month: 7) && !mid.isComplete(year: 2025, month: 9))
        // The portfolio's first month and year are all there is: complete.
        let all = CalendarCoverage(interval: DayInterval(start: first.advanced(by: -1), end: Self.today), firstTransactionDay: first)
        #expect(all.isComplete(year: 2019) && all.isComplete(year: 2019, month: 3) && all.isComplete(year: 2025))
        #expect(!all.isComplete(year: 2026))
        #expect(all.months(of: 2019) == 1...12 && all.months(of: 2026) == 1...6)
    }

    @Test func partialYearsAreMarkedAndNotRanked() async throws {
        let store = demoStore(.lastYears(1))
        let model = try await store.analyze("test.returns") { ReturnsModel($0) }
        #expect(model.years.map(\.label) == ["2025*", "2026*"])
        #expect(model.heatmapRows.map(\.label) == ["2026*", "2025*"])
        #expect(model.heatmapRows.map(\.id) == ["2026", "2025"])
        #expect(model.partialYearsNote?.contains("2025 covers") == true)
        // Two half years are no calendar years; one 12-month window is no statistic.
        #expect(!model.extremes.contains { $0.id == "year" || $0.id == "rolling" })
        #expect(model.positiveYearWindows == nil && model.averageYearWindow == nil)
        #expect(model.monthCount == 12 && model.partialMonthsNote == nil)

        // All time: the running year is shown but does not compete with complete years.
        store.period = .allTime
        let all = try await store.analyze("test.returns") { ReturnsModel($0) }
        let ranked = try #require(all.extremes.first { $0.id == "year" })
        #expect(ranked.bestLabel != "2026" && ranked.worstLabel != "2026")
        #expect(all.years.last?.label == "2026*")
        #expect(all.years.dropLast().allSatisfy { !$0.label.hasSuffix("*") })
        let engine2025 = try #require(store.ledger.performance(in: store.interval(for: .year(2025))).returns.yearlyReturns().first)
        let index = try #require(all.years.firstIndex { $0.id == "2025" })
        #expect(abs(all.yearlyReturns[index] - engine2025.value) < 1e-9)

        // A period that starts and ends mid-month: the edge months are not months.
        store.period = .custom(from: Day(year: 2025, month: 9, day: 14), to: Day(year: 2026, month: 2, day: 10))
        let cut = try await store.analyze("test.returns") { ReturnsModel($0) }
        #expect(cut.monthCount == 4)
        #expect(cut.partialMonthsNote != nil)
        let risk = try await store.analyze("test.risk") { RiskModel($0) }
        #expect(risk.monthlyCount == 4 && risk.monthlyHistogram.total == 4)
    }

    // MARK: Annualizing

    @Test func shortPeriodsAreNotAnnualized() async throws {
        #expect(ReturnHorizon.moneyWeighted(irr: 0.10, days: 730) == 0.10)
        #expect(ReturnHorizon.moneyWeighted(irr: nil, days: 30) == nil)
        #expect(ReturnHorizon.moneyWeighted(irr: -1.5, days: 30) == -1)
        let month = try #require(ReturnHorizon.moneyWeighted(irr: 0.6920, days: 30))
        #expect(abs(month - 0.04418) < 0.0001)
        // The inverse of the engine's annualizing.
        #expect(abs((Returns.annualize(total: month, days: 30) ?? 0) - 0.6920) < 1e-9)
        // Continuous where the rule switches.
        let year = try #require(ReturnHorizon.moneyWeighted(irr: 0.08, days: 365))
        #expect(abs(year - 0.08) < 1e-12)

        let store = demoStore(.monthToDate)
        let model = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        let irr = try #require(model.irr), shown = try #require(model.moneyWeightedReturn)
        #expect(!model.showsAnnualized)
        #expect(abs(shown) < abs(irr) && abs(shown - model.ttwror) < 0.01)
        #expect(model.sharpeRatio != nil && model.shownSharpeRatio == nil)
        let risk = try await store.analyze("test.risk") { RiskModel($0) }
        #expect(!risk.showsSharpeRatio)
        let period = try await store.analyze("test.period") { PeriodFigures($0) }
        #expect(period.moneyWeightedReturn == shown && !period.isAnnualized)
        let summary = try await store.analyze("test.summary") { PerformanceSummary($0, scopeTitle: "Whole Portfolio") }
        #expect(!summary.text.contains("per Year") && !summary.text.contains("Sharpe"))

        // Exactly one year: nothing is extrapolated, so the Sharpe ratio stays.
        store.period = .lastYears(1)
        let oneYear = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(oneYear.shownSharpeRatio == oneYear.sharpeRatio && oneYear.sharpeRatio != nil)
        #expect(abs((oneYear.moneyWeightedReturn ?? 0) - (oneYear.irr ?? 1)) < 1e-9)

        #expect(PercentAxis.decimals(for: [0, 0.05, 0.10]) == 0)
        #expect(PercentAxis.decimals(for: [0, 0.025, 0.05, 0.075, 0.125]) == 1)
        #expect(PercentAxis.decimals(for: [0, 0.0025]) == 2)

        store.period = .lastYears(3)
        let long = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(long.showsAnnualized && long.moneyWeightedReturn == long.irr && long.shownSharpeRatio == long.sharpeRatio)
    }

    // MARK: Chart range

    @Test func aPinnedRangeReplacesADraggedOne() {
        let dragged = DayInterval(start: Day(year: 2025, month: 1, day: 1), end: Day(year: 2025, month: 2, day: 1))
        let drawdown = DayInterval(start: Day(year: 2024, month: 3, day: 1), end: Day(year: 2024, month: 6, day: 1))
        var state = ChartRangeState()
        state.drag(dragged)
        #expect(state.active == dragged)
        let generation = state.generation
        state.pin(drawdown)                       // "Show in Chart" of a drawdown
        #expect(state.active == drawdown && state.dragged == nil)
        #expect(state.generation != generation)   // the chart drops its own selection
        state.drag(dragged)                       // dragging again wins over the pin
        #expect(state.active == dragged && state.pinned == nil)
        state.drag(nil)
        #expect(state.active == nil)
        state.pin(drawdown)
        let pinnedGeneration = state.generation
        state.clear()
        #expect(state.active == nil && state.generation != pinnedGeneration)
    }

    // MARK: Chart series

    @Test func theScopesOwnSeriesCarriesItsName() async throws {
        let store = demoStore(.lastYears(1))
        let model = try await store.analyze("test.overview.named") { OverviewModel($0, compare: [], scopeName: "Kids Depot") }
        #expect(model.returnSeries[0].name == "Kids Depot" && model.drawdownSeries[0].name == "Kids Depot")
    }

    @Test func comparisonsWithoutPricesAreReportedNotSwallowed() async throws {
        var file = Fixture.incompleteData()
        let store = store(file)
        let compare = [Fixture.neverPriced, Fixture.quoted]
        let model = try await store.analyze("test.overview.compare") { OverviewModel($0, compare: compare) }
        #expect(model.comparisons.map(\.id) == [Fixture.quoted])
        #expect(model.undrawnComparisons == [Fixture.neverPriced])
        #expect(!ComparisonRules.canDraw(Fixture.neverPriced, ledger: store.ledger, on: store.periodInterval.start))
        #expect(ComparisonRules.canDraw(Fixture.quoted, ledger: store.ledger, on: store.periodInterval.start))

        // A benchmark that cannot be drawn must not hand the scope's own color to the next line.
        file.settings.benchmarkSecurityIDs = [Fixture.neverPriced]
        let withBenchmark = self.store(file)
        let drawn = try await withBenchmark.analyze("test.overview.compare") { OverviewModel($0, compare: [Fixture.quoted]) }
        #expect(drawn.returnSeries.count == 2)
        #expect(drawn.returnSeries[1].color != drawn.returnSeries[0].color)
        #expect(drawn.returnSeries[1].color == ChartColors.series(1))
    }

    // MARK: Empty state

    @Test func nothingToMeasureNeverOffersWhatChangesNothing() {
        let allTime = DayInterval(start: Self.today, end: Self.today)
        let future = NothingToMeasureAdvice(scopeTitle: "Whole Portfolio", isWholePortfolio: true, interval: allTime, allTime: allTime,
                                            firstTransactionDay: Day(year: 2026, month: 8, day: 15), today: Self.today)
        #expect(!future.offersAllTime && future.offersTransactions && !future.offersWholePortfolio)
        #expect(future.message.contains("after today"))

        let year = DayInterval(start: Day(year: 2015, month: 12, day: 31), end: Day(year: 2016, month: 12, day: 31))
        let longer = DayInterval(start: Day(year: 2019, month: 1, day: 1), end: Self.today)
        let early = NothingToMeasureAdvice(scopeTitle: "Kids Depot", isWholePortfolio: false, interval: year, allTime: longer,
                                           firstTransactionDay: Day(year: 2019, month: 1, day: 2), today: Self.today)
        #expect(early.offersAllTime && early.offersWholePortfolio && !early.offersTransactions)

        let never = NothingToMeasureAdvice(scopeTitle: "Kids Depot", isWholePortfolio: false, interval: longer, allTime: longer,
                                           firstTransactionDay: Day(year: 2019, month: 1, day: 2), today: Self.today)
        #expect(!never.offersAllTime && never.offersWholePortfolio)
    }

    @Test func aDepositInTheFutureHasNoActivity() async throws {
        let store = store(Fixture.singleDeposit(on: Day(year: 2026, month: 8, day: 15)))
        let model = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(!model.hasActivity)
        #expect(model.interval == store.interval(for: .allTime))
    }

    // MARK: Securities footer

    @Test func theRemainderIsBrokenDownExactly() async throws {
        for period in [ReportingPeriod.allTime, .lastYears(1), .ytd] {
            let store = demoStore(period)
            let query = SecuritiesQuery(filter: "", sortOrder: [KeyPathComparator(\SecurityRow.name)])
            let model = try await store.analyze("test.securities", variant: query) { SecuritiesModel($0, query: query) }
            #expect(model.remainder.reduce(0) { $0 + $1.amount } == model.totalResult - model.securitiesResult)
            // The named parts explain everything: nothing is left for "other".
            #expect(!model.remainder.contains { $0.label == "Rounding and other" }, "\(period): \(model.remainder)")
            let breakdown = store.ledger.breakdown(in: store.periodInterval)
            #expect(model.remainder.first { $0.label == "Interest" }?.amount == (breakdown.interest == 0 ? nil : breakdown.interest))
        }
    }

    @Test func securityReturnsFollowTheAnnualizingRule() async throws {
        let store = demoStore(.monthToDate)
        let query = SecuritiesQuery(filter: "", sortOrder: [KeyPathComparator(\SecurityRow.name)])
        let model = try await store.analyze("test.securities", variant: query) { SecuritiesModel($0, query: query) }
        #expect(!model.irrIsAnnualized)
        let engine = store.ledger.securityPerformance(in: store.periodInterval)
        for row in model.rows {
            let irr = engine.first { $0.securityID == row.id }?.irr
            #expect(row.irr == ReturnHorizon.moneyWeighted(irr: irr, days: store.periodInterval.dayCount))
        }
        #expect(SecuritiesModel.tsv(model.rows, currency: model.currency, irrIsAnnualized: false).contains("IRR (not annualized)"))
    }

    // MARK: Line drill-down

    @Test func amountsSortByTheirValueInTheReportingCurrency() async throws {
        let store = demoStore()
        let query = LineDetailQuery(line: .dividends, sortOrder: [KeyPathComparator(\ContributionRow.sortValue, order: .reverse)])
        let detail = try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
        #expect(Set(detail.transactions.map(\.amount.currency)).count > 1)
        let converter = store.ledger.converter
        let values = detail.transactions.map { converter.convert(minor: $0.amount.minor, from: $0.amount.currency, to: store.baseCurrency, on: $0.date) ?? 0 }
        #expect(values == values.sorted(by: >))
        #expect(detail.transactions.map(\.sortValue) == values)
        #expect(detail.unconvertedCount == 0)
    }

    @Test func aSelectionNeverOutlivesItsRows() {
        let a = UUID(), b = UUID(), gone = UUID()
        #expect(LineSelection.valid([a, gone], rows: [a, b]) == [a])
        #expect(LineSelection.single([a, gone], rows: [a, b]) == a)
        #expect(LineSelection.single([a, b], rows: [a, b]) == nil)
        #expect(LineSelection.single([gone], rows: [a, b]) == nil)
        #expect(LineSelection.single([], rows: [a, b]) == nil)
    }

    @Test func countsArePluralizedProperly() {
        #expect(Plural.count(1, "complete month", "complete months") == "1 complete month")
        #expect(Plural.count(3, "complete month", "complete months") == "3 complete months")
    }
}
