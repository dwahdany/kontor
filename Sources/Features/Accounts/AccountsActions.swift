import SwiftUI
import KontorUI

/// Every change the Accounts feature makes to the document, and the transaction requests behind
/// its quick actions. Each mutation is one named undo step.
@MainActor
enum AccountsActions {
    // MARK: Quick actions → prefilled transaction requests

    static let accountKinds: [Transaction.Kind] = [.deposit, .withdrawal, .cashTransfer, .interest, .fee]
    static let depotKinds: [Transaction.Kind] = [.buy, .sell, .deliveryIn, .deliveryOut, .securityTransfer]

    /// Short verb for a quick-action button.
    static func verb(_ kind: Transaction.Kind) -> String {
        switch kind {
        case .deposit: "Deposit"
        case .withdrawal: "Withdraw"
        case .cashTransfer, .securityTransfer: "Transfer"
        case .interest: "Interest"
        case .fee: "Fee"
        case .buy: "Buy"
        case .sell: "Sell"
        case .deliveryIn: "Deliver In"
        case .deliveryOut: "Deliver Out"
        default: kind.title
        }
    }

    static func help(_ kind: Transaction.Kind) -> String {
        switch kind {
        case .deposit: "Record money paid into this account"
        case .withdrawal: "Record money taken out of this account"
        case .cashTransfer: "Move money from this account to another one"
        case .interest: "Record interest credited to this account"
        case .fee: "Record a fee charged to this account"
        case .buy: "Record a purchase into this depot"
        case .sell: "Record a sale from this depot"
        case .deliveryIn: "Record securities delivered into this depot without a payment"
        case .deliveryOut: "Record securities leaving this depot without a payment"
        case .securityTransfer: "Move a position from this depot to another one"
        default: kind.title
        }
    }

    static func record(_ kind: Transaction.Kind, account id: UUID, in store: PortfolioStore) {
        store.present(.newTransaction(TransactionPrefill(kind: kind, date: store.today, accountID: id)))
    }

    static func record(_ kind: Transaction.Kind, depot id: UUID, in store: PortfolioStore) {
        // Purchases and sales settle on the depot's reference account by default.
        let account = kind == .buy || kind == .sell ? store.depot(id)?.referenceAccountID : nil
        store.present(.newTransaction(TransactionPrefill(kind: kind, date: store.today, accountID: account, depotID: id)))
    }

    // MARK: Hand-off to the Transactions screen

    /// The Transactions screen, listing exactly this entity's entries (the routing contract's
    /// "Show Transactions").
    static func transactionsRoute(_ entity: AccountsEntity) -> Route {
        Route(.transactions, focus: entity.focus)
    }

    static func showTransactions(_ entity: AccountsEntity, in store: PortfolioStore) {
        store.navigate(to: transactionsRoute(entity))
    }

    static func exists(_ entity: AccountsEntity, in store: PortfolioStore) -> Bool {
        switch entity {
        case .account(let id): store.account(id) != nil
        case .depot(let id): store.depot(id) != nil
        }
    }

    // MARK: Retire

    static func setRetired(_ retired: Bool, _ entity: AccountsEntity, in store: PortfolioStore) {
        switch entity {
        case .account(let id):
            store.mutate(retired ? "Retire Account" : "Reactivate Account") { file in
                if let i = file.accounts.firstIndex(where: { $0.id == id }) { file.accounts[i].isRetired = retired }
            }
        case .depot(let id):
            store.mutate(retired ? "Retire Depot" : "Reactivate Depot") { file in
                if let i = file.depots.firstIndex(where: { $0.id == id }) { file.depots[i].isRetired = retired }
            }
        }
    }

    static func isRetired(_ entity: AccountsEntity, in store: PortfolioStore) -> Bool {
        switch entity {
        case .account(let id): store.account(id)?.isRetired ?? false
        case .depot(let id): store.depot(id)?.isRetired ?? false
        }
    }

    // MARK: Reorder

    /// Whether `entity` can move one place up (`offset` −1) or down (+1) among its peers (active
    /// and retired entities are listed separately, so they are reordered separately).
    static func canMove(_ entity: AccountsEntity, by offset: Int, in file: PortfolioFile) -> Bool {
        switch entity {
        case .account(let id): swapIndex(file.accounts, id: id, offset: offset, retired: \.isRetired) != nil
        case .depot(let id): swapIndex(file.depots, id: id, offset: offset, retired: \.isRetired) != nil
        }
    }

