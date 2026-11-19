import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureSecurities

// Tests of the Securities feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Securities"):
//
//     KONTOR_FEATURES=Securities swift test --scratch-path .build-securities --filter FeatureSecuritiesTests

private let today = Day(year: 2026, month: 6, day: 30)

@MainActor private func demoStore() -> PortfolioStore {
    PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
}

@MainActor private func chartModel(_ store: PortfolioStore, _ query: ChartQuery, _ interval: DayInterval) async throws -> SecurityChartModel {
    try await store.analyze("test.chart", scope: .security(query.securityID), interval: interval, variant: query) {
        SecurityChartModel($0, query: query)
    }
}

@MainActor private func listModel(_ store: PortfolioStore, _ query: SecurityListQuery) async throws -> SecurityListModel {
    let watchlists = store.file.watchlists
    return try await store.analyze("test.list", scope: .portfolio, variant: query) { analysis in
        SecurityListModel(analysis, query: query, watchlists: watchlists, providerNames: ["manual": "Manual"], automaticProviders: [])
    }
}

@Suite @MainActor struct SecuritiesFeatureTests {
    @Test func moduleRegistersItsScreen() {
        #expect(SecuritiesFeature.module.screen == .securities)
    }

    @Test func paletteCommandsFollowTheFocusedSecurity() {
        let store = demoStore()
        let general = SecuritiesFeature.commands(store).map(\.id)
        #expect(general == ["securities.new", "securities.copy"])
        store.navigate(to: .security(store.file.securities[0].id))
        let focused = SecuritiesFeature.commands(store).map(\.id)
        #expect(focused.contains("securities.edit") && focused.contains("securities.split") && focused.contains("securities.benchmark"))
        // No quote updater in tests: nothing that needs the network is offered.
        #expect(!focused.contains("securities.update"))
    }
}

@Suite @MainActor struct SecurityListModelTests {
    @Test func rowsMatchTheEngineSnapshot() async throws {
        let store = demoStore()
        let model = try await listModel(store, SecurityListQuery(today: today))
        let snapshot = try await store.analyze("test.snapshot", scope: .portfolio) { $0.snapshot }
        #expect(model.rows.count == store.file.securities.count)
        #expect(model.counts.all == 16)
        #expect(model.counts.held == snapshot.positions.count)
        #expect(model.counts.held + model.counts.notHeld == model.counts.all)
        #expect(model.counts.retired == 1)
        #expect(model.totalValue == snapshot.securitiesValue.minor)
        for row in model.rows {
            #expect(row.value == snapshot.position(row.id)?.value)
            #expect(row.shares == (snapshot.position(row.id)?.shares ?? .zero))
        }
        // Default order: by name.
        #expect(model.rows.map(\.name) == model.rows.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func dayAndPeriodChangeComeFromTheQuotes() async throws {
        let store = demoStore()
        let model = try await listModel(store, SecurityListQuery(today: today))
        let interval = store.periodInterval
        for row in model.rows {
            let prices = try #require(store.security(row.id)).prices
            guard prices.count >= 2 else { continue }
            let last = prices[prices.count - 1].price.doubleValue, previous = prices[prices.count - 2].price.doubleValue
            #expect(abs((row.dayChange ?? .nan) - (last / previous - 1)) < 1e-12)
            if let start = prices.point(onOrBefore: interval.start) ?? prices.first, let end = prices.point(onOrBefore: interval.end), end.day > start.day {
                #expect(abs((row.periodChange ?? .nan) - (end.price.doubleValue / start.price.doubleValue - 1)) < 1e-12)
            }
            #expect(row.spark.count <= 62)
        }
    }

