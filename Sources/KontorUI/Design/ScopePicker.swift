import SwiftUI
import KontorModel
import KontorEngine

/// A toolbar control that narrows a screen to a part of the portfolio: the whole portfolio, one
/// depot, one cash account, or a classification of a taxonomy.
///
/// Without arguments it edits the window's shared scope (`store.scopeSelection`), so every screen
/// that shows a `ScopePicker` follows the same choice; pass a binding for a screen-local scope.
///
/// ```swift
/// .toolbar { ToolbarItem { ScopePicker() } }
/// // then compute with store.scope — analysisTask does so by default
/// ```
///
/// In a toolbar, pass the store (`ScopePicker(store: store)`): toolbar items are hosted outside the
/// screen's view tree, and the picker renders nothing rather than trapping if the environment is
/// not there (for example while a window is being torn down).
public struct ScopePicker: View {
    @Environment(PortfolioStore.self) private var environmentStore: PortfolioStore?
    private let explicitStore: PortfolioStore?
    private let external: Binding<ScopeSelection>?
    private let includesAccounts: Bool
    private let includesClassifications: Bool

    /// Bound to the window's scope.
    /// - Parameters:
    ///   - accounts: Offer single cash accounts (screens about securities may leave them out).
    ///   - classifications: Offer taxonomy classifications.
    public init(store: PortfolioStore? = nil, accounts: Bool = true, classifications: Bool = true) {
        explicitStore = store
        external = nil
        includesAccounts = accounts
        includesClassifications = classifications
    }

    /// Bound to a local selection.
    public init(selection: Binding<ScopeSelection>, store: PortfolioStore? = nil, accounts: Bool = true, classifications: Bool = true) {
        explicitStore = store
        external = selection
        includesAccounts = accounts
        includesClassifications = classifications
    }

    public var body: some View {
        if let store = explicitStore ?? environmentStore {
            ScopePickerMenu(store: store, external: external, includesAccounts: includesAccounts, includesClassifications: includesClassifications)
        }
    }
}

private struct ScopePickerMenu: View {
    let store: PortfolioStore
    let external: Binding<ScopeSelection>?
    let includesAccounts: Bool
    let includesClassifications: Bool

    private var selection: ScopeSelection {
        get {
            let current = external?.wrappedValue ?? store.scopeSelection
            return current.resolve(in: store.file) == nil ? .portfolio : current
        }
        nonmutating set {
            if let external { external.wrappedValue = newValue } else { store.scopeSelection = newValue }
        }
    }

    var body: some View {
        Menu {
            item(.portfolio, title: "Whole Portfolio")
            if !depots.isEmpty {
                Section("Depots") {
                    ForEach(depots) { depot in
                        item(.depot(depot.id), title: depot.name.isEmpty ? "Untitled Depot" : depot.name)
                    }
                }
            }
            if includesAccounts, !accounts.isEmpty {
                Section("Accounts") {
                    ForEach(accounts) { account in
                        item(.account(account.id), title: account.name.isEmpty ? "Untitled Account" : account.name)
                    }
                }
            }
            if includesClassifications {
                let taxonomies = store.file.taxonomies.filter { !$0.root.isEmpty }
                if !taxonomies.isEmpty {
                    Section("Classifications") {
                        ForEach(taxonomies) { taxonomy in
                            Menu(taxonomy.name.isEmpty ? "Untitled Taxonomy" : taxonomy.name) {
                                ForEach(taxonomy.flattened, id: \.classification.id) { entry in
                                    item(
                                        .classification(taxonomy: taxonomy.id, id: entry.classification.id),
                                        title: String(repeating: "    ", count: entry.depth) + entry.classification.name)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(selection.title(in: store.file), systemImage: selection.symbol)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .help("Scope: \(selection.title(in: store.file))")
        .accessibilityLabel("Scope")
        .accessibilityValue(selection.title(in: store.file))
    }

    private var depots: [Depot] { store.file.depots.filter { !$0.isRetired || selection == .depot($0.id) } }
    private var accounts: [Account] { store.file.accounts.filter { !$0.isRetired || selection == .account($0.id) } }

    private func item(_ value: ScopeSelection, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { selection == value }, set: { if $0 { selection = value } }))
    }
}
