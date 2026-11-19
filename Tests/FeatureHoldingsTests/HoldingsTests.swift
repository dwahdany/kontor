import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureHoldings

// Tests of the Holdings feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Holdings"):
//
//     KONTOR_FEATURES=Holdings swift test --scratch-path .build-holdings --filter FeatureHoldingsTests
@Suite @MainActor struct HoldingsFeatureTests {
    let today = Day(year: 2026, month: 6, day: 30)

    private func makeStore() -> PortfolioStore {
        PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
    }

    private func base(
        _ store: PortfolioStore, grouping: HoldingsGrouping = .none, scope: Scope? = nil, interval: DayInterval? = nil
    ) async throws -> HoldingsBase {
        var taxonomy: Taxonomy?
        if case .taxonomy(let id) = grouping { taxonomy = store.file.taxonomies.first { $0.id == id } }
        let query = HoldingsQuery(grouping: grouping, taxonomy: taxonomy)
        return try await store.analyze("holdings.base", scope: scope, interval: interval, variant: query) { analysis in
            HoldingsBase(analysis, query: query)
        }
    }

    @Test func moduleRegistersItsScreen() {
        #expect(HoldingsFeature.module.screen == .holdings)
    }

    @Test func statementMatchesTheEngineSnapshot() async throws {
        let store = makeStore()
        let model = try await base(store)
        let snapshot = store.ledger.snapshot(on: today)
        #expect(model.day == today)
        #expect(model.totalValue == snapshot.totalValue.minor)
        #expect(model.positionCount == snapshot.positions.count)
        #expect(model.groups.count == 1)
        let rows = model.groups[0].rows
        #expect(rows.reduce(0) { $0 + $1.value } == snapshot.totalValue.minor)
        let weights = rows.compactMap(\.weight).reduce(0, +)
        #expect(abs(weights - 1) < 1e-9)
        // Every position row carries the engine's figures unchanged.
        let report = store.ledger.performance(in: store.periodInterval)
        for position in snapshot.positions {
            let row = try #require(rows.first { $0.securityID == position.securityID })
            #expect(row.costBasis == position.costBasis.minor)
            #expect(row.gain == position.unrealizedGain.minor)
            #expect(row.shares == position.shares)
            #expect(row.ttwror == report.security(position.securityID)?.ttwror)
            #expect(row.dividends == report.security(position.securityID)?.dividends)
            #expect(row.spark.count == 91)
        }
        #expect(model.ttwror == report.ttwror)
    }

