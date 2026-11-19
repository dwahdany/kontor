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

        // Snapshot widgets ignore the period, so changing it does not recompute them.
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
