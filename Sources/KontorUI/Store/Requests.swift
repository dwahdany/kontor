import Foundation
import KontorModel

/// Initial values for a new transaction (everything optional — the editor fills in defaults).
///
/// ```swift
/// store.present(.newTransaction(TransactionPrefill(kind: .buy, securityID: id, depotID: depot)))
/// store.present(.newTransaction(TransactionPrefill(copying: transaction, date: store.today)))   // "Duplicate"
/// ```
public struct TransactionPrefill: Hashable, Sendable {
    public var kind: Transaction.Kind?
    public var date: Day?
    public var securityID: UUID?
    public var accountID: UUID?
    public var depotID: UUID?
    /// Target of a cash transfer.
    public var counterAccountID: UUID?
    /// Target of a security transfer.
    public var counterDepotID: UUID?
    public var shares: Shares?
    /// Total amount (see the sign conventions of `Transaction`).
    public var amount: Money?
    public var fees: Int64?
    public var taxes: Int64?
    public var note: String?
    /// `Transaction.source` of the new entry, e.g. a plan's `sourceTag`.
    public var source: String?

    public init(
        kind: Transaction.Kind? = nil, date: Day? = nil, securityID: UUID? = nil, accountID: UUID? = nil,
        depotID: UUID? = nil, counterAccountID: UUID? = nil, counterDepotID: UUID? = nil, shares: Shares? = nil,
        amount: Money? = nil, fees: Int64? = nil, taxes: Int64? = nil, note: String? = nil, source: String? = nil
    ) {
        self.kind = kind
        self.date = date
        self.securityID = securityID
        self.accountID = accountID
        self.depotID = depotID
        self.counterAccountID = counterAccountID
        self.counterDepotID = counterDepotID
        self.shares = shares
        self.amount = amount
        self.fees = fees
        self.taxes = taxes
        self.note = note
        self.source = source
    }

    /// Everything of an existing transaction (for "Duplicate"), optionally on another day.
    public init(copying transaction: Transaction, date: Day? = nil) {
        self.init(
            kind: transaction.kind, date: date ?? transaction.date, securityID: transaction.securityID,
            accountID: transaction.accountID, depotID: transaction.depotID, counterAccountID: transaction.counterAccountID,
            counterDepotID: transaction.counterDepotID, shares: transaction.shares.isZero ? nil : transaction.shares,
            amount: transaction.amount, fees: transaction.fees == 0 ? nil : transaction.fees,
            taxes: transaction.taxes == 0 ? nil : transaction.taxes, note: transaction.note.isEmpty ? nil : transaction.note)
    }
}

/// Initial values for a new security (e.g. from an import row or a search result).
public struct SecurityPrefill: Hashable, Sendable {
    public var name: String?
    public var currency: CurrencyCode?
    public var isin: String?
    public var wkn: String?
    public var ticker: String?
    public var feed: QuoteFeed?

    public init(
        name: String? = nil, currency: CurrencyCode? = nil, isin: String? = nil, wkn: String? = nil, ticker: String? = nil,
        feed: QuoteFeed? = nil
    ) {
        self.name = name
        self.currency = currency
        self.isin = isin
        self.wkn = wkn
        self.ticker = ticker
        self.feed = feed
    }
}

/// Initial values for a new cash account.
public struct AccountPrefill: Hashable, Sendable {
    public var name: String?
    public var currency: CurrencyCode?

    public init(name: String? = nil, currency: CurrencyCode? = nil) {
        self.name = name
        self.currency = currency
    }
}

/// Initial values for a new depot.
public struct DepotPrefill: Hashable, Sendable {
    public var name: String?
    public var referenceAccountID: UUID?

    public init(name: String? = nil, referenceAccountID: UUID? = nil) {
        self.name = name
        self.referenceAccountID = referenceAccountID
    }
}