    @Test func everyGroupingAddsUpToTheTotal() async throws {
        let store = makeStore()
        var groupings: [HoldingsGrouping] = [.depot, .currency]
        groupings += store.file.taxonomies.map { .taxonomy($0.id) }
        for grouping in groupings {
            let model = try await base(store, grouping: grouping)
            let sum = model.groups.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.value } }
            #expect(sum == model.totalValue, "grouping \(grouping.key)")
            #expect(model.groups.count > 1, "grouping \(grouping.key)")
            let cost = model.groups.reduce(0) { $0 + $1.rows.reduce(0) { $0 + ($1.costBasis ?? 0) } }
            // Classification splits round each part; the sum stays within a cent per row.
            #expect(abs(cost - model.costBasis) <= 100, "grouping \(grouping.key)")
            let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
            #expect(display.total?.value == model.totalValue)
            #expect(display.total?.ttwror == model.ttwror)
            #expect(display.groups.allSatisfy { $0.header?.kind == .group })
            #expect(Set(display.lines.map(\.id)).count == display.lines.count, "row ids are unique (\(grouping.key))")
            // Whole-portfolio scope: every group carries its own period return.
            #expect(display.groups.allSatisfy { $0.header?.ttwror != nil })
        }
    }

    @Test func depotGroupingSplitsPositionsExactly() async throws {
        let store = makeStore()
        let model = try await base(store, grouping: .depot)
        let snapshot = store.ledger.snapshot(on: today)
        let split = try #require(snapshot.positions.first { $0.holdings.count > 1 })
        let parts = model.groups.flatMap(\.rows).filter { $0.securityID == split.securityID }
        #expect(parts.count == split.holdings.count)
        #expect(parts.reduce(0) { $0 + $1.value } == split.value.minor)
        #expect(parts.reduce(0) { $0 + ($1.costBasis ?? 0) } == split.costBasis.minor)
        #expect(parts.reduce(Shares.zero) { $0 + ($1.shares ?? .zero) } == split.shares)
        // Period figures of a part come from the engine with the depot as scope.
        for part in parts {
            let depot = try #require(part.depotID)
            let record = store.ledger.securityPerformance(in: store.periodInterval, scope: .depot(depot)).first { $0.securityID == split.securityID }
            #expect(part.ttwror == record?.ttwror)
            #expect(part.dividends == record?.dividends)
        }
    }

    @Test func filterCashAndClosedOptions() async throws {
        let store = makeStore()
        store.period = .allTime
        let model = try await base(store)
        #expect(!model.closed.isEmpty)

        let all = HoldingsDisplay(model, options: HoldingsDisplayOptions())
        #expect(all.entityCount == model.positionCount + model.cashCount)

        var options = HoldingsDisplayOptions()
        options.filter = "meridian"
        let filtered = HoldingsDisplay(model, options: options)
        #expect(filtered.entityCount > 0 && filtered.entityCount < all.entityCount)
        #expect(filtered.lines.filter(\.isEntity).allSatisfy { $0.name.localizedCaseInsensitiveContains("meridian") })
        #expect(filtered.total?.ttwror == nil)
        #expect(filtered.total?.value == filtered.lines.filter(\.isEntity).reduce(0) { $0 + $1.value })

        options = HoldingsDisplayOptions()
        options.showsCash = false
        let withoutCash = HoldingsDisplay(model, options: options)
        #expect(withoutCash.entityCount == model.positionCount)
        #expect(withoutCash.total?.value == model.securitiesValue)

        options = HoldingsDisplayOptions()
        options.includesClosed = true
        let withClosed = HoldingsDisplay(model, options: options)
        #expect(withClosed.entityCount == all.entityCount + model.closed.count)
        #expect(withClosed.total?.value == model.totalValue)

        options = HoldingsDisplayOptions()
        options.sortOrder = [KeyPathComparator(\HoldingRow.name, order: .forward)]
        let sorted = HoldingsDisplay(model, options: options).lines.filter(\.isEntity).map(\.name)
        #expect(sorted == sorted.sorted())
    }

    @Test func chartsFollowTheTable() async throws {
        let store = makeStore()
        let model = try await base(store)
        let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
        #expect(display.treemap.count == display.lines.filter { $0.isEntity && $0.value > 0 }.count)
        #expect(display.treemap.reduce(0) { $0 + $1.value } == Double(model.totalValue))
        let concentration = display.concentration
        #expect(abs(concentration.segments.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(concentration.segments.reduce(0) { $0 + $1.value } == model.totalValue)
        let largest = try #require(concentration.largest)
        let topFive = try #require(concentration.topFive)
        let topTen = try #require(concentration.topTen)
        #expect(largest <= topFive && topFive <= topTen && topTen <= 1)
    }

    @Test func pastStatementDayEndsThePeriodOnThatDay() async throws {
        let store = makeStore()
        let state = HoldingsViewState.of(store)
        #expect(state === HoldingsViewState.of(store))
        #expect(state.interval(in: store) == store.periodInterval)
        let past = Day(year: 2025, month: 12, day: 31)
        state.setDay(past, in: store)
        let interval = state.interval(in: store)
        #expect(interval.end == past)
        #expect(interval.start < past)
        let model = try await base(store, interval: interval)
        #expect(model.day == past)
        #expect(model.totalValue == store.ledger.snapshot(on: past).totalValue.minor)
        state.setDay(Day(year: 2030, month: 1, day: 1), in: store)
        #expect(state.day == nil)
        #expect(state.day(in: store) == today)
    }

    @Test func scopedStatementUsesTheWindowScope() async throws {
        let store = makeStore()
        let depot = try #require(store.file.depots.last)
        let model = try await base(store, grouping: .depot, scope: .depot(depot.id))
        #expect(model.totalValue == store.ledger.snapshot(on: today, scope: .depot(depot.id)).totalValue.minor)
        #expect(model.groups.count == 1)
    }

    @Test func groupingKeysRoundTrip() {
        let taxonomies = makeStore().file.taxonomies
        let first = taxonomies[0]
        for grouping in [HoldingsGrouping.none, .depot, .currency, .taxonomy(first.id)] {
            #expect(HoldingsGrouping(key: grouping.key, taxonomies: taxonomies) == grouping)
        }
        #expect(HoldingsGrouping(key: "taxonomy", taxonomies: taxonomies) == .taxonomy(first.id))
        #expect(HoldingsGrouping(key: "regions", taxonomies: taxonomies) == .taxonomy(taxonomies[1].id))
        #expect(HoldingsGrouping(key: "taxonomy:\(UUID().uuidString)", taxonomies: taxonomies) == nil)
        #expect(HoldingsGrouping(key: "bogus", taxonomies: taxonomies) == nil)
    }

    @Test func dayJumps() {
        #expect(HoldingsDayJump.today.day(today: today) == today)
        #expect(HoldingsDayJump.lastMonth.day(today: today) == Day(year: 2026, month: 5, day: 31))
        #expect(HoldingsDayJump.lastQuarter.day(today: today) == Day(year: 2026, month: 3, day: 31))
        #expect(HoldingsDayJump.lastYear.day(today: today) == Day(year: 2025, month: 12, day: 31))
        #expect(HoldingsDayJump.lastQuarter.day(today: Day(year: 2026, month: 2, day: 10)) == Day(year: 2025, month: 12, day: 31))
    }

    @Test func exportWritesOneLinePerRow() async throws {
        let store = makeStore()
        let model = try await base(store, grouping: .currency)
        let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
        let csv = HoldingsExport.csv(display.lines, reportingCurrency: model.currency)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == display.lines.count + 1)
        #expect(lines[0].hasPrefix("Type,Name,Details,Currency,Shares,Price"))
        #expect(lines.last?.hasPrefix("Total,Total,") == true)
        // Numbers use "." and no grouping, whatever the user's locale.
        let total = try #require(lines.last?.components(separatedBy: ","))
        let header = HoldingsExport.header(reportingCurrency: model.currency)
        #expect(total.count == header.count)
        #expect(total[9] == "\(model.totalValue / 100).\(String(format: "%02d", model.totalValue % 100))")
        let tsv = HoldingsExport.tsv(display.lines, reportingCurrency: model.currency)
        #expect(tsv.split(separator: "\n").count == display.lines.count + 1)
    }

    @Test func csvFieldsAreQuotedAndNeutralized() {
        #expect(HoldingsExport.field("ACME, Inc.", isText: true) == "\"ACME, Inc.\"")
        #expect(HoldingsExport.field("say \"hi\"", isText: true) == "\"say \"\"hi\"\"\"")
        #expect(HoldingsExport.field("=SUM(A1)", isText: true) == "'=SUM(A1)")
        #expect(HoldingsExport.field("-12.50", isText: false) == "-12.50")
        #expect(HoldingsExport.field("plain", isText: true) == "plain")
    }
}
