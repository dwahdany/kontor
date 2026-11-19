import Foundation
import KontorUI

/// Merges an imported portfolio into an existing one without duplicating what is already there.
///
/// * **Securities** are matched by ISIN, then ticker, then WKN, then name (case-insensitive) — always
///   within one currency: the same ISIN quoted in another currency is another listing with its own
///   prices and is added. An ISIN is authoritative (two different ISINs never match), every existing
///   security is matched by at most one incoming security, and the securities of the incoming file
///   are never merged with each other. Matched securities receive the incoming quotes they do not
///   have yet and any identifier they were missing; `Summary.securityMatches` lists every pair.
/// * **Accounts** are matched by name and currency, **depots** by name.
/// * **Transactions** that already exist — same kind, date, security, shares and amount in the same
///   account (the depot for bookings that move shares, the cash account otherwise) — are skipped;
///   everything else is appended with its references re-pointed.
/// * **Taxonomies** with a new name are added. One whose name exists is merged into the existing
///   taxonomy: classifications are matched by name level by level, missing ones are added, and
///   securities and accounts the existing taxonomy has not classified yet receive the incoming
///   assignments (what is already classified stays as it is).
/// * **Plans** are matched by name, kind and security; the executions of a matched plan are
///   re-tagged to the existing plan. **Watchlists** are added unless one with the same name exists.
/// * **Exchange rates** are merged per currency pair. Settings and dashboards are left alone.
///
/// Pure and deterministic; the result is applied through `store.mutate`, so it is one undo step.
enum PortfolioMerge {
    /// An incoming security that was recognised as one the portfolio already has.
    struct SecurityMatch: Sendable, Hashable, Identifiable {
        enum Rule: Int, Sendable, Hashable, Comparable {
            // Weakest first: that is the order in which a person should check them.
            case name, wkn, ticker, isin

            static func < (a: Rule, b: Rule) -> Bool { a.rawValue < b.rawValue }

            var title: String {
                switch self {
                case .isin: "same ISIN"
                case .ticker: "same ticker"
                case .wkn: "same WKN"
                case .name: "same name"
                }
            }
        }

        /// The id of the existing security.
        var id: UUID
        var incomingName: String
        var existingName: String
        var currency: CurrencyCode
        var rule: Rule
        /// The identifier both share ("IE00B4L5Y983", "ACM"); the name for name matches.
        var identifier: String
    }

    struct Summary: Sendable, Hashable {
        var addedSecurities = 0
        var matchedSecurities = 0
        var addedAccounts = 0
        var matchedAccounts = 0
        var addedDepots = 0
        var matchedDepots = 0
        var addedTransactions = 0
        var skippedTransactions = 0
        var addedPrices = 0
        var addedTaxonomies = 0
        /// Existing taxonomies of the same name that received classifications or assignments.
        var mergedTaxonomies = 0
        /// Securities and accounts newly classified in those taxonomies (counted per taxonomy).
        var addedAssignments = 0
        /// Existing taxonomies of the same name the file had nothing new for.
        var skippedTaxonomies = 0
        var addedPlans = 0
        var addedWatchlists = 0
        /// Every incoming security matched to an existing one, weakest evidence first.
        var securityMatches: [SecurityMatch] = []
        /// Names of the matched cash accounts and depots.
        var accountMatches: [String] = []
        var depotMatches: [String] = []

        var changesNothing: Bool {
            addedSecurities + addedAccounts + addedDepots + addedTransactions + addedPrices + addedTaxonomies + mergedTaxonomies
                + addedPlans + addedWatchlists == 0
        }
    }

    struct Result: Sendable {
        var file: PortfolioFile
        var summary: Summary
        /// Ids (in `file`) of the transactions that were added.
        var addedTransactionIDs: [UUID]
    }

