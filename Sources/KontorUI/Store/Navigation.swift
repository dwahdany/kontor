import Foundation
import SwiftUI

/// The top-level screens of a portfolio window. Each one is implemented by exactly one feature target.
public enum AppScreen: String, CaseIterable, Identifiable, Codable, Sendable {
    case dashboard, holdings, performance
    case allocation, earnings, trades
    case securities, transactions, accounts, plans
    case `import`

    public var id: String { rawValue }

    /// Sidebar grouping.
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case overview, analysis, data, tools
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .overview: "Overview"
            case .analysis: "Analysis"
            case .data: "Data"
            case .tools: "Tools"
            }
        }
        public var screens: [AppScreen] { AppScreen.allCases.filter { $0.section == self } }
    }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .holdings: "Holdings"
        case .performance: "Performance"
        case .allocation: "Allocation"
        case .earnings: "Earnings"
        case .trades: "Trades"
        case .securities: "Securities"
        case .transactions: "Transactions"
        case .accounts: "Accounts"
        case .plans: "Plans"
        case .import: "Import"
        }
    }

    /// One-line description used by placeholders, the command palette and tooltips.
    public var summary: String {
        switch self {
        case .dashboard: "Your portfolio at a glance"
        case .holdings: "Current positions and their value"
        case .performance: "Returns, benchmarks and risk over time"
        case .allocation: "Asset classes, targets and rebalancing"
        case .earnings: "Dividends and interest by period"
        case .trades: "Closed and open trades with realised gains"
        case .securities: "Instruments, quotes and price history"
        case .transactions: "The complete ledger"
        case .accounts: "Cash accounts and depots"
        case .plans: "Savings plans and recurring bookings"
        case .import: "Bring in data from files and other apps"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .holdings: "briefcase"
        case .performance: "chart.xyaxis.line"
        case .allocation: "chart.pie"
        case .earnings: "banknote"
        case .trades: "arrow.left.arrow.right"
        case .securities: "building.columns"
        case .transactions: "list.bullet.rectangle"
        case .accounts: "creditcard"
        case .plans: "calendar.badge.clock"
        case .import: "square.and.arrow.down"
        }
    }

    public var section: Section {
        switch self {
        case .dashboard, .holdings, .performance: .overview
        case .allocation, .earnings, .trades: .analysis
        case .securities, .transactions, .accounts, .plans: .data
        case .import: .tools
        }
    }

    /// ⌘1 … ⌘9 for the first nine screens, ⌘0 for Plans. Import is reached with ⇧⌘I (File ▸ Import…).
    public var shortcutKey: KeyEquivalent? {
        switch self {
        case .dashboard: "1"
        case .holdings: "2"
        case .performance: "3"
        case .allocation: "4"
        case .earnings: "5"
        case .trades: "6"
        case .securities: "7"
        case .transactions: "8"
        case .accounts: "9"
        case .plans: "0"
        case .import: nil
        }
    }

    /// Human-readable shortcut ("⌘1") for menus drawn by hand, e.g. the command palette.
    public var shortcutHint: String? { shortcutKey.map { "⌘\($0.character)" } }
}

/// A navigation target: a screen plus, optionally, the entity it should focus.
///
/// ```swift
/// store.navigate(to: .security(id))          // Securities screen, that security selected
/// store.navigate(to: Route(.transactions))   // just switch screens
/// ```
public struct Route: Hashable, Codable, Sendable {
    /// The entity a screen is asked to select / scroll to / show details for.
    public enum Focus: Hashable, Codable, Sendable {
        case security(UUID)
        case account(UUID)
        case depot(UUID)
        case transaction(UUID)
        case plan(UUID)
        case taxonomy(UUID)
        case classification(taxonomy: UUID, id: UUID)
    }

    public var screen: AppScreen
    public var focus: Focus?

    public init(_ screen: AppScreen, focus: Focus? = nil) {
        self.screen = screen
        self.focus = focus
    }

    public static func screen(_ screen: AppScreen) -> Route { Route(screen) }
    public static func security(_ id: UUID) -> Route { Route(.securities, focus: .security(id)) }
    public static func account(_ id: UUID) -> Route { Route(.accounts, focus: .account(id)) }
    public static func depot(_ id: UUID) -> Route { Route(.accounts, focus: .depot(id)) }
    public static func transaction(_ id: UUID) -> Route { Route(.transactions, focus: .transaction(id)) }
    public static func plan(_ id: UUID) -> Route { Route(.plans, focus: .plan(id)) }
    public static func taxonomy(_ id: UUID) -> Route { Route(.allocation, focus: .taxonomy(id)) }

    /// Compact text form used by `--route` and scene storage: `holdings`, `security:<uuid>`,
    /// `account:<uuid>`, `depot:<uuid>`, `transaction:<uuid>`, `plan:<uuid>`, `taxonomy:<uuid>`,
    /// or `<screen>/<kind>:<uuid>` to combine an arbitrary screen with a focus.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        var screenPart: Substring?
        var focusPart = Substring(trimmed)
        if let slash = trimmed.firstIndex(of: "/") {
            screenPart = trimmed[..<slash]
            focusPart = trimmed[trimmed.index(after: slash)...]
        }
        if let colon = focusPart.firstIndex(of: ":") {
            guard let id = UUID(uuidString: String(focusPart[focusPart.index(after: colon)...])) else { return nil }
            let route: Route
            switch focusPart[..<colon] {
            case "security": route = .security(id)
            case "account": route = .account(id)
            case "depot": route = .depot(id)
            case "transaction": route = .transaction(id)
            case "plan": route = .plan(id)
            case "taxonomy": route = .taxonomy(id)
            default: return nil
            }
            self = route
            if let screenPart {
                guard let screen = AppScreen(rawValue: String(screenPart)) else { return nil }
                self.screen = screen
            }
        } else {
            guard screenPart == nil, let screen = AppScreen(rawValue: trimmed) else { return nil }
            self.init(screen)
        }
    }

    public var stringValue: String {
        guard let focus else { return screen.rawValue }
        let focusText: String
        switch focus {
        case .security(let id): focusText = "security:\(id.uuidString)"
        case .account(let id): focusText = "account:\(id.uuidString)"
        case .depot(let id): focusText = "depot:\(id.uuidString)"
        case .transaction(let id): focusText = "transaction:\(id.uuidString)"
        case .plan(let id): focusText = "plan:\(id.uuidString)"
        case .taxonomy(let id), .classification(let id, _): focusText = "taxonomy:\(id.uuidString)"
        }
        return "\(screen.rawValue)/\(focusText)"
    }
}
