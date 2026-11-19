import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureDashboard

// Tests of the Dashboard feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Dashboard"):
//
//     KONTOR_FEATURES=Dashboard swift test --scratch-path .build-dashboard --filter FeatureDashboardTests

private let today = Day(year: 2026, month: 6, day: 30)

@MainActor private func demoStore() -> PortfolioStore {
    PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
}

@MainActor private func data(_ store: PortfolioStore, _ widget: Dashboard.Widget) async throws -> WidgetData {
    let request = WidgetRequest(widget, kind: try #require(widget.widgetKind), store: store)
    let query = request.query
    return try await store.analyze("dashboard.widget", scope: request.scope, interval: request.interval, variant: query) {
        WidgetData.compute(query, $0)
    }
}

@Suite @MainActor struct DashboardFeatureTests {
    @Test func moduleRegistersItsScreen() {
        #expect(DashboardFeature.module.screen == .dashboard)
    }

    @Test func catalogIdsAreStableAndUnique() {
        #expect(Set(WidgetKind.allCases.map(\.rawValue)).count == WidgetKind.allCases.count)
        // The ids the sample data (and so existing files) use.
        for id in ["total-value", "ttwror", "irr", "max-drawdown", "performance-chart", "allocation", "earnings", "top-movers"] {
            #expect(WidgetKind(rawValue: id) != nil, "missing widget kind \(id)")
        }
    }

    @Test func everySampleWidgetIsSupported() {
        let file = SampleData.demoPortfolio(today: today)
        #expect(!file.dashboards.isEmpty)
        for widget in file.dashboards.flatMap(\.widgets) { #expect(widget.widgetKind != nil) }
    }
}

@Suite struct WidgetConfigTests {
    @Test func periodCodesAreCaseInsensitiveAndRoundTrip() {
        var widget = Dashboard.Widget(.ttwror, config: ["period": "max"])
        #expect(widget.periodOverride == .allTime)
        widget.config["period"] = "1m"
        #expect(widget.periodOverride == .lastMonths(1))
        widget.periodOverride = .year(2024)
        #expect(widget.config["period"] == "2024")
        widget.periodOverride = nil
        #expect(widget.config["period"] == nil)
    }

    @Test func periodAndScopeAlsoDecodeFromJSON() throws {
        let period = String(decoding: try JSONEncoder().encode(ReportingPeriod.lastYears(3)), as: UTF8.self)
        let depot = UUID()
        let scope = String(decoding: try JSONEncoder().encode(ScopeSelection.depot(depot)), as: UTF8.self)
        let widget = Dashboard.Widget(.netWorth, config: ["period": period, "scope": scope])
        #expect(widget.periodOverride == .lastYears(3))
        #expect(widget.scopeOverride == .depot(depot))
    }

    @Test func scopeRoundTripsAsText() {
        var widget = Dashboard.Widget(.netWorth)
        let id = UUID()
        widget.scopeOverride = .account(id)
        #expect(widget.config["scope"] == "account:\(id.uuidString)")
        #expect(widget.scopeOverride == .account(id))
    }

    @Test func spanAndCountAreClamped() {
        var widget = Dashboard.Widget(kind: "holdings", span: 9, config: ["count": "500"])
        #expect(widget.clampedSpan == 4)
        #expect(widget.count == 15)
        widget.span = 0
        #expect(widget.clampedSpan == 1)
        widget.count = WidgetKind.holdings.defaultCount
        #expect(widget.config["count"] == nil)
    }

    @Test func unknownKindKeepsItsTitle() {
        let widget = Dashboard.Widget(kind: "from-the-future", title: "  ")
        #expect(widget.widgetKind == nil)
        #expect(widget.displayTitle == "Unsupported Widget")
    }
}

@Suite struct DashboardLayoutTests {
    @Test func columnsFollowTheWidth() {
        #expect(DashboardGridLayout.columnCount(for: 1170) == 4)
        #expect(DashboardGridLayout.columnCount(for: 730) == 2)
        #expect(DashboardGridLayout.columnCount(for: 900) == 2)
        #expect(DashboardGridLayout.columnCount(for: 400) == 1)
    }

    @Test func rowsPackInOrderWithoutSplitting() {
        // 1 1 1 1 | 4 | 2 2 | 2 (the sample dashboard)
        #expect(DashboardGridLayout.rows(spans: [1, 1, 1, 1, 4, 2, 2, 2], columns: 4) == [[0, 1, 2, 3], [4], [5, 6], [7]])
        // A widget that does not fit starts a new row.
        #expect(DashboardGridLayout.rows(spans: [1, 1, 1, 2, 1], columns: 4) == [[0, 1, 2], [3, 4]])
        // Two columns: wide widgets take the row, tiles pair up.
        #expect(DashboardGridLayout.rows(spans: [1, 1, 1, 1, 4, 2, 3], columns: 2) == [[0, 1], [2, 3], [4], [5], [6]])
        #expect(DashboardGridLayout.rows(spans: [3, 9, 0], columns: 1) == [[0], [1], [2]])
    }
}

@Suite @MainActor struct DashboardEditingTests {
    @Test func editingIsUndoableOneStepPerAction() {
        let store = demoStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let original = store.file.dashboards
        let first = store.currentDashboard.widgets[0].id

        undo.beginUndoGrouping()
        store.addWidget(.holdings)
        undo.endUndoGrouping()
        #expect(store.currentDashboard.widgets.count == original[0].widgets.count + 1)
        #expect(store.currentDashboard.widgets.last?.kind == "holdings")

        undo.beginUndoGrouping()
        store.resizeWidget(first, to: 7)
        undo.endUndoGrouping()
        #expect(store.currentDashboard.widgets[0].span == 4)

        undo.beginUndoGrouping()
        store.moveWidget(first, by: 2)
        undo.endUndoGrouping()
        #expect(store.currentDashboard.widgets[2].id == first)

        undo.undo(); undo.undo(); undo.undo()
        #expect(store.file.dashboards == original)
    }

    @Test func moveOntoAnotherWidgetTakesItsPlace() {
        let store = demoStore()
        let ids = store.currentDashboard.widgets.map(\.id)
        store.moveWidget(ids[0], onto: ids[3])
        #expect(store.currentDashboard.widgets.map(\.id).prefix(4) == [ids[1], ids[2], ids[3], ids[0]])
        store.moveWidget(ids[0], onto: ids[1])
        #expect(store.currentDashboard.widgets.map(\.id) == ids)
    }

    @Test func implicitDashboardIsSavedByItsFirstEdit() {
        var file = SampleData.demoPortfolio(today: today)
        file.dashboards = []
        let store = PortfolioStore(file: file, today: today)
        #expect(store.currentDashboard.id == DashboardDefaults.implicitID)
        #expect(!store.currentDashboard.widgets.isEmpty)
        let revision = store.revision
        store.removeWidget(store.currentDashboard.widgets[0].id)
        #expect(store.revision == revision + 1)
        #expect(store.file.dashboards.count == 1)
        #expect(store.file.dashboards[0].widgets.count == DashboardDefaults.widgets(for: file).count - 1)
    }

    @Test func dashboardsCanBeAddedDuplicatedRenamedDeletedAndReset() {
        let store = demoStore()
        let overview = store.currentDashboard
        store.newDashboard()
        #expect(store.file.dashboards.count == 2)
        #expect(store.currentDashboard.id != overview.id)
        #expect(store.dashboardSession.isEditing)
        store.renameDashboard("  Income ")
        #expect(store.currentDashboard.name == "Income")
        store.duplicateDashboard()
        #expect(store.file.dashboards.map(\.name) == [overview.name, "Income", "Income Copy"])
        #expect(Set(store.file.dashboards.flatMap(\.widgets).map(\.id)).count == store.file.dashboards.flatMap(\.widgets).count)
        store.resetDashboardToDefault()
        #expect(store.currentDashboard.widgets.map(\.kind) == DashboardDefaults.widgets(for: store.file).map(\.kind))
        store.deleteCurrentDashboard()
        store.deleteCurrentDashboard()
        #expect(store.file.dashboards.map(\.id) == [overview.id])
        #expect(store.currentDashboard.id == overview.id)
    }

    @Test func catalogDashboardIsNeverSaved() {
        let store = demoStore()
        store.dashboardSession.showsCatalog = true
        #expect(store.currentDashboard.widgets.count == WidgetKind.allCases.count)
        let revision = store.revision
        store.addWidget(.cash)
        #expect(store.revision == revision)
    }
}

@Suite @MainActor struct WidgetDataTests {
    @Test func netWorthMatchesTheEngineSnapshot() async throws {
        let store = demoStore()
        let analysis = await store.analysis()
        guard case .netWorth(let net) = try await data(store, .init(.netWorth)) else { Issue.record("wrong case"); return }
        #expect(net.total == analysis.snapshot.totalValue)
        #expect(net.hasData && net.sparkline.count >= 2)
        // Day change is the engine's daily return of that day, in money: value change net of flows.
        let v = analysis.valuation
        let i = try #require(v.index(of: net.changeDay))
        #expect(net.dayChange.minor == v.values[i] - v.values[i - 1] - v.inflows[i] + v.outflows[i])
        #expect(net.dayFraction == analysis.returns.daily[i])
    }

    @Test func statTilesShowEngineFigures() async throws {
        let store = demoStore()
        let analysis = await store.analysis()
        func percent(_ kind: WidgetKind) async throws -> Double? {
            guard case .stat(let stat) = try await data(store, .init(kind)), case .percent(let value) = stat.value else { return nil }
            return value
        }
        #expect(try await percent(.ttwror) == analysis.ttwror)
        #expect(try await percent(.irr) == analysis.irr)
        #expect(try await percent(.volatility) == analysis.risk.volatility)
        #expect(try await percent(.maxDrawdown) == analysis.risk.maxDrawdown.map { -$0.depth })
        guard case .stat(let gain) = try await data(store, .init(.absoluteGain)), case .money(let money) = gain.value else {
            Issue.record("wrong case"); return
        }
        #expect(money?.minor == analysis.absolutePerformance)
    }

    @Test func periodAndScopeOverridesChangeTheRequest() async throws {
        let store = demoStore()
        store.period = .ytd
        let depot = try #require(store.file.depots.first)
        var widget = Dashboard.Widget(.ttwror)
        widget.periodOverride = .allTime
        widget.scopeOverride = .depot(depot.id)
        let request = WidgetRequest(widget, kind: .ttwror, store: store)
        #expect(request.interval == store.interval(for: .allTime))
        #expect(request.scope == Scope.depot(depot.id))
        #expect(request.isPeriodOverridden && request.scopeLabel == depot.name)
        let expected = await store.analysis(scope: .depot(depot.id), period: .allTime).ttwror
        guard case .stat(let stat) = try await data(store, widget), case .percent(let value) = stat.value else { Issue.record("wrong case"); return }
        #expect(value == expected)

        // Snapshot widgets are valued at the end of the period: periods ending today share one request.
        let holdings = WidgetRequest(.init(.holdings), kind: .holdings, store: store)
        store.period = .lastYears(3)
        #expect(WidgetRequest(.init(.holdings), kind: .holdings, store: store).interval == holdings.interval)
    }

    @Test func allocationAndCashAddUpToNetWorth() async throws {
        let store = demoStore()
        let snapshot = await store.analysis().snapshot
        guard case .allocation(let allocation) = try await data(store, .init(.allocation)) else { Issue.record("wrong case"); return }
        #expect(Int64(allocation.slices.reduce(0) { $0 + $1.value }) == snapshot.totalValue.minor)
        guard case .cash(let cash) = try await data(store, .init(.cash)) else { Issue.record("wrong case"); return }
        #expect(cash.total == snapshot.cashValue)
        #expect(cash.rows.reduce(0) { $0 + $1.value.minor } == snapshot.cashValue.minor)
        guard case .holdings(let holdings) = try await data(store, .init(.holdings)) else { Issue.record("wrong case"); return }
        #expect(holdings.rows.count == 6 && holdings.total == snapshot.positions.count)
        #expect(holdings.rows.map(\.value.minor) == holdings.rows.map(\.value.minor).sorted(by: >))
    }

    @Test func earningsCoverTwelveMonthsAndMatchTheEngine() async throws {
        let store = demoStore()
        guard case .earnings(let months) = try await data(store, .init(.earnings)) else { Issue.record("wrong case"); return }
        #expect(months.categories.count == 12 && !months.byYear)
        #expect(months.total.minor == zip(months.dividends, months.interest).reduce(0) { $0 + $1.0 + $1.1 })
        let ytd = await store.analysis(period: .ytd).earnings.total.earnings
        #expect(months.thisYear.minor == ytd)
        guard case .earnings(let years) = try await data(store, .init(.earnings, config: ["grouping": "year"])) else { Issue.record("wrong case"); return }
        #expect(years.byYear && years.categories.last?.label == "2026")
        #expect(years.dividends.last! + years.interest.last! == ytd)
    }

    @Test func moversAreSortedAndSigned() async throws {
        let store = demoStore()
        guard case .movers(let movers) = try await data(store, .init(.topMovers, config: ["period": "1m"])) else { Issue.record("wrong case"); return }
        #expect(movers.best.allSatisfy { $0.change > 0 } && movers.worst.allSatisfy { $0.change < 0 })
        #expect(movers.best.map(\.change) == movers.best.map(\.change).sorted(by: >))
        #expect(movers.worst.map(\.change) == movers.worst.map(\.change).sorted(by: <))
        #expect(movers.best.count <= 3 && movers.worst.count <= 3)
    }

    @Test func listsReflectTheDocument() async throws {
        let store = demoStore()
        guard case .transactions(let rows) = try await data(store, .init(.recentTransactions)) else { Issue.record("wrong case"); return }
        #expect(rows.count == 6)
        #expect(rows.first?.id == store.ledger.transactions.last?.id)
        guard case .plans(let plans) = try await data(store, .init(.upcomingPlans)) else { Issue.record("wrong case"); return }
        #expect(plans.count == store.file.plans.count)
        #expect(plans.allSatisfy { ($0.nextDue ?? today) >= today })
        guard case .watchlist(let watch) = try await data(store, .init(.watchlist)) else { Issue.record("wrong case"); return }
        #expect(watch.map(\.id) == store.file.watchlists[0].securityIDs)
        #expect(watch.allSatisfy { $0.price != nil && $0.sparkline.count >= 2 })
        guard case .checklist(let checklist) = try await data(store, .init(.gettingStarted)) else { Issue.record("wrong case"); return }
        #expect(checklist.hasAccount && checklist.hasSecurity && checklist.hasTransaction)
        guard case .consistency(let check) = try await data(store, .init(.consistency)) else { Issue.record("wrong case"); return }
        #expect(check.total == (try await store.consistencyIssues()).count)
    }

    @Test func emptyFileProducesPlaceholdersNotCrashes() async throws {
        let store = PortfolioStore(file: PortfolioFile(), today: today)
        for kind in WidgetKind.allCases {
            _ = try await data(store, .init(kind))
        }
        guard case .stat(let stat) = try await data(store, .init(.ttwror)), case .percent(let value) = stat.value else { Issue.record("wrong case"); return }
        #expect(value == nil)
        guard case .checklist(let checklist) = try await data(store, .init(.gettingStarted)) else { Issue.record("wrong case"); return }
        #expect(checklist.doneCount == 0)
    }
}

// MARK: - Regression tests for the review findings

@Suite @MainActor struct DashboardConsistencyTests {
    /// One valuation day per screen: with a period that ends in the past, net worth, allocation,
    /// holdings and cash are all statements of that day — and say so.
    @Test func statementWidgetsAreValuedAtTheEndOfThePeriod() async throws {
        let store = demoStore()
        store.period = .year(2024)
        let end = Day(year: 2024, month: 12, day: 31)
        let snapshot = store.ledger.snapshot(on: end, scope: .portfolio)
        #expect(snapshot.totalValue != store.ledger.snapshot(on: today, scope: .portfolio).totalValue)

        guard case .netWorth(let net) = try await data(store, .init(.netWorth)) else { Issue.record("wrong case"); return }
        guard case .allocation(let allocation) = try await data(store, .init(.allocation)) else { Issue.record("wrong case"); return }
        guard case .cash(let cash) = try await data(store, .init(.cash)) else { Issue.record("wrong case"); return }
        guard case .holdings(let holdings) = try await data(store, .init(.holdings, config: ["count": "15"])) else { Issue.record("wrong case"); return }
        #expect(net.total == snapshot.totalValue)
        #expect(Int64(allocation.slices.reduce(0) { $0 + $1.value }) == net.total.minor)
        #expect(cash.total == snapshot.cashValue)
        #expect(holdings.rows.reduce(0) { $0 + $1.value.minor } + cash.total.minor == net.total.minor)

        for kind in [WidgetKind.netWorth, .allocation, .holdings, .cash] {
            #expect(WidgetRequest(.init(kind), kind: kind, store: store).asOf == end, "\(kind) must show its valuation day")
        }
        #expect(WidgetRequest(.init(.watchlist), kind: .watchlist, store: store).asOf == end)
        // Widgets that have nothing to do with a valuation day carry no date.
        #expect(WidgetRequest(.init(.ttwror), kind: .ttwror, store: store).asOf == nil)
        #expect(WidgetRequest(.init(.recentTransactions), kind: .recentTransactions, store: store).asOf == nil)

        // A period that runs until today: no date, and the values are today's.
        store.period = .lastYears(1)
        for kind in [WidgetKind.netWorth, .allocation, .holdings, .cash] {
            #expect(WidgetRequest(.init(kind), kind: kind, store: store).asOf == nil)
        }
        // A net worth tile pinned to a past year is a statement of that year's end, whatever the window shows.
        let pinned = WidgetRequest(.init(.netWorth, config: ["period": "2024"]), kind: .netWorth, store: store)
        #expect(pinned.asOf == end && pinned.isPeriodOverridden)
    }

    @Test func balancesWithoutAnExchangeRateAreFlagged() async throws {
        var file = SampleData.demoPortfolio(today: today)
        let account = Account(name: "Swiss Account", currency: "CHF")
        file.accounts.append(account)
        file.transactions.append(Transaction(kind: .deposit, date: today.advanced(by: -30), accountID: account.id,
                                             amount: Money(minor: 500_000, currency: "CHF")))
        let store = PortfolioStore(file: file, today: today)

        guard case .cash(let cash) = try await data(store, .init(.cash)) else { Issue.record("wrong case"); return }
        let row = try #require(cash.rows.first { $0.id == account.id })
        #expect(!row.isValued && row.balance == Money(minor: 500_000, currency: "CHF"))
        #expect(cash.rows.filter { !$0.isValued }.count == 1)
        #expect(cash.gaps.messages.count == 1)
        #expect(cash.gaps.messages[0].contains("Swiss Account") && cash.gaps.messages[0].contains("CHF"))
        // The rows that are valued still add up to the total — the flagged one is what is missing.
        #expect(cash.rows.filter(\.isValued).reduce(0) { $0 + $1.value.minor } == cash.total.minor)

        guard case .netWorth(let net) = try await data(store, .init(.netWorth)) else { Issue.record("wrong case"); return }
        #expect(net.gaps == cash.gaps)
        // The list of positions is complete: the missing rate concerns cash only.
        guard case .holdings(let holdings) = try await data(store, .init(.holdings)) else { Issue.record("wrong case"); return }
        #expect(holdings.gaps.isEmpty && holdings.rows.allSatisfy(\.isValued))
        #expect(cash.gaps.summary == "1 cash balance cannot be valued and is not included")
        guard case .allocation(let allocation) = try await data(store, .init(.allocation)) else { Issue.record("wrong case"); return }
        #expect(!allocation.gaps.isEmpty)

        // Scoped to that account alone: the total is zero *and flagged*, not a silent "0,00".
        guard case .netWorth(let scoped) = try await data(store, .init(.netWorth, config: ["scope": "account:\(account.id.uuidString)"])) else {
            Issue.record("wrong case"); return
        }
        #expect(scoped.total.minor == 0 && !scoped.gaps.isEmpty)

        // A file where everything can be valued has no warnings.
        guard case .cash(let clean) = try await data(demoStore(), .init(.cash)) else { Issue.record("wrong case"); return }
        #expect(clean.gaps.isEmpty && clean.rows.allSatisfy(\.isValued))
    }

    @Test func moversOfTheDayUseEachPositionsLatestQuotedDay() async throws {
        // A Sunday: only assets that trade every day have a quote "today".
        let sunday = Day(year: 2026, month: 6, day: 28)
        let store = PortfolioStore(file: SampleData.demoPortfolio(today: sunday), today: sunday)
        let widget = Dashboard.Widget(.topMovers, config: ["mode": "day", "count": "8"])
        let request = WidgetRequest(widget, kind: .topMovers, store: store)
        #expect(request.query.dayMode && request.interval.end == sunday)
        guard case .movers(let movers) = try await data(store, widget) else { Issue.record("wrong case"); return }
        let friday = Day(year: 2026, month: 6, day: 26)
        #expect(movers.days.contains(friday), "positions quoted on weekdays show Friday's change")
        #expect(!movers.best.isEmpty && !movers.worst.isEmpty)
        #expect(movers.best.count + movers.worst.count > 2)
        #expect(movers.positionCount == store.ledger.snapshot(on: sunday, scope: .portfolio).positions.count)

        // Each figure is the engine's return of that position on its latest quoted day.
        let analysis = await store.analysis(interval: DayInterval(start: friday.advanced(by: -1), end: friday))
        let fridayReturns = Dictionary(uniqueKeysWithValues: analysis.securities.map { ($0.securityID, $0.ttwror) })
        let snapshot = store.ledger.snapshot(on: sunday, scope: .portfolio)
        for mover in movers.best + movers.worst where snapshot.position(mover.id)?.priceDay == friday {
            #expect(mover.change == fridayReturns[mover.id])
        }

        // The chip names the day once the data is there.
        let labelled = request.labelled(with: .movers(movers), today: sunday)
        if movers.days.count == 1 { #expect(labelled.periodLabel != "1D") } else { #expect(labelled.periodHelp?.contains("latest quoted day") == true) }

        // On a normal trading day it is simply today against yesterday.
        let weekday = demoStore()
        guard case .movers(let normal) = try await data(weekday, widget) else { Issue.record("wrong case"); return }
        #expect(normal.days == [today])
        let oneDay = await weekday.analysis(interval: DayInterval(start: today.advanced(by: -1), end: today))
        let expected = oneDay.securities.filter { $0.ttwror > 0 }.map(\.ttwror).sorted(by: >)
        #expect(normal.best.map(\.change) == Array(expected.prefix(8)))
    }

    @Test func partialScopesAreNamedAndWholePortfolioListsSaySo() throws {
        let store = demoStore()
        let depot = try #require(store.file.depots.first)
        #expect(Dashboard.Widget(.netWorth).displayTitle(isPartialScope: false) == "Net Worth")
        #expect(Dashboard.Widget(.netWorth).displayTitle(isPartialScope: true) == "Value")
        #expect(Dashboard.Widget(.netWorth, title: "Mine").displayTitle(isPartialScope: true) == "Mine")
        #expect(Dashboard.Widget(.ttwror).displayTitle(isPartialScope: true) == "Time-Weighted Return")

        #expect(!WidgetRequest(.init(.recentTransactions), kind: .recentTransactions, store: store).ignoresWindowScope)
        store.scopeSelection = .depot(depot.id)
        for kind in [WidgetKind.recentTransactions, .upcomingPlans, .consistency] {
            #expect(WidgetRequest(.init(kind), kind: kind, store: store).ignoresWindowScope)
        }
        let net = WidgetRequest(.init(.netWorth), kind: .netWorth, store: store)
        #expect(net.isPartialScope && net.scopeTitle == depot.name && !net.ignoresWindowScope)
        // Fixed to the whole portfolio under a depot window: it is the net worth again.
        let whole = WidgetRequest(.init(.netWorth, config: ["scope": "portfolio"]), kind: .netWorth, store: store)
        #expect(!whole.isPartialScope)
    }

    @Test func changeDayKeepsTheCapitalsOfDates() {
        let formatter = KontorFormatter(locale: Locale(identifier: "en_US"))
        let past = Day(year: 2024, month: 12, day: 31)
        #expect(WidgetText.changeDay(today, today: today) == Fmt.relativeDay(today, today: today).lowercased())
        #expect(WidgetText.changeDay(today.advanced(by: -1), today: today) == Fmt.relativeDay(today.advanced(by: -1), today: today).lowercased())
        // Beyond a week Fmt prints a date; month names stay as the locale writes them.
        #expect(WidgetText.changeDay(past, today: today) == Fmt.day(past, style: .medium))
        #expect(formatter.day(past, style: .medium).contains("Dec"))
        #expect(WidgetText.changeDay(past, today: today) != Fmt.day(past, style: .medium).lowercased()
                || Fmt.day(past, style: .medium) == Fmt.day(past, style: .medium).lowercased())
    }

    @Test func monthlyReturnsShowWholeCalendarYearsWhateverThePeriod() async throws {
        let store = demoStore()
        #expect(!WidgetKind.monthlyReturns.usesPeriod)
        store.period = .lastYears(1)
        let request = WidgetRequest(.init(.monthlyReturns), kind: .monthlyReturns, store: store)
        #expect(request.interval == store.interval(for: .allTime) && request.periodLabel == nil)
        guard case .heatmap(let rows) = try await data(store, .init(.monthlyReturns)) else { Issue.record("wrong case"); return }
        #expect(rows.count == 6 && rows.first?.label == "2026")
        // 2025 is a complete year: twelve months, and "Year" is the calendar-year return.
        let year2025 = try #require(rows.first { $0.label == "2025" })
        #expect(year2025.cells.allSatisfy { $0 != nil })
        let expected = await store.analysis(period: .year(2025)).ttwror
        #expect(abs((year2025.total ?? 0) - expected) < 1e-9)
        // The "Years" option works without pinning anything.
        guard case .heatmap(let two) = try await data(store, .init(.monthlyReturns, config: ["count": "2"])) else { Issue.record("wrong case"); return }
        #expect(two.map(\.label) == ["2026", "2025"])

        // A portfolio that starts today has no months before today.
        var file = PortfolioFile()
        let account = Account(name: "Cash", currency: file.settings.baseCurrency)
        file.accounts = [account]
        file.transactions = [Transaction(kind: .deposit, date: today, accountID: account.id, amount: Money(minor: 100_000, currency: account.currency))]
        guard case .heatmap(let fresh) = try await data(PortfolioStore(file: file, today: today), .init(.monthlyReturns)) else { Issue.record("wrong case"); return }
        #expect(fresh.count == 1)
        #expect(fresh[0].cells.prefix(5).allSatisfy { $0 == nil } && fresh[0].cells.suffix(6).allSatisfy { $0 == nil })
    }

    @Test func heatmapCellsFitLossesToo() {
        // The default two-column tile: a month cell is about 36 pt wide.
        let narrow = HeatmapCellText.best(forCellWidth: 36)
        #expect(narrow.widestLabel <= 36 - 6)
        #expect(narrow != .percent || HeatmapCellText.percent.widestLabel <= 30)
        // A loss and a gain of the same size get the same form, so a loss is never the one left blank.
        #expect(narrow.format(-0.0077).count == narrow.format(0.0077).count + 1)
        // Wide cells keep the percent sign.
        #expect(HeatmapCellText.best(forCellWidth: 90) == .percent)
        #expect(HeatmapCellText.best(forCellWidth: 5) == .rounded)
        // The cell width mirrors the grid's metrics: 13.25 units after the year label and the gap.
        let cell = HeatmapCellText.cellWidth(gridWidth: 560, yearLabel: "2026")
        #expect(cell > 36 && cell < 41)
    }

    @Test func drawdownDetailNamesTheRecoveryMonth() {
        let recovered = RiskMetrics.Drawdown(depth: 0.29, peak: Day(year: 2021, month: 3, day: 16), trough: Day(year: 2023, month: 8, day: 9),
                                             recovery: Day(year: 2025, month: 7, day: 7))
        let text = WidgetData.drawdownDetail(recovered)
        #expect(text.hasSuffix("recovered \(Fmt.day(Day(year: 2025, month: 7, day: 7), style: .shortMonthYear))"))
        #expect(!text.contains("recovered in"))
        let open = RiskMetrics.Drawdown(depth: 0.1, peak: Day(year: 2026, month: 1, day: 5), trough: Day(year: 2026, month: 3, day: 2), recovery: nil)
        #expect(WidgetData.drawdownDetail(open).hasSuffix("not yet recovered"))
    }

    @Test func danglingReferencesAreReportedAndNormalizedAway() throws {
        let store = demoStore()
        let file = store.file
        let gone = UUID().uuidString
        let taxonomy = try #require(file.taxonomies.first)
        let security = try #require(file.securities.first)

        let chart = Dashboard.Widget(.performanceChart, config: ["benchmark": gone, "scope": "depot:\(gone)", "period": "max"])
        #expect(chart.danglingReferences(in: file).count == 2)
        #expect(WidgetRequest(chart, kind: .performanceChart, store: store).warnings.count == 2)
        let cleaned = chart.normalized(in: file)
        #expect(cleaned.config == ["period": "max"])
        #expect(cleaned.danglingReferences(in: file).isEmpty)

        let allocation = Dashboard.Widget(.allocation, config: ["taxonomy": gone])
        #expect(allocation.danglingReferences(in: file).count == 1)
        #expect(allocation.normalized(in: file).config["taxonomy"] == nil)

        // Valid references and the "none" benchmark survive untouched.
        let valid = Dashboard.Widget(.performanceChart, config: ["benchmark": security.id.uuidString])
        #expect(valid.normalized(in: file) == valid && valid.danglingReferences(in: file).isEmpty)
        let none = Dashboard.Widget(.performanceChart, config: ["benchmark": "none"])
        #expect(none.normalized(in: file) == none)
        let good = Dashboard.Widget(.allocation, config: ["taxonomy": taxonomy.id.uuidString])
        #expect(good.normalized(in: file) == good)
        // A period on a widget that has none is dropped.
        #expect(Dashboard.Widget(.monthlyReturns, config: ["period": "max"]).normalized(in: file).config.isEmpty)
        // A period nobody can read is reported and dropped.
        let garbage = Dashboard.Widget(.ttwror, config: ["period": "garbage"])
        #expect(garbage.danglingReferences(in: file).count == 1 && garbage.normalized(in: file).config.isEmpty)
        // Unknown kinds are never touched.
        let future = Dashboard.Widget(kind: "from-the-future", config: ["scope": "depot:\(gone)"])
        #expect(future.normalized(in: file) == future)
    }
}

@Suite @MainActor struct DashboardFlowTests {
    private func implicitStore() -> PortfolioStore {
        var file = SampleData.demoPortfolio(today: today)
        file.dashboards = []
        return PortfolioStore(file: file, today: today)
    }

    @Test func noOpLayoutActionsDoNotTouchTheDocument() {
        let store = implicitStore()
        let undo = UndoManager()
        store.undoManager = undo
        let widgets = store.currentDashboard.widgets
        let revision = store.revision

        store.moveWidget(widgets[0].id, by: -1)                          // first widget, "Move Earlier"
        store.moveWidget(widgets[widgets.count - 1].id, by: 1)           // last widget, "Move Later"
        store.resizeWidget(widgets[0].id, to: widgets[0].span)           // the width it already has
        store.resizeWidget(widgets[0].id, to: 0)                         // "−" on a 1-column widget
        store.updateWidget(widgets[0])
        store.removeWidget(UUID())
        store.renameDashboard(store.currentDashboard.name)

        #expect(store.revision == revision)
        #expect(store.file.dashboards.isEmpty)
        #expect(!undo.canUndo)

        // A real edit still saves the implicit dashboard.
        store.moveWidget(widgets[0].id, by: 1)
        #expect(store.revision == revision + 1 && store.file.dashboards.count == 1)
    }

    @Test func resettingADefaultLayoutIsANoOp() {
        let store = implicitStore()
        let revision = store.revision
        store.resetDashboardToDefault()
        #expect(store.revision == revision && store.file.dashboards.isEmpty)
        store.removeWidget(store.currentDashboard.widgets[0].id)
        store.resetDashboardToDefault()
        #expect(store.currentDashboard.widgets.map(\.kind) == DashboardDefaults.widgets(for: store.file).map(\.kind))
    }

    @Test func aDiscardedNameNeverComesBack() {
        let store = demoStore()
        let session = store.dashboardSession
        let name = store.currentDashboard.name
        let widget = store.currentDashboard.widgets[0]

        // Type a name, leave with Esc: discarded.
        session.isEditing = true
        store.setDashboardNameDraft("Foo")
        #expect(store.dashboardNameText == "Foo")
        store.finishDashboardEditing(commitName: false)
        #expect(!session.isEditing && store.currentDashboard.name == name)
        #expect(store.dashboardNameText == name)

        // Edit again, resize a widget, Done: the old draft must not be committed.
        session.isEditing = true
        store.resizeWidget(widget.id, to: widget.clampedSpan == 4 ? 3 : widget.clampedSpan + 1)
        store.finishDashboardEditing()
        #expect(store.currentDashboard.name == name)

        // Every "Done" (toolbar, edit bar, inspector, palette) commits what is typed.
        store.toggleDashboardEditing()
        store.setDashboardNameDraft("  Income ")
        store.toggleDashboardEditing()
        #expect(!session.isEditing && store.currentDashboard.name == "Income" && session.nameDraft == nil)

        // An emptied field is not a name: the real one is shown again.
        store.toggleDashboardEditing()
        store.setDashboardNameDraft("")
        #expect(store.dashboardNameText == "")
        store.finishDashboardEditing()
        #expect(store.currentDashboard.name == "Income" && store.dashboardNameText == "Income")
    }

    @Test func switchingDashboardsCommitsTheTypedName() {
        let store = demoStore()
        let first = store.currentDashboard.id
        store.newDashboard()
        let second = store.currentDashboard.id
        store.setDashboardNameDraft("Risk")
        store.selectDashboard(first)
        #expect(store.currentDashboard.id == first)
        #expect(store.file.dashboards.first { $0.id == second }?.name == "Risk")
        // The draft belonged to the other dashboard; this one shows its own name.
        #expect(store.dashboardNameText == store.currentDashboard.name)

        // Typing the stored name is no draft at all.
        store.setDashboardNameDraft(store.currentDashboard.name)
        #expect(store.dashboardSession.nameDraft == nil)
    }

    @Test func dashboardsCanBeReordered() {
        let store = demoStore()
        let undo = UndoManager()
        store.undoManager = undo
        let first = store.currentDashboard.id
        #expect(!store.canMoveCurrentDashboard(by: -1) && !store.canMoveCurrentDashboard(by: 1))
        store.newDashboard()
        store.newDashboard()
        let ids = store.file.dashboards.map(\.id)
        #expect(ids.count == 3 && store.currentDashboard.id == ids[2])
        #expect(!store.canMoveCurrentDashboard(by: 1))
        store.moveCurrentDashboard(by: -1)
        #expect(store.file.dashboards.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(store.currentDashboard.id == ids[2])
        store.moveCurrentDashboard(by: -1)
        #expect(store.file.dashboards.map(\.id) == [ids[2], first, ids[1]])
        let revision = store.revision
        store.moveCurrentDashboard(by: -1)                               // already first: nothing happens
        #expect(store.revision == revision)
    }
}

@Suite struct DashboardStackingTests {
    @Test func underfilledRowsStretchToTheFullWidth() {
        // A lone tile in front of a full-width chart fills its row.
        #expect(DashboardGridLayout.slotWidths(spans: [1], columns: 4, width: 1000, spacing: 16) == [1000])
        #expect(DashboardGridLayout.slotWidths(spans: [1], columns: 2, width: 600, spacing: 16) == [600])
        let three = DashboardGridLayout.slotWidths(spans: [1, 2], columns: 4, width: 1000, spacing: 16)
        #expect(abs(three[0] - 328) < 0.01 && abs(three[1] - 656) < 0.01)
        #expect(abs(three.reduce(0, +) + 16 - 1000) < 0.01)
        // A full row keeps the column grid.
        let full = DashboardGridLayout.slotWidths(spans: [1, 1, 2], columns: 4, width: 1000, spacing: 16)
        #expect(full == [238, 238, 492])
        #expect(DashboardGridLayout.slotWidths(spans: [4], columns: 4, width: 1000, spacing: 16) == [1000])
    }

    @Test func neighbouringTilesStackBesideATallWidget() {
        let spans = [1, 1, 2, 1, 1, 1, 1, 1, 2]
        let tiles = [true, true, false, true, true, true, true, false, false]
        // tile tile list → the two tiles share a column
        #expect(DashboardGridLayout.stackedSlots(row: [0, 1, 2], spans: spans, tiles: tiles) == [[0, 1], [2]])
        // only tiles → nothing to gain
        #expect(DashboardGridLayout.stackedSlots(row: [3, 4, 5, 6], spans: spans, tiles: tiles) == [[3], [4], [5], [6]])
        // a single tile beside a list stays where it is; three tiles pair up once
        #expect(DashboardGridLayout.stackedSlots(row: [6, 7], spans: spans, tiles: tiles) == [[6], [7]])
        #expect(DashboardGridLayout.stackedSlots(row: [4, 5, 6, 7], spans: spans, tiles: tiles) == [[4, 5], [6], [7]])
        // a tile widened to two columns is not stacked
        #expect(DashboardGridLayout.stackedSlots(row: [0, 1, 2], spans: [1, 2, 1], tiles: [true, true, false]) == [[0], [1], [2]])
    }
}
