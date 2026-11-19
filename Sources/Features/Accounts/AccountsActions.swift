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
        if includesReorder {
            Divider()
            Button("Move Up", systemImage: "arrow.up") { move(entity, by: -1, in: store) }
                .disabled(!canMove(entity, by: -1, in: store.file))
            Button("Move Down", systemImage: "arrow.down") { move(entity, by: 1, in: store) }
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
