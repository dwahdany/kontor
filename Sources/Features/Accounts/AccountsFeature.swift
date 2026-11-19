import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Accounts feature with the app shell. The executable lists `AccountsFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Accounts` needs to change.
///
/// Sheets owned: `.newAccount(AccountPrefill)`, `.editAccount(id)`, `.newDepot(DepotPrefill)`,
/// `.editDepot(id)`. Routes honoured: `.account(id)`, `.depot(id)`.
public enum AccountsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.accounts) { AccountsScreen() }
            .commands { store in commands(store) }
            .inspector { AccountsInspector() }
            .sheet { request in
                if case .newAccount(let prefill) = request {
                    AccountEditor(prefill: prefill)
                } else if case .editAccount(let id) = request {
                    AccountEditor(editing: id)
                } else if case .newDepot(let prefill) = request {
                    DepotEditor(prefill: prefill)
                } else if case .editDepot(let id) = request {
                    DepotEditor(editing: id)
                }
            }
    }

    /// Command-palette entries. The shell already lists every account and depot and the "New …"
    /// commands; this adds transfers, the balance export and the actions on the open account or depot.
    @MainActor static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        var result = [
            PaletteCommand(id: "accounts.transfer", title: "Transfer Between Accounts…", symbol: Transaction.Kind.cashTransfer.symbol,
                           keywords: ["move", "cash transfer"]) {
                store.present(.newTransaction(TransactionPrefill(kind: .cashTransfer, date: store.today, accountID: store.route.accountID)))
            },
            PaletteCommand(id: "accounts.copy-balances", title: "Copy Account Balances", subtitle: "Tab-separated, for a spreadsheet",
                           symbol: "doc.on.doc", keywords: ["export", "clipboard", "tsv"]) {
                let today = store.today
                Task {
                    guard let overview = try? await store.analyze("accounts.overview", scope: .portfolio, variant: today, { analysis in
                        AccountsOverview(analysis, today: today)
                    }) else { return }
                    Pasteboard.copy(overview.tsv)
                    store.toast("Copied \(overview.accounts.count + overview.depots.count) balances", style: .success)
                }
            },
        ]
        let focused: AccountsEntity? = store.route.accountID.map { .account($0) } ?? store.route.depotID.map { .depot($0) }
        if store.route.screen == .accounts, let focused {
            let name: String
            let kinds: [Transaction.Kind]
            switch focused {
            case .account(let id):
                name = store.account(id)?.name ?? ""
                kinds = AccountsActions.accountKinds
            case .depot(let id):
                name = store.depot(id)?.name ?? ""
                kinds = AccountsActions.depotKinds
            }
            for kind in kinds {
                result.append(PaletteCommand(
                    id: "accounts.record.\(kind.rawValue)", title: "\(kind.title)…", subtitle: name, symbol: kind.symbol,
                    keywords: ["record", "new", AccountsActions.verb(kind)]) {
                        switch focused {
                        case .account(let id): AccountsActions.record(kind, account: id, in: store)
                        case .depot(let id): AccountsActions.record(kind, depot: id, in: store)
                        }
                    })
            }
            let retired = AccountsActions.isRetired(focused, in: store)
            result.append(PaletteCommand(id: "accounts.edit", title: "Edit “\(name)”…", symbol: "pencil") {
                switch focused {
                case .account(let id): store.present(.editAccount(id))
                case .depot(let id): store.present(.editDepot(id))
                }
            })
            result.append(PaletteCommand(id: "accounts.retire", title: retired ? "Reactivate “\(name)”" : "Retire “\(name)”",
                                         symbol: retired ? "arrow.uturn.backward" : "archivebox", keywords: ["archive", "hide", "close"]) {
                AccountsActions.setRetired(!retired, focused, in: store)
            })
            result.append(PaletteCommand(id: "accounts.delete", title: "Delete “\(name)”…", symbol: "trash", keywords: ["remove"]) {
                AccountsActions.delete(focused, in: store)
            })
        }
        return result
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