    /// - Parameter source: the import's tag; the plan executions that are added are recorded under it
    ///   (`ImportRecord`), so that "Recent Imports" can count and remove them.
    static func merge(_ incoming: PortfolioFile, into existing: PortfolioFile, recordAs source: String? = nil) -> Result {
        var file = existing
        var summary = Summary()

        // Securities — matched against the securities that existed before the merge only.
        var index: [SecurityMatch.Rule: [String: [Int]]] = [.isin: [:], .ticker: [:], .wkn: [:], .name: [:]]
        for (position, security) in file.securities.enumerated() {
            if let key = key(security.isin) { index[.isin]?[key, default: []].append(position) }
            if let key = key(security.ticker) { index[.ticker]?[key, default: []].append(position) }
            if let key = key(security.wkn) { index[.wkn]?[key, default: []].append(position) }
            if let key = key(security.name) { index[.name]?[key, default: []].append(position) }
        }
        var taken = Set<Int>()
        var usedIDs = Set(file.securities.map(\.id))
        var securityMap: [UUID: UUID] = [:]
        for security in incoming.securities {
            let isin = key(security.isin)
            func find(_ rule: SecurityMatch.Rule, _ text: String) -> (position: Int, rule: SecurityMatch.Rule, identifier: String)? {
                guard let key = key(text), let candidates = index[rule]?[key] else { return nil }
                let position = candidates.first { position in
                    let candidate = file.securities[position]
                    // Another currency is another listing; and each existing security stands for one incoming security.
                    guard !taken.contains(position), candidate.currency == security.currency else { return false }
                    // An ISIN is authoritative: never match a security that carries a different one.
                    if rule != .isin, let isin, let other = PortfolioMerge.key(candidate.isin), other != isin { return false }
                    return true
                }
                return position.map { ($0, rule, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            let match = find(.isin, security.isin) ?? find(.ticker, security.ticker) ?? find(.wkn, security.wkn) ?? find(.name, security.name)
            if let match {
                let position = match.position
                taken.insert(position)
                securityMap[security.id] = file.securities[position].id
                summary.matchedSecurities += 1
                summary.securityMatches.append(SecurityMatch(
                    id: file.securities[position].id, incomingName: security.name, existingName: file.securities[position].name,
                    currency: security.currency, rule: match.rule, identifier: match.identifier))
                // Only quotes for days the existing security has none for: the user's own data wins.
                let known = Set(file.securities[position].prices.days)
                let fresh = security.prices.filter { !known.contains($0.day.rawValue) }
                if !fresh.isEmpty { summary.addedPrices += file.securities[position].prices.merge(fresh) }
                if file.securities[position].isin.isEmpty { file.securities[position].isin = security.isin }
                if file.securities[position].wkn.isEmpty { file.securities[position].wkn = security.wkn }
                if file.securities[position].ticker.isEmpty { file.securities[position].ticker = security.ticker }
                if file.securities[position].feed == nil { file.securities[position].feed = security.feed }
            } else {
                var added = security
                if !usedIDs.insert(added.id).inserted {
                    added.id = UUID()
                    usedIDs.insert(added.id)
                }
                securityMap[security.id] = added.id
                file.securities.append(added)
                summary.addedSecurities += 1
                summary.addedPrices += added.prices.count
            }
        }
        summary.securityMatches.sort { a, b in
            a.rule != b.rule ? a.rule < b.rule : a.existingName.localizedStandardCompare(b.existingName) == .orderedAscending
        }

        // Accounts
        var accountMap: [UUID: UUID] = [:]
        var accountIDs = Set(file.accounts.map(\.id))
        for account in incoming.accounts {
            if let match = file.accounts.first(where: { key($0.name) == key(account.name) && $0.currency == account.currency }) {
                accountMap[account.id] = match.id
                summary.matchedAccounts += 1
                summary.accountMatches.append(match.name)
            } else {
                var added = account
                if !accountIDs.insert(added.id).inserted {
                    added.id = UUID()
                    accountIDs.insert(added.id)
                }
                accountMap[account.id] = added.id
                file.accounts.append(added)
                summary.addedAccounts += 1
            }
        }

        // Depots
        var depotMap: [UUID: UUID] = [:]
        var depotIDs = Set(file.depots.map(\.id))
        for depot in incoming.depots {
            if let match = file.depots.first(where: { key($0.name) == key(depot.name) }) {
                depotMap[depot.id] = match.id
                summary.matchedDepots += 1
                summary.depotMatches.append(match.name)
            } else {
                var added = depot
                if !depotIDs.insert(added.id).inserted {
                    added.id = UUID()
                    depotIDs.insert(added.id)
                }
                added.referenceAccountID = depot.referenceAccountID.flatMap { accountMap[$0] }
                depotMap[depot.id] = added.id
                file.depots.append(added)
                summary.addedDepots += 1
            }
        }

        // Plans — before the transactions, whose plan tags follow a matched plan.
        var planMap: [UUID: UUID] = [:]
        var planIDs = Set(file.plans.map(\.id))
        for plan in incoming.plans {
            var added = plan
            added.securityID = plan.securityID.flatMap { securityMap[$0] }
            added.accountID = plan.accountID.flatMap { accountMap[$0] }
            added.depotID = plan.depotID.flatMap { depotMap[$0] }
            if let match = file.plans.first(where: {
                $0.id == plan.id || (key($0.name) == key(plan.name) && $0.kind == plan.kind && $0.securityID == added.securityID)
            }) {
                planMap[plan.id] = match.id
                continue
            }
            if !planIDs.insert(added.id).inserted {
                added.id = UUID()
                planIDs.insert(added.id)
            }
            planMap[plan.id] = added.id
            file.plans.append(added)
            summary.addedPlans += 1
        }

        // Transactions
        struct Fingerprint: Hashable {
            var kind: Transaction.Kind, date: Day, security: UUID?, shares: Int64, amount: Int64, currency: CurrencyCode
            var account: UUID?, depot: UUID?
            init(_ t: Transaction) {
                kind = t.kind; date = t.date; security = t.securityID; shares = t.shares.raw; amount = t.amount.minor
                currency = t.amount.currency
                // Like the CSV importer: the securities account identifies bookings that move shares, the
                // cash account all others (Portfolio Performance keeps no depot on dividends, fees and taxes).
                if t.kind.sharesSign != 0 {
                    depot = t.depotID
                } else {
                    account = t.accountID
                }
            }
        }
        // Counted, so that two identical bookings on one day in the incoming file survive when only one exists.
        var present: [Fingerprint: Int] = [:]
        for transaction in file.transactions { present[Fingerprint(transaction), default: 0] += 1 }
        var transactionIDs = Set(file.transactions.map(\.id))
        var addedIDs: [UUID] = []
        var addedExecutions: [Transaction] = []
        file.transactions.reserveCapacity(file.transactions.count + incoming.transactions.count)
        for transaction in incoming.transactions {
            var added = transaction
            added.securityID = transaction.securityID.flatMap { securityMap[$0] }
            added.accountID = transaction.accountID.flatMap { accountMap[$0] }
            added.counterAccountID = transaction.counterAccountID.flatMap { accountMap[$0] }
            added.depotID = transaction.depotID.flatMap { depotMap[$0] }
            added.counterDepotID = transaction.counterDepotID.flatMap { depotMap[$0] }
            let planID = ImportRecord.planID(of: transaction)
            if let planID, let target = planMap[planID], target != planID {
                added.source = "plan:\(target.uuidString)"
            }
            let fingerprint = Fingerprint(added)
            if let count = present[fingerprint], count > 0 {
                present[fingerprint] = count - 1
                summary.skippedTransactions += 1
                continue
            }
            if !transactionIDs.insert(added.id).inserted {
                added.id = UUID()
                transactionIDs.insert(added.id)
            }
            file.transactions.append(added)
            addedIDs.append(added.id)
            if planID != nil { addedExecutions.append(added) }
            summary.addedTransactions += 1
        }
        if let source {
            ImportRecord(planExecutionsIn: addedExecutions)?.write(for: source, to: &file.settings.preferences)
        }

        // Taxonomies
        for taxonomy in incoming.taxonomies {
            var remapped = taxonomy
            remapped.root = taxonomy.root.map { remap($0, securities: securityMap, accounts: accountMap) }
            if let position = file.taxonomies.firstIndex(where: { key($0.name) == key(taxonomy.name) || $0.id == taxonomy.id }) {
                var merger = TaxonomyMerger(existing: file.taxonomies[position])
                file.taxonomies[position].root = merger.merge(remapped.root, into: file.taxonomies[position].root)
                if merger.changed {
                    summary.mergedTaxonomies += 1
                    summary.addedAssignments += merger.assignedCount
                } else {
                    summary.skippedTaxonomies += 1
                }
            } else {
                file.taxonomies.append(remapped)
                summary.addedTaxonomies += 1
            }
        }

        // Watchlists
        for watchlist in incoming.watchlists
        where !file.watchlists.contains(where: { key($0.name) == key(watchlist.name) || $0.id == watchlist.id }) {
            var added = watchlist
            added.securityIDs = watchlist.securityIDs.compactMap { securityMap[$0] }
            file.watchlists.append(added)
            summary.addedWatchlists += 1
        }

        // Exchange rates
        for series in incoming.exchangeRates {
            if let position = file.exchangeRates.firstIndex(where: { $0.base == series.base && $0.quote == series.quote }) {
                let known = Set(file.exchangeRates[position].days)
                let fresh = zip(series.days, series.rates).filter { !known.contains($0.0) }
                if !fresh.isEmpty {
                    file.exchangeRates[position].merge(fresh.map { (day: Day(rawValue: $0.0), rate: $0.1) })
                }
            } else {
                file.exchangeRates.append(series)
            }
        }

        return Result(file: file, summary: summary, addedTransactionIDs: addedIDs)
    }

    /// Two names that differ only in case and surrounding space.
    static func sameName(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    fileprivate static func key(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func remap(_ classification: Classification, securities: [UUID: UUID], accounts: [UUID: UUID]) -> Classification {
        var result = classification
        result.assignments = classification.assignments.compactMap { assignment in
            var mapped = assignment
            if let id = assignment.securityID {
                guard let target = securities[id] else { return nil }
                mapped.securityID = target
            }
            if let id = assignment.accountID {
                guard let target = accounts[id] else { return nil }
                mapped.accountID = target
            }
            return mapped
        }
        result.children = classification.children.map { remap($0, securities: securities, accounts: accounts) }
        return result
    }
}

/// Merges the classification tree of an incoming taxonomy into an existing one of the same name.
private struct TaxonomyMerger {
    /// A security or an account.
    private struct Vehicle: Hashable {
        var security: UUID?
        var account: UUID?
        init(_ assignment: Classification.Assignment) {
            security = assignment.securityID
            account = assignment.accountID
        }
    }

    /// What the existing taxonomy classified before the merge — those assignments are the user's and stay.
    private let classified: Set<Vehicle>
    private var ids: Set<UUID>
    private var addedClassifications = 0
    private var assigned = Set<Vehicle>()

    /// Securities and accounts that were newly classified.
    var assignedCount: Int { assigned.count }
    var changed: Bool { addedClassifications > 0 || !assigned.isEmpty }

    init(existing: Taxonomy) {
        var vehicles = Set<Vehicle>()
        var ids = Set<UUID>()
        func visit(_ node: Classification) {
            ids.insert(node.id)
            for assignment in node.assignments { vehicles.insert(Vehicle(assignment)) }
            node.children.forEach(visit)
        }
        existing.root.forEach(visit)
        classified = vehicles
        self.ids = ids
    }

    mutating func merge(_ incoming: [Classification], into existing: [Classification]) -> [Classification] {
        var result = existing
        for node in incoming {
            if let position = result.firstIndex(where: { PortfolioMerge.key($0.name) == PortfolioMerge.key(node.name) }) {
                result[position].assignments += fresh(node.assignments)
                result[position].children = merge(node.children, into: result[position].children)
            } else {
                result.append(adopt(node))
                addedClassifications += 1
            }
        }
        return result
    }

    /// The assignments of vehicles the existing taxonomy had not classified.
    private mutating func fresh(_ assignments: [Classification.Assignment]) -> [Classification.Assignment] {
        let kept = assignments.filter { !classified.contains(Vehicle($0)) }
        for assignment in kept { assigned.insert(Vehicle(assignment)) }
        return kept
    }

    /// A classification the existing taxonomy does not have: taken over with its subtree.
    private mutating func adopt(_ node: Classification) -> Classification {
        var result = node
        if !ids.insert(result.id).inserted {
            result.id = UUID()
            ids.insert(result.id)
        }
        result.assignments = fresh(node.assignments)
        result.children = node.children.map { adopt($0) }
        return result
    }
}

/// An import becomes the content of a portfolio nothing was recorded in yet (`PortfolioFile.isUntouched`).
enum PortfolioReplace {
    /// `imported` as the new content of `existing`: the portfolio keeps its name, and — because a
    /// Portfolio Performance file has neither — its dashboards (re-pointed to the imported taxonomies
    /// of the same name) and, if the file brings no taxonomies at all, its taxonomy templates.
    static func apply(_ imported: PortfolioFile, to existing: PortfolioFile) -> PortfolioFile {
        var file = imported
        if !existing.name.trimmingCharacters(in: .whitespaces).isEmpty { file.name = existing.name }
        if imported.taxonomies.isEmpty {
            file.taxonomies = existing.taxonomies.map { taxonomy in
                var kept = taxonomy
                kept.root = taxonomy.root.map(withoutAssignments)
                return kept
            }
        }
        if imported.dashboards.isEmpty, !existing.dashboards.isEmpty {
            // Widgets refer to taxonomies by id: follow the name into the imported file.
            var replacements: [String: String] = [:]
            for taxonomy in existing.taxonomies {
                let key = taxonomy.name.trimmingCharacters(in: .whitespaces).lowercased()
                guard let match = file.taxonomies.first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key })
                    ?? file.taxonomies.first, match.id != taxonomy.id else { continue }
                replacements[taxonomy.id.uuidString.lowercased()] = match.id.uuidString
            }
            file.dashboards = existing.dashboards.map { dashboard in
                var kept = dashboard
                for index in kept.widgets.indices {
                    kept.widgets[index].config = kept.widgets[index].config.mapValues { replacements[$0.lowercased()] ?? $0 }
                }
                return kept
            }
        }
        return file
    }

    private static func withoutAssignments(_ classification: Classification) -> Classification {
        var result = classification
        result.assignments = []
        result.children = classification.children.map(withoutAssignments)
        return result
    }
}
