import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Transactions feature with the app shell. The executable lists `TransactionsFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, sheets) is
/// declared here, so no file outside `Sources/Features/Transactions` needs to change.
///
/// Sheets provided: `.newTransaction(prefill)` and `.editTransaction(id)` — the transaction editor
/// used by the whole app — and the feature-private `.custom(id: "transactions.change-date")`.
public enum TransactionsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.transactions) { TransactionsScreen() }
            .commands { store in commands(store) }
            .sheet { request in
                if case .newTransaction(let prefill) = request {
                    TransactionEditor(mode: .new(prefill))
                } else if case .editTransaction(let id) = request {
                    TransactionEditor(mode: .edit(id))
                } else if case .custom(id: ChangeDateSheet.requestID, let payload) = request {
                    ChangeDateSheet(payload: payload)
                }
            }
    }

    /// "New Buy", "New Dividend", … for every kind, plus clipboard and export of the whole ledger.
    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        var commands = Transaction.Kind.menuOrder.map { kind in
            PaletteCommand(
                id: "transactions.new.\(kind.rawValue)", title: "New \(kind.title)", subtitle: kind.explanation, symbol: kind.symbol,
                keywords: ["add", "record", "book", "transaction", kind.group.title]
            ) {
                store.present(.newTransaction(TransactionPrefill(kind: kind)))
            }
        }
        guard !store.file.transactions.isEmpty else { return commands }
        if let last = store.file.transactions.last {
            commands.append(PaletteCommand(
                id: "transactions.repeat-last", title: "Repeat Last Transaction", subtitle: "A copy of the entry added last, dated today",
                symbol: "plus.square.on.square", keywords: ["duplicate", "again", "copy"]
            ) {
                store.present(.newTransaction(TransactionPrefill(copying: last, date: store.today)))
            })
        }
        commands.append(PaletteCommand(
            id: "transactions.copy-all", title: "Copy All Transactions as TSV", subtitle: "For Numbers, Excel or Sheets",
            symbol: "doc.on.doc", keywords: ["export", "clipboard", "spreadsheet"]
        ) {
            let today = store.today
            let count = store.file.transactions.count
            Task {
                await store.whileBusy {
                    guard let base = try? await store.compute(LedgerBaseKey(today: today), { ledger in LedgerBase(ledger, today: today) }) else { return }
                    Pasteboard.copy(await LedgerExport.tsvOffMain(base.rows))
                    store.toast("Copied \(Fmt.integer(count)) transactions", style: .success)
                }
            }
        })
        commands.append(PaletteCommand(
            id: "transactions.export", title: "Export Transactions…", symbol: "square.and.arrow.up", keywords: ["csv", "save"]
        ) {
            store.present(.export(ExportRequest(.transactions())))
        })
        return commands
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
