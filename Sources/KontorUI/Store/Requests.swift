import Foundation
import KontorModel

/// Initial values for a new transaction (everything optional — the editor fills in defaults).
public struct TransactionPrefill: Hashable, Sendable {
    public var kind: Transaction.Kind?
    public var date: Day?
    public var securityID: UUID?
    public var accountID: UUID?
    public var depotID: UUID?
    public var shares: Shares?
    public var amount: Money?
    public var note: String?

    public init(
        kind: Transaction.Kind? = nil, date: Day? = nil, securityID: UUID? = nil, accountID: UUID? = nil,
        depotID: UUID? = nil, shares: Shares? = nil, amount: Money? = nil, note: String? = nil
    ) {
        self.kind = kind
        self.date = date
        self.securityID = securityID
        self.accountID = accountID
        self.depotID = depotID
        self.shares = shares
        self.amount = amount
        self.note = note
    }
}

/// A sheet some part of the app wants presented. Any feature may *request* a sheet with
/// `store.present(_:)`; the feature that owns the editor *provides* it through its `FeatureModule`.
/// This is how e.g. Holdings opens the transaction editor without depending on FeatureTransactions.
public enum SheetRequest: Hashable, Identifiable, Sendable {
    case newTransaction(TransactionPrefill)
    case editTransaction(UUID)
    case newSecurity
    case editSecurity(UUID)
    case newAccount
    case editAccount(UUID)
    case newDepot
    case editDepot(UUID)
    case newPlan
    case editPlan(UUID)
    /// Import a file (Portfolio Performance XML, CSV, …). `nil` lets the importer ask for a file.
    case importFile(URL?)
    case portfolioSettings
    case consistencyReport
    /// Escape hatch for feature-private sheets: `id` namespaced by feature ("allocation.rebalance").
    case custom(id: String, payload: [String: String] = [:])

    public var id: Self { self }

    public static var newTransaction: SheetRequest { .newTransaction(TransactionPrefill()) }

    /// Fallback title for requests whose feature has not registered an editor yet.
    public var title: String {
        switch self {
        case .newTransaction: "New Transaction"
        case .editTransaction: "Edit Transaction"
        case .newSecurity: "New Security"
        case .editSecurity: "Edit Security"
        case .newAccount: "New Account"
        case .editAccount: "Edit Account"
        case .newDepot: "New Depot"
        case .editDepot: "Edit Depot"
        case .newPlan: "New Plan"
        case .editPlan: "Edit Plan"
        case .importFile: "Import"
        case .portfolioSettings: "Portfolio Settings"
        case .consistencyReport: "Consistency Check"
        case .custom(let id, _): id
        }
    }

    public var symbol: String {
        switch self {
        case .newTransaction, .editTransaction: "list.bullet.rectangle"
        case .newSecurity, .editSecurity: "building.columns"
        case .newAccount, .editAccount: "creditcard"
        case .newDepot, .editDepot: "briefcase"
        case .newPlan, .editPlan: "calendar.badge.clock"
        case .importFile: "square.and.arrow.down"
        case .portfolioSettings: "slider.horizontal.3"
        case .consistencyReport: "checkmark.seal"
        case .custom: "rectangle.on.rectangle"
        }
    }
}

/// A confirmation dialog the shell presents on behalf of a feature (typically before deleting).
public struct ConfirmationRequest: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var isDestructive: Bool
    public var action: @MainActor () -> Void

    public init(
        title: String, message: String, confirmTitle: String = "Delete", isDestructive: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// A transient, non-blocking notification shown at the bottom of the window.
public struct Toast: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case info, success, warning, error }
    public let id: UUID
    public var style: Style
    public var title: String
    public var message: String?
    /// Seconds until it disappears on its own.
    public var duration: Double

    public init(_ title: String, message: String? = nil, style: Style = .info, duration: Double = 3.5) {
        self.id = UUID()
        self.style = style
        self.title = title
        self.message = message
        self.duration = duration
    }

    public var symbol: String {
        switch style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// A long-running background job shown in the toolbar/sidebar ("Updating quotes 3/14").
public struct BackgroundActivity: Equatable, Sendable {
    public var title: String
    public var completed: Int
    /// nil = indeterminate.
    public var total: Int?

    public init(title: String, completed: Int = 0, total: Int? = nil) {
        self.title = title
        self.completed = completed
        self.total = total
    }

    /// 0…1, or nil while indeterminate.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    /// "Updating quotes 3/14"
    public var statusText: String {
        guard let total else { return title }
        return "\(title) \(completed)/\(total)"
    }
}

/// Operations implemented outside the UI kit (market data, import/export engines). The executable
/// installs the real implementations; features just call `store.services.…`.
public struct PortfolioServices {
    /// Fetches the latest quotes and exchange rates and merges them into the store.
    public var updateQuotes: (@MainActor (PortfolioStore) async -> Void)?
    /// Presents the export flow for the open portfolio.
    public var export: (@MainActor (PortfolioStore) -> Void)?
    /// Lets the user choose a file to import, then issues `.importFile(url)`.
    public var chooseImportFile: (@MainActor (PortfolioStore) -> Void)?

    public init() {}
}
