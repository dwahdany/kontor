import SwiftUI
import ObjectiveC
import KontorUI

/// Which chart accompanies the table.
enum HoldingsVisual: String, CaseIterable, Identifiable, Sendable {
    case table, treemap, concentration

    var id: String { rawValue }
    var title: String {
        switch self {
        case .table: "Table Only"
        case .treemap: "Treemap"
        case .concentration: "Concentration"
        }
    }
    var symbol: String {
        switch self {
        case .table: "tablecells"
        case .treemap: "square.grid.3x3.topleft.filled"
        case .concentration: "chart.bar.xaxis"
        }
    }
}

/// View state of the Holdings screen that outlives the screen view (the shell recreates screens
/// when the user navigates) and is shared with the feature's inspector and palette commands.
/// One instance per portfolio window, attached to its store.
@MainActor @Observable
final class HoldingsViewState {
    /// The statement day; nil follows `store.today`.
    var day: Day?
    var grouping = HoldingsGrouping.none
    var visual = HoldingsVisual.table
    var options = HoldingsDisplayOptions()
    var selection = Set<String>()
    /// Group ids the user collapsed.
    var collapsed = Set<String>()
    /// What the table currently shows — kept here so commands (copy, export) work without the view.
    var display = HoldingsDisplay()
    var displayedDay: Day?
    var displayedCurrency: CurrencyCode?
    /// Set once the launch state / stored settings were applied.
    var isSeeded = false

    private nonisolated(unsafe) static var key: UInt8 = 0

    static func of(_ store: PortfolioStore) -> HoldingsViewState {
        if let existing = objc_getAssociatedObject(store, &key) as? HoldingsViewState { return existing }
        let state = HoldingsViewState()
        objc_setAssociatedObject(store, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// The statement day, never after today.
    func day(in store: PortfolioStore) -> Day { min(day ?? store.today, store.today) }

    /// The reporting period resolved against the statement day: the window's period when the
    /// statement is for today, otherwise the same period ending on that day.
    func interval(in store: PortfolioStore) -> DayInterval {
        let day = day(in: store)
        if day == store.today { return store.periodInterval }
        var interval = store.period.interval(today: day, firstTransactionDay: store.inception)
        interval.end = day
        if interval.start >= day { interval.start = day.advanced(by: -1) }
        return interval
    }

    func setDay(_ newDay: Day, in store: PortfolioStore) {
        let clamped = min(newDay, store.today)
        day = clamped == store.today ? nil : clamped
    }

    /// The grouping, falling back to none when its taxonomy no longer exists.
    func resolvedGrouping(in store: PortfolioStore) -> HoldingsGrouping {
        if case .taxonomy(let id) = grouping, !store.file.taxonomies.contains(where: { $0.id == id }) { return .none }
        return grouping
    }

    func query(in store: PortfolioStore) -> HoldingsQuery {
        let grouping = resolvedGrouping(in: store)
        var taxonomy: Taxonomy?
        if case .taxonomy(let id) = grouping { taxonomy = store.file.taxonomies.first { $0.id == id } }
        return HoldingsQuery(grouping: grouping, taxonomy: taxonomy)
    }

    /// The rows the actions apply to: the selected entity rows in table order.
    var selectedRows: [HoldingRow] {
        display.lines.filter { selection.contains($0.id) && $0.isEntity }
    }
}

/// Quick jumps of the statement date.
enum HoldingsDayJump: String, CaseIterable, Identifiable {
    case today, lastMonth, lastQuarter, lastYear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .lastMonth: "End of Last Month"
        case .lastQuarter: "End of Last Quarter"
        case .lastYear: "End of Last Year"
        }
    }

    func day(today: Day) -> Day {
        switch self {
        case .today: return today
        case .lastMonth: return today.startOfMonth.advanced(by: -1)
        case .lastQuarter:
            let quarterStartMonth = (today.month - 1) / 3 * 3 + 1
            return Day(year: today.year, month: quarterStartMonth, day: 1).advanced(by: -1)
        case .lastYear: return today.startOfYear.advanced(by: -1)
        }
    }
}
