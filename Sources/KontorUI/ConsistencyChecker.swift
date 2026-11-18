import Foundation
import KontorModel

/// Structural validation of a portfolio file: dangling references, missing required fields,
/// currency mismatches, impossible magnitudes. Pure and fast (single pass over each collection).
///
/// ```swift
/// let issues = ConsistencyChecker.check(store.file)
/// ```
public enum ConsistencyChecker {
    public struct Issue: Identifiable, Hashable, Sendable {
        public enum Severity: Int, Sendable, Comparable {
            case warning, error
            public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }
        public let id: Int
        public var severity: Severity
        public var message: String
        /// Where to look — pass to `store.navigate(to:)`.
        public var route: Route?
    }

    public static func check(_ file: PortfolioFile) -> [Issue] {
        var issues = [Issue]()
        func add(_ severity: Issue.Severity, _ message: String, _ route: Route? = nil) {
            issues.append(Issue(id: issues.count, severity: severity, message: message, route: route))
        }

        var securities = [UUID: Security](minimumCapacity: file.securities.count)
        for s in file.securities {
            if securities.updateValue(s, forKey: s.id) != nil { add(.error, "Duplicate security id for “\(s.name)”.", .security(s.id)) }
            if s.name.trimmingCharacters(in: .whitespaces).isEmpty { add(.warning, "A security has no name.", .security(s.id)) }
            if s.currency.isEmpty { add(.error, "Security “\(s.name)” has no currency.", .security(s.id)) }
        }
        var accounts = [UUID: Account](minimumCapacity: file.accounts.count)
        for a in file.accounts {
            if accounts.updateValue(a, forKey: a.id) != nil { add(.error, "Duplicate account id for “\(a.name)”.", .account(a.id)) }
            if a.currency.isEmpty { add(.error, "Account “\(a.name)” has no currency.", .account(a.id)) }
        }
        var depots = Set<UUID>(minimumCapacity: file.depots.count)
        for d in file.depots {
            if !depots.insert(d.id).inserted { add(.error, "Duplicate depot id for “\(d.name)”.", .depot(d.id)) }
            if let ref = d.referenceAccountID, accounts[ref] == nil {
                add(.warning, "Depot “\(d.name)” refers to a reference account that no longer exists.", .depot(d.id))
            }
        }

        var transactionIDs = Set<UUID>(minimumCapacity: file.transactions.count)
        for t in file.transactions {
            let label = "\(t.kind.rawValue) on \(t.date.iso)"
            let route = Route.transaction(t.id)
            if !transactionIDs.insert(t.id).inserted { add(.error, "Duplicate transaction id (\(label)).", route) }
            if t.amount.minor < 0 || t.fees < 0 || t.taxes < 0 || t.shares.raw < 0 {
                add(.error, "Transaction \(label) stores a negative magnitude.", route)
            }
            if t.kind.requiresAccount {
                if let id = t.accountID, let account = accounts[id] {
                    if account.currency != t.amount.currency {
                        add(.error, "Transaction \(label) is in \(t.amount.currency) but account “\(account.name)” is in \(account.currency).", route)
                    }
                } else {
                    add(.error, "Transaction \(label) has no valid cash account.", route)
                }
            }
            if t.kind.requiresDepot, t.depotID.map(depots.contains) != true {
                add(.error, "Transaction \(label) has no valid depot.", route)
            }
            if t.kind.requiresSecurity {
                if t.securityID.flatMap({ securities[$0] }) == nil {
                    add(.error, "Transaction \(label) has no valid security.", route)
                }
                if t.kind.sharesSign != 0, t.shares.isZero {
                    add(.warning, "Transaction \(label) moves zero shares.", route)
                }
            } else if let id = t.securityID, securities[id] == nil {
                add(.warning, "Transaction \(label) refers to a security that no longer exists.", route)
            }
            switch t.kind {
            case .cashTransfer:
                if let id = t.counterAccountID, let target = accounts[id] {
                    if id == t.accountID { add(.warning, "Transfer \(label) has the same source and target account.", route) }
                    let credited = t.counterAmount ?? t.amount
                    if credited.currency != target.currency {
                        add(.error, "Transfer \(label) credits \(credited.currency) to “\(target.name)” (\(target.currency)).", route)
                    }
                } else {
                    add(.error, "Transfer \(label) has no valid target account.", route)
                }
            case .securityTransfer:
                if t.counterDepotID.map(depots.contains) != true {
                    add(.error, "Transfer \(label) has no valid target depot.", route)
                } else if t.counterDepotID == t.depotID {
                    add(.warning, "Transfer \(label) has the same source and target depot.", route)
                }
            default:
                break
            }
            if t.fees + t.taxes > t.amount.minor, t.kind == .buy || t.kind == .deliveryIn {
                add(.warning, "Transaction \(label): fees and taxes exceed the total amount.", route)
            }
        }

        for plan in file.plans {
            if let id = plan.securityID, securities[id] == nil { add(.warning, "Plan “\(plan.name)” refers to a missing security.", .plan(plan.id)) }
            if let id = plan.accountID, accounts[id] == nil { add(.warning, "Plan “\(plan.name)” refers to a missing account.", .plan(plan.id)) }
            if let id = plan.depotID, !depots.contains(id) { add(.warning, "Plan “\(plan.name)” refers to a missing depot.", .plan(plan.id)) }
            if plan.intervalMonths < 1 { add(.error, "Plan “\(plan.name)” has an invalid interval.", .plan(plan.id)) }
        }

        for taxonomy in file.taxonomies {
            var weights = [UUID: Int]()
            PortfolioStoreTaxonomy.walk(taxonomy.root) { c in
                for a in c.assignments {
                    if let id = a.securityID {
                        if securities[id] == nil { add(.warning, "“\(taxonomy.name) ▸ \(c.name)” assigns a missing security.", .taxonomy(taxonomy.id)) }
                        weights[id, default: 0] += a.weight
                    } else if let id = a.accountID {
                        if accounts[id] == nil { add(.warning, "“\(taxonomy.name) ▸ \(c.name)” assigns a missing account.", .taxonomy(taxonomy.id)) }
                        weights[id, default: 0] += a.weight
                    }
                }
            }
            for (id, weight) in weights where weight > 10_000 {
                let name = securities[id]?.name ?? accounts[id]?.name ?? "An entry"
                add(.warning, "“\(name)” is assigned more than 100 % in “\(taxonomy.name)”.", .taxonomy(taxonomy.id))
            }
        }

        for id in file.settings.benchmarkSecurityIDs where securities[id] == nil {
            add(.warning, "A benchmark refers to a security that no longer exists.")
        }
        return issues
    }
}

enum PortfolioStoreTaxonomy {
    static func walk(_ nodes: [Classification], _ visit: (Classification) -> Void) {
        for node in nodes {
            visit(node)
            walk(node.children, visit)
        }
    }
}
