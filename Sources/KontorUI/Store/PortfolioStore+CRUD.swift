import Foundation
import KontorModel

/// What still refers to an entity — show this in the confirmation before a cascading delete.
public struct EntityUsage: Equatable, Sendable {
    public var transactions = 0
    public var plans = 0
    public var classifications = 0
    public var watchlists = 0
    public var depots = 0

    public var isUnused: Bool { transactions + plans + classifications + watchlists + depots == 0 }

    /// "12 transactions, 1 plan"; empty when unused.
    public var summary: String {
        func part(_ n: Int, _ singular: String) -> String? { n == 0 ? nil : "\(n) \(singular)\(n == 1 ? "" : "s")" }
        return [
            part(transactions, "transaction"), part(plans, "plan"), part(classifications, "classification"),
            part(watchlists, "watchlist"), part(depots, "depot"),
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Entity CRUD
//
// Every method is one undo step. Deleting an entity that others refer to also removes those
// references (transactions, plan links, taxonomy assignments, …) — so call the matching `usage(…)`
// first and ask the user (`store.confirm(…)` or the `confirmDelete…` helpers) before deleting.

extension PortfolioStore {
    // MARK: Transactions

    public func addTransaction(_ transaction: Transaction) {
        mutate("Add Transaction") { $0.transactions.append(transaction) }
    }

    public func addTransactions(_ transactions: [Transaction], actionName: String = "Add Transactions") {
        guard !transactions.isEmpty else { return }
        mutate(actionName) { $0.transactions.append(contentsOf: transactions) }
    }

    /// Replaces the transaction with the same id. Does nothing if it no longer exists.
    public func updateTransaction(_ transaction: Transaction) {
        mutate("Edit Transaction") { file in
            if let i = file.transactions.firstIndex(where: { $0.id == transaction.id }) { file.transactions[i] = transaction }
        }
    }

    public func deleteTransactions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Transaction" : "Delete Transactions") { file in
            file.transactions.removeAll { ids.contains($0.id) }
        }
    }

    public func deleteTransaction(_ id: UUID) { deleteTransactions([id]) }

    // MARK: Securities

    public func addSecurity(_ security: Security) {
        mutate("Add Security") { $0.securities.append(security) }
    }

    public func updateSecurity(_ security: Security) {
        mutate("Edit Security") { file in
            if let i = file.securities.firstIndex(where: { $0.id == security.id }) { file.securities[i] = security }
        }
    }

    /// Edits one security in place (cheaper than `updateSecurity` for large price histories).
    public func updateSecurity(_ id: UUID, actionName: String = "Edit Security", undoable: Bool = true, _ body: (inout Security) -> Void) {
        mutate(actionName, undoable: undoable) { file in
            if let i = file.securities.firstIndex(where: { $0.id == id }) { body(&file.securities[i]) }
        }
    }

    public func usage(ofSecurities ids: Set<UUID>) -> EntityUsage {
        var usage = EntityUsage()
        for t in file.transactions where t.securityID.map(ids.contains) == true { usage.transactions += 1 }
        for p in file.plans where p.securityID.map(ids.contains) == true { usage.plans += 1 }
        for w in file.watchlists where w.securityIDs.contains(where: ids.contains) { usage.watchlists += 1 }
        for taxonomy in file.taxonomies {
            Self.forEachClassification(taxonomy.root) { c in
                if c.assignments.contains(where: { $0.securityID.map(ids.contains) == true }) { usage.classifications += 1 }
            }
        }
        return usage
    }

    /// Deletes securities **and everything that refers to them**: their transactions, plans,
    /// taxonomy assignments, watchlist entries and benchmark settings.
    public func deleteSecurities(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Security" : "Delete Securities") { file in
            file.securities.removeAll { ids.contains($0.id) }
            file.transactions.removeAll { $0.securityID.map(ids.contains) == true }
            file.plans.removeAll { $0.securityID.map(ids.contains) == true }
            for i in file.watchlists.indices where file.watchlists[i].securityIDs.contains(where: ids.contains) {
                file.watchlists[i].securityIDs.removeAll(where: ids.contains)
            }
            if file.settings.benchmarkSecurityIDs.contains(where: ids.contains) {
                file.settings.benchmarkSecurityIDs.removeAll(where: ids.contains)
            }
            Self.removeAssignments(in: &file.taxonomies) { $0.securityID.map(ids.contains) == true }
        }
    }