    @Test func periodChangeOfAllTimeStartsAtTheFirstQuote() async throws {
        let store = demoStore()
        store.period = .allTime
        let model = try await listModel(store, SecurityListQuery(today: today))
        let security = store.file.securities[0]
        let row = try #require(model.rows.first { $0.id == security.id })
        let expected = security.prices.last!.price.doubleValue / security.prices.first!.price.doubleValue - 1
        #expect(abs((row.periodChange ?? .nan) - expected) < 1e-12)
        // The same figure as the engine's price performance over the period (before the first
        // quote the engine carries the first quote, too).
        let engine = store.ledger.benchmark(securityID: security.id, in: store.periodInterval, basis: .securityCurrency)
        #expect(abs((engine?.total ?? .nan) - expected) < 1e-9)
    }

    @Test func filtersAndSorts() async throws {
        let store = demoStore()
        var query = SecurityListQuery(today: today)
        query.filter = .held
        query.sort = .value
        query.ascending = false
        let held = try await listModel(store, query)
        #expect(held.rows.count == held.counts.held)
        #expect(!held.rows.contains { !$0.isHeld })
        let values = held.rows.compactMap { $0.value?.minor }
        #expect(values == values.sorted(by: >))

        query.filter = .retired
        let retired = try await listModel(store, query)
        #expect(retired.rows.count == 1 && retired.rows[0].isRetired)

        query.filter = .notHeld
        let notHeld = try await listModel(store, query)
        #expect(notHeld.rows.count == notHeld.counts.notHeld)

        let list = try #require(store.file.watchlists.first)
        query.filter = .watchlist(list.id)
        let watched = try await listModel(store, query)
        #expect(Set(watched.rows.map(\.id)) == Set(list.securityIDs))
        #expect(watched.counts.watchlists[list.id] == list.securityIDs.count)

        query.filter = .all
        query.text = store.file.securities[4].isin.lowercased()
        let found = try await listModel(store, query)
        #expect(found.rows.map(\.id) == [store.file.securities[4].id])
        #expect(found.counts.all == 16)
    }

    @Test func missingValuesSortLast() async throws {
        let store = demoStore()
        var query = SecurityListQuery(today: today)
        query.sort = .value
        for ascending in [true, false] {
            query.ascending = ascending
            let rows = try await listModel(store, query).rows
            let firstMissing = try #require(rows.firstIndex { $0.value == nil })
            #expect(!rows[firstMissing...].contains { $0.value != nil })
        }
    }

    @Test func staleAndMissingQuotesAreFlagged() async throws {
        let store = demoStore()
        let id = store.file.securities[0].id, other = store.file.securities[2].id
        store.updateSecurity(id) { $0.prices.removeAll() }
        store.updateSecurity(other) { security in
            security.prices = PriceSeries(security.prices.filter { $0.day < today.advanced(by: -30) })
        }
        var query = SecurityListQuery(today: today)
        query.filter = .missingQuotes
        let model = try await listModel(store, query)
        #expect(Set(model.rows.map(\.id)) == [id, other])
        #expect(model.rows.first { $0.id == id }?.health == .missing)
        if case .stale(let days)? = model.rows.first(where: { $0.id == other })?.health { #expect(days > 30) } else { Issue.record("expected stale") }
        // The retired security has old quotes by design and is not flagged.
        #expect(model.counts.missingQuotes == 2)
    }

    @Test func filterLaunchValues() {
        let file = SampleData.demoPortfolio(today: today)
        #expect(SecurityFilter(launchValue: "held", file: file) == .held)
        #expect(SecurityFilter(launchValue: "notheld", file: file) == .notHeld)
        #expect(SecurityFilter(launchValue: "missing", file: file) == .missingQuotes)
        #expect(SecurityFilter(launchValue: "watchlist:1", file: file) == .watchlist(file.watchlists[0].id))
        #expect(SecurityFilter(launchValue: "watchlist:\(file.watchlists[1].name)", file: file) == .watchlist(file.watchlists[1].id))
        #expect(SecurityFilter(launchValue: "watchlist:99", file: file) == nil)
        #expect(SecurityFilter(launchValue: "nonsense", file: file) == nil)
    }
}

@Suite @MainActor struct SecurityDetailModelTests {
    @Test func figuresAreTheEnginesNumbers() async throws {
        let store = demoStore()
        let id = store.file.securities[0].id
        let figures = try await store.analyze("test.figures", scope: .security(id), variant: id) { SecurityFigures($0, securityID: id) }
        let (performance, position) = try await store.analyze("test.reference", scope: .portfolio, variant: id) { analysis in
            (analysis.security(id), analysis.snapshot.position(id))
        }
        let reference = try #require(performance)
        let held = try #require(position)
        #expect(figures.isHeld)
        #expect(figures.shares == held.shares)
        #expect(figures.value == held.value)
        #expect(figures.costBasis == held.costBasis)
        #expect(figures.unrealizedGain == held.unrealizedGain)
        #expect(figures.realizedGain == reference.realizedGain)
        #expect(figures.dividends == reference.dividends)
        #expect(figures.fees == reference.fees && figures.taxes == reference.taxes)
        #expect(abs((figures.ttwror ?? .nan) - reference.ttwror) < 1e-9)
        #expect(figures.irr == reference.irr)
        #expect(figures.holdings.reduce(0) { $0 + $1.value.minor } == held.value.minor)
        #expect(figures.transactionCount == store.transactions(forSecurity: id).count)
    }

