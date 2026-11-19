import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeaturePerformance

// Tests of the Performance feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Performance"):
//
//     KONTOR_FEATURES=Performance swift test --scratch-path .build-performance --filter FeaturePerformanceTests
@Suite @MainActor struct PerformanceFeatureTests {
    static let today = Day(year: 2026, month: 6, day: 30)

    private func demoStore(_ period: ReportingPeriod = .allTime) -> PortfolioStore {
        let store = PortfolioStore(file: SampleData.demoPortfolio(today: Self.today), today: Self.today)
        store.period = period
        return store
    }

    @Test func moduleRegistersItsScreenCommandsAndInspector() {
        let store = demoStore()
        #expect(PerformanceFeature.module.screen == .performance)
        let commands = PerformanceFeature.commands(store)
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(commands.allSatisfy { $0.id.hasPrefix("performance.") })
        #expect(commands.count >= PerformanceTab.allCases.count + PerformanceChartMode.allCases.count)
    }

    @Test func overviewMatchesTheEngine() async throws {
        let store = demoStore()
        let model = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        let report = store.ledger.performance(in: store.periodInterval)
        #expect(model.hasActivity)
        #expect(model.ttwror == report.ttwror)
        #expect(model.irr == report.irr)
        #expect(model.absolutePerformance == report.absolutePerformance)
        #expect(model.finalValue == report.breakdown.finalValue)
        #expect(model.maxDrawdown == report.risk.maxDrawdown)
        // Portfolio + the two demo benchmarks, all on the period's day axis.
        #expect(model.returnSeries.count == 3)
        #expect(model.comparisons.allSatisfy { $0.isBenchmark })
        #expect(model.returnSeries.allSatisfy { $0.values.count == store.periodInterval.dayCount + 1 })
        #expect(model.returnSeries[0].values.last == report.ttwror)
        #expect(model.valueSeries[0].values.last == Double(report.breakdown.finalValue))
        #expect(model.drawdownSeries[0].values.allSatisfy { $0 <= 0 })
        #expect(model.drawdownSeries[0].values.min() == report.risk.maxDrawdown.map { -$0.depth })
    }

    @Test func adHocComparisonsAreAddedOnceAndCapped() async throws {
        let store = demoStore(.lastYears(3))
        let held = store.file.securities.prefix(10).map(\.id)
        let benchmark = try #require(store.file.settings.benchmarkSecurityIDs.first)
        let compare = [held[0], held[0], benchmark] + held
        let model = try await store.analyze("test.overview.compare") { OverviewModel($0, compare: compare) }
        #expect(model.comparisons.count == OverviewModel.comparisonLimit)
        #expect(Set(model.comparisons.map(\.id)).count == model.comparisons.count)
        #expect(model.comparisons.filter(\.isBenchmark).count == 2)
        #expect(model.returnSeries.count == OverviewModel.comparisonLimit + 1)
    }

    @Test func statementReconciles() async throws {
        for period in [ReportingPeriod.allTime, .lastYears(1), .ytd, .year(2023)] {
            let store = demoStore(period)
            let model = try await store.analyze("test.calculation") { CalculationModel($0) }
            #expect(model.reconciliationGap == 0)
            let components = model.entries.filter { $0.line.role == .component && !StatementLine.flowLines.contains($0.line) }
            let flows = model.entries.filter { StatementLine.flowLines.contains($0.line) }
            #expect(flows.reduce(0) { $0 + $1.amount } == model.amount(.netFlows))
            #expect(components.reduce(0) { $0 + $1.amount } == model.amount(.performance))
            #expect(model.amount(.initialValue) + model.amount(.netFlows) + model.amount(.performance) == model.amount(.finalValue))
            // The waterfall ends where the statement ends.
            #expect(model.waterfall.last?.value == Double(model.amount(.finalValue)))
        }
    }

    /// In the EUR-only lines of the whole portfolio the listed transactions add up to the line.
    @Test func contributingTransactionsAddUpToTheirLine() async throws {
        let store = demoStore()
        let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
        for line in [StatementLine.deposits, .withdrawals, .deliveriesIn, .interest] {
            let query = LineDetailQuery(line: line, sortOrder: [KeyPathComparator(\ContributionRow.date)])
            let detail = try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
            #expect(!detail.transactions.isEmpty, "\(line)")
            #expect(detail.isSingleCurrency, "\(line)")
            #expect(detail.transactions.reduce(0) { $0 + $1.amount.minor } == statement.amount(line), "\(line)")
        }
    }

