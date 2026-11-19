import Foundation
import KontorModel
import KontorUI

/// Hooks for the app's headless self-test (`Kontor --selftest`): the account and depot editors'
/// save paths, without a view.
public enum AccountsSelfTest {
    /// "New Account" → name, currency → Add Account.
    @MainActor @discardableResult
    public static func addAccount(name: String, currency: CurrencyCode, in store: PortfolioStore) throws -> UUID {
        let draft = Account(name: name, currency: currency)
        AccountEditor.commit(draft, isNew: true, in: store)
        guard store.account(draft.id)?.currency == currency else { throw SelfTestFailure("the account “\(name)” was not added") }
        return draft.id
    }

    /// "New Depot" → name, reference account → Add Depot.
    @MainActor @discardableResult
    public static func addDepot(name: String, referenceAccountID: UUID?, in store: PortfolioStore) throws -> UUID {
        let draft = Depot(name: name, referenceAccountID: referenceAccountID)
        DepotEditor.commit(draft, isNew: true, in: store)
        guard store.depot(draft.id) != nil else { throw SelfTestFailure("the depot “\(name)” was not added") }
        return draft.id
    }

    /// Edit Account → rename → Save.
    @MainActor
    public static func renameAccount(_ id: UUID, to name: String, in store: PortfolioStore) throws {
        guard var account = store.account(id) else { throw SelfTestFailure("account \(id) does not exist") }
        account.name = name
        AccountEditor.commit(account, isNew: false, in: store)
        guard store.account(id)?.name == name else { throw SelfTestFailure("the account was not renamed") }
    }
}