    @Test func neverHeldSecurityHasNoPosition() async throws {
        let store = demoStore()
        let id = try #require(store.file.settings.benchmarkSecurityIDs.first)
        let figures = try await store.analyze("test.figures", scope: .security(id), variant: id) { SecurityFigures($0, securityID: id) }
        #expect(!figures.isHeld && figures.value == nil && figures.transactionCount == 0)
    }

    @Test func chartRangeNeverStartsBeforeTheFirstQuote() {
        var security = Security(name: "Young", currency: "EUR")
        security.prices = PriceSeries((0..<40).map { PricePoint(day: today.advanced(by: -$0), price: Price(100 + Double($0))) })
        let first = today.advanced(by: -39)
        for range in ChartRange.allCases {
            let interval = range.interval(for: security, today: today)
            #expect(interval.end == today)
            #expect(interval.start >= first.advanced(by: -1))
            #expect(interval.start < interval.end)
        }
        #expect(ChartRange.oneMonth.interval(for: security, today: today).start == today.addingMonths(-1))
        // Without quotes the interval is still well-formed.
        let empty = ChartRange.max.interval(for: Security(name: "Empty", currency: "EUR"), today: today)
        #expect(empty.start < empty.end)
    }

    @Test func priceChartSeriesMarkersAndIndicators() async throws {
        let store = demoStore()
        let security = store.file.securities[0]
        let interval = ChartRange.oneYear.interval(for: security, today: today)
        var query = ChartQuery(securityID: security.id)
        let plain = try await chartModel(store, query, interval)
        #expect(plain.series.map(\.id) == ["price"])
        #expect(!plain.isComparison && plain.currency == security.currency)
        let quotes = security.prices.filter { $0.day >= interval.start && $0.day <= interval.end }
        #expect(plain.quoteCount == quotes.count)
        #expect(plain.high?.price == quotes.map(\.price).max())
        #expect(plain.low?.price == quotes.map(\.price).min())
        let expected = quotes.last!.price.doubleValue / quotes.first!.price.doubleValue - 1
        #expect(abs((plain.change ?? .nan) - expected) < 1e-12)
        let bookings = store.transactions(forSecurity: security.id).filter { $0.date >= interval.start && $0.date <= interval.end }
        #expect(plain.markers.count == bookings.count && plain.markerCount == bookings.count && !plain.markersHidden)

        query.showsAverage50 = true
        query.showsAverage200 = true
        query.showsPurchasePrice = true
        let full = try await chartModel(store, query, interval)
        #expect(full.series.map(\.id) == ["price", "ma50", "ma200", "purchase"])

        query.compareID = store.file.settings.benchmarkSecurityIDs.first
        let compared = try await chartModel(store, query, interval)
        #expect(compared.isComparison)
        #expect(compared.series.map(\.id) == ["price", "compare"])
        #expect(abs((compared.change ?? .nan) - expected) < 1e-9)
        #expect(compared.comparisonName == store.security(query.compareID)?.name)

        let all = try await chartModel(store, query, ChartRange.max.interval(for: security, today: today))
        #expect(all.isComparison && all.comparisonProblem == nil)

        // A comparison without quotes is reported, not silently dropped.
        store.updateSecurity(query.compareID!) { $0.prices.removeAll() }
        let late = try await chartModel(store, query, interval)
        #expect(!late.isComparison && late.comparisonProblem != nil && late.series.first?.id == "price")
    }