    /// Lines with foreign-currency bookings: converting each listed amount at its day's rate gives the line.
    @Test func foreignCurrencyContributionsConvertToTheirLine() async throws {
        let store = demoStore()
        let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
        let converter = store.ledger.converter
        for line in [StatementLine.dividends, .fees, .taxes] {
            let query = LineDetailQuery(line: line, sortOrder: [KeyPathComparator(\ContributionRow.date)])
            let detail = try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
            let sum = detail.transactions.reduce(Int64(0)) { total, row in
                total + (converter.convert(minor: row.amount.minor, from: row.amount.currency, to: store.baseCurrency, on: row.date) ?? 0)
            }
            // Per-transaction rounding of fee and tax parts may differ by a cent each.
            #expect(abs(sum - statement.amount(line)) <= Int64(detail.transactions.count), "\(line): \(sum) vs \(statement.amount(line))")
        }
    }

    @Test func capitalGainLinesListSecuritiesThatAddUp() async throws {
        let store = demoStore()
        let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
        for line in [StatementLine.realizedGains, .unrealizedGains] {
            let query = LineDetailQuery(line: line, sortOrder: [KeyPathComparator(\ContributionRow.date)])
            let detail = try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
            #expect(detail.securities.reduce(0) { $0 + $1.amount } == statement.amount(line), "\(line)")
        }
    }

    @Test func partialScopesListBoundaryTransfers() async throws {
        let store = demoStore(.lastYears(3))
        let depot = store.file.depots[1]
        store.scopeSelection = .depot(depot.id)
        let statement = try await store.analyze("test.calculation") { CalculationModel($0) }
        #expect(statement.reconciliationGap == 0)
        #expect(statement.amount(.transfersIn) > 0)
        let query = LineDetailQuery(line: .transfersIn, sortOrder: [KeyPathComparator(\ContributionRow.date)])
        let detail = try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
        #expect(!detail.transactions.isEmpty)
        #expect(detail.transactions.allSatisfy { $0.amount.minor > 0 })
    }

    @Test func drawdownEpisodesAgreeWithTheEngine() async throws {
        let store = demoStore()
        let model = try await store.analyze("test.risk") { RiskModel($0) }
        let engine = try #require(model.maxDrawdown)
        let deepest = try #require(model.episodes.first)
        #expect(deepest.depth == engine.depth)
        #expect(deepest.trough == engine.trough)
        #expect(deepest.peak == engine.peak)
        #expect(deepest.recovery == engine.recovery)
        #expect(model.episodes.count <= RiskModel.episodeLimit)
        #expect(model.episodes == model.episodes.sorted { $0.depth > $1.depth })
        #expect(model.episodes.allSatisfy { episode in episode.peak < episode.trough && (episode.recovery.map { $0 > episode.trough } ?? true) })
        #expect(model.dailyHistogram.total == model.dailyCount)
        #expect(model.monthlyHistogram.total == model.monthlyCount)
    }

    @Test func episodesOfAHandMadeCurve() {
        let start = Day(year: 2024, month: 1, day: 1)
        let curve = [0, 0, 0.1, 0.3, 0.2, 0, 0, 0.05, 0.02]
        let episodes = DrawdownEpisode.episodes(underwater: curve, start: start)
        #expect(episodes.count == 2)
        #expect(episodes[0].depth == 0.3)
        #expect(episodes[0].peak == start.advanced(by: 1))
        #expect(episodes[0].trough == start.advanced(by: 3))
        #expect(episodes[0].recovery == start.advanced(by: 5))
        #expect(episodes[0].durationDays == 4)
        #expect(episodes[1].recovery == nil)
        #expect(episodes[1].depth == 0.05)
        #expect(episodes[1].durationDays == 2)
        #expect(DrawdownEpisode.episodes(underwater: [0, 0, 0], start: start).isEmpty)
    }

    @Test func returnsModelCoversThePeriod() async throws {
        let store = demoStore()
        let model = try await store.analyze("test.returns") { ReturnsModel($0) }
        #expect(model.years.count == model.yearlyReturns.count)
        #expect(model.heatmap.rows.count == model.years.count)
        #expect(model.hasRollingOneYear && model.hasRollingThreeYears)
        #expect(model.rollingOneYear.count == store.periodInterval.dayCount + 1)
        #expect(model.positiveMonths <= model.monthCount)
        #expect(Set(model.extremes.map(\.id)) == ["day", "month", "year", "rolling"])
        for row in model.extremes {
            #expect((row.best ?? 0) >= (row.worst ?? 0))
        }

        // A month has no rolling windows and no year comparison.
        store.period = .monthToDate
        let short = try await store.analyze("test.returns") { ReturnsModel($0) }
        #expect(!short.hasRollingOneYear)
        #expect(!short.extremes.contains { $0.id == "rolling" || $0.id == "year" })
    }

