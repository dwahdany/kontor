import Foundation
import KontorUI

/// Merges an imported portfolio into an existing one without duplicating what is already there.
///
/// * **Securities** are matched by ISIN, then ticker, then WKN, then name (case-insensitive; an ISIN
///   is authoritative — two different ISINs never match). Matched securities receive the incoming
///   quotes they do not have yet and any identifier they were missing.
/// * **Accounts** are matched by name and currency, **depots** by name.
/// * **Transactions** that already exist — same kind, date, security, shares and amount in the same
///   account (the depot for bookings that move shares, the cash account otherwise) — are skipped;
///   everything else is appended with its references re-pointed.
/// * **Taxonomies, watchlists and plans** are added unless one with the same name exists.
/// * **Exchange rates** are merged per currency pair. Settings and dashboards are left alone.
///
/// Pure and deterministic; the result is applied through `store.mutate`, so it is one undo step.
enum PortfolioMerge {
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
        var skippedTaxonomies = 0
        var addedPlans = 0
        var addedWatchlists = 0

        var changesNothing: Bool {
            addedSecurities + addedAccounts + addedDepots + addedTransactions + addedPrices + addedTaxonomies + addedPlans + addedWatchlists == 0
        }
    }

    struct Result: Sendable {
        var file: PortfolioFile
        var summary: Summary
        /// Ids (in `file`) of the transactions that were added.
        var addedTransactionIDs: [UUID]
    }

    static func merge(_ incoming: PortfolioFile, into existing: PortfolioFile) -> Result {
        var file = existing
        var summary = Summary()

        // Securities
        var byISIN: [String: Int] = [:], byTicker: [String: Int] = [:], byWKN: [String: Int] = [:], byName: [String: Int] = [:]
        func index(_ security: Security, at position: Int) {
            if let key = key(security.isin), byISIN[key] == nil { byISIN[key] = position }
            if let key = key(security.ticker), byTicker[key] == nil { byTicker[key] = position }
            if let key = key(security.wkn), byWKN[key] == nil { byWKN[key] = position }
            if let key = key(security.name), byName[key] == nil { byName[key] = position }
        }
        for (position, security) in file.securities.enumerated() { index(security, at: position) }
        var usedIDs = Set(file.securities.map(\.id))
        var securityMap: [UUID: UUID] = [:]
        for security in incoming.securities {
            let isin = key(security.isin)
            func compatible(_ position: Int?) -> Int? {
                guard let position else { return nil }
                // An ISIN is authoritative: never match a security that carries a different one.
                if let isin, let other = key(file.securities[position].isin), other != isin { return nil }
                return position
            }
            let match = isin.flatMap { byISIN[$0] }
                ?? compatible(key(security.ticker).flatMap { byTicker[$0] })
                ?? compatible(key(security.wkn).flatMap { byWKN[$0] })
                ?? compatible(key(security.name).flatMap { byName[$0] }).flatMap { file.securities[$0].currency == security.currency ? $0 : nil }
            if let match {
                securityMap[security.id] = file.securities[match].id
                summary.matchedSecurities += 1
                // Only quotes for days the existing security has none for: the user's own data wins.
                let known = Set(file.securities[match].prices.days)
                let fresh = security.prices.filter { !known.contains($0.day.rawValue) }
                if !fresh.isEmpty { summary.addedPrices += file.securities[match].prices.merge(fresh) }
                if file.securities[match].isin.isEmpty { file.securities[match].isin = security.isin }
                if file.securities[match].wkn.isEmpty { file.securities[match].wkn = security.wkn }
                if file.securities[match].ticker.isEmpty { file.securities[match].ticker = security.ticker }
                if file.securities[match].feed == nil { file.securities[match].feed = security.feed }
            } else {
                var added = security
                if !usedIDs.insert(added.id).inserted {
                    added.id = UUID()
                    usedIDs.insert(added.id)
                }
                securityMap[security.id] = added.id
                index(added, at: file.securities.count)
                file.securities.append(added)
                summary.addedSecurities += 1
                summary.addedPrices += added.prices.count
            }
        }

        // Accounts
        var accountMap: [UUID: UUID] = [:]
        var accountIDs = Set(file.accounts.map(\.id))
        for account in incoming.accounts {
            if let match = file.accounts.first(where: { key($0.name) == key(account.name) && $0.currency == account.currency }) {
                accountMap[account.id] = match.id
                summary.matchedAccounts += 1
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
        file.transactions.reserveCapacity(file.transactions.count + incoming.transactions.count)
        for transaction in incoming.transactions {
            var added = transaction
            added.securityID = transaction.securityID.flatMap { securityMap[$0] }
            added.accountID = transaction.accountID.flatMap { accountMap[$0] }
            added.counterAccountID = transaction.counterAccountID.flatMap { accountMap[$0] }
            added.depotID = transaction.depotID.flatMap { depotMap[$0] }
            added.counterDepotID = transaction.counterDepotID.flatMap { depotMap[$0] }
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
            summary.addedTransactions += 1
        }

        // Taxonomies
        for taxonomy in incoming.taxonomies {
            if file.taxonomies.contains(where: { key($0.name) == key(taxonomy.name) || $0.id == taxonomy.id }) {
                summary.skippedTaxonomies += 1
            } else {
                var added = taxonomy
                added.root = taxonomy.root.map { remap($0, securities: securityMap, accounts: accountMap) }
                file.taxonomies.append(added)
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

        // Plans
        for plan in incoming.plans where !file.plans.contains(where: { $0.id == plan.id || (key($0.name) == key(plan.name) && $0.kind == plan.kind) }) {
            var added = plan
            added.securityID = plan.securityID.flatMap { securityMap[$0] }
            added.accountID = plan.accountID.flatMap { accountMap[$0] }
            added.depotID = plan.depotID.flatMap { depotMap[$0] }
            file.plans.append(added)
            summary.addedPlans += 1
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

    private static func key(_ text: String) -> String? {
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