    @Test func movingAverageUsesEarlierQuotes() throws {
        let prices = PriceSeries((0..<10).map { PricePoint(day: Day(rawValue: Int32(20_000 + $0)), price: Price(Double($0 + 1))) })
        let average = try #require(SecurityChartModel.movingAverage(prices, window: 3, range: 5..<10))
        #expect(average.days.first == Day(rawValue: 20_005))
        #expect(average.values.count == 5)
        // Quotes 4,5,6 → 5; … ; 8,9,10 → 9
        for (index, value) in average.values.enumerated() { #expect(abs(value - Double(index + 5)) < 1e-9) }
        // Not enough history at the start of the range: the average starts later.
        let late = try #require(SecurityChartModel.movingAverage(prices, window: 4, range: 0..<10))
        #expect(late.days.first == Day(rawValue: 20_003) && abs(late.values[0] - 2.5) < 1e-9)
        #expect(SecurityChartModel.movingAverage(prices, window: 11, range: 0..<10) == nil)
    }

    @Test func quoteRowsAreNewestFirstWithChanges() {
        var security = Security(name: "S", currency: "EUR")
        security.prices = PriceSeries([
            PricePoint(day: Day(rawValue: 20_000), price: Price(100)),
            PricePoint(day: Day(rawValue: 20_001), price: Price(110)),
            PricePoint(day: Day(rawValue: 20_004), price: Price(99)),
        ])
        let rows = QuoteRow.rows(of: security)
        #expect(rows.map(\.day.rawValue) == [20_004, 20_001, 20_000])
        #expect(abs((rows[0].change ?? .nan) - (-0.1)) < 1e-12)
        #expect(abs((rows[1].change ?? .nan) - 0.1) < 1e-12)
        #expect(rows[2].change == nil)
        #expect(QuoteRow.rows(of: nil).isEmpty)
    }

    @Test func transactionRowsCoverTheSecuritysBookings() async throws {
        let store = demoStore()
        let id = store.file.securities[6].id
        let rows = try await store.compute("test.transactions") { SecurityTransactionRow.rows($0, securityID: id) }
        #expect(rows.count == store.transactions(forSecurity: id).count)
        #expect(rows.map(\.date) == rows.map(\.date).sorted(by: >))
        #expect(rows.contains { $0.kind == .sell && $0.signedShares < 0 })
        #expect(rows.contains { $0.kind == .dividend && $0.signedShares == 0 })
    }

    @Test func splitPreviewMatchesWhatApplyingDoes() async throws {
        let store = demoStore()
        let security = store.file.securities[4]
        let day = today.advanced(by: -400)
        let query = SplitQuery(securityID: security.id, day: day, newShares: 4, oldShares: 1)
        let preview = try await store.compute(query) { SplitPreview($0, query: query) }
        #expect(preview.isValid && !preview.isRecorded && preview.ratio == "4:1")
        #expect(preview.adjustedPrices == security.prices.filter { $0.day < day }.count)
        let before = try #require(preview.priceBefore), after = try #require(preview.priceAfter)
        #expect(abs(after.doubleValue * 4 - before.doubleValue) < 1e-6)
        for sample in preview.samples { #expect(sample.after.raw == sample.before.raw * 4) }

        let split = try #require(StockSplit(securityID: security.id, day: day, newShares: 4, oldShares: 1))
        store.mutate("Apply Stock Split") { file in
            if let changed = file.applying(split) { file = changed }
        }
        let again = try await store.compute(query) { SplitPreview($0, query: query) }
        #expect(again.isRecorded)
        #expect(store.security(security.id)?.events.contains { $0.kind == .split && $0.detail == "4:1" } == true)
    }
}

@Suite @MainActor struct SecurityActionTests {
    @Test func duplicateCopiesMasterDataAndQuotesOnly() throws {
        let store = demoStore()
        let original = store.file.securities[0]
        let id = try #require(store.duplicateSecurity(original.id))
        let copy = try #require(store.security(id))
        #expect(copy.name == original.name + " Copy")
        #expect(copy.prices == original.prices && copy.isin == original.isin && copy.feed == original.feed)
        #expect(store.transactions(forSecurity: id).isEmpty)
        #expect(store.file.securities[1].id == id)
        #expect(store.file.securities.count == 17)
    }

    @Test func retireBenchmarkAndWatchlists() throws {
        let store = demoStore()
        let ids = Set(store.file.securities.prefix(2).map(\.id))
        store.setRetired(ids, true)
        #expect(!ids.contains { store.security($0)?.isRetired != true })
        store.setRetired(ids, false)
        #expect(!ids.contains { store.security($0)?.isRetired != false })

        let id = store.file.securities[0].id
        #expect(!store.isBenchmark(id))
        store.toggleBenchmark(id)
        #expect(store.isBenchmark(id))
        store.toggleBenchmark(id)
        #expect(!store.isBenchmark(id))

        let list = try #require(store.file.watchlists.first)
        let outsider = try #require(store.file.securities.first { !list.securityIDs.contains($0.id) }).id
        let revision = store.revision
        store.addSecurities([outsider, outsider, list.securityIDs[0]], toWatchlist: list.id)
        #expect(store.file.watchlists[0].securityIDs == list.securityIDs + [outsider])
        #expect(store.revision == revision + 1)
        store.addSecurities([outsider], toWatchlist: list.id)          // already there: no change, no undo step
        #expect(store.revision == revision + 1)
        store.removeSecurities([outsider], fromWatchlist: list.id)
        #expect(store.file.watchlists[0].securityIDs == list.securityIDs)
    }

    @Test func prefillsTheDepotOfTheLastBooking() throws {
        let store = demoStore()
        let id = store.file.securities[0].id
        let last = try #require(store.transactions(forSecurity: id).last { $0.depotID != nil })
        #expect(store.preferredDepot(forSecurity: id) == last.depotID)
        store.presentNewTransaction(.sell, securityID: id)
        guard case .newTransaction(let prefill)? = store.sheet else {
            Issue.record("expected a new-transaction request")
            return
        }
        #expect(prefill.kind == .sell && prefill.securityID == id && prefill.date == today && prefill.depotID == last.depotID)
    }

    @Test func copiesMasterDataAsTSV() {
        let store = demoStore()
        let ids = Set(store.file.securities.prefix(3).map(\.id))
        let lines = store.securitiesTSV(ids).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Name\tTicker\tISIN"))
        #expect(lines[1].contains(store.file.securities[0].isin))
    }

    @Test func offlineRegistryStillDescribesTheProviders() {
        let store = demoStore()
        #expect(!MarketAccess.isOnline(store))
        let ids = MarketAccess.registry(store).descriptors.map(\.id)
        #expect(ids.contains("yahoo") && ids.contains("coingecko") && ids.contains("manual"))
        #expect(MarketAccess.providerNames(store)["manual"] != nil)
        #expect(!MarketAccess.automaticProviders(store).contains("manual"))
    }

    @Test func feedProbeNeverTouchesTheNetworkOffline() async {
        let store = demoStore()
        let security = store.file.securities[0]
        let state = await FeedProbe.test(QuoteFeed(provider: "yahoo", symbol: "X"), security: security, store: store)
        #expect(state == .failure(MarketAccess.offlineHint))
        let suggestions = await FeedProbe.suggestions(for: security, store: store)
        #expect(suggestions == .failure(FeedError(message: MarketAccess.offlineHint)))
    }
}
