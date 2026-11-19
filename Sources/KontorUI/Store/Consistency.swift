import SwiftUI
import KontorModel
import KontorEngine

// Presentation of the engine's consistency check (`ConsistencyChecker.check(file)` /
// `ledger.consistencyIssues(options:)`): where an issue lives and how its severity looks.

extension ConsistencyIssue {
    /// Where to look to fix the issue — pass to `store.navigate(to:)`. The first involved
    /// transaction if there is one, otherwise the security, account or depot; nil for issues about
    /// the file as a whole (e.g. a missing exchange rate).
    public var route: Route? {
        if let transaction = transactionIDs.first { return .transaction(transaction) }
        if let securityID { return .security(securityID) }
        if let accountID { return .account(accountID) }
        if let depotID { return .depot(depotID) }
        return nil
    }

    /// Short headline for grouping: "Negative share position", "Stale quotes", …
    public var title: String { kind.title }
}

extension ConsistencyIssue.Kind {
    public var title: String {
        switch self {
        case .negativeShares: "Negative share position"
        case .negativeCashBalance: "Overdrawn account"
        case .missingField: "Incomplete transaction"
        case .unknownReference: "Broken reference"
        case .currencyMismatch: "Currency mismatch"
        case .invalidValue: "Invalid value"
        case .securityWithoutPrices: "No quotes"
        case .stalePrices: "Stale quotes"
        case .missingExchangeRate: "Missing exchange rate"
        case .duplicateTransactions: "Possible duplicate"
        }
    }
}

extension ConsistencyIssue.Severity {
    /// "Error", "Warning", "Hint".
    public var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Hint"
        }
    }

    /// "Errors", "Warnings", "Hints".
    public var pluralTitle: String { title + "s" }

    /// Filled SF Symbol — distinct shapes, so severity never depends on color alone.
    public var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .error: DS.Colors.red
        case .warning: DS.Colors.warning
        case .info: .secondary
        }
    }
}

extension PortfolioStore {
    /// Runs the engine's consistency check for the current revision off the main actor (memoized
    /// like every analysis request). Most severe first.
    public func consistencyIssues(staleAfterDays: Int = 10) async throws -> [ConsistencyIssue] {
        let options = ConsistencyChecker.Options(today: today, staleAfterDays: staleAfterDays)
        return try await compute(options) { ledger in ledger.consistencyIssues(options: options) }
    }
}