/// Initial values for a new investment plan.
public struct PlanPrefill: Hashable, Sendable {
    public var kind: InvestmentPlan.Kind?
    public var securityID: UUID?
    public var depotID: UUID?
    public var accountID: UUID?
    public var amount: Money?
    public var start: Day?

    public init(
        kind: InvestmentPlan.Kind? = nil, securityID: UUID? = nil, depotID: UUID? = nil, accountID: UUID? = nil,
        amount: Money? = nil, start: Day? = nil
    ) {
        self.kind = kind
        self.securityID = securityID
        self.depotID = depotID
        self.accountID = accountID
        self.amount = amount
        self.start = start
    }
}

/// What an export sheet should offer first.
public struct ExportRequest: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// The whole portfolio (the user picks the format: JSON copy, Portfolio Performance XML, CSV).
        case portfolio
        /// The ledger as CSV; `only` restricts it to a selection.
        case transactions(only: Set<UUID>? = nil)
        /// The list of securities as CSV.
        case securities
        /// The price history of one security as CSV.
        case quotes(securityID: UUID)
    }

    public var content: Content

    public init(_ content: Content = .portfolio) {
        self.content = content
    }
}

/// A sheet some part of the app wants presented. Any feature may *request* a sheet with
/// `store.present(_:)`; the feature that owns the editor *provides* it through its `FeatureModule`.
/// This is how e.g. Holdings opens the transaction editor without depending on FeatureTransactions.
///
/// | request | provided by |
/// |---|---|
/// | `.newTransaction`, `.editTransaction` | FeatureTransactions |
/// | `.newSecurity`, `.editSecurity` | FeatureSecurities |
/// | `.newAccount`, `.editAccount`, `.newDepot`, `.editDepot` | FeatureAccounts |
/// | `.newPlan`, `.editPlan` | FeaturePlans |
/// | `.importFile`, `.export` | FeatureImport |
/// | `.portfolioSettings`, `.consistencyReport` | the shell |
/// | `.custom(id:payload:)` | whoever claims the id (namespace it: `"allocation.rebalance"`) |
public enum SheetRequest: Hashable, Identifiable, Sendable {
    case newTransaction(TransactionPrefill)
    case editTransaction(UUID)
    case newSecurity(SecurityPrefill)
    case editSecurity(UUID)
    case newAccount(AccountPrefill)
    case editAccount(UUID)
    case newDepot(DepotPrefill)
    case editDepot(UUID)
    case newPlan(PlanPrefill)
    case editPlan(UUID)
    /// Import a file (Portfolio Performance XML, CSV, …). `nil` lets the importer ask for a file.
    case importFile(URL?)
    /// Export the portfolio or a part of it.
    case export(ExportRequest)
    case portfolioSettings
    case consistencyReport
    /// Escape hatch for feature-private sheets: `id` namespaced by feature ("allocation.rebalance").
    case custom(id: String, payload: [String: String] = [:])

    public var id: Self { self }

