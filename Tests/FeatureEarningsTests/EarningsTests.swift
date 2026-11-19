import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureEarnings

// Tests of the Earnings feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Earnings"):
//
//     KONTOR_FEATURES=Earnings swift test --scratch-path .build-earnings --filter FeatureEarningsTests
@Suite @MainActor struct EarningsFeatureTests {
    private let today = Day(year: 2026, month: 6, day: 30)

    private func demoStore() -> PortfolioStore {
        PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
    }

    private func model(_ store: PortfolioStore, kind: EarningsKind = .dividends, interval: DayInterval? = nil) async throws -> EarningsModel {
        let all = store.interval(for: .allTime)
        let query = EarningsModel.Query(kind: kind, today: store.today, allYears: all)
        return try await store.analyze("earnings.model", interval: interval ?? all, variant: query) { analysis in
            EarningsModel(analysis, query: query)
        }
    }

    @Test func moduleRegistersItsScreen() {
        #expect(EarningsFeature.module.screen == .earnings)
    }

    @Test func totalsAgreeWithTheEngineAndWithEachOther() async throws {
        let store = demoStore()
        let all = store.interval(for: .allTime)
        let report = store.ledger.earnings(in: all, scope: .portfolio)
        for kind in EarningsKind.allCases {
            let model = try await model(store, kind: kind)
            #expect(!model.isEmpty)
            #expect(model.totalValue == report.total[kind.metric])
            // Matrix: rows and columns both add up to the engine total.
            #expect(model.matrix.reduce(0) { $0 + $1.total } == model.totalValue)
            #expect(model.matrixColumnTotals.reduce(0, +) == model.totalValue)
            for row in model.matrix { #expect(row.values.reduce(0, +) == row.total) }
            // Chart: every bar width adds up to the same total, stacked or not.
            for grouping in EarningsGrouping.allCases {
                let chart = try #require(model.charts[grouping])
                let plain = chart.plain.reduce(0.0) { $0 + $1.values.reduce(0, +) }
                #expect(Int64(plain.rounded()) == model.totalValue)
                #expect(chart.amounts.reduce(0) { $0 + $1[kind.metric] } == model.totalValue)
                if let stacked = chart.bySecurity {
                    let sum = stacked.reduce(0.0) { $0 + $1.values.reduce(0, +) }
                    #expect(Int64(sum.rounded()) == model.totalValue)
                }
            }
            // By security: rows (incl. "not tied to a security") add up to the total.
            #expect(model.securities.reduce(0) { $0 + $1.amount } == model.totalValue)
        }
    }

    @Test func tilesUseCalendarWindows() async throws {
        let store = demoStore()
        let model = try await model(store)
        let ledger = store.ledger
        let ytd = ledger.earnings(in: store.interval(for: .ytd), scope: .portfolio).total.dividends
        let lastYear = ledger.earnings(in: store.interval(for: .year(2025)), scope: .portfolio).total.dividends
        #expect(model.tiles.thisYear == ytd)
        #expect(model.tiles.lastYear == lastYear)
        #expect(model.tiles.year == 2026)
        // The engine's rolling twelve-month sum at the current month is the "last 12 months" tile.
        let trailing = ledger.earnings(in: store.interval(for: .allTime), scope: .portfolio).trailingTwelveMonths(.dividends)
        #expect(model.tiles.trailing == trailing.last?.value)
        #expect(model.tiles.averagePerMonth == model.tiles.trailing / 12)
        // The current year is compared with the same days of last year in the tile and the matrix.
        let current = try #require(model.matrix.first)
        #expect(current.year == 2026)
        #expect(current.growthIsSamePeriod)
        #expect(current.growth == model.tiles.samePeriodGrowth)
        let expected = Double(model.tiles.thisYear) / Double(model.tiles.samePeriodLastYear) - 1
        #expect(abs((model.tiles.samePeriodGrowth ?? 0) - expected) < 1e-12)
    }

    @Test func tilesIgnoreTheSelectedRangeButTheTablesFollowIt() async throws {
        let store = demoStore()
        let all = try await model(store)
        let threeYears = try await model(store, interval: store.interval(for: .lastYears(3)))
        #expect(threeYears.tiles.thisYear == all.tiles.thisYear)
        #expect(threeYears.tiles.trailing == all.tiles.trailing)
        #expect(threeYears.totalValue < all.totalValue)
        #expect(threeYears.matrix.count == 4)
        // The first, cut-off year of the range is not a fair basis for the next year's growth.
        let secondYear = threeYears.matrix[threeYears.matrix.count - 2]
        #expect(secondYear.growth == nil)
        // The calendar always looks at all years.
        #expect(threeYears.calendar.expectedTotal == all.calendar.expectedTotal)
    }

    @Test func projectionRepeatsLastYearsPaymentsForTheSharesHeldToday() async throws {
        let store = demoStore()
        let model = try await model(store)
        let calendar = model.calendar
        #expect(calendar.months.count == 12)
        #expect(calendar.months.first?.detail == Fmt.month(year: 2026, month: 7, long: true))
        #expect(calendar.expected.reduce(0, +) == calendar.expectedTotal)
        #expect(calendar.rows.reduce(0) { $0 + $1.expectedTotal } == calendar.expectedTotal)
        #expect(calendar.expectedTotal > 0)

        // Recompute one security by hand from the engine's payments and today's position.
        let ledger = store.ledger
        let report = ledger.earnings(in: store.interval(for: .allTime), scope: .portfolio)
        let positions = ledger.snapshot(on: today, scope: .portfolio).positions
        let row = try #require(calendar.rows.first)
        let shares = try #require(positions.first { $0.securityID == row.id }?.shares)
        #expect(row.shares == shares)
        let windowStart = Day(year: 2025, month: 7, day: 1)
        let expected = report.dividendHistory(for: row.id)
            .filter { $0.day >= windowStart && $0.day <= today }
            .reduce(Int64(0)) { $0 + ($1.perShare?.value(of: shares) ?? 0) }
        #expect(row.expectedTotal == expected)
        // Dots: a month is "recent" exactly if a payment fell into it during the last twelve months.
        for month in 0..<12 {
            let paid = report.dividendHistory(for: row.id).contains { $0.day >= windowStart && $0.day <= today && $0.day.month == month + 1 }
            #expect(row.recent[month] == paid)
        }
    }

    @Test func paymentsFilterSortAndAddUp() async throws {
        let store = demoStore()
        let all = store.interval(for: .allTime)
        let newestFirst = [KeyPathComparator(\PaymentRow.day, order: .reverse)]
        let everything = PaymentsModel.Query(filter: "", month: nil, securityID: nil, sortOrder: newestFirst)
        let payments = try await store.analyze("earnings.payments", interval: all, variant: everything) { PaymentsModel($0, query: everything) }
        let report = store.ledger.earnings(in: all, scope: .portfolio)
        #expect(payments.rows.count == report.payments.count)
        #expect(payments.gross == report.total.dividends)
        #expect(payments.rows.first!.day >= payments.rows.last!.day)
        #expect(payments.rows.allSatisfy { store.transaction($0.id)?.kind == .dividend })

        let october = PaymentsModel.Query(filter: "", month: 2025 * 12 + 9, securityID: nil, sortOrder: newestFirst)
        let filtered = try await store.analyze("earnings.payments", interval: all, variant: october) { PaymentsModel($0, query: october) }
        #expect(!filtered.rows.isEmpty)
        #expect(filtered.rows.allSatisfy { $0.day.year == 2025 && $0.day.month == 10 })
        #expect(filtered.totalCount == report.payments.count)
        let month = try #require(report.months.first { $0.year == 2025 && $0.month == 10 })
        #expect(filtered.gross == month.amounts.dividends)
    }

    @Test func emptyAndScopedStates() async throws {
        var file = SampleData.demoPortfolio(today: today)
        file.transactions = []
        let empty = PortfolioStore(file: file, today: today)
        let model = try await model(empty)
        #expect(model.isEmpty)
        #expect(model.calendar.isEmpty)
        #expect(model.securities.isEmpty)
        #expect(model.tiles.samePeriodGrowth == nil)
    }

    @Test func csvIsQuotedNeutralizedAndMachineReadable() async throws {
        let table = EarningsTable(name: "T", header: ["Name", "Amount"], rows: [
            ["Plain", "12.5"], ["Has, comma", "-3"], ["=SUM(A1)", "1"], ["Say \"hi\"", "0.1"],
        ])
        let csv = EarningsExport.csv(table)
        #expect(csv == "Name,Amount\r\nPlain,12.5\r\n\"Has, comma\",-3\r\n'=SUM(A1),1\r\n\"Say \"\"hi\"\"\",0.1\r\n")

        let store = demoStore()
        let model = try await model(store)
        let matrix = EarningsExport.matrix(model, numbers: .plain)
        #expect(matrix.header.count == 16)
        #expect(matrix.rows.count == model.matrix.count + 1)
        #expect(matrix.rows.first?.first == "2017")
        #expect(matrix.rows.last?[13] == "\(Decimal(model.totalValue) / 100)")
        for view in EarningsView.allCases where view != .payments {
            let table = EarningsExport.table(for: view, model: model, grouping: .month, payments: nil)
            #expect(!table.rows.isEmpty)
            #expect(table.rows.allSatisfy { $0.count == table.header.count })
        }
    }

    @Test func formatsDerivedValuesCompactly() {
        Fmt.setLocale(Locale(identifier: "en_US"))
        #expect(EarningsFormat.perShare(Price(0.47534615), currency: "EUR") == Fmt.price(Price(0.4753), currency: "EUR"))
        #expect(EarningsFormat.perShare(nil, currency: "EUR") == Fmt.missing)
        #expect(EarningsFormat.shares(Shares(81.36014567)) == Fmt.shares(Shares(81.3601)))
        #expect(EarningsFormat.shares(Shares(75)) == "75")
    }
}