    // MARK: Accounts

    public func addAccount(_ account: Account) {
        mutate("Add Account") { $0.accounts.append(account) }
    }

    public func updateAccount(_ account: Account) {
        mutate("Edit Account") { file in
            if let i = file.accounts.firstIndex(where: { $0.id == account.id }) { file.accounts[i] = account }
        }
    }

    public func usage(ofAccounts ids: Set<UUID>) -> EntityUsage {
        var usage = EntityUsage()
        for t in file.transactions
        where t.accountID.map(ids.contains) == true || t.counterAccountID.map(ids.contains) == true {
            usage.transactions += 1
        }
        for p in file.plans where p.accountID.map(ids.contains) == true { usage.plans += 1 }
        for d in file.depots where d.referenceAccountID.map(ids.contains) == true { usage.depots += 1 }
        for taxonomy in file.taxonomies {
            Self.forEachClassification(taxonomy.root) { c in
                if c.assignments.contains(where: { $0.accountID.map(ids.contains) == true }) { usage.classifications += 1 }
            }
        }
        return usage
    }

    /// Deletes accounts **and everything that refers to them**: transactions booked on them
    /// (including transfers to/from them), plans, taxonomy assignments; depots lose their reference account.
    public func deleteAccounts(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Account" : "Delete Accounts") { file in
            file.accounts.removeAll { ids.contains($0.id) }
            file.transactions.removeAll {
                $0.accountID.map(ids.contains) == true || $0.counterAccountID.map(ids.contains) == true
            }
            file.plans.removeAll { $0.accountID.map(ids.contains) == true }
            for i in file.depots.indices where file.depots[i].referenceAccountID.map(ids.contains) == true {
                file.depots[i].referenceAccountID = nil
            }
            Self.removeAssignments(in: &file.taxonomies) { $0.accountID.map(ids.contains) == true }
        }
    }

    // MARK: Depots

    public func addDepot(_ depot: Depot) {
        mutate("Add Depot") { $0.depots.append(depot) }
    }

    public func updateDepot(_ depot: Depot) {
        mutate("Edit Depot") { file in
            if let i = file.depots.firstIndex(where: { $0.id == depot.id }) { file.depots[i] = depot }
        }
    }

    public func usage(ofDepots ids: Set<UUID>) -> EntityUsage {
        var usage = EntityUsage()
        for t in file.transactions
        where t.depotID.map(ids.contains) == true || t.counterDepotID.map(ids.contains) == true {
            usage.transactions += 1
        }
        for p in file.plans where p.depotID.map(ids.contains) == true { usage.plans += 1 }
        return usage
    }

    /// Deletes depots together with the transactions booked in them and the plans targeting them.
    public func deleteDepots(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Depot" : "Delete Depots") { file in
            file.depots.removeAll { ids.contains($0.id) }
            file.transactions.removeAll {
                $0.depotID.map(ids.contains) == true || $0.counterDepotID.map(ids.contains) == true
            }
            file.plans.removeAll { $0.depotID.map(ids.contains) == true }
        }
    }

    // MARK: Plans, watchlists, taxonomies, dashboards

    public func addPlan(_ plan: InvestmentPlan) {
        mutate("Add Plan") { $0.plans.append(plan) }
    }

    public func updatePlan(_ plan: InvestmentPlan) {
        mutate("Edit Plan") { file in
            if let i = file.plans.firstIndex(where: { $0.id == plan.id }) { file.plans[i] = plan }
        }
    }

    public func deletePlans(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Plan" : "Delete Plans") { file in file.plans.removeAll { ids.contains($0.id) } }
    }

    /// Inserts or replaces a watchlist (matched by id).
    public func upsertWatchlist(_ watchlist: Watchlist) {
        mutate("Edit Watchlist") { file in
            if let i = file.watchlists.firstIndex(where: { $0.id == watchlist.id }) {
                file.watchlists[i] = watchlist
            } else {
                file.watchlists.append(watchlist)
            }
        }
    }

    public func deleteWatchlist(_ id: UUID) {
        mutate("Delete Watchlist") { file in file.watchlists.removeAll { $0.id == id } }
    }

    /// Inserts or replaces a taxonomy (matched by id).
    public func upsertTaxonomy(_ taxonomy: Taxonomy, actionName: String = "Edit Taxonomy") {
        mutate(actionName) { file in
            if let i = file.taxonomies.firstIndex(where: { $0.id == taxonomy.id }) {
                file.taxonomies[i] = taxonomy
            } else {
                file.taxonomies.append(taxonomy)
            }
        }
    }

    public func deleteTaxonomy(_ id: UUID) {
        mutate("Delete Taxonomy") { file in file.taxonomies.removeAll { $0.id == id } }
    }

    /// Inserts or replaces a dashboard (matched by id).
    public func upsertDashboard(_ dashboard: Dashboard, actionName: String = "Edit Dashboard") {
        mutate(actionName) { file in
            if let i = file.dashboards.firstIndex(where: { $0.id == dashboard.id }) {
                file.dashboards[i] = dashboard
            } else {
                file.dashboards.append(dashboard)
            }
        }
    }

    public func deleteDashboard(_ id: UUID) {
        mutate("Delete Dashboard") { file in file.dashboards.removeAll { $0.id == id } }
    }

    /// Edits the document-level settings (base currency, cost method, benchmarks, …).
    public func updateSettings(_ actionName: String = "Change Portfolio Settings", _ body: (inout Settings) -> Void) {
        mutate(actionName) { body(&$0.settings) }
    }

    public func rename(_ name: String) {
        mutate("Rename Portfolio") { $0.name = name }
    }

    // MARK: Confirmed deletes

    /// Deletes securities, asking first if anything refers to them.
    public func confirmDeleteSecurities(_ ids: Set<UUID>) {
        let names = ids.compactMap { security($0)?.name }
        confirmDelete(noun: "security", plural: "securities", names: names, usage: usage(ofSecurities: ids)) { [weak self] in
            self?.deleteSecurities(ids)
        }
    }

    /// Deletes accounts, asking first if anything refers to them.
    public func confirmDeleteAccounts(_ ids: Set<UUID>) {
        let names = ids.compactMap { account($0)?.name }
        confirmDelete(noun: "account", plural: "accounts", names: names, usage: usage(ofAccounts: ids)) { [weak self] in
            self?.deleteAccounts(ids)
        }
    }

    /// Deletes depots, asking first if anything refers to them.
    public func confirmDeleteDepots(_ ids: Set<UUID>) {
        let names = ids.compactMap { depot($0)?.name }
        confirmDelete(noun: "depot", plural: "depots", names: names, usage: usage(ofDepots: ids)) { [weak self] in
            self?.deleteDepots(ids)
        }
    }

    private func confirmDelete(
        noun: String, plural: String, names: [String], usage: EntityUsage, action: @escaping @MainActor () -> Void
    ) {
        guard !names.isEmpty else { return }
        guard !usage.isUnused else { return action() }
        let subject = names.count == 1 ? "“\(names[0])”" : "\(names.count) \(plural)"
        confirm(ConfirmationRequest(
            title: "Delete \(subject)?",
            message: "This also removes everything that refers to \(names.count == 1 ? "this \(noun)" : "these \(plural)"): \(usage.summary). You can undo this.",
            action: action
        ))
    }

    // MARK: Taxonomy helpers

    static func forEachClassification(_ nodes: [Classification], _ visit: (Classification) -> Void) {
        for node in nodes {
            visit(node)
            forEachClassification(node.children, visit)
        }
    }

    /// Removes matching assignments without touching (and thereby copying) unaffected subtrees.
    static func removeAssignments(in taxonomies: inout [Taxonomy], where matches: (Classification.Assignment) -> Bool) {
        func prune(_ nodes: inout [Classification]) {
            for i in nodes.indices {
                if nodes[i].assignments.contains(where: matches) { nodes[i].assignments.removeAll(where: matches) }
                if !nodes[i].children.isEmpty { prune(&nodes[i].children) }
            }
        }
        for i in taxonomies.indices { prune(&taxonomies[i].root) }
    }
}
