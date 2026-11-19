import SwiftUI
import KontorUI

/// Shared chrome of the two editors: a grouped form with a Cancel / Save bar.
private struct EditorFrame<Content: View>: View {
    @Environment(PortfolioStore.self) private var store
    let title: String
    let symbol: String
    let saveTitle: String
    let canSave: Bool
    let onDelete: (() -> Void)?
    let onSave: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.top, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.xs)

            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack {
                if let onDelete {
                    Button("Delete…", role: .destructive, action: onDelete)
                        .help("Delete — you will see exactly what goes with it first")
                }
                Spacer()
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A caption under a form row: why something is the way it is.
private struct Explanation: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Cash account

/// Creates or edits a cash account (`.newAccount(prefill)` / `.editAccount(id)`).
struct AccountEditor: View {
    @Environment(PortfolioStore.self) private var store
    private let editingID: UUID?
    private let prefill: AccountPrefill

    @State private var draft = Account(name: "", currency: "EUR")
    @State private var isLoaded = false
    /// Evaluated once when the sheet opens (the document cannot change underneath a modal sheet).
    @State private var currencyLock = AccountCurrencyLock.open
    @FocusState private var nameFocused: Bool

    init(prefill: AccountPrefill) {
        editingID = nil
        self.prefill = prefill
    }

    init(editing id: UUID) {
        editingID = id
        prefill = AccountPrefill()
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameIsTaken: Bool {
        !trimmedName.isEmpty && store.file.accounts.contains { $0.id != draft.id && $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        EditorFrame(
            title: editingID == nil ? "New Cash Account" : "Edit Cash Account", symbol: "creditcard",
            saveTitle: editingID == nil ? "Add Account" : "Save", canSave: !trimmedName.isEmpty,
            onDelete: editingID.map { id in { store.dismissSheet(); AccountsActions.delete(.account(id), in: store) } },
            onSave: save
        ) {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Settlement Account"))
                    .focused($nameFocused)
                if nameIsTaken {
                    Explanation(symbol: "exclamationmark.triangle.fill", text: "Another account is already called “\(trimmedName)”. That works, but the two are hard to tell apart in pickers.", tint: DS.Colors.warning)
                }
                if currencyLock.isLocked {
                    LabeledContent("Currency") {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.tertiary)
                            Text("\(draft.currency) – \(Currencies.name(draft.currency))")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Currencies.name(draft.currency)), locked")
                    }
                } else {
                    LabeledContent("Currency") {
                        CurrencyPicker(selection: $draft.currency, preferred: store.file.currencies).frame(width: 220)
                    }
                }
                Explanation(symbol: "info.circle", text: currencyLock.explanation(currency: draft.currency))
            }
            Section {
                TextField("Note", text: $draft.note, prompt: Text("Bank, IBAN, purpose…"), axis: .vertical)
                    .lineLimit(2...4)
            }
            if editingID != nil {
                Section {
                    Toggle("Retired", isOn: $draft.isRetired)
                    Explanation(symbol: "archivebox", text: "Retired accounts keep their history and still count towards your net worth, but move to the bottom of the list and are no longer offered for new transactions.")
                }
            }
        }
        .onAppear(perform: load)
    }

    static func currencyLock(_ id: UUID, in store: PortfolioStore) -> AccountCurrencyLock {
        AccountCurrencyLock.evaluate(account: id, bookedTransactions: store.transactions(forAccount: id).count, plans: store.file.plans)
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        if let editingID {
            guard let account = store.account(editingID) else { return store.dismissSheet() }
            draft = account
            currencyLock = Self.currencyLock(editingID, in: store)
        } else {
            draft = Account(name: prefill.name ?? "", currency: prefill.currency ?? store.baseCurrency)
            nameFocused = true
        }
    }

    private func save() {
        Self.commit(draft, isNew: editingID == nil, in: store)
        store.dismissSheet()
    }

    /// What "Save" does with the draft (also driven by the app's self-test).
    static func commit(_ draft: Account, isNew: Bool, in store: PortfolioStore) {
        var account = draft
        account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.note = account.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            store.addAccount(account)
        } else {
            // The currency of an account with bookings or plans never changes, whatever the draft says.
            if Self.currencyLock(account.id, in: store).isLocked, let current = store.account(account.id) { account.currency = current.currency }
            store.updateAccount(account)
        }
    }
}

// MARK: - Depot

/// Creates or edits a depot (`.newDepot(prefill)` / `.editDepot(id)`).
struct DepotEditor: View {
    @Environment(PortfolioStore.self) private var store
    private let editingID: UUID?
    private let prefill: DepotPrefill

    @State private var draft = Depot(name: "")
    @State private var isLoaded = false
    @FocusState private var nameFocused: Bool

    init(prefill: DepotPrefill) {
        editingID = nil
        self.prefill = prefill
    }

    init(editing id: UUID) {
        editingID = id
        prefill = DepotPrefill()
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameIsTaken: Bool {
        !trimmedName.isEmpty && store.file.depots.contains { $0.id != draft.id && $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        EditorFrame(
            title: editingID == nil ? "New Depot" : "Edit Depot", symbol: "briefcase",
            saveTitle: editingID == nil ? "Add Depot" : "Save", canSave: !trimmedName.isEmpty,
            onDelete: editingID.map { id in { store.dismissSheet(); AccountsActions.delete(.depot(id), in: store) } },
            onSave: save
        ) {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Main Depot"))
                    .focused($nameFocused)
                if nameIsTaken {
                    Explanation(symbol: "exclamationmark.triangle.fill", text: "Another depot is already called “\(trimmedName)”. That works, but the two are hard to tell apart in pickers.", tint: DS.Colors.warning)
                }
            }
            Section {
                LabeledContent("Reference Account") {
                    AccountPicker(selection: $draft.referenceAccountID, allowsNone: true).frame(width: 220)
                }
                if store.file.accounts.isEmpty {
                    Explanation(symbol: "info.circle", text: "There is no cash account yet. You can add one later and link it here; until then, record holdings as deliveries.")
                } else {
                    Explanation(symbol: "info.circle", text: "The cash account that purchases, sales and dividends of this depot are settled on by default. You can still choose another account for any single transaction.")
                }
            }
            Section {
                TextField("Note", text: $draft.note, prompt: Text("Broker, depot number…"), axis: .vertical)
                    .lineLimit(2...4)
            }
            if editingID != nil {
                Section {
                    Toggle("Retired", isOn: $draft.isRetired)
                    Explanation(symbol: "archivebox", text: "Retired depots keep their history and positions, but move to the bottom of the list and are no longer offered for new transactions.")
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        if let editingID {
            guard let depot = store.depot(editingID) else { return store.dismissSheet() }
            draft = depot
        } else {
            let fallback = store.file.accounts.count == 1 ? store.file.accounts.first?.id : nil
            draft = Depot(name: prefill.name ?? "", referenceAccountID: prefill.referenceAccountID.flatMap { store.account($0)?.id } ?? fallback)
            nameFocused = true
        }
    }

    private func save() {
        Self.commit(draft, isNew: editingID == nil, in: store)
        store.dismissSheet()
    }

    /// What "Save" does with the draft (also driven by the app's self-test).
    static func commit(_ draft: Depot, isNew: Bool, in store: PortfolioStore) {
        var depot = draft
        depot.name = depot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        depot.note = depot.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew { store.addDepot(depot) } else { store.updateDepot(depot) }
    }
}