    @Test func securitiesTableSortsFiltersAndReconciles() async throws {
        let store = demoStore()
        let byGain = SecuritiesQuery(filter: "", sortOrder: [KeyPathComparator(\SecurityRow.absolutePerformance, order: .reverse)])
        let model = try await store.analyze("test.securities", variant: byGain) { SecuritiesModel($0, query: byGain) }
        #expect(model.rows.count == model.totalCount)
        #expect(model.rows.map(\.absolutePerformance) == model.rows.map(\.absolutePerformance).sorted(by: >))
        #expect(model.securitiesResult == model.rows.reduce(0) { $0 + $1.absolutePerformance })
        let breakdown = store.ledger.breakdown(in: store.periodInterval)
        #expect(model.totalResult == breakdown.absolutePerformance)
        #expect(model.rows.reduce(0) { $0 + $1.realized } == breakdown.realizedGains)
        #expect(model.rows.reduce(0) { $0 + $1.unrealized } == breakdown.unrealizedGains)
        #expect(model.rows.reduce(0) { $0 + $1.dividends } == breakdown.dividends)
        // Benchmarks are never held, so they are not listed.
        #expect(!model.rows.contains { store.file.settings.benchmarkSecurityIDs.contains($0.id) })

        let filtered = SecuritiesQuery(filter: "etf", sortOrder: [KeyPathComparator(\SecurityRow.name)])
        let etfs = try await store.analyze("test.securities", variant: filtered) { SecuritiesModel($0, query: filtered) }
        #expect(!etfs.rows.isEmpty && etfs.rows.count < etfs.totalCount)
        #expect(etfs.rows.allSatisfy { $0.name.localizedCaseInsensitiveContains("etf") })
        #expect(SecuritiesModel.tsv(etfs.rows, currency: etfs.currency).split(separator: "\n").count == etfs.rows.count + 1)
    }

    @Test func periodsBeforeTheFirstTransactionHaveNoActivity() async throws {
        let store = demoStore(.custom(from: Day(year: 2016, month: 1, day: 1), to: Day(year: 2016, month: 6, day: 30)))
        let model = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
        #expect(!model.hasActivity)
    }

    @Test func rangeAndPeriodFiguresMatchTheEngine() async throws {
        let store = demoStore()
        let range = DayInterval(start: Day(year: 2025, month: 2, day: 3), end: Day(year: 2025, month: 9, day: 15))
        let figures = try await store.analyze("test.range", interval: range) { RangeFigures($0) }
        let report = store.ledger.performance(in: range)
        #expect(figures.ttwror == report.ttwror)
        #expect(figures.irr == report.irr)
        #expect(figures.absolutePerformance == report.absolutePerformance)

        let ytd = store.interval(for: .ytd)
        let period = try await store.analyze("test.period", interval: ytd) { PeriodFigures($0) }
        #expect(period.ttwror == store.ledger.performance(in: ytd).ttwror)
    }

    @Test func commandCenterDeliversRequestsToTheRightWindow() {
        let a = demoStore(), b = demoStore()
        let center = PerformanceCommandCenter.shared
        center.show(tab: .risk, in: a)
        #expect(a.route.screen == .performance)
        #expect(center.take(for: b) == nil)
        #expect(center.take(for: a)?.tab == .risk)
        #expect(center.take(for: a) == nil)
    }

    @Test func stressPortfolioModelsBuildQuickly() async throws {
        let file = SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000, endingOn: Self.today)
        let store = PortfolioStore(file: file, today: Self.today)
        store.period = .allTime
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            let overview = try await store.analyze("test.overview") { OverviewModel($0, compare: []) }
            let calculation = try await store.analyze("test.calculation") { CalculationModel($0) }
            let query = LineDetailQuery(line: .fees, sortOrder: [KeyPathComparator(\ContributionRow.date, order: .reverse)])
            let detail = try await store.analyze("test.detail", variant: query) { LineDetail($0, query: query) }
            #expect(overview.hasActivity)
            #expect(calculation.reconciliationGap == 0)
            #expect(!detail.transactions.isEmpty)
        }
        // Debug build, 25 years × 200 securities × 50,000 transactions, everything off the main actor.
        #expect(elapsed < .seconds(20))
    }
}