    static func move(_ entity: AccountsEntity, by offset: Int, in store: PortfolioStore) {
        switch entity {
        case .account(let id):
            store.mutate("Reorder Accounts") { file in
                guard let i = file.accounts.firstIndex(where: { $0.id == id }),
                      let j = swapIndex(file.accounts, id: id, offset: offset, retired: \.isRetired) else { return }
                file.accounts.swapAt(i, j)
            }
        case .depot(let id):
            store.mutate("Reorder Depots") { file in
                guard let i = file.depots.firstIndex(where: { $0.id == id }),
                      let j = swapIndex(file.depots, id: id, offset: offset, retired: \.isRetired) else { return }
                file.depots.swapAt(i, j)
            }
        }
    }

    private static func swapIndex<E: Identifiable>(_ items: [E], id: UUID, offset: Int, retired: KeyPath<E, Bool>) -> Int? where E.ID == UUID {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let group = items[index][keyPath: retired]
        var j = index + offset
        while items.indices.contains(j) {
            if items[j][keyPath: retired] == group { return j }
            j += offset
        }
        return nil
    }

    // MARK: Delete

    /// What deleting an entity takes with it, in plain language.
    struct DeletionImpact: Equatable {
        var title: String
        var message: String
        /// Nothing refers to the entity: it can be deleted without asking.
        var isFree: Bool
    }

    static func deletionImpact(_ entity: AccountsEntity, in store: PortfolioStore) -> DeletionImpact? {
        func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
            "\(Fmt.integer(n)) \(n == 1 ? singular : plural ?? singular + "s")"
        }
        func list(_ parts: [String]) -> String {
            switch parts.count {
            case 0: ""
            case 1: parts[0]
            default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            }
        }
        switch entity {
        case .account(let id):
            guard let account = store.account(id) else { return nil }
            let usage = store.usage(ofAccounts: [id])
            var removed = [String]()
            if usage.transactions > 0 { removed.append(count(usage.transactions, "transaction") + " (including transfers to and from other accounts)") }
            if usage.plans > 0 { removed.append(count(usage.plans, "investment plan")) }
            if usage.classifications > 0 { removed.append(count(usage.classifications, "classification assignment")) }
            var message = removed.isEmpty ? "" : "This also deletes \(list(removed))."
            if usage.depots > 0 {
                message += (message.isEmpty ? "" : " ") + "\(count(usage.depots, "depot")) \(usage.depots == 1 ? "loses its" : "lose their") reference account."
            }
            if usage.transactions > 0 { message += " Balances and performance figures of the whole portfolio will change." }
            message += " You can undo this with ⌘Z."
            return DeletionImpact(title: "Delete “\(account.name)”?", message: message.trimmingCharacters(in: .whitespaces), isFree: usage.isUnused)
        case .depot(let id):
            guard let depot = store.depot(id) else { return nil }
            let usage = store.usage(ofDepots: [id])
            var removed = [String]()
            if usage.transactions > 0 { removed.append(count(usage.transactions, "transaction") + " (purchases, sales, deliveries and transfers of this depot)") }
            if usage.plans > 0 { removed.append(count(usage.plans, "investment plan")) }
            var message = removed.isEmpty ? "" : "This also deletes \(list(removed))."
            if usage.transactions > 0 { message += " The positions held in it disappear from the portfolio, and the cash paid or received for them is no longer booked." }
            message += " You can undo this with ⌘Z."
            return DeletionImpact(title: "Delete “\(depot.name)”?", message: message.trimmingCharacters(in: .whitespaces), isFree: usage.isUnused)
        }
    }

    /// Deletes immediately when nothing refers to the entity; otherwise asks once, spelling out
    /// exactly what goes with it. Either way it is one undoable step.
    static func delete(_ entity: AccountsEntity, in store: PortfolioStore) {
        guard let impact = deletionImpact(entity, in: store) else { return }
        let perform: @MainActor () -> Void = {
            switch entity {
            case .account(let id): store.deleteAccounts([id])
            case .depot(let id): store.deleteDepots([id])
            }
        }
        if impact.isFree {
            perform()
        } else {
            store.confirm(ConfirmationRequest(title: impact.title, message: impact.message, confirmTitle: "Delete", action: perform))
        }
    }

    // MARK: Menus shared by rows, detail headers and the inspector

    @ViewBuilder
    static func manageMenu(_ entity: AccountsEntity, store: PortfolioStore, includesReorder: Bool) -> some View {
        let retired = isRetired(entity, in: store)
        Button("Edit…", systemImage: "pencil") {
            switch entity {
            case .account(let id): store.present(.editAccount(id))
            case .depot(let id): store.present(.editDepot(id))
            }
        }
        Button("Show in Transactions", systemImage: "list.bullet.rectangle") { showTransactions(entity, in: store) }
        if includesReorder {
            Divider()
            // The list handles ⌥⌘↑ / ⌥⌘↓ for its highlighted row. The items only name the shortcut
            // (as a subtitle): a real `.keyboardShortcut` here would exist once per row.
            Button {
                move(entity, by: -1, in: store)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
                Text("⌥⌘↑ on the highlighted row")
            }
            .disabled(!canMove(entity, by: -1, in: store.file))
            Button {
                move(entity, by: 1, in: store)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
                Text("⌥⌘↓ on the highlighted row")
            }
            .disabled(!canMove(entity, by: 1, in: store.file))
        }
        Divider()
        Button(retired ? "Reactivate" : "Retire", systemImage: retired ? "arrow.uturn.backward" : "archivebox") {
            setRetired(!retired, entity, in: store)
        }
        Button("Delete…", systemImage: "trash", role: .destructive) { delete(entity, in: store) }
    }

    @ViewBuilder
    static func recordMenu(_ entity: AccountsEntity, store: PortfolioStore) -> some View {
        switch entity {
        case .account(let id):
            ForEach(accountKinds, id: \.self) { kind in
                Button(kind.title + "…", systemImage: kind.symbol) { record(kind, account: id, in: store) }
            }
        case .depot(let id):
            ForEach(depotKinds, id: \.self) { kind in
                Button(kind.title + "…", systemImage: kind.symbol) { record(kind, depot: id, in: store) }
            }
        }
    }
}