    public static var newTransaction: SheetRequest { .newTransaction(TransactionPrefill()) }
    public static var newSecurity: SheetRequest { .newSecurity(SecurityPrefill()) }
    public static var newAccount: SheetRequest { .newAccount(AccountPrefill()) }
    public static var newDepot: SheetRequest { .newDepot(DepotPrefill()) }
    public static var newPlan: SheetRequest { .newPlan(PlanPrefill()) }
    public static var importFile: SheetRequest { .importFile(nil) }
    public static var export: SheetRequest { .export(ExportRequest()) }

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
        case .export: "Export"
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
        case .export: "square.and.arrow.up"
        case .portfolioSettings: "slider.horizontal.3"
        case .consistencyReport: "checkmark.seal"
        case .custom: "rectangle.on.rectangle"
        }
    }

    /// Parses the text form used by the screenshot mode's `--sheet` option:
    ///
    /// ```
    /// new-transaction            new-transaction:<kind>         (kind = Transaction.Kind raw value, e.g. buy)
    /// edit-transaction:<uuid>    edit-transaction:first
    /// new-security               edit-security:<uuid>|first
    /// new-account                edit-account:<uuid>|first
    /// new-depot                  edit-depot:<uuid>|first
    /// new-plan                   edit-plan:<uuid>|first
    /// import                     import:<path>
    /// export                     export:transactions | export:securities | export:quotes:<uuid>|first
    /// portfolio-settings         consistency
    /// custom:<id>                custom:<id>?key=value&key=value
    /// ```
    ///
    /// `first` picks the first entity of that kind in `file` (transactions: the chronologically
    /// first). Returns nil for malformed text, unknown ids and `first` on an empty collection.
    public static func parse(_ text: String, in file: PortfolioFile) -> SheetRequest? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let name: Substring, argument: Substring?
        if let colon = text.firstIndex(of: ":") {
            name = text[..<colon]
            argument = text[text.index(after: colon)...]
        } else {
            name = Substring(text)
            argument = nil
        }
        func entity<E: Identifiable>(_ items: [E], first: (() -> E?)? = nil) -> UUID? where E.ID == UUID {
            guard let argument else { return nil }
            if argument == "first" { return (first?() ?? items.first)?.id }
            guard let id = UUID(uuidString: String(argument)) else { return nil }
            return items.contains { $0.id == id } ? id : nil
        }
        switch name {
        case "new-transaction":
            guard let argument else { return .newTransaction }
            guard let kind = Transaction.Kind(rawValue: String(argument)) else { return nil }
            return .newTransaction(TransactionPrefill(kind: kind))
        case "edit-transaction":
            return entity(file.transactions) { file.transactions.min(by: Transaction.chronological) }.map { .editTransaction($0) }
        case "new-security": return argument == nil ? .newSecurity : nil
        case "edit-security": return entity(file.securities).map { .editSecurity($0) }
        case "new-account": return argument == nil ? .newAccount : nil
        case "edit-account": return entity(file.accounts).map { .editAccount($0) }
        case "new-depot": return argument == nil ? .newDepot : nil
        case "edit-depot": return entity(file.depots).map { .editDepot($0) }
        case "new-plan": return argument == nil ? .newPlan : nil
        case "edit-plan": return entity(file.plans).map { .editPlan($0) }
        case "import":
            guard let argument else { return .importFile(nil) }
            guard !argument.isEmpty else { return nil }
            return .importFile(URL(fileURLWithPath: (String(argument) as NSString).expandingTildeInPath))
        case "export":
            guard let argument else { return .export }
            if argument == "portfolio" { return .export }
            if argument == "transactions" { return .export(ExportRequest(.transactions())) }
            if argument == "securities" { return .export(ExportRequest(.securities)) }
            if argument.hasPrefix("quotes:") {
                let value = argument.dropFirst("quotes:".count)
                let id = value == "first" ? file.securities.first?.id : UUID(uuidString: String(value)).flatMap { id in file.securities.contains { $0.id == id } ? id : nil }
                return id.map { .export(ExportRequest(.quotes(securityID: $0))) }
            }
            return nil
        case "portfolio-settings": return argument == nil ? .portfolioSettings : nil
        case "consistency": return argument == nil ? .consistencyReport : nil
        case "custom":
            guard let argument, !argument.isEmpty else { return nil }
            var id = String(argument)
            var payload: [String: String] = [:]
            if let question = argument.firstIndex(of: "?") {
                id = String(argument[..<question])
                for pair in argument[argument.index(after: question)...].split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, !parts[0].isEmpty else { return nil }
                    payload[String(parts[0])] = String(parts[1])
                }
            }
            return id.isEmpty ? nil : .custom(id: id, payload: payload)
        default:
            return nil
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

/// Operations implemented by the executable (they need AppKit panels); features call
/// `store.services.…`.
public struct PortfolioServices {
    /// Lets the user choose a file to import, then issues `.importFile(url)`.
    public var chooseImportFile: (@MainActor (PortfolioStore) -> Void)?

    public init() {}
}
