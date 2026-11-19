import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureTrades

// Tests of the Trades feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Trades"):
//
//     KONTOR_FEATURES=Trades swift test --scratch-path .build-trades --filter FeatureTradesTests
@Suite @MainActor struct TradesFeatureTests {
    private let today = Day(year: 2026, month: 6, day: 30)

    private func demoStore(period: ReportingPeriod = .allTime) -> PortfolioStore {
        let store = PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
        store.period = period
        return store
    }

    private func query(_ kind: TradeKind, _ edit: (inout TradeQuery) -> Void = { _ in }) -> TradeQuery {
        var query = TradeQuery(kind: kind, sortOrder: [KeyPathComparator(\TradeRow.end, order: .reverse)])
        edit(&query)
        return query
    }

    private func model(_ store: PortfolioStore, _ query: TradeQuery) async throws -> TradeListModel {
        try await store.analyze("trades.list", variant: query) { TradeListModel($0, query: query) }
    }

    @Test func moduleRegistersItsScreen() {
        #expect(TradesFeature.module.screen == .trades)
    }

    @Test func moduleContributesCommands() {
        let ids = FeatureRegistry([TradesFeature.module]).commands(for: demoStore()).map(\.id)
        #expect(ids.contains("trades.show-years"))
        #expect(ids.contains("trades.export-years"))
        #expect(Set(ids).count == ids.count)
    }

    @Test func unfilteredModelMatchesTheEngineReport() async throws {
        let store = demoStore()
        let report = try await store.analyze("test.report") { $0.trades }
        let closed = try await model(store, query(.closed))
        let open = try await model(store, query(.open))

        #expect(!closed.rows.isEmpty)
        #expect(closed.rows.count == report.closed.count)
        #expect(closed.totalCount == report.closed.count)
        #expect(closed.statistics == report.statistics)
        #expect(closed.rows.reduce(0) { $0 + $1.gain } == report.statistics.totalGain)
        #expect(closed.exitTotal - closed.entryTotal == report.statistics.totalGain)   // the demo has no short trades
        #expect(closed.rows.allSatisfy { !$0.isOpen && $0.closingTransactionID != nil })
        #expect(Set(closed.rows.map(\.id)).count == closed.rows.count)

        #expect(open.rows.count == report.open.count)
        #expect(open.rows.allSatisfy { $0.isOpen && $0.closingTransactionID == nil && $0.end == today })
        #expect(open.statistics == TradeStatistics(report.open))
        #expect(open.currency == report.currency)
    }

    @Test func defaultOrderIsNewestCloseFirstAndSortFollowsTheQuery() async throws {
        let store = demoStore()
        let newest = try await model(store, query(.closed))
        #expect(newest.rows.map(\.end) == newest.rows.map(\.end).sorted(by: >))

        let byGain = try await model(store, query(.closed) { $0.sortOrder = [TradesTable.comparator("gain:asc")!] })
        #expect(byGain.rows.map(\.gain) == byGain.rows.map(\.gain).sorted())
    }

    @Test func outcomeFilterSplitsWinnersAndLosers() async throws {
        let store = demoStore()
        let all = try await model(store, query(.closed))
        let winners = try await model(store, query(.closed) { $0.outcome = .winners })
        let losers = try await model(store, query(.closed) { $0.outcome = .losers })

        #expect(winners.rows.allSatisfy { $0.gain > 0 })
        #expect(losers.rows.allSatisfy { $0.gain < 0 })
        #expect(winners.rows.count == all.statistics.winners)
        #expect(losers.rows.count == all.statistics.losers)
        #expect(winners.statistics.totalGain == all.statistics.grossProfit)
        #expect(losers.statistics.totalGain == -all.statistics.grossLoss)
        #expect(winners.totalCount == all.totalCount)        // totalCount ignores the filters
    }

    @Test func holdingFilterUsesTheThreshold() async throws {
        let store = demoStore()
        let all = try await model(store, query(.closed))
        for threshold in [365, 1826] {
            let long = try await model(store, query(.closed) { $0.holding = .longTerm; $0.thresholdDays = threshold })
            let short = try await model(store, query(.closed) { $0.holding = .shortTerm; $0.thresholdDays = threshold })
            #expect(long.rows.allSatisfy { $0.holdingDays > threshold })
            #expect(short.rows.allSatisfy { $0.holdingDays <= threshold })
            #expect(long.rows.count + short.rows.count == all.rows.count)
            let counted = try await model(store, query(.closed) { $0.thresholdDays = threshold })
            #expect(counted.longTermCount == long.rows.count)
        }
    }

