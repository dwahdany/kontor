import Foundation
import KontorModel
import KontorEngine
import KontorUI

/// Hooks for the app's headless self-test (`Kontor --selftest`): they drive the transaction
/// editor's own model — `TransactionDraft`, its validation and `TransactionEditor.commit` — the way
/// typing into the sheet does, without a view.
public enum TransactionsSelfTest {
    /// What a user would enter in the editor. Amounts are minor units of the booking's currency,
    /// `price` is in the security's currency.
    public struct Entry: Sendable {
        public var kind: KontorModel.Transaction.Kind
        public var date: Day
        public var securityID: UUID?
        public var depotID: UUID?
        public var accountID: UUID?
        public var counterAccountID: UUID?
        public var counterDepotID: UUID?
        public var shares: Shares?
        public var price: Price?
        /// The amount field of kinds without a price (deposit, dividend gross, fee, transfer …).
        public var amount: Int64?
        public var fees: Int64?
        public var taxes: Int64?
        /// Security currency → booking currency, typed by hand (foreign-currency trades).
        public var rate: Double?
        /// Cross-currency cash transfer: what arrives on the target account.
        public var counterAmount: Int64?
        public var note: String

        public init(
            _ kind: KontorModel.Transaction.Kind, date: Day, securityID: UUID? = nil, depotID: UUID? = nil, accountID: UUID? = nil,
            counterAccountID: UUID? = nil, counterDepotID: UUID? = nil, shares: Shares? = nil, price: Price? = nil,
            amount: Int64? = nil, fees: Int64? = nil, taxes: Int64? = nil, rate: Double? = nil, counterAmount: Int64? = nil,
            note: String = ""
        ) {
            self.kind = kind
            self.date = date
            self.securityID = securityID
            self.depotID = depotID
            self.accountID = accountID
            self.counterAccountID = counterAccountID
            self.counterDepotID = counterDepotID
            self.shares = shares
            self.price = price
            self.amount = amount
            self.fees = fees
            self.taxes = taxes
            self.rate = rate
            self.counterAmount = counterAmount
            self.note = note
        }
    }

    /// Opens a draft for a new entry, types `entry` into it, validates it as the sheet's Save does
    /// and commits it. Throws if the editor would refuse to save.
    @MainActor @discardableResult
    public static func record(_ entry: Entry, in store: PortfolioStore) async throws -> KontorModel.Transaction {
        let ledger = await store.ledgerOffMain()
        let prefill = TransactionPrefill(
            kind: entry.kind, date: entry.date, securityID: entry.securityID, accountID: entry.accountID, depotID: entry.depotID,
            counterAccountID: entry.counterAccountID, counterDepotID: entry.counterDepotID)
        var draft = TransactionDraft(prefill: prefill, ledger: ledger, today: store.today)
        draft.note = entry.note
        let context = PositionContext(
            ledger: ledger, day: draft.date, securityID: draft.securityID, depotID: draft.depotID, counterDepotID: draft.counterDepotID,
            accountID: draft.accountID, counterAccountID: draft.counterAccountID, excluding: nil)
        // As the sheet does once the positions are known: a dividend (fee, tax) goes to the depot
        // that holds the security unless one was chosen.
        draft.adopt(context, choosesDepot: entry.depotID == nil)
        if let shares = entry.shares { draft.edit(.shares, shares.raw) }
        if let price = entry.price { draft.edit(.price, price.raw) }
        if let rate = entry.rate { draft.editRate(rate) }
        if let amount = entry.amount { draft.edit(entry.kind.chargeSign != 0 ? .gross : .total, amount) }
        if let fees = entry.fees { draft.edit(.fees, fees) }
        if let taxes = entry.taxes { draft.edit(.taxes, taxes) }
        if let counterAmount = entry.counterAmount { draft.edit(.counterAmount, counterAmount) }
        try validate(draft, context: context, in: store)
        return TransactionEditor.commit(draft, in: store)
    }

    /// Opens an existing entry in the editor's model, changes its note and saves — the Edit path.
    @MainActor @discardableResult
    public static func editNote(of id: UUID, to note: String, in store: PortfolioStore) async throws -> KontorModel.Transaction {
        guard let transaction = store.transaction(id) else { throw SelfTestFailure("transaction \(id) does not exist") }
        let ledger = await store.ledgerOffMain()
        var draft = TransactionDraft(editing: transaction, ledger: ledger)
        guard draft.makeTransaction() == transaction else {
            throw SelfTestFailure("opening and saving a \(transaction.kind.rawValue) unchanged would alter it")
        }
        draft.note = note
        let context = PositionContext(
            ledger: ledger, day: draft.date, securityID: draft.securityID, depotID: draft.depotID, counterDepotID: draft.counterDepotID,
            accountID: draft.accountID, counterAccountID: draft.counterAccountID, excluding: transaction)
        try validate(draft, context: context, in: store)
        return TransactionEditor.commit(draft, in: store)
    }

    /// Every stored transaction survives "open in the editor, save unchanged". Returns the ids of
    /// those that would not.
    @MainActor
    public static func unstableRoundTrips(in store: PortfolioStore) async -> [UUID] {
        let ledger = await store.ledgerOffMain()
        return store.file.transactions.filter { TransactionDraft(editing: $0, ledger: ledger).makeTransaction() != $0 }.map(\.id)
    }

    @MainActor
    private static func validate(_ draft: TransactionDraft, context: PositionContext, in store: PortfolioStore) throws {
        let issues = draft.issues(
            context: context, today: store.today,
            names: .init(account: store.account(draft.accountID)?.name, depot: store.depot(draft.depotID)?.name))
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw SelfTestFailure("the editor refuses the \(draft.kind.rawValue): " + errors.map(\.message).joined(separator: " / "))
        }
    }
}
