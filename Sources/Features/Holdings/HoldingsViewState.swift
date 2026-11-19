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
    /// Changes requested (by palette commands) before the screen applied its stored settings; the
    /// screen runs them right after seeding, so they win over the restored values.
    @ObservationIgnored private var changesAfterSeeding: [@MainActor (HoldingsViewState) -> Void] = []
    /// The row the table should scroll to: set when the selection changes from outside the table
    /// (a route, a click in a chart). The table clears it once it has scrolled.
    var revealTarget: String?

    private nonisolated(unsafe) static var key: UInt8 = 0

    static func of(_ store: PortfolioStore) -> HoldingsViewState {
        if let existing = objc_getAssociatedObject(store, &key) as? HoldingsViewState { return existing }
        let state = HoldingsViewState()
        objc_setAssociatedObject(store, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// The statement day, never after today.
    func day(in store: PortfolioStore) -> Day { min(day ?? store.today, store.today) }

    /// The window's reporting period resolved against the statement day. The statement day is
    /// authoritative: holdings are always those of that day, whatever the period.
    func statementPeriod(in store: PortfolioStore) -> HoldingsStatementPeriod {
        HoldingsStatementPeriod(period: store.period, day: day(in: store), firstTransactionDay: store.inception)
    }

    /// The interval of the period figures (see `HoldingsStatementPeriod`).
    func interval(in store: PortfolioStore) -> DayInterval { statementPeriod(in: store).interval }

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
        let period = statementPeriod(in: store)
        return HoldingsQuery(grouping: grouping, taxonomy: taxonomy, day: period.day, hasPeriodFigures: period.hasFigures)
    }

    /// The lines the table shows: everything except the rows of collapsed groups.
    var visibleLines: [HoldingRow] {
        collapsed.isEmpty ? display.lines : display.lines.filter { row in row.groupID.map { !collapsed.contains($0) } ?? true }
    }

    /// The rows the actions apply to: the selected entity rows in table order. Rows hidden in a
    /// collapsed group are not acted on — the user cannot see that they are selected.
    var selectedRows: [HoldingRow] {
        visibleLines.filter { selection.contains($0.id) && $0.isEntity }
    }

    /// Selects a line from outside the table (route, chart click): expands its group and asks the
    /// table to scroll to it.
    func reveal(_ id: String) {
        guard let row = display.rowsByID[id] else { return }
        if let group = row.groupID { collapsed.remove(group) }
        if selection != [id] { selection = [id] }
        revealTarget = id
    }

    /// Applies a view change requested from outside the screen (palette command). Before the screen
    /// has restored its stored settings the change is queued, so restoring cannot be skipped or
    /// overwrite it.
    func apply(_ change: @escaping @MainActor (HoldingsViewState) -> Void) {
        if isSeeded { change(self) } else { changesAfterSeeding.append(change) }
    }

    /// Called by the screen once stored settings and launch state are in place.
    func finishSeeding() {
        isSeeded = true
        let changes = changesAfterSeeding
        changesAfterSeeding = []
        for change in changes { change(self) }
    }
}

/// The window's reporting period seen from the statement day.
///
/// The statement day decides what is held; the period only decides which stretch TTWROR, IRR,
/// dividends and realized gains cover:
///
/// * rolling periods (YTD, 1Y, Max …) end on the statement day;
/// * a fixed period (calendar year, custom range) that contains the statement day is cut off there;
/// * a fixed period that ended before the statement day keeps its own dates — the table then shows
///   the holdings of the statement day with the figures of that earlier period;
/// * a period that begins on or after the statement day has no figures (never a synthetic one-day
///   interval, whose annualized IRR would be meaningless).
struct HoldingsStatementPeriod: Hashable, Sendable {
    enum Coverage: Hashable, Sendable {
        /// The period as selected, ending on the statement day.
        case full
        /// A fixed period cut off at the statement day.
        case clipped
        /// A fixed period that ended before the statement day.
        case ended
        /// The period lies after the statement day (or has no length): no period figures.
        case unavailable
    }

    var day: Day
    /// The interval of the period figures. For `.unavailable` a placeholder ending on the statement
    /// day; nothing but the statement itself may be derived from it.
    var interval: DayInterval
    var coverage: Coverage

    var hasFigures: Bool { coverage != .unavailable }

    init(period: ReportingPeriod, day: Day, firstTransactionDay: Day?) {
        self.day = day
        let placeholder = DayInterval(start: day.advanced(by: -1), end: day)
        switch period {
        case .custom(let from, let to):
            let fixed = DayInterval(start: from, end: to)
            if day <= fixed.start || fixed.dayCount == 0 {
                interval = placeholder
                coverage = .unavailable
            } else if day < fixed.end {
                interval = DayInterval(start: fixed.start, end: day)
                coverage = .clipped
            } else {
                interval = fixed
                coverage = day == fixed.end ? .full : .ended
            }
        case .year:
            // The engine ends a running year on "today" — here: on the statement day.
            let resolved = period.interval(today: day, firstTransactionDay: firstTransactionDay)
            if day <= resolved.start {
                interval = placeholder
                coverage = .unavailable
            } else {
                interval = resolved
                coverage = resolved.end < day ? .ended : .full
            }
        default:
            let resolved = period.interval(today: day, firstTransactionDay: firstTransactionDay)
            if resolved.end == day, resolved.start < day {
                interval = resolved
                coverage = .full
            } else {
                interval = placeholder
                coverage = .unavailable
            }
        }
    }

    /// The period's short label for tiles, saying so when the figures cover less than the picker shows.
    func shortTitle(of period: ReportingPeriod) -> String {
        coverage == .clipped ? "\(period.shortTitle) to \(Fmt.day(day, style: .medium))" : period.shortTitle
    }

    /// The period's full title, e.g. "Last year", "2024", "2024-01-01 – 2024-06-30 to 31 Mar 2024".
    func title(of period: ReportingPeriod) -> String {
        coverage == .clipped ? "\(period.title) to \(Fmt.day(day, style: .medium))" : period.title
    }

    /// One sentence for the user when the figures do not simply cover the selected period up to
    /// the statement day; nil in the ordinary case.
    func note(of period: ReportingPeriod) -> String? {
        let statement = Fmt.day(day, style: .medium)
        switch coverage {
        case .full:
            return nil
        case .clipped:
            return "The statement day \(statement) lies inside the selected period, so TTWROR, IRR, dividends and realized gains cover it only up to that day."
        case .ended:
            return "The selected period ended on \(Fmt.day(interval.end, style: .medium)), before the statement day. The table shows the holdings of \(statement) with the TTWROR, IRR, dividends and realized gains of that period."
        case .unavailable:
            return "The selected period begins after the statement day \(statement), so there are no TTWROR, IRR, dividends or realized gains to show. Choose an earlier period or a later statement day."
        }
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
