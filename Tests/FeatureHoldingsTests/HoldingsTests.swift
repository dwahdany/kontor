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

    /// The model exactly as the screen derives it: statement day and period from the view state.
    private func screenModel(_ store: PortfolioStore, grouping: HoldingsGrouping = .none) async throws -> HoldingsBase {
        let state = HoldingsViewState.of(store)
        state.grouping = grouping
        let query = state.query(in: store)
        return try await store.analyze("holdings.base", interval: state.interval(in: store), variant: query) { analysis in
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
            // Split positions are apportioned, so every grouping adds up to the cent.
            #expect(cost == model.costBasis, "grouping \(grouping.key)")
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

    // MARK: Statement day and period

    @Test func statementPeriodResolution() {
        let first = Day(year: 2018, month: 1, day: 2)
        func period(_ p: ReportingPeriod, _ day: Day) -> HoldingsStatementPeriod {
            HoldingsStatementPeriod(period: p, day: day, firstTransactionDay: first)
        }
        let year2024 = DayInterval(start: Day(year: 2023, month: 12, day: 31), end: Day(year: 2024, month: 12, day: 31))

        // A past calendar year, statement for today: the period keeps its dates.
        var p = period(.year(2024), today)
        #expect(p.coverage == .ended)
        #expect(p.interval == year2024)
        #expect(p.day == today)
        // The statement day inside the year: the year so far.
        p = period(.year(2024), Day(year: 2024, month: 6, day: 30))
        #expect(p.coverage == .full)
        #expect(p.interval == DayInterval(start: year2024.start, end: Day(year: 2024, month: 6, day: 30)))
        // After the year (the reviewer's 15-month case): still exactly 2024.
        p = period(.year(2024), Day(year: 2025, month: 3, day: 31))
        #expect(p.coverage == .ended)
        #expect(p.interval == year2024)
        // Before the year: no figures, never a synthetic one-day period.
        p = period(.year(2024), Day(year: 2023, month: 6, day: 30))
        #expect(p.coverage == .unavailable)
        #expect(!p.hasFigures)

        let custom = ReportingPeriod.custom(from: Day(year: 2024, month: 1, day: 1), to: Day(year: 2024, month: 6, day: 30))
        p = period(custom, today)
        #expect(p.coverage == .ended)
        #expect(p.interval == DayInterval(start: Day(year: 2024, month: 1, day: 1), end: Day(year: 2024, month: 6, day: 30)))
        p = period(custom, Day(year: 2024, month: 6, day: 30))
        #expect(p.coverage == .full)
        p = period(custom, Day(year: 2024, month: 3, day: 31))
        #expect(p.coverage == .clipped)
        #expect(p.interval == DayInterval(start: Day(year: 2024, month: 1, day: 1), end: Day(year: 2024, month: 3, day: 31)))
        #expect(p.shortTitle(of: custom) != custom.shortTitle)
        #expect(p.note(of: custom) != nil)
        p = period(custom, Day(year: 2023, month: 6, day: 30))
        #expect(p.coverage == .unavailable)
        p = period(custom, Day(year: 2024, month: 1, day: 1))
        #expect(p.coverage == .unavailable)

        // Rolling periods end on the statement day.
        let past = Day(year: 2025, month: 12, day: 31)
        p = period(.lastYears(1), past)
        #expect(p.coverage == .full)
        #expect(p.interval == DayInterval(start: Day(year: 2024, month: 12, day: 31), end: past))
        #expect(p.note(of: .lastYears(1)) == nil)
        p = period(.ytd, past)
        #expect(p.interval == DayInterval(start: Day(year: 2024, month: 12, day: 31), end: past))
        #expect(period(.lastDays(0), today).coverage == .unavailable)
    }

    @Test func aPastPeriodNeverReplacesTheStatementDay() async throws {
        for period in [ReportingPeriod.year(2024), .custom(from: Day(year: 2024, month: 1, day: 1), to: Day(year: 2024, month: 6, day: 30))] {
            let store = makeStore()
            store.period = period
            let model = try await screenModel(store)
            let snapshot = store.ledger.snapshot(on: today)
            #expect(model.day == today, "\(period.title)")
            #expect(model.totalValue == snapshot.totalValue.minor)
            let rows = model.groups[0].rows
            for position in snapshot.positions {
                #expect(rows.first { $0.securityID == position.securityID }?.shares == position.shares)
            }
            // The period figures are those of the period as selected.
            let interval = store.periodInterval
            #expect(model.interval == interval)
            let report = store.ledger.performance(in: interval)
            #expect(model.ttwror == report.ttwror)
            for position in snapshot.positions {
                let row = try #require(rows.first { $0.securityID == position.securityID })
                #expect(row.ttwror == report.security(position.securityID)?.ttwror)
                #expect(row.dividends == report.security(position.securityID)?.dividends)
            }
            // Grouped by taxonomy the statement is still today's.
            let grouped = try await screenModel(store, grouping: .taxonomy(store.file.taxonomies[0].id))
            #expect(grouped.groups.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.value } } == snapshot.totalValue.minor)
        }
    }

    @Test func aPeriodAfterTheStatementDayHasNoFigures() async throws {
        let store = makeStore()
        store.period = .custom(from: Day(year: 2024, month: 1, day: 1), to: Day(year: 2024, month: 6, day: 30))
        let state = HoldingsViewState.of(store)
        let day = Day(year: 2023, month: 6, day: 30)
        state.setDay(day, in: store)
        for grouping in [HoldingsGrouping.none, .depot, .currency] {
            let model = try await screenModel(store, grouping: grouping)
            #expect(model.day == day)
            #expect(model.totalValue == store.ledger.snapshot(on: day).totalValue.minor)
            #expect(!model.hasPeriodFigures)
            #expect(model.ttwror == nil && model.irr == nil && model.absolutePerformance == nil)
            #expect(model.closed.isEmpty)
            let rows = model.groups.flatMap(\.rows)
            #expect(!rows.isEmpty)
            #expect(rows.allSatisfy { $0.ttwror == nil && $0.irr == nil && $0.dividends == nil && $0.realized == nil })
            #expect(model.groups.allSatisfy { $0.ttwror == nil && $0.irr == nil })
            let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
            #expect(display.total?.ttwror == nil && display.total?.irr == nil)
        }
    }

    // MARK: Day change

    @Test func dayChangeIsTheChangeInReportingCurrency() async throws {
        let store = makeStore()
        let model = try await base(store)
        let ledger = store.ledger
        let yesterday = today.advanced(by: -1)
        let now = ledger.snapshot(on: today), before = ledger.snapshot(on: yesterday)
        let tradedToday = Set(store.file.transactions.filter { $0.date == today }.compactMap(\.securityID))
        let rows = model.groups[0].rows
        var checked = 0, foreign = 0
        for position in now.positions where !tradedToday.contains(position.securityID) {
            guard let quote = ledger.price(of: position.securityID, on: today), quote.day == today,
                  let earlier = ledger.price(of: position.securityID, on: yesterday), earlier.day == yesterday,
                  let old = before.position(position.securityID) else { continue }
            let row = try #require(rows.first { $0.securityID == position.securityID })
            let truth = position.value.minor - old.value.minor
            let amount = try #require(row.dayChangeAmount)
            // Rounding of the earlier value only.
            #expect(abs(amount - truth) <= 1, "\(row.name): \(amount) vs \(truth)")
            let fraction = try #require(row.dayChange)
            #expect(abs(fraction - Double(truth) / Double(old.value.minor)) <= 2 / Double(old.value.minor))
            #expect(row.dayChangeSince == yesterday)
            checked += 1
            if row.currency != model.currency {
                foreign += 1
                // The quote's own move is kept apart; it is not what the amount is based on.
                let quoteChange = try #require(row.quoteChange)
                #expect(abs(quoteChange - (Double(quote.price.raw) / Double(earlier.price.raw) - 1)) < 1e-12)
            }
        }
        #expect(checked > 3)
        #expect(foreign > 0)

        // Totals: amount = Σ rows, percentage relative to everything the line shows (cash included).
        let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
        let total = try #require(display.total)
        let sum = rows.reduce(Int64(0)) { $0 + ($1.dayChangeAmount ?? 0) }
        #expect(total.dayChangeAmount == sum)
        let fraction = try #require(total.dayChange)
        #expect(abs(fraction - Double(sum) / Double(model.totalValue - sum)) < 1e-12)
        if store.file.transactions.allSatisfy({ $0.date != today }) {
            // Nothing booked today: the total is the portfolio's change, foreign cash included.
            #expect(abs(sum - (now.totalValue.minor - before.totalValue.minor)) <= Int64(rows.count))
        }
        // Base-currency cash is part of the base, without a figure of its own.
        let cash = try #require(rows.first { $0.kind == .cash && $0.currency == model.currency })
        #expect(cash.dayChange == nil && cash.dayChangeAmount == 0)

        // Every grouping shows the same total amount, to the cent.
        var groupings: [HoldingsGrouping] = [.depot, .currency]
        groupings += store.file.taxonomies.map { .taxonomy($0.id) }
        for grouping in groupings {
            let grouped = HoldingsDisplay(try await base(store, grouping: grouping), options: HoldingsDisplayOptions())
            #expect(grouped.total?.dayChangeAmount == sum, "grouping \(grouping.key)")
            #expect(grouped.total?.dividends == total.dividends, "grouping \(grouping.key)")
            #expect(grouped.total?.gain == total.gain, "grouping \(grouping.key)")
            for group in grouped.groups {
                let header = try #require(group.header)
                guard let change = header.dayChange, let amount = header.dayChangeAmount else { continue }
                #expect(abs(change - Double(amount) / Double(header.value - amount)) < 1e-12)
            }
        }
    }

    @Test func changeHelper() throws {
        // 100 → 110 in USD while USD/EUR falls from 0.92 to 0.90: value now 9 900 minor.
        let change = try #require(HoldingsMath.change(value: 9_900, price: 110, rate: 0.90, previousPrice: 100, previousRate: 0.92))
        #expect(change.amount == 700)
        #expect(abs((change.fraction ?? 0) - 700.0 / 9_200.0) < 1e-12)
        // A falling quote can still be a gain in the reporting currency.
        let gbp = try #require(HoldingsMath.change(value: 10_000, price: 99, rate: 1.02, previousPrice: 100, previousRate: 1.00))
        #expect(gbp.amount > 0)
        #expect(HoldingsMath.change(value: 100, price: 0, rate: 1, previousPrice: 1, previousRate: 1) == nil)
    }

    @Test func staleQuotesHaveNoDayChange() async throws {
        let store = makeStore()
        // A month after the last quotes nothing is a "day" change any more.
        let later = today.advanced(by: 30)
        let model = try await base(store, interval: DayInterval(start: today, end: later))
        let positions = model.groups[0].rows.filter { $0.kind == .position }
        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { $0.isStale && $0.dayChange == nil && $0.dayChangeAmount == nil })
    }

    // MARK: Yield on cost

    @Test func yieldOnCostIsAnnualAndIndependentOfThePeriod() async throws {
        let store = makeStore()
        let trailing = store.ledger.earnings(in: DayInterval(start: today.addingYears(-1), end: today))
        var reference: [UUID: Double] = [:]
        for period in [ReportingPeriod.lastYears(1), .allTime, .lastMonths(1), .year(2024)] {
            store.period = period
            let model = try await screenModel(store)
            let rows = model.groups[0].rows.filter { $0.kind == .position }
            for row in rows {
                let id = try #require(row.securityID)
                let dividends = trailing.bySecurity.first { $0.securityID == id }?.amounts.dividends
                #expect(row.trailingDividends == dividends)
                if let dividends, let cost = row.costBasis, cost > 0 {
                    #expect(row.yieldOnCost == Double(dividends) / Double(cost))
                }
                if let value = row.yieldOnCost {
                    if let known = reference[id] { #expect(known == value, "\(row.name) in \(period.title)") }
                    reference[id] = value
                }
            }
            let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
            let total = try #require(display.total)
            let cost = rows.filter { ($0.costBasis ?? 0) > 0 && $0.trailingDividends != nil }.reduce(Int64(0)) { $0 + ($1.costBasis ?? 0) }
            let sum = rows.reduce(Int64(0)) { $0 + ($1.trailingDividends ?? 0) }
            #expect(total.yieldOnCost == Double(sum) / Double(cost))
            // A sane annual figure, not years of dividends over today's cost.
            #expect(rows.compactMap(\.yieldOnCost).allSatisfy { $0 < 0.15 })
        }
        #expect(!reference.isEmpty)
        #expect(HoldingsMath.yieldOnCost(trailingDividends: 100, costBasis: 0) == nil)
        #expect(HoldingsMath.yieldOnCost(trailingDividends: nil, costBasis: 100) == nil)
    }

    // MARK: Splits

    @Test func apportionIsExact() {
        #expect(HoldingsMath.apportion(100, [1, 1, 1]) == [34, 33, 33])
        #expect(HoldingsMath.apportion(-100, [1, 1, 1]) == [-34, -33, -33])
        #expect(HoldingsMath.apportion(1, [6_800, 1_800, 1_400]) == [1, 0, 0])
        #expect(HoldingsMath.apportion(5, [0, 0]) == [5, 0])
        #expect(HoldingsMath.apportion(5, []) == [])
        #expect(HoldingsMath.apportion(7, [-3, 1]) == [0, 7])
        let big = HoldingsMath.apportion(Int64.max / 2, [6_800, 1_800, 1_400])
        #expect(big.reduce(0, +) == Int64.max / 2)
        for total in [Int64(0), 1, 99, 18_296_826, -4_464_22, 123_456_789_012] {
            let parts = HoldingsMath.apportion(total, [6_800, 1_800, 1_400])
            #expect(parts.reduce(0, +) == total)
            for (part, weight) in zip(parts, [6_800.0, 1_800, 1_400]) {
                #expect(abs(Double(part) - Double(total) * weight / 10_000) <= 1)
            }
        }
    }

    @Test func taxonomyPartsAddUpToThePosition() async throws {
        let store = makeStore()
        let whole = try await base(store).groups[0].rows
        for taxonomy in store.file.taxonomies {
            let model = try await base(store, grouping: .taxonomy(taxonomy.id))
            let parts = model.groups.flatMap(\.rows)
            var split = 0
            for row in whole {
                let mine = parts.filter { $0.securityID == row.securityID && $0.accountID == row.accountID }
                if mine.count > 1 { split += 1 }
                #expect(mine.reduce(0) { $0 + $1.value } == row.value, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.costBasis ?? 0) } == row.costBasis ?? 0, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.gain ?? 0) } == row.gain ?? 0, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.dayChangeAmount ?? 0) } == row.dayChangeAmount ?? 0, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.dividends ?? 0) } == row.dividends ?? 0, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.realized ?? 0) } == row.realized ?? 0, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.localValue ?? 0) } == row.localValue ?? 0, "\(row.name)")
                #expect(mine.reduce(0) { $0 + ($1.shares?.raw ?? 0) } == row.shares?.raw ?? 0, "\(row.name)")
                if mine.count > 1 { #expect(mine.reduce(0) { $0 + ($1.assignedWeight ?? 0) } == 10_000) }
            }
            if taxonomy.id == store.file.taxonomies[1].id { #expect(split > 0) }
            let display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
            #expect(display.total?.costBasis == model.costBasis)
            #expect(display.total?.gain == model.securitiesValue - model.costBasis)
        }
    }

    // MARK: Classification scope

    @Test func classificationScopeScalesSharesLikeTheValue() async throws {
        let store = makeStore()
        let taxonomy = store.file.taxonomies[1]
        let whole = store.ledger.snapshot(on: today)
        var found = false
        for classification in taxonomy.root {
            guard let scope = taxonomy.scope(forClassification: classification.id) else { continue }
            let snapshot = store.ledger.snapshot(on: today, scope: scope)
            guard let partial = snapshot.positions.first(where: { $0.weight != 10_000 && $0.weight != 0 && $0.isValued }) else { continue }
            found = true
            for grouping in [HoldingsGrouping.none, .depot, .currency] {
                let model = try await base(store, grouping: grouping, scope: scope)
                let rows = model.groups.flatMap(\.rows).filter { $0.securityID == partial.securityID }
                #expect(!rows.isEmpty)
                let shares = rows.reduce(Int64(0)) { $0 + ($1.shares?.raw ?? 0) }
                let full = try #require(whole.position(partial.securityID)).shares.raw
                #expect(abs(shares - FixedMath.weighted(full, Int32(partial.weight))) <= Int64(rows.count))
                #expect(shares < full)
                #expect(rows.allSatisfy { $0.assignedWeight == partial.weight })
                // Shares × price reconciles with the value shown (in the security's currency).
                let price = try #require(partial.price)
                let local = rows.reduce(Int64(0)) { $0 + ($1.localValue ?? 0) }
                #expect(abs(FixedMath.marketValue(price: price, shares: Shares(raw: shares)) - local) <= 2)
            }
            let query = HoldingDetail.Query(securityID: partial.securityID)
            let detail = try await store.analyze("holdings.detail", scope: scope, variant: query) { HoldingDetail($0, query: query) }
            #expect(detail.assignedWeight == partial.weight)
            #expect(detail.shares?.raw == FixedMath.weighted(partial.shares.raw, Int32(partial.weight)))
            break
        }
        #expect(found)
    }

    // MARK: Valuation issues

    @Test func missingExchangeRateIsNotCalledAMissingPrice() async throws {
        var file = SampleData.demoPortfolio(today: today)
        let foreign = try #require(file.securities.first { $0.currency != file.settings.baseCurrency })
        file.exchangeRates.removeAll()
        let store = PortfolioStore(file: file, today: today)
        let model = try await base(store)
        let rows = model.groups[0].rows
        let unvalued = rows.filter { !$0.isValued }
        #expect(!unvalued.isEmpty)
        #expect(unvalued.allSatisfy { $0.valuationIssue == .noExchangeRate && $0.currency != model.currency })
        #expect(unvalued.allSatisfy { HoldingsFormat.issueTitle($0) == "No \($0.currency) rate" })
        #expect(unvalued.allSatisfy { $0.dayChange == nil && $0.dayChangeAmount == nil })
        if let row = unvalued.first(where: { $0.securityID == foreign.id }) { #expect(row.price != nil) }
        #expect(rows.filter(\.isValued).allSatisfy { $0.valuationIssue == nil })
        var priceless = HoldingRow(id: "x", kind: .position, name: "X", detail: "", searchText: "", currency: "EUR")
        priceless.isValued = false
        priceless.valuationIssue = .noPrice
        #expect(HoldingsFormat.issueTitle(priceless) == "No price")
    }

    // MARK: View state

    @Test func paletteChangesWaitForTheStoredSettings() {
        let state = HoldingsViewState()
        // A palette command before the screen was ever shown in this window…
        state.apply { $0.visual = .treemap }
        #expect(!state.isSeeded)
        #expect(state.visual == .table)
        // …the screen restores its stored settings, then applies the command on top.
        state.grouping = .depot
        state.visual = .concentration
        state.finishSeeding()
        #expect(state.isSeeded)
        #expect(state.grouping == .depot)
        #expect(state.visual == .treemap)
        // Later commands apply at once, and nothing is replayed.
        state.apply { $0.grouping = .currency }
        #expect(state.grouping == .currency)
        state.visual = .table
        state.finishSeeding()
        #expect(state.visual == .table)
    }

    @Test func deletedTaxonomyFallsBackToNoGrouping() {
        let store = makeStore()
        let state = HoldingsViewState.of(store)
        let taxonomy = store.file.taxonomies[0]
        state.grouping = .taxonomy(taxonomy.id)
        #expect(state.resolvedGrouping(in: store) == .taxonomy(taxonomy.id))
        store.mutate("Delete Taxonomy") { $0.taxonomies.removeAll { $0.id == taxonomy.id } }
        #expect(state.resolvedGrouping(in: store) == HoldingsGrouping.none)
        #expect(state.query(in: store).grouping == HoldingsGrouping.none)
    }

    @Test func revealExpandsTheGroupAndHiddenRowsAreNotActedOn() async throws {
        let store = makeStore()
        let state = HoldingsViewState.of(store)
        let model = try await base(store, grouping: .currency)
        state.display = HoldingsDisplay(model, options: HoldingsDisplayOptions())
        let group = try #require(state.display.groups.last)
        let row = try #require(group.rows.first)
        state.collapsed = Set(state.display.groups.map(\.id))
        #expect(state.visibleLines.allSatisfy { !$0.isEntity })
        // A selection inside a collapsed group is invisible: shortcuts must not act on it.
        state.selection = [row.id]
        #expect(state.selectedRows.isEmpty)
        // Selecting from a chart or a route expands the group and asks the table to scroll.
        state.selection = []
        state.reveal(row.id)
        #expect(!state.collapsed.contains(group.id))
        #expect(state.selection == [row.id])
        #expect(state.revealTarget == row.id)
        #expect(state.selectedRows.map(\.id) == [row.id])
        #expect(state.visibleLines.contains { $0.id == row.id })
    }

    @Test func sellDoesNotShareTheSidebarShortcut() {
        // ⌃⌘S toggles the sidebar (View menu); Sell needs a chord of its own.
        #expect(!(HoldingsShortcut.sell.key == "s" && HoldingsShortcut.sell.modifiers == [.command, .control]))
        let chords = [HoldingsShortcut.buy, .sell, .dividend, .transactions].map { "\($0.key.character)|\($0.modifiers.rawValue)" }
        #expect(Set(chords).count == chords.count)
        var cash = HoldingRow(id: "a", kind: .cash, name: "Cash", detail: "", searchText: "", currency: "EUR")
        cash.accountID = UUID()
        #expect(!HoldingsShortcut.sell.applies(to: cash) && !HoldingsShortcut.buy.applies(to: cash))
        #expect(HoldingsShortcut.transactions.applies(to: cash))
    }

    // MARK: Texts

    @Test func numbersFitTheirColumns() {
        Fmt.setLocale(Locale(identifier: "en_US"))
        #expect(HoldingsFormat.shareDecimals(Shares(1_106)) == 4)
        #expect(HoldingsFormat.shareDecimals(Shares(25_000)) == 2)
        #expect(HoldingsFormat.shareDecimals(Shares(2_500_000)) == 0)
        #expect(HoldingsFormat.compactReturn(0.1234) == Fmt.percent(0.1234, signed: true))
        // +6 618.3 % and beyond lose their decimals instead of being cut off with an ellipsis.
        #expect(HoldingsFormat.compactReturn(66.183) == Fmt.percent(66.183, decimals: 0, signed: true))
        #expect(HoldingsFormat.compactReturn(66.183).count <= 8)
        #expect(HoldingsFormat.compactReturn(2_288.5).hasPrefix("> "))
        #expect(HoldingsFormat.compactReturn(2_288.5).count <= 10)
        #expect(HoldingsFormat.compactReturn(.nan) == Fmt.missing)
        // Amounts of a million and more drop the cents instead of ending in an ellipsis.
        #expect(HoldingsFormat.money(99_999_999, currency: "EUR") == Fmt.money(minor: 99_999_999, currency: "EUR"))
        #expect(HoldingsFormat.money(-129_011_000, currency: "EUR") == Fmt.moneyRounded(Money(minor: -129_011_000, currency: "EUR")))
        #expect(HoldingsFormat.money(-129_011_000, currency: "EUR").count < Fmt.money(minor: -129_011_000, currency: "EUR").count)
        #expect(HoldingsFormat.exact(-129_011_000, currency: "EUR") == Fmt.money(minor: -129_011_000, currency: "EUR"))
        #expect(HoldingsFormat.exact(1_000, currency: "EUR").isEmpty)
    }

    @Test func subtitlesUseOneNoun() async throws {
        #expect(HoldingsDisplay.holdings(1).hasSuffix("1 holding"))
        #expect(HoldingsDisplay.holdings(7).hasSuffix("7 holdings"))
        let store = makeStore()
        let model = try await base(store, grouping: .currency)
        let all = HoldingsDisplay(model, options: HoldingsDisplayOptions())
        #expect(all.total?.detail == HoldingsDisplay.holdings(all.entityCount))
        #expect(all.groups.allSatisfy { $0.header?.detail == "" && $0.header?.count == $0.rows.count })
        var options = HoldingsDisplayOptions()
        options.filter = "meridian"
        let filtered = HoldingsDisplay(model, options: options)
        #expect(filtered.total?.detail == "\(filtered.entityCount) of \(HoldingsDisplay.holdings(all.entityCount))")
    }
}