    @Test func yearDepotSecurityAndTextFilters() async throws {
        let store = demoStore()
        let all = try await model(store, query(.closed))
        let year = try #require(all.years.first)
        #expect(all.years == all.years.sorted(by: >))

        let inYear = try await model(store, query(.closed) { $0.year = year })
        #expect(!inYear.rows.isEmpty)
        #expect(inYear.rows.allSatisfy { $0.end.year == year })

        let first = try #require(all.rows.first)
        let bySecurity = try await model(store, query(.closed) { $0.securityID = first.securityID })
        #expect(bySecurity.rows.allSatisfy { $0.securityID == first.securityID })
        let byDepot = try await model(store, query(.closed) { $0.depotID = first.id.depotID })
        #expect(byDepot.rows.allSatisfy { $0.id.depotID == first.id.depotID })

        let byText = try await model(store, query(.closed) { $0.text = first.security })
        #expect(byText.rows.contains { $0.id == first.id })
        let none = try await model(store, query(.closed) { $0.text = "no such security zzz" })
        #expect(none.rows.isEmpty)
        #expect(none.statistics.count == 0)
        #expect(none.totalCount == all.totalCount)
        #expect(query(.closed) { $0.text = "x" }.isFiltering)
        #expect(!query(.closed).isFiltering)

        // Open trades filter by the year they were opened.
        let open = try await model(store, query(.open))
        let openYear = try #require(open.years.last)
        let openedThen = try await model(store, query(.open) { $0.year = openYear })
        #expect(openedThen.rows.allSatisfy { $0.opened.year == openYear })
    }

    @Test func periodFiltersByClosingDate() async throws {
        let all = try await model(demoStore(), query(.closed))
        let year = try #require(all.years.last)
        let store = demoStore(period: .year(year))
        let inPeriod = try await model(store, query(.closed))
        #expect(!inPeriod.rows.isEmpty)
        #expect(inPeriod.rows.allSatisfy { $0.end.year == year })
        #expect(inPeriod.rows.count == all.rows.count { $0.end.year == year })
    }