// MARK: - Rules that do not need the store

/// Why the currency of an account can no longer be changed. Every amount booked on an account —
/// and every amount an investment plan will book on it — is in the account's currency, so the
/// currency is fixed as soon as either exists.
enum AccountCurrencyLock: Equatable {
    case open
    case transactions(Int)
    case plans(Int)

    var isLocked: Bool { self != .open }

    static func evaluate(account id: UUID, bookedTransactions: Int, plans: [InvestmentPlan]) -> AccountCurrencyLock {
        if bookedTransactions > 0 { return .transactions(bookedTransactions) }
        let count = plans.filter { $0.accountID == id }.count
        return count > 0 ? .plans(count) : .open
    }

    func explanation(currency: CurrencyCode) -> String {
        switch self {
        case .open:
            "Every transaction on this account is in this currency. It can be changed until the first transaction is recorded or an investment plan uses the account."
        case .transactions(let n):
            "The currency is fixed because \(Fmt.integer(n)) transaction\(n == 1 ? " is" : "s are") booked in \(currency). Changing it would turn every one of those amounts into a different sum of money. To switch currency, add a new account and transfer the balance."
        case .plans(let n):
            "The currency is fixed because \(Fmt.integer(n)) investment plan\(n == 1 ? " books" : "s book") \(currency) amounts on this account. Point the plan\(n == 1 ? "" : "s") to another account (or delete \(n == 1 ? "it" : "them")) to change the currency."
        }
    }
}

/// What else in the document refers to an account or depot — without walking the transactions
/// (their count comes from the overview model).
struct EntityReferences: Equatable, Sendable {
    /// Depots that settle on the account.
    var depots: [String] = []
    var plans = 0
    var classifications = 0

    static func account(_ id: UUID, in file: PortfolioFile) -> EntityReferences {
        var result = EntityReferences()
        result.depots = file.depots.filter { $0.referenceAccountID == id }.map(\.name)
        result.plans = file.plans.filter { $0.accountID == id }.count
        func visit(_ nodes: [Classification]) {
            for node in nodes {
                if node.assignments.contains(where: { $0.accountID == id }) { result.classifications += 1 }
                visit(node.children)
            }
        }
        for taxonomy in file.taxonomies { visit(taxonomy.root) }
        return result
    }

    static func depot(_ id: UUID, in file: PortfolioFile) -> EntityReferences {
        EntityReferences(plans: file.plans.filter { $0.depotID == id }.count)
    }
}

/// Keyboard navigation of the overview list: everything acts on the highlighted row only while
/// that row is listed.
enum OverviewNavigation {
    /// The highlight, if its row is visible.
    static func resolved(_ highlight: AccountsEntity?, visible: [AccountsEntity]) -> AccountsEntity? {
        guard let highlight, visible.contains(highlight) else { return nil }
        return highlight
    }

    /// The row an arrow key moves to (`offset` −1 = up, +1 = down); nil if nothing is listed.
    static func moved(_ highlight: AccountsEntity?, by offset: Int, visible: [AccountsEntity]) -> AccountsEntity? {
        guard !visible.isEmpty else { return nil }
        guard let highlight, let index = visible.firstIndex(of: highlight) else { return offset > 0 ? visible.first : visible.last }
        return visible[min(max(0, index + offset), visible.count - 1)]
    }
}

/// Whether a detail page has room for its charts above a usable table. When it does not, the
/// charts step aside so that the table and its footer stay inside the window instead of the whole
/// page turning into a scroll view with the table's own scroller nested in it.
enum DetailLayout {
    static func showsCharts(available: CGFloat, fixed: CGFloat, charts: CGFloat, minTable: CGFloat) -> Bool {
        available - fixed - charts >= minTable
    }
}
