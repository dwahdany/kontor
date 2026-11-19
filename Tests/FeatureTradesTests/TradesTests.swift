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
        expectEqual(closed.figures, report.statistics)
        #expect(closed.rows.reduce(0) { $0 + $1.gain } == report.statistics.totalGain)
        #expect(closed.figures.longExit - closed.figures.longEntry == report.statistics.totalGain)   // the demo has no short trades
        #expect(closed.figures.shortCount == 0 && closed.figures.unvalued == 0)
        #expect(closed.notices.isEmpty)
        #expect(closed.rows.allSatisfy { !$0.isOpen && $0.closingTransactionID != nil })
        #expect(Set(closed.rows.map(\.id)).count == closed.rows.count)

        #expect(open.rows.count == report.open.count)
        #expect(open.rows.allSatisfy { $0.isOpen && $0.closingTransactionID == nil && $0.end == today })
        expectEqual(open.figures, TradeStatistics(report.open))
        #expect(open.currency == report.currency)
        // Whole trades carry the engine's own figures.
        for row in open.rows {
            let trade = try #require(report.open.first { $0.securityID == row.securityID && $0.depotID == row.id.depotID })
            #expect(row.entryValue == trade.entryValue && row.exitValue == trade.exitValue && row.gain == trade.gain)
            #expect(row.annualized == trade.irr && row.shares == trade.shares && row.oldestDays == trade.holdingDays)
            #expect(!row.isPartial && row.weight == ScopeWeights.full && row.countedShares == row.shares)
        }
    }

    /// The feature's figures agree with the engine's statistics for whole, valued trades (the
    /// holding period is deliberately different: share-weighted instead of the oldest lot).
    private func expectEqual(_ figures: TradeFigures, _ statistics: TradeStatistics, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(figures.count == statistics.count, sourceLocation: sourceLocation)
        #expect(figures.winners == statistics.winners && figures.losers == statistics.losers, sourceLocation: sourceLocation)
        #expect(figures.winRate == statistics.winRate, sourceLocation: sourceLocation)
        #expect(figures.totalGain == statistics.totalGain, sourceLocation: sourceLocation)
        #expect(figures.grossProfit == statistics.grossProfit && figures.grossLoss == statistics.grossLoss, sourceLocation: sourceLocation)
        #expect(figures.averageGain == statistics.averageGain && figures.averageLoss == statistics.averageLoss, sourceLocation: sourceLocation)
        #expect(figures.averageReturn == statistics.averageReturn, sourceLocation: sourceLocation)
        #expect(figures.profitFactor == statistics.profitFactor, sourceLocation: sourceLocation)
        #expect(figures.totalFees == statistics.totalFees && figures.totalTaxes == statistics.totalTaxes, sourceLocation: sourceLocation)
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
        #expect(winners.rows.count == all.figures.winners)
        #expect(losers.rows.count == all.figures.losers)
        #expect(winners.figures.totalGain == all.figures.grossProfit)
        #expect(losers.figures.totalGain == -all.figures.grossLoss)
        #expect(winners.totalCount == all.totalCount)        // totalCount ignores the filters
    }

    @Test func holdingFilterSplitsEveryTradeByLot() async throws {
        let store = demoStore()
        for kind in [TradeKind.closed, .open] {
            for threshold in [365, 1826] {
                let all = try await model(store, query(kind) { $0.thresholdDays = threshold })
                let long = try await model(store, query(kind) { $0.holding = .longTerm; $0.thresholdDays = threshold })
                let short = try await model(store, query(kind) { $0.holding = .shortTerm; $0.thresholdDays = threshold })
                // Every lot is on exactly one side, so the two filters partition shares, cost, value and gain.
                #expect(long.rows.allSatisfy { $0.term == .longTerm })
                #expect(short.rows.allSatisfy { $0.term == .shortTerm })
                #expect(long.rows.reduce(0) { $0 + $1.lotCount } + short.rows.reduce(0) { $0 + $1.lotCount } == all.rows.reduce(0) { $0 + $1.lotCount })
                #expect(long.figures.totalGain + short.figures.totalGain == all.figures.totalGain)
                #expect(long.figures.longEntry + short.figures.longEntry == all.figures.longEntry)
                #expect(long.figures.longExit + short.figures.longExit == all.figures.longExit)
                #expect(long.figures.totalFees + short.figures.totalFees == all.figures.totalFees)
                // The tile's long-term gain is what the Long-Term filter lists.
                #expect(all.figures.longTermGain == long.figures.totalGain)
                #expect(all.figures.shortTermGain == short.figures.totalGain)
                #expect(long.figures.longTermGain == long.figures.totalGain && short.figures.longTermGain == 0)
            }
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
        #expect(none.figures.count == 0)
        #expect(none.totalCount == all.totalCount)
        #expect(query(.closed) { $0.text = "x" }.isFiltering)
        #expect(!query(.closed).isFiltering)

        // Open trades filter by the year their lots were bought.
        let open = try await model(store, query(.open))
        let openYear = try #require(open.years.last)
        let openedThen = try await model(store, query(.open) { $0.year = openYear })
        #expect(!openedThen.rows.isEmpty)
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
        #expect(Int64(charts.byPeriod.values.reduce(0, +)) == closed.figures.totalGain)
        let years = charts.byPeriod.categories.compactMap { Int($0.id) }
        #expect(years == Array((years.first ?? 0)...(years.last ?? 0)))

        // The running total starts at zero and ends at the total.
        #expect(charts.cumulativeValues.first == 0)
        #expect(charts.cumulativeValues.last == Double(closed.figures.totalGain))
        #expect(charts.cumulativeDays == charts.cumulativeDays.sorted())
        #expect(Set(charts.cumulativeDays).count == charts.cumulativeDays.count)

        #expect(charts.returns.total == closed.rows.count { $0.returnFraction != nil })
        #expect(charts.byHolding.categories.count == TradeListModel.holdingBuckets.count)

        // Short periods are bucketed by month, one bar per month of the period.
        let ytd = try await model(demoStore(period: .year(try #require(closed.years.first))), query(.closed))
        #expect(ytd.charts.byPeriodTitle == "Realized Gain by Month")
        #expect(Int64(ytd.charts.byPeriod.values.reduce(0, +)) == ytd.figures.totalGain)

        let open = try await model(store, query(.open))
        #expect(open.charts.cumulativeDays.isEmpty)
        #expect(Int64(open.charts.byPeriod.values.reduce(0, +)) == open.figures.totalGain)
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
        let openDetails = try await store.analyze("trades.detail", variant: TradeFocus.open(securityID: position.securityID, depotID: nil)) {
            TradeDetail.details($0, focus: .open(securityID: position.securityID, depotID: nil))
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

    // MARK: - Regression tests for the review findings

    /// A small portfolio with the awkward cases: a JPY security without an exchange rate, a fund
    /// without quotes, an open short position, and a savings plan sold in one go.
    private struct Edge {
        var file: PortfolioFile
        var yen: UUID, unquoted: UUID, shorted: UUID, plan: UUID, normal: UUID
        var depot: UUID
        var planSale: UUID
    }

    private func edge() -> Edge {
        let account = Account(name: "Cash", currency: "EUR")
        let depot = Depot(name: "Depot", referenceAccountID: account.id)
        func quotes(_ points: [(Day, Double)]) -> PriceSeries { PriceSeries(points.map { PricePoint(day: $0.0, price: Price($0.1)) }) }
        let yen = Security(name: "Nippon KK", currency: "JPY", prices: quotes([(Day(year: 2024, month: 1, day: 10), 15_000), (today, 18_000)]))
        let unquoted = Security(name: "Unquoted Private Fund", currency: "EUR")
        let shorted = Security(name: "Shorted AG", currency: "EUR", prices: quotes([(Day(year: 2026, month: 3, day: 2), 40), (today, 30)]))
        let plan = Security(name: "Plan ETF", currency: "EUR", prices: quotes([(Day(year: 2024, month: 1, day: 5), 100), (today, 120)]))
        let normal = Security(name: "Normal AG", currency: "EUR", prices: quotes([(Day(year: 2024, month: 2, day: 1), 50), (today, 60)]))
        func eur(_ value: Double) -> Money { Money(value, "EUR") }
        var transactions = [
            Transaction(kind: .deposit, date: Day(year: 2024, month: 1, day: 2), accountID: account.id, amount: eur(100_000)),
            Transaction(kind: .buy, date: Day(year: 2024, month: 1, day: 10), accountID: account.id, depotID: depot.id, securityID: yen.id, shares: Shares(10), amount: eur(1_000)),
            Transaction(kind: .buy, date: Day(year: 2024, month: 2, day: 10), accountID: account.id, depotID: depot.id, securityID: unquoted.id, shares: Shares(10), amount: eur(1_000)),
            Transaction(kind: .buy, date: Day(year: 2024, month: 2, day: 1), accountID: account.id, depotID: depot.id, securityID: normal.id, shares: Shares(20), amount: eur(1_000)),
            Transaction(kind: .sell, date: Day(year: 2026, month: 3, day: 2), accountID: account.id, depotID: depot.id, securityID: shorted.id, shares: Shares(3), amount: eur(120)),
        ]
        for month in 0..<24 {
            transactions.append(Transaction(
                kind: .buy, date: Day(year: 2024 + month / 12, month: month % 12 + 1, day: 5), accountID: account.id, depotID: depot.id,
                securityID: plan.id, shares: Shares(1), amount: eur(100)))
        }
        let sale = Transaction(
            kind: .sell, date: Day(year: 2026, month: 1, day: 10), accountID: account.id, depotID: depot.id, securityID: plan.id,
            shares: Shares(24), amount: eur(2_776), fees: 1_000, taxes: 2_400)
        transactions.append(sale)
        let file = PortfolioFile(
            name: "Edge", securities: [yen, unquoted, shorted, plan, normal], accounts: [account], depots: [depot], transactions: transactions)
        return Edge(file: file, yen: yen.id, unquoted: unquoted.id, shorted: shorted.id, plan: plan.id, normal: normal.id, depot: depot.id, planSale: sale.id)
    }

    private func edgeStore() -> (Edge, PortfolioStore) {
        let edge = edge()
        let store = PortfolioStore(file: edge.file, today: today)
        store.period = .allTime
        return (edge, store)
    }

    // Finding: the inspector showed another depot's trade than the selected open row.
    @Test func inspectorFollowsTheSelectedDepot() async throws {
        let store = demoStore()
        let open = try await model(store, query(.open))
        let bySecurity = Dictionary(grouping: open.rows, by: \.securityID)
        let pair = try #require(bySecurity.values.first { $0.count > 1 }, "the demo holds one security in two depots")
        for row in pair {
            let focus = try #require(TradeFocus.resolve(.security(row.securityID), selectedRow: row.id))
            #expect(focus == .open(securityID: row.securityID, depotID: row.id.depotID))
            let details = try await store.analyze("trades.detail", variant: focus) { TradeDetail.details($0, focus: focus) }
            #expect(details.count == 1)
            let detail = try #require(details.first)
            #expect(detail.row.id == row.id)
            #expect(detail.row.gain == row.gain && detail.row.shares == row.shares && detail.lots.count == row.lotCount)
        }
        #expect(pair[0].gain != pair[1].gain)       // otherwise the test could not tell them apart

        // A deep link names only the security: every depot is listed. A stale row of another
        // security, or a closed row, must not narrow it.
        let securityID = pair[0].securityID
        #expect(TradeFocus.resolve(.security(securityID), selectedRow: nil) == .open(securityID: securityID, depotID: nil))
        let other = try #require(open.rows.first { $0.securityID != securityID })
        #expect(TradeFocus.resolve(.security(securityID), selectedRow: other.id) == .open(securityID: securityID, depotID: nil))
        let closedRow = try #require(try await model(store, query(.closed)).rows.first)
        #expect(TradeFocus.resolve(.security(closedRow.securityID), selectedRow: closedRow.id) == .open(securityID: closedRow.securityID, depotID: nil))
        #expect(TradeFocus.resolve(.transaction(try #require(closedRow.closingTransactionID)), selectedRow: closedRow.id) == .closing(try #require(closedRow.closingTransactionID)))
        #expect(TradeFocus.resolve(nil, selectedRow: pair[0].id) == nil)
    }

    // Finding: a position without an exchange rate was shown as a real −100 % loss.
    @Test func positionsWithoutValuationAreNotCountedAsLosses() async throws {
        let (edge, store) = edgeStore()
        // What the engine reports: value 0 and a diagnostic.
        let report = try await store.analyze("test.report") { $0.trades }
        let engineYen = try #require(report.open.first { $0.securityID == edge.yen })
        #expect(engineYen.exitValue == 0 && engineYen.gain == -100_000)
        #expect(report.diagnostics.contains(.missingExchangeRate(from: "JPY", to: "EUR")))

        let open = try await model(store, query(.open))
        let yen = try #require(open.rows.first { $0.securityID == edge.yen })
        #expect(yen.valuation == .missingRate("JPY"))
        #expect(!yen.isValued && yen.gain == 0 && yen.returnFraction == nil && yen.annualized == nil)
        #expect(yen.entryValue == 100_000)                       // the cost is known and stays

        let unquoted = try #require(open.rows.first { $0.securityID == edge.unquoted })
        #expect(unquoted.valuation == .derivedPrice && unquoted.isValued)
        let normal = try #require(open.rows.first { $0.securityID == edge.normal })
        #expect(normal.valuation == .market && normal.gain == 20_000)

        // Statistics, footer and charts leave the unvalued position out.
        #expect(open.figures.count == open.rows.count)
        #expect(open.figures.unvalued == 1)
        #expect(open.figures.totalGain == open.rows.filter(\.isValued).reduce(0) { $0 + $1.gain })
        #expect(open.figures.totalGain > -100_000)
        #expect(open.figures.grossLoss < 100_000)
        #expect(open.figures.losers == open.rows.count { $0.isValued && $0.gain < 0 })
        #expect(open.charts.returns.total == open.rows.count { $0.returnFraction != nil })
        #expect(open.charts.returns.bins.allSatisfy { $0.lower > -1 })
        #expect(Int64(open.charts.byPeriod.values.reduce(0, +)) == open.figures.totalGain)

        // The user is told, with a link to the security.
        let notice = try #require(open.notices.first { $0.kind == .notValued })
        #expect(notice.securities.map(\.id) == [edge.yen])
        #expect(notice.message.contains("JPY"))
        #expect(open.notices.first { $0.kind == .derivedPrices }?.securities.map(\.id) == [edge.unquoted])

        // Neither a winner nor a loser.
        let losers = try await model(store, query(.open) { $0.outcome = .losers })
        let winners = try await model(store, query(.open) { $0.outcome = .winners })
        #expect(!losers.rows.contains { $0.securityID == edge.yen } && !winners.rows.contains { $0.securityID == edge.yen })

        // Exports leave the unknown figures empty instead of writing 0 or −100 %.
        let line = try #require(TradeExport.tsv([yen], kind: .open, currency: "EUR").split(separator: "\n").last)
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(fields[9] == "" && fields[12] == "" && fields[14] == "")

        // The closed tab does not warn about JPY: no closed trade was booked in it.
        #expect(try await model(store, query(.closed)).notices.isEmpty)

        let details = try await store.analyze("trades.detail", variant: "yen") {
            TradeDetail.details($0, focus: .open(securityID: edge.yen, depotID: edge.depot))
        }
        #expect(details.first?.row.isValued == false)
    }

    // Finding: long-term / short-term was decided by the oldest lot.
    @Test func longTermIsDecidedPerLot() async throws {
        let (edge, store) = edgeStore()
        let all = try await model(store, query(.closed) { $0.thresholdDays = 730 })
        let row = try #require(all.rows.first { $0.securityID == edge.plan })
        // 24 monthly lots sold on 2026-01-10: only the first is older than 730 days.
        #expect(row.lotCount == 24 && row.oldestDays == 736)
        #expect(row.term == .mixed && row.longTermLots == 1)
        #expect(abs(row.longTermShare - 1.0 / 24) < 1e-12)
        // Gross 2,810 − 10 fees = 2,800 (taxes are not part of the gain) for 24 × 100 cost → gain 400, one lot's part ≈ 16.67.
        #expect(row.gain == 40_000)
        #expect(row.longTermGain == 1_667)
        #expect(all.figures.longTermGain == 1_667 && all.figures.shortTermGain == 40_000 - 1_667)
        // "Held" is the share-weighted average of the lots, not the age of the oldest one.
        let lotDays = (0..<24).map { Day(year: 2024 + $0 / 12, month: $0 % 12 + 1, day: 5).distance(to: Day(year: 2026, month: 1, day: 10)) }
        #expect(row.holdingDays == Int((Double(lotDays.reduce(0, +)) / 24).rounded()))
        #expect(row.holdingDays < 400)

        let long = try await model(store, query(.closed) { $0.thresholdDays = 730; $0.holding = .longTerm })
        let longRow = try #require(long.rows.first { $0.securityID == edge.plan })
        #expect(long.rows.count == 1)
        #expect(longRow.isPartial && longRow.lotCount == 1 && longRow.totalLots == 24)
        #expect(longRow.shares == Shares(1) && longRow.entryValue == 10_000 && longRow.gain == 1_667)
        #expect(longRow.id == row.id)

        let short = try await model(store, query(.closed) { $0.thresholdDays = 730; $0.holding = .shortTerm })
        let shortRow = try #require(short.rows.first { $0.securityID == edge.plan })
        #expect(shortRow.lotCount == 23 && shortRow.gain == 40_000 - 1_667)
        #expect(longRow.fees + shortRow.fees == row.fees && longRow.taxes + shortRow.taxes == row.taxes)
        #expect(longRow.annualized != nil && shortRow.annualized != nil)

        // With a 1-year threshold 13 of the 24 lots are long-term.
        let year = try await model(store, query(.closed) { $0.thresholdDays = 365 })
        #expect(year.rows.first { $0.securityID == edge.plan }?.longTermLots == 13)
    }

    @Test func lotSlicesAddUpToTheTrade() async throws {
        let store = demoStore()
        let report = try await store.analyze("test.report") { $0.trades }
        for trade in report.closed + report.open {
            let slices = trade.slices
            #expect(slices.count == trade.lots.count)
            #expect(slices.reduce(0) { $0 + $1.exitValue } == trade.exitValue)
            #expect(slices.reduce(0) { $0 + $1.entryValue } == trade.entryValue)
            #expect(slices.reduce(0) { $0 + $1.fees } == trade.fees)
            #expect(slices.reduce(0) { $0 + $1.taxes } == trade.taxes)
            #expect(slices.reduce(0) { $0 + $1.gain(isShort: trade.isShort) } == trade.gain)
            #expect(slices.allSatisfy { $0.exitValue >= 0 })
        }
        #expect(Proportion.scale(100, 1, 3) == 33)
        #expect(Proportion.scale(200, 1, 3) == 67)
        #expect(Proportion.scale(-200, 1, 3) == -67)
        #expect(Proportion.scale(5, 1, 2) == 3)                                          // half away from zero
        #expect(Proportion.scale(1_000_000_000_000, 123_456_789_012_345, 246_913_578_024_690) == 500_000_000_000)   // no Int64 overflow
        #expect(Proportion.scale(7, 0, 10) == 0 && Proportion.scale(7, 3, 0) == 0)
    }

    // Finding: classification scopes showed full share counts next to weighted money, and a wrong lot price.
    @Test func weightedScopesCountSharesLikeMoney() async throws {
        let store = demoStore()
        let full = try await model(store, query(.open))
        let position = try #require(full.rows.max { $0.lotCount < $1.lotCount })
        let scope = Scope.weighted(securities: [position.securityID: 6_800], accounts: [:])
        let q = query(.open)
        let weighted = try await store.analyze("trades.list", scope: scope, variant: q) { TradeListModel($0, query: q) }
        #expect(weighted.hasWeightedRows && !full.hasWeightedRows)
        let row = try #require(weighted.rows.first { $0.id == position.id })
        #expect(row.weight == 6_800)
        #expect(row.shares == position.shares)                                           // what a sale has to name
        #expect(row.countedShares == Shares(raw: Proportion.scale(position.shares.raw, 68, 100)))
        #expect(abs(row.entryValue - Proportion.scale(position.entryValue, 68, 100)) <= Int64(position.lotCount))

        // The price per share of a lot is the same in both scopes (it used to be 68 % of it).
        let focus = TradeFocus.open(securityID: position.securityID, depotID: position.id.depotID)
        let plain = try #require(try await store.analyze("trades.detail", variant: focus) { TradeDetail.details($0, focus: focus) }.first)
        let scaled = try #require(try await store.analyze("trades.detail", scope: scope, variant: focus) { TradeDetail.details($0, focus: focus) }.first)
        #expect(plain.lots.count == scaled.lots.count && !plain.lots.isEmpty)
        for (a, b) in zip(plain.lots, scaled.lots) {
            let unweighted = try #require(a.entryPrice), counted = try #require(b.entryPrice)
            #expect(abs(unweighted.doubleValue - counted.doubleValue) <= max(0.02, unweighted.doubleValue * 0.001))
            #expect(b.shares == Shares(raw: Proportion.scale(a.shares.raw, 68, 100)))
        }
        #expect(ScopeWeights(.portfolio)[position.securityID] == 10_000)
        #expect(ScopeWeights(scope)[UUID()] == 0)
    }

    // Finding: "Sell…" prefilled the holding of the period end instead of today's.
    @Test func closingAPositionStartsFromTodaysHolding() async throws {
        let demo = demoStore(period: .year(2024))
        let open = try await model(demo, query(.open))
        // A position that was partly sold after the end of 2024.
        let stale = try #require(open.rows.first { row in
            TradeActions.holding(demo.ledger, securityID: row.securityID, depotID: row.id.depotID, on: today) < row.shares
        }, "the demo sells part of a position after 2024")
        let held = TradeActions.holding(demo.ledger, securityID: stale.securityID, depotID: stale.id.depotID, on: today)
        #expect(held < stale.shares && held.raw > 0)
        #expect(TradeActions.holding(demo.ledger, securityID: stale.securityID, depotID: stale.id.depotID, on: stale.end) == stale.shares)
        let close = TradeActions.close(demo.ledger, securityID: stale.securityID, depotID: stale.id.depotID, today: today)
        #expect(close == .sell(held))
        let prefill = try #require(TradeActions.closePrefill(close, securityID: stale.securityID, depotID: stale.id.depotID, today: today))
        #expect(prefill.kind == .sell && prefill.shares == held && prefill.date == today && prefill.depotID == stale.id.depotID)

        // Today's holdings agree with the engine's open trades as of today.
        let current = try await model(demoStore(), query(.open))
        for row in current.rows {
            #expect(TradeActions.holding(demo.ledger, securityID: row.securityID, depotID: row.id.depotID, on: today) == row.shares)
        }

        // A short position is covered with a purchase, and a position that is gone offers nothing.
        let (edge, store) = edgeStore()
        let cover = TradeActions.close(store.ledger, securityID: edge.shorted, depotID: edge.depot, today: today)
        #expect(cover == .cover(Shares(3)) && cover.isCover && cover.title == "Cover…")
        #expect(TradeActions.closePrefill(cover, securityID: edge.shorted, depotID: edge.depot, today: today)?.kind == .buy)
        let gone = TradeActions.close(store.ledger, securityID: edge.plan, depotID: edge.depot, today: today)
        #expect(gone == .nothingHeld)
        #expect(TradeActions.closePrefill(gone, securityID: edge.plan, depotID: edge.depot, today: today) == nil)
        #expect(TradeActions.close(store.ledger, securityID: edge.plan, depotID: edge.depot, today: Day(year: 2025, month: 6, day: 30)) == .sell(Shares(18)))
    }

    // Finding: filters were half-restored and the year filter leaked between the tabs.
    @Test func viewStateRoundTrips() {
        let security = UUID(), depot = UUID()
        let state = TradesViewState(
            tab: .open, filterText: "etf", showsCharts: false, leadChart: .holding, outcome: .losers, holding: .longTerm,
            closedYear: 2023, openYear: 2019, securityID: security, depotID: depot, closedSort: "gain:asc", openSort: "held:desc")
        #expect(TradesViewState(storage: state.storage) == state)
        #expect(TradesViewState(storage: "") == TradesViewState())
        #expect(TradesViewState(storage: "{not json") == TradesViewState())
        #expect(TradesViewState().closedYear == nil && TradesViewState().openYear == nil)

        // Every sort order survives the trip through its text form.
        for key in ["security", "depot", "opened", "closed", "held", "shares", "entry", "exit", "fees", "taxes", "gain", "return", "annualized"] {
            for order in ["asc", "desc"] {
                let comparator = try! #require(TradesTable.comparator("\(key):\(order)"))
                #expect(TradesTable.sortKey(comparator) == "\(key):\(order)")
            }
        }
    }

    // Finding: the Open tab attributed a savings plan's whole gain to the year of its first purchase.
    @Test func openTradesAreSpreadOverThePurchaseYearsOfTheirLots() async throws {
        let store = demoStore()
        let open = try await model(store, query(.open))
        let plan = try #require(open.rows.max { $0.lotCount < $1.lotCount })
        #expect(plan.lotCount > 50)
        #expect(open.charts.byPeriodTitle == "Unrealized Gain by Purchase Year")
        let chartYears = open.charts.byPeriod.categories.compactMap { Int($0.id) }
        #expect(chartYears.last == today.year)                   // the plan still buys this year
        #expect(open.years.first == today.year)
        #expect(Int64(open.charts.byPeriod.values.reduce(0, +)) == open.figures.totalGain)

        // The year filter keeps the lots bought in that year; all years together are the whole list.
        var gain: Int64 = 0, lots = 0, cost: Int64 = 0
        for year in open.years {
            let inYear = try await model(store, query(.open) { $0.year = year })
            #expect(!inYear.rows.isEmpty)
            #expect(inYear.rows.allSatisfy { $0.opened.year == year })
            gain += inYear.figures.totalGain
            cost += inYear.figures.longEntry
            lots += inYear.rows.reduce(0) { $0 + $1.lotCount }
            let bar = try #require(chartYears.firstIndex(of: year))
            #expect(Int64(open.charts.byPeriod.values[bar]) == inYear.figures.totalGain)
        }
        #expect(gain == open.figures.totalGain && cost == open.figures.longEntry)
        #expect(lots == open.rows.reduce(0) { $0 + $1.lotCount })
        let firstYear = try await model(store, query(.open) { $0.year = plan.opened.year })
        let part = try #require(firstYear.rows.first { $0.id == plan.id })
        #expect(part.isPartial && part.gain < plan.gain)
    }

    // Finding: the last column was clipped and Gain / Return scrolled out of view.
    @Test func columnsFitTheWindow() {
        // Content widths: default window (1224), default window with inspector (944), 1000-pt window (784).
        let full = TradeColumns()
        #expect(TradeColumns.fitting(width: 1224, kind: .closed, hasSeveralDepots: true) == full)
        #expect(TradeColumns.fitting(width: 1224, kind: .open, hasSeveralDepots: true) == full)
        #expect(full.widths(.closed).count == 13 && full.widths(.open).count == 11)
        for kind in [TradeKind.closed, .open] {
            for severalDepots in [true, false] {
                var previous = 0
                for width in stride(from: CGFloat(780), through: 1600, by: 4) {
                    let columns = TradeColumns.fitting(width: width, kind: kind, hasSeveralDepots: severalDepots)
                    #expect(columns.requiredWidth(kind) <= width, "\(kind) at \(width)")
                    #expect(columns.widths(kind).count >= previous)         // more room never hides a column
                    previous = columns.widths(kind).count
                }
            }
        }
        // Fees and taxes go first, the depot last — unless there is only one depot.
        let withInspector = TradeColumns.fitting(width: 944, kind: .open, hasSeveralDepots: true)
        #expect(!withInspector.showsCosts && withInspector.showsDepot && withInspector.showsShares && withInspector.showsOpened)
        let narrow = TradeColumns.fitting(width: 784, kind: .closed, hasSeveralDepots: true)
        #expect(!narrow.showsCosts && !narrow.showsShares && !narrow.showsOpened && !narrow.showsDepot)
        let oneDepot = TradeColumns.fitting(width: 1100, kind: .closed, hasSeveralDepots: false)
        #expect(!oneDepot.showsDepot && oneDepot.showsCosts)
    }

    // Finding: selection and inspector went stale when the rows changed but their number did not.
    @Test func rowsTokenFollowsTheRowsNotTheirNumber() async throws {
        let store = demoStore()
        let all = try await model(store, query(.closed))
        let byYear = Dictionary(grouping: all.rows, by: \.end.year).filter { $0.value.count == 1 }
        let years = byYear.keys.sorted()
        try #require(years.count >= 2, "the demo has two years with one closed trade each")
        let first = try await model(store, query(.closed) { $0.year = years[0] })
        let second = try await model(store, query(.closed) { $0.year = years[1] })
        #expect(first.rows.count == second.rows.count)
        #expect(first.rowsToken != second.rowsToken)
        let again = try await model(store, query(.closed) { $0.year = years[0]; $0.thresholdDays = 400 })
        #expect(again.rowsToken == first.rowsToken)
    }

    // Finding: short positions were summed with long positions under Cost / Value.
    @Test func footerTotalsLeaveShortTradesOut() async throws {
        let (edge, store) = edgeStore()
        let open = try await model(store, query(.open))
        let short = try #require(open.rows.first { $0.securityID == edge.shorted })
        #expect(short.isShort && short.entryValue == 12_000 && short.exitValue == 9_000 && short.gain == 3_000)
        #expect(open.figures.shortCount == 1)
        let long = open.rows.filter { !$0.isShort && $0.isValued }
        #expect(open.figures.longEntry == long.reduce(0) { $0 + $1.entryValue })
        #expect(open.figures.longExit == long.reduce(0) { $0 + $1.exitValue })
        #expect(open.figures.totalGain == long.reduce(0) { $0 + $1.gain } + short.gain)     // the gain still counts
    }

    // Omissions: file export of the trade list, links to the opening transactions, YTD marker.
    @Test func tradesExportAsCSVWithOneLinePerLot() async throws {
        let (edge, store) = edgeStore()
        let q = query(.closed) { $0.thresholdDays = 730 }
        let (csv, exported) = try await store.analyze("trades.csv", variant: q) { analysis in
            let model = TradeListModel(analysis, query: q, collectsLots: true)
            return (TradeExport.csv(model, ledger: analysis.ledger, thresholdDays: q.thresholdDays), model)
        }
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(lines[0] == TradeExport.csvHeader)
        #expect(lines.count == 1 + exported.rows.reduce(0) { $0 + $1.lotCount })
        #expect(lines.allSatisfy { $0.count == TradeExport.csvHeader.count })
        let plan = lines.filter { $0[0] == "Plan ETF" }
        #expect(plan.count == 24)
        func column(_ name: String) -> Int { TradeExport.csvHeader.firstIndex(of: name)! }
        func sum(_ name: String) -> Decimal { plan.reduce(0) { $0 + (Decimal(string: $1[column(name)]) ?? 0) } }
        #expect(sum("Entry Value") == 2_400 && sum("Exit Value") == 2_800 && sum("Gain") == 400 && sum("Fees") == 10 && sum("Taxes") == 24)
        #expect(sum("Shares") == 24)
        #expect(plan[0][column("Acquired")] == "2024-01-05" && plan[0][column("Closed or Valued")] == "2026-01-10")
        #expect(plan[0][column("Term")] == "Long-term" && plan[1][column("Term")] == "Short-term")
        #expect(plan[0][column("Status")] == "Closed" && plan[0][column("Currency")] == "EUR")
        #expect(CSV.field("a,b") == "\"a,b\"" && CSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        _ = edge
    }

    @Test func lotsLinkToTheTransactionThatOpenedThem() async throws {
        let (edge, store) = edgeStore()
        let details = try await store.analyze("trades.detail", variant: "plan") { TradeDetail.details($0, focus: .closing(edge.planSale)) }
        let detail = try #require(details.first)
        #expect(detail.lots.count == 24)
        for lot in detail.lots {
            let transaction = try #require(store.transaction(lot.transactionID))
            #expect(transaction.kind == .buy && transaction.date == lot.opened && transaction.securityID == edge.plan)
        }
        #expect(Set(detail.lots.compactMap(\.transactionID)).count == 24)

        // A short trade is opened by a sale.
        let short = try await store.analyze("trades.detail", variant: "short") {
            TradeDetail.details($0, focus: .open(securityID: edge.shorted, depotID: nil))
        }
        #expect(store.transaction(short.first?.lots.first?.transactionID)?.kind == .sell)
    }

    @Test func runningTaxYearIsMarkedAsYearToDate() async throws {
        let store = demoStore()
        let model = try await store.analyze("trades.years", interval: store.interval(for: .allTime)) { TaxYearsModel($0) }
        let running = try #require(model.years.first)
        #expect(running.id == today.year && running.isPartial)
        #expect(running.displayLabel == "\(today.year) YTD" && running.label == String(today.year))     // exports stay numeric
        #expect(model.years.dropFirst().allSatisfy { !$0.isPartial && $0.displayLabel == $0.label })
        #expect(!model.total.isPartial && model.total.displayLabel == "Total")
        #expect(model.unconvertedCurrencies.isEmpty)

        // Bookings in a currency without an exchange rate are named instead of silently counting as 0.
        var (edge, _) = edgeStore()
        let yenAccount = Account(name: "Yen", currency: "JPY")
        edge.file.accounts.append(yenAccount)
        edge.file.transactions.append(Transaction(kind: .dividend, date: Day(year: 2025, month: 3, day: 3), accountID: yenAccount.id, securityID: edge.yen, amount: Money(5_000, "JPY")))
        let yenStore = PortfolioStore(file: edge.file, today: today)
        let years = try await yenStore.analyze("trades.years", interval: yenStore.interval(for: .allTime)) { TaxYearsModel($0) }
        #expect(years.unconvertedCurrencies == ["JPY"])
    }
}