    @Test func chartsAreConsistentWithTheTrades() async throws {
        let store = demoStore()
        let closed = try await model(store, query(.closed))
        let charts = closed.charts

        // Bars per closing year add up to the total realized gain and cover every year in between.
        #expect(charts.byPeriod.categories.count == charts.byPeriod.values.count)
        #expect(Int64(charts.byPeriod.values.reduce(0, +)) == closed.statistics.totalGain)
        let years = charts.byPeriod.categories.compactMap { Int($0.id) }
        #expect(years == Array((years.first ?? 0)...(years.last ?? 0)))

        // The running total starts at zero and ends at the total.
        #expect(charts.cumulativeValues.first == 0)
        #expect(charts.cumulativeValues.last == Double(closed.statistics.totalGain))
        #expect(charts.cumulativeDays == charts.cumulativeDays.sorted())
        #expect(Set(charts.cumulativeDays).count == charts.cumulativeDays.count)

        #expect(charts.returns.total == closed.rows.count { $0.returnFraction != nil })
        #expect(charts.byHolding.categories.count == TradeListModel.holdingBuckets.count)

        // Short periods are bucketed by month, one bar per month of the period.
        let ytd = try await model(demoStore(period: .year(try #require(closed.years.first))), query(.closed))
        #expect(ytd.charts.byPeriodTitle == "Realized Gain by Month")
        #expect(Int64(ytd.charts.byPeriod.values.reduce(0, +)) == ytd.statistics.totalGain)

        let open = try await model(store, query(.open))
        #expect(open.charts.cumulativeDays.isEmpty)
        #expect(Int64(open.charts.byPeriod.values.reduce(0, +)) == open.statistics.totalGain)
    }

    @Test func detailsListTheMatchedLots() async throws {
        let store = demoStore()
        let closed = try await model(store, query(.closed))
        let row = try #require(closed.rows.first)
        let transaction = try #require(row.closingTransactionID)
        let details = try await store.analyze("trades.detail", variant: TradeFocus.closing(transaction)) {
            TradeDetail.details($0, focus: .closing(transaction))
        }
        let detail = try #require(details.first)
        #expect(details.count == 1)
        #expect(detail.row.id == row.id)
        #expect(detail.lots.count == row.lotCount)
        #expect(detail.lots.reduce(0) { $0 + $1.entryValue } == row.entryValue)
        #expect(detail.lots.reduce(Shares.zero) { $0 + $1.shares } == row.shares)
        #expect(detail.gainAfterTaxes == row.gain - row.taxes)
        #expect(store.transaction(transaction) != nil)       // the deep link target exists

        let open = try await model(store, query(.open))
        let position = try #require(open.rows.first)
        let openDetails = try await store.analyze("trades.detail", variant: TradeFocus.open(securityID: position.securityID)) {
            TradeDetail.details($0, focus: .open(securityID: position.securityID))
        }
        #expect(openDetails.count == open.rows.count { $0.securityID == position.securityID })
        #expect(openDetails.allSatisfy { $0.row.isOpen })
    }

    @Test func taxYearsReconcileWithTheEngine() async throws {
        let store = demoStore()
        let interval = store.interval(for: .allTime)
        let model = try await store.analyze("trades.years", interval: interval) { TaxYearsModel($0) }
        let statistics = try await store.analyze("test.statistics", interval: interval) { $0.trades.statistics }
        let earnings = try await store.analyze("test.earnings", interval: interval) { $0.earnings.total }

        #expect(!model.isEmpty)
        #expect(model.years.map(\.id) == model.years.map(\.id).sorted(by: >))
        #expect(model.total.isTotal)
        #expect(model.total.net == statistics.totalGain)
        #expect(model.total.gains == statistics.grossProfit)
        #expect(model.total.losses == -statistics.grossLoss)
        #expect(model.total.trades == statistics.count)
        #expect(model.total.dividends == earnings.dividends)
        #expect(model.total.taxes == earnings.taxes)
        #expect(model.total.fees == earnings.fees)

        // Every column of the years adds up to the totals row.
        for column in [\TaxYearRow.gains, \.losses, \.net, \.dividends, \.interest, \.fees, \.taxes] as [KeyPath<TaxYearRow, Int64>] {
            #expect(model.years.reduce(0) { $0 + $1[keyPath: column] } == model.total[keyPath: column])
        }
        #expect(model.years.reduce(0) { $0 + $1.trades } == model.total.trades)
        #expect(model.years.allSatisfy { $0.net == $0.gains + $0.losses })
    }

    @Test func taxYearsCSVIsMachineReadable() async throws {
        let store = demoStore()
        let model = try await store.analyze("trades.years", interval: store.interval(for: .allTime)) { TaxYearsModel($0) }
        let lines = model.csv().components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == model.years.count + 2)                       // header + years + total
        #expect(lines[0] == "Year,Closed Trades,Realized Gains,Realized Losses,Net Realized,Dividends,Interest,Fees,Taxes Paid,Currency")
        let oldest = try #require(model.years.last)
        let first = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(first.count == 10)
        #expect(first[0] == String(oldest.id))
        #expect(Decimal(string: first[5], locale: Locale(identifier: "en_US_POSIX")) == Money(minor: oldest.dividends, currency: model.currency).decimalValue)
        #expect(first[9] == model.currency)
        #expect(lines.last?.hasPrefix("Total,") == true)
        #expect(model.tsv().split(separator: "\n").count == model.years.count + 2)
    }

    @Test func emptyPortfolioYieldsEmptyModels() async throws {
        var file = SampleData.demoPortfolio(today: today)
        file.transactions = []
        file.plans = []
        let store = PortfolioStore(file: file, today: today)
        let closed = try await model(store, query(.closed))
        #expect(closed.rows.isEmpty && closed.totalCount == 0 && closed.charts.byPeriod.isEmpty)
        let years = try await store.analyze("trades.years", interval: store.interval(for: .allTime)) { TaxYearsModel($0) }
        #expect(years.isEmpty)
        #expect(years.csv().components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 2)
    }

    @Test func sortKeysParse() {
        for key in ["security", "depot", "opened", "closed", "held", "shares", "entry", "exit", "fees", "taxes", "gain", "return", "annualized"] {
            #expect(TradesTable.comparator(key) != nil)
        }
        #expect(TradesTable.comparator("gain:asc")?.order == .forward)
        #expect(TradesTable.comparator("gain")?.order == .reverse)
        #expect(TradesTable.comparator("security")?.order == .forward)
        #expect(TradesTable.comparator("nonsense") == nil)
    }

    @Test func longTermThreshold() {
        #expect(LongTermThreshold.isLongTerm(holdingDays: 366, threshold: 365))
        #expect(!LongTermThreshold.isLongTerm(holdingDays: 365, threshold: 365))
        #expect(LongTermThreshold.presets.contains(LongTermThreshold.defaultDays))
    }
}
