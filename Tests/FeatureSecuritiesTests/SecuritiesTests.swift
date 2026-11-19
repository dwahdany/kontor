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

    /// Shares, "Held" and the values are today's, whatever reporting period the window shows; only
    /// the percentage follows the period.
    @Test func holdingsAreValuedTodayWhateverThePeriod() async throws {
        let store = demoStore()
        let now = try await listModel(store, SecurityListQuery(today: today))
        store.period = .year(2020)
        #expect(store.periodInterval.end == Day(year: 2020, month: 12, day: 31))
        let model = try await listModel(store, SecurityListQuery(today: today))
        #expect(model.valuationDay == today)
        #expect(model.counts == now.counts)
        #expect(model.totalValue == now.totalValue)
        let todays = store.ledger.snapshot(on: today)
        #expect(model.counts.held == todays.positions.count && model.totalValue == todays.securitiesValue.minor)
        // The retired security was held at the end of 2020 and sold in 2021: not held today.
        let retired = try #require(model.rows.first { $0.isRetired })
        #expect(store.ledger.snapshot(on: store.periodInterval.end).position(retired.id) != nil)
        #expect(!retired.isHeld && retired.value == nil)
        for row in model.rows {
            #expect(row.value == now.rows.first { $0.id == row.id }?.value)
            let prices = try #require(store.security(row.id)).prices
            if let start = prices.point(onOrBefore: store.periodInterval.start) ?? prices.first,
               let end = prices.point(onOrBefore: store.periodInterval.end), end.day > start.day {
                #expect(abs((row.periodChange ?? .nan) - (end.price.doubleValue / start.price.doubleValue - 1)) < 1e-12)
            }
        }
    }

    /// A holding without an exchange rate or quote has an unknown value — not 0 — in the list and
    /// in the detail; what depends on it shows as missing.
    @Test func holdingsThatCannotBeValuedAreNotZero() async throws {
        var file = SampleData.starterPortfolio(name: "Edge", baseCurrency: "EUR")
        let depot = try #require(file.depots.first).id
        let quotes = PriceSeries((0..<5).map { PricePoint(day: today.advanced(by: -$0), price: Price(3.3)) })
        let pound = Security(name: "Pound plc", currency: "GBP", prices: quotes)       // quote, but no GBP rate
        let silent = Security(name: "Silent AG", currency: "EUR")                         // no quote, delivered at no value
        let fine = Security(name: "Fine AG", currency: "EUR", prices: quotes)
        let nameless = Security(name: "", currency: "USD")
        file.securities += [pound, silent, fine, nameless]
        file.exchangeRates = []
        let day = today.advanced(by: -100)
        file.transactions += [
            Transaction(kind: .deliveryIn, date: day, depotID: depot, securityID: pound.id, shares: Shares(10), amount: Money(minor: 3_000, currency: "GBP")),
            Transaction(kind: .deliveryIn, date: day, depotID: depot, securityID: silent.id, shares: Shares(4), amount: Money(minor: 0, currency: "EUR")),
            Transaction(kind: .deliveryIn, date: day, depotID: depot, securityID: fine.id, shares: Shares(10), amount: Money(minor: 2_500, currency: "EUR")),
        ]
        let store = PortfolioStore(file: file, today: today)
        let snapshot = store.ledger.snapshot(on: today)
        // What the engine reports: unvalued, value 0.
        #expect(snapshot.position(pound.id)?.isValued == false && snapshot.position(pound.id)?.value.minor == 0)

        let model = try await listModel(store, SecurityListQuery(today: today))
        let poundRow = try #require(model.rows.first { $0.id == pound.id })
        let silentRow = try #require(model.rows.first { $0.id == silent.id })
        let fineRow = try #require(model.rows.first { $0.id == fine.id })
        #expect(poundRow.isHeld && poundRow.value == nil && poundRow.valuationProblem == "No GBP → EUR exchange rate")
        #expect(silentRow.isHeld && silentRow.value == nil && silentRow.valuationProblem == "No quote")
        #expect(fineRow.value == Money(minor: 3_300, currency: "EUR") && fineRow.valuationProblem == nil)
        #expect(model.totalValue == 3_300 && model.unvaluedCount == 2 && model.counts.held == 3)
        #expect(model.rows.first { $0.id == nameless.id }?.displayName == "Untitled Security")
        // Unknown values sort last, like those of securities that are not held.
        var query = SecurityListQuery(today: today)
        query.sort = .value
        query.ascending = false
        #expect(try await listModel(store, query).rows.first?.id == fine.id)

        func figures(_ id: UUID) async throws -> SecurityFigures {
            try await store.analyze("test.figures", scope: .security(id), variant: id) { SecurityFigures($0, securityID: id) }
        }
        // No exchange rate: neither the value nor the cost of the GBP delivery is known.
        let foreign = try await figures(pound.id)
        #expect(foreign.isHeld && !foreign.isValued && !foreign.isCostKnown)
        #expect(foreign.value == nil && foreign.costBasis == nil && foreign.purchasePrice == nil && foreign.unrealizedGain == nil)
        #expect(foreign.ttwror == nil && foreign.ttwrorAnnualized == nil && foreign.irr == nil)
        #expect(foreign.problemNote == "No GBP → EUR exchange rate")
        // No quote and delivered without a value: the market value is unknown, the cost (0 €) is known.
        let unquoted = try await figures(silent.id)
        #expect(!unquoted.isValued && unquoted.isCostKnown && unquoted.value == nil)
        #expect(unquoted.costBasis == Money(minor: 0, currency: "EUR"))
        #expect(unquoted.unrealizedGain == nil && unquoted.ttwror == nil && unquoted.irr == nil)
        #expect(unquoted.problemNote == "No quote")
        // Valued: nothing is hidden.
        let valued = try await figures(fine.id)
        #expect(valued.isValued && valued.isCostKnown && valued.arePeriodAmountsKnown && valued.problemNote == nil)
        #expect(valued.value == Money(minor: 3_300, currency: "EUR") && valued.unrealizedGain == Money(minor: 800, currency: "EUR"))
        #expect(valued.ttwror != nil)
        // No purchase-price line from a cost of 0.
        var chart = ChartQuery(securityID: pound.id)
        chart.showsPurchasePrice = true
        let line = try await chartModel(store, chart, ChartRange.max.interval(for: pound, today: today))
        #expect(!line.series.contains { $0.id == "purchase" })
    }

    @Test func filterOnADeletedWatchlistFallsBackToAll() {
        let file = SampleData.demoPortfolio(today: today)
        let list = file.watchlists[0]
        #expect(SecurityFilter.watchlist(list.id).validated(in: file.watchlists) == .watchlist(list.id))
        #expect(SecurityFilter.watchlist(list.id).validated(in: []) == .all)
        #expect(SecurityFilter.watchlist(UUID()).validated(in: file.watchlists) == .all)
        #expect(SecurityFilter.held.validated(in: []) == .held)
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
        #expect(figures.holdings.reduce(0) { $0 + ($1.value?.minor ?? 0) } == held.value.minor)
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
        // The change is measured from the last close on or before the start of the range.
        let baseline = try #require(security.prices.point(onOrBefore: interval.start))
        let expected = quotes.last!.price.doubleValue / baseline.price.doubleValue - 1
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

    /// A range that starts on a day without a quote (30 May 2026 is a Saturday) is measured from
    /// the last close before it — the same figure as the list's period change and the comparison.
    @Test func chartChangeStartsAtTheLastCloseBeforeTheRange() async throws {
        let store = demoStore()
        let security = try #require(store.file.securities.first { $0.currency == "USD" && !$0.isRetired })
        let interval = ChartRange.oneMonth.interval(for: security, today: today)
        #expect(interval.start == Day(year: 2026, month: 5, day: 30) && interval.start.isWeekend)
        #expect(security.prices.point(onOrBefore: interval.start)?.day != interval.start)
        let before = try #require(security.prices.point(onOrBefore: interval.start))
        let latest = try #require(security.prices.point(onOrBefore: today))
        let expected = latest.price.doubleValue / before.price.doubleValue - 1

        var query = ChartQuery(securityID: security.id)
        let plain = try await chartModel(store, query, interval)
        #expect(abs((plain.change ?? .nan) - expected) < 1e-12)
        // The line starts at the left edge with that close.
        let line = try #require(plain.series.first)
        #expect(line.days.first == interval.start.rawValue)
        #expect(abs((line.values.first ?? .nan) - before.price.doubleValue) < 1e-9)
        #expect(plain.quoteCount == security.prices.filter { $0.day >= interval.start && $0.day <= today }.count)

        store.period = .lastMonths(1)
        #expect(store.periodInterval == interval)
        let row = try #require(try await listModel(store, SecurityListQuery(today: today)).rows.first { $0.id == security.id })
        #expect(abs((row.periodChange ?? .nan) - expected) < 1e-12)

        query.compareID = store.file.settings.benchmarkSecurityIDs.first
        let compared = try await chartModel(store, query, interval)
        #expect(compared.isComparison && abs((compared.change ?? .nan) - expected) < 1e-9)
    }

    /// Quotes that ended long ago (retired, or stale) are what the chart shows: its periods end on
    /// the last quote instead of an empty stretch up to today.
    @Test func chartOfEndedQuotesIsAnchoredOnTheLastQuote() async throws {
        let store = demoStore()
        let retired = try #require(store.file.securities.first { $0.isRetired })
        let last = try #require(retired.prices.lastDay)
        #expect(last < today.advanced(by: -365))
        for range in ChartRange.allCases {
            let interval = range.interval(for: retired, today: today)
            #expect(interval.end == last && interval.start < interval.end)
            let model = try await chartModel(store, ChartQuery(securityID: retired.id), interval)
            #expect(!model.isEmpty)
        }
        // An active security with current quotes keeps today; one whose quotes went stale does not.
        var active = store.file.securities[0]
        #expect(ChartRange.anchor(for: active, today: today) == today)
        active.prices = PriceSeries(active.prices.filter { $0.day <= today.advanced(by: -3) })
        #expect(ChartRange.anchor(for: active, today: today) == today)
        active.prices = PriceSeries(active.prices.filter { $0.day <= today.advanced(by: -40) })
        #expect(ChartRange.anchor(for: active, today: today) == active.prices.lastDay)
        #expect(ChartRange.anchor(for: Security(name: "Empty", currency: "EUR"), today: today) == today)
    }

    /// The purchase-price line of a foreign security is what was paid in its currency — it does
    /// not move with the exchange rate.
    @Test func purchasePriceLineIsInTheSecuritysCurrency() async throws {
        let store = demoStore()
        let security = try #require(store.file.securities.first { $0.name.hasPrefix("Quillon") })
        #expect(security.currency == "USD" && store.file.settings.baseCurrency == "EUR" && store.file.settings.costMethod == .fifo)
        // Independent FIFO over the bookings, in USD (gross value in the security's currency plus fees).
        var lots = [(shares: Double, cost: Double)]()
        let ledger = store.ledger
        for t in ledger.transactions(forSecurity: security.id) where !t.shares.isZero {
            if t.kind == .buy || t.kind == .deliveryIn {
                // Booked in USD: what was paid, fees included.
                #expect(t.amount.currency == "USD" && t.taxes == 0)
                lots.append((t.shares.doubleValue, t.amount.doubleValue))
            } else if t.kind == .sell || t.kind == .deliveryOut {
                var left = t.shares.doubleValue
                while left > 1e-9, let first = lots.first {
                    let take = min(left, first.shares)
                    lots[0] = (first.shares - take, first.cost * (1 - take / first.shares))
                    if lots[0].shares < 1e-9 { lots.removeFirst() }
                    left -= take
                }
            }
        }
        let expected = lots.reduce(0) { $0 + $1.cost } / lots.reduce(0) { $0 + $1.shares }
        #expect(expected > 100)

        var query = ChartQuery(securityID: security.id)
        query.showsPurchasePrice = true
        let interval = ChartRange.oneYear.interval(for: security, today: today)
        let model = try await chartModel(store, query, interval)
        let level = try #require(model.series.first { $0.id == "purchase" }?.values.first)
        // The engine keeps the cost in EUR at the purchase day's rate; converted back at that rate
        // it is the USD amount again, up to the rounding of one cent per lot.
        #expect(abs(level - expected) < 0.01)

        // No purchase or sale in the last 200 days: the line is the same on an earlier day, whatever the
        // exchange rate did in between (it used to be the EUR average at the rate of the last day).
        #expect(!ledger.transactions(forSecurity: security.id).contains { $0.date > today.advanced(by: -200) && $0.kind.sharesSign != 0 })
        let earlier = DayInterval(start: today.advanced(by: -500), end: today.advanced(by: -150))
        let rateNow = try #require(ledger.converter.rate(from: "EUR", to: "USD", on: today))
        let rateThen = try #require(ledger.converter.rate(from: "EUR", to: "USD", on: earlier.end))
        #expect(rateNow != rateThen)
        let then = try await chartModel(store, query, earlier)
        let levelThen = try #require(then.series.first { $0.id == "purchase" }?.values.first)
        #expect(abs(levelThen - level) < 1e-9)

        // The Position card names the same figure next to the EUR one.
        let figures = try await store.analyze("test.figures", scope: .security(security.id), variant: security.id) {
            SecurityFigures($0, securityID: security.id)
        }
        #expect(abs((figures.purchasePriceInSecurityCurrency?.doubleValue ?? .nan) - level) < 1e-6)

        // Moving-average cost method: pooled per depot, still in USD and close to what was paid.
        store.updateSettings("Cost Method") { $0.costMethod = .average }
        let pooled = try await chartModel(store, query, interval)
        let pooledLevel = try #require(pooled.series.first { $0.id == "purchase" }?.values.first)
        var poolShares = 0.0, poolCost = 0.0
        for t in store.ledger.transactions(forSecurity: security.id) where !t.shares.isZero {
            if t.kind == .buy {
                poolShares += t.shares.doubleValue
                poolCost += t.amount.doubleValue
            } else if t.kind == .sell {
                poolCost *= 1 - t.shares.doubleValue / poolShares
                poolShares -= t.shares.doubleValue
            }
        }
        #expect(abs(pooledLevel - poolCost / poolShares) < 1e-6)
    }

    @Test func annualizedReturnOnlyWhenHeldThroughout() async throws {
        func tx(_ kind: Transaction.Kind, _ day: Int, _ shares: Double) -> Transaction {
            Transaction(kind: kind, date: Day(rawValue: Int32(day)), shares: Shares(shares), amount: Money(minor: 100, currency: "EUR"))
        }
        let interval = DayInterval(start: Day(rawValue: 20_000), end: Day(rawValue: 20_400))
        // Bought before the period (or on its first day) and still held.
        #expect(SecurityFigures.isHeldThroughout([tx(.buy, 19_000, 5)], interval: interval))
        #expect(SecurityFigures.isHeldThroughout([tx(.buy, 20_001, 5), tx(.dividend, 20_100, 0), tx(.sell, 20_200, 2)], interval: interval))
        // A transfer between depots does not interrupt the holding.
        #expect(SecurityFigures.isHeldThroughout([tx(.buy, 19_000, 5), tx(.securityTransfer, 20_100, 5)], interval: interval))
        // Bought later, sold in between, or sold and bought back.
        #expect(!SecurityFigures.isHeldThroughout([tx(.buy, 20_050, 5)], interval: interval))
        #expect(!SecurityFigures.isHeldThroughout([tx(.buy, 19_000, 5), tx(.sell, 20_200, 5)], interval: interval))
        #expect(!SecurityFigures.isHeldThroughout([tx(.buy, 19_000, 5), tx(.sell, 20_200, 5), tx(.buy, 20_300, 5)], interval: interval))
        #expect(!SecurityFigures.isHeldThroughout([tx(.buy, 19_000, 5), tx(.sell, 19_500, 5)], interval: interval))
        #expect(!SecurityFigures.isHeldThroughout([], interval: interval))
        // Later bookings do not matter.
        #expect(SecurityFigures.isHeldThroughout([tx(.buy, 19_000, 5), tx(.sell, 20_401, 5)], interval: interval))

        // The retired demo security was sold in 2021: over "all time" the engine annualizes its
        // loss over nine years; the feature does not show that as a yearly rate.
        let store = demoStore()
        store.period = .allTime
        let retired = try #require(store.file.securities.first { $0.isRetired }).id
        let figures = try await store.analyze("test.figures", scope: .security(retired), variant: retired) { SecurityFigures($0, securityID: retired) }
        let engine = try await store.analyze("test.engine", scope: .security(retired), variant: retired) { $0.security(retired) }
        #expect(engine?.ttwrorAnnualized != nil && figures.ttwror != nil && figures.ttwrorAnnualized == nil)
        // Held during the whole last year: the engine's figure is shown.
        store.period = .lastYears(1)
        let held = try #require(store.file.securities.first { security in
            let all = store.ledger.transactions(forSecurity: security.id)
            return !all.isEmpty && SecurityFigures.isHeldThroughout(all, interval: store.periodInterval)
        }).id
        let shown = try await store.analyze("test.figures", scope: .security(held), variant: held) { SecurityFigures($0, securityID: held) }
        #expect(shown.ttwrorAnnualized != nil)
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

    /// A booking that records its value in the security's currency shows the price there (so it
    /// can be compared with the quotes); the booking-currency price is kept for the tooltip.
    @Test func transactionPricesAreInTheSecuritysCurrency() async throws {
        let store = demoStore()
        let security = try #require(store.file.securities.first { $0.currency == "GBP" })
        let rows = try await store.compute("test.transactions.gbp") { SecurityTransactionRow.rows($0, securityID: security.id) }
        let buy = try #require(store.transactions(forSecurity: security.id).first { $0.kind == .buy && $0.securityGross != nil })
        #expect(buy.amount.currency == "EUR" && buy.securityGross?.currency == "GBP")
        let row = try #require(rows.first { $0.id == buy.id })
        #expect(row.priceCurrency == "GBP")
        #expect(row.price == Price(minor: try #require(buy.securityGross).minor, per: buy.shares))
        #expect(row.bookedPrice == buy.grossPrice)
        // Near the quote of that day, which the EUR price is not.
        let quote = try #require(security.prices.point(onOrBefore: buy.date)).price.doubleValue
        #expect(abs((row.price?.doubleValue ?? 0) / quote - 1) < 0.05)
        // Without a value in the security's currency the booking's own currency is used.
        let dollar = try #require(store.file.securities.first { $0.name.hasPrefix("Quillon") }).id
        let plain = try await store.compute("test.transactions.usd") { SecurityTransactionRow.rows($0, securityID: dollar) }
        #expect(!plain.isEmpty && !plain.contains { $0.priceCurrency != $0.amount.currency || $0.bookedPrice != nil })
    }

    @Test func splitCanAdjustQuotesAndShareCountsSeparately() async throws {
        let store = demoStore()
        let security = store.file.securities[4]
        let day = today.advanced(by: -400)
        let split = try #require(StockSplit(securityID: security.id, day: day, newShares: 2, oldShares: 1))
        let before = store.file
        let earlier = before.transactions.filter { $0.securityID == security.id && $0.date < day && !$0.shares.isZero }
        #expect(!earlier.isEmpty)

        // Share counts only (quotes from a feed are already split-adjusted).
        let sharesOnly = try #require(before.applying(split, adjusting: SplitAdjustments(quotes: false, shares: true)))
        #expect(sharesOnly.securities[4].prices == security.prices)
        for t in earlier { #expect(sharesOnly.transactions.first { $0.id == t.id }?.shares.raw == t.shares.raw * 2) }
        #expect(sharesOnly.securities[4].events.contains { $0.kind == .split && $0.detail == "2:1" })

        // Quotes only.
        let quotesOnly = try #require(before.applying(split, adjusting: SplitAdjustments(quotes: true, shares: false)))
        #expect(quotesOnly.transactions == before.transactions)
        let old = try #require(security.prices.point(onOrBefore: day.advanced(by: -1)))
        #expect(quotesOnly.securities[4].prices.point(onOrBefore: day.advanced(by: -1))?.price.raw == old.price.raw / 2)
        #expect(quotesOnly.securities[4].prices.point(onOrBefore: today)?.price == security.prices.point(onOrBefore: today)?.price)

        // Both: the engine's own result. Neither: only the event.
        let both = try #require(before.applying(split, adjusting: SplitAdjustments()))
        #expect(both.transactions == sharesOnly.transactions && both.securities[4].prices == quotesOnly.securities[4].prices)
        let neither = try #require(before.applying(split, adjusting: SplitAdjustments(quotes: false, shares: false)))
        #expect(neither.transactions == before.transactions && neither.securities[4].prices == security.prices)
        #expect(neither.securities[4].events.count == security.events.count + 1)

        // The preview says the same.
        let query = SplitQuery(securityID: security.id, day: day, newShares: 2, oldShares: 1, adjusting: SplitAdjustments(quotes: false, shares: true))
        let preview = try await store.compute(query) { SplitPreview($0, query: query) }
        #expect(preview.isValid && preview.adjustedPrices == 0 && preview.priceAfter == nil)
        #expect(preview.adjustedTransactions == earlier.count)
        let quotesQuery = SplitQuery(securityID: security.id, day: day, newShares: 2, oldShares: 1, adjusting: SplitAdjustments(quotes: true, shares: false))
        let quotesPreview = try await store.compute(quotesQuery) { SplitPreview($0, query: quotesQuery) }
        #expect(quotesPreview.adjustedTransactions == 0 && quotesPreview.samples.isEmpty && quotesPreview.adjustedPrices > 0)
        // A ratio the engine rejects is reported as invalid, not left pending.
        let invalid = SplitQuery(securityID: security.id, day: day, newShares: 0, oldShares: 1)
        #expect(try await store.compute(invalid) { SplitPreview($0, query: invalid) }.isValid == false)
    }

    @Test func tableColumnsAndDeleteRangeDefaults() {
        // Columns leave in the order Note, Depot, Costs; Amount always stays.
        #expect(TransactionColumns(width: 800).hiddenHint == nil)
        #expect(TransactionColumns(width: 783).noteWidth == 40 && TransactionColumns(width: 1000).noteWidth == 260)
        let medium = TransactionColumns(width: 750)
        #expect(!medium.showsNote && medium.showsPlace && medium.showsCosts && !medium.isTight)
        #expect(medium.hiddenHint == "Note hidden — widen the window")
        let narrow = TransactionColumns(width: 450)
        #expect(!narrow.showsNote && !narrow.showsPlace && !narrow.showsCosts && narrow.isTight)
        #expect(narrow.hiddenHint == "Costs, Depot and Note hidden — widen the window")

        // The delete-range bar never starts with the whole history.
        let prices = PriceSeries((0..<50).map { PricePoint(day: Day(rawValue: Int32(20_000 + $0)), price: Price(10)) })
        let none = SecurityPricesTab.defaultDeleteRange(selection: [], prices: prices, today: today)
        #expect(none == Day(rawValue: 20_000)...Day(rawValue: 20_000))
        let picked = SecurityPricesTab.defaultDeleteRange(selection: [20_010, 20_005, 20_007], prices: prices, today: today)
        #expect(picked == Day(rawValue: 20_005)...Day(rawValue: 20_010))
        #expect(SecurityPricesTab.defaultDeleteRange(selection: [], prices: PriceSeries(), today: today) == today...today)
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
