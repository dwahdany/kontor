import Foundation
import KontorModel

/// Independent consistency checker for generated files. Deliberately re-derives everything from the
/// file alone (no generator internals), mirroring what the app's engine will assume.
enum Audit {
    static func allClassifications(_ nodes: [Classification]) -> [Classification] {
        nodes.flatMap { [$0] + allClassifications($0.children) }
    }

    /// Returns human-readable violations; empty means the file is consistent.
    static func violations(in file: PortfolioFile, today: Day, expectFullCoverage: Bool = true) -> [String] {
        var out = [String]()
        func fail(_ message: String) { if out.count < 40 { out.append(message) } }

        let securities = Dictionary(uniqueKeysWithValues: file.securities.map { ($0.id, $0) })
        let accounts = Dictionary(uniqueKeysWithValues: file.accounts.map { ($0.id, $0) })
        let depots = Set(file.depots.map(\.id))
        let base = file.settings.baseCurrency
        let rates = Dictionary(uniqueKeysWithValues: file.exchangeRates.map { ($0.quote, $0) })
        func convert(_ minor: Int64, from: CurrencyCode, to: CurrencyCode, on day: Day) -> Int64 {
            if from == to { return minor }
            var v = Double(minor)
            if from != base { v /= rates[from]?.rate(on: day) ?? .nan }
            if to != base { v *= rates[to]?.rate(on: day) ?? .nan }
            return Int64(v.rounded())
        }

        // Unique ids across the whole file.
        var ids = [UUID]()
        ids += file.securities.map(\.id) + file.accounts.map(\.id) + file.depots.map(\.id) + file.transactions.map(\.id)
        ids += file.securities.flatMap { $0.events.map(\.id) }
        ids += file.taxonomies.map(\.id) + file.taxonomies.flatMap { allClassifications($0.root).map(\.id) }
        ids += file.watchlists.map(\.id) + file.plans.map(\.id) + file.dashboards.map(\.id)
        ids += file.dashboards.flatMap { $0.widgets.map(\.id) }
        if Set(ids).count != ids.count { fail("duplicate ids: \(ids.count - Set(ids).count)") }

        // References outside the ledger.
        for depot in file.depots where depot.referenceAccountID.map({ accounts[$0] == nil }) ?? true {
            fail("depot \(depot.name) lacks a valid reference account")
        }
        for id in file.settings.benchmarkSecurityIDs where securities[id] == nil { fail("unknown benchmark") }
        for list in file.watchlists { for id in list.securityIDs where securities[id] == nil { fail("unknown watchlist security") } }
        for plan in file.plans {
            if let id = plan.securityID, securities[id] == nil { fail("plan security") }
            if let id = plan.accountID, accounts[id] == nil { fail("plan account") }
            if let id = plan.depotID, !depots.contains(id) { fail("plan depot") }
            if plan.start > today { fail("plan starts after today") }
        }
        for taxonomy in file.taxonomies {
            var weights = [UUID: Int]()
            for node in allClassifications(taxonomy.root) {
                if !node.color.hasPrefix("#") || node.color.count != 7 { fail("bad color \(node.color)") }
                for a in node.assignments {
                    switch (a.securityID, a.accountID) {
                    case (let id?, nil): if securities[id] == nil { fail("assignment to unknown security") } else { weights[id, default: 0] += a.weight }
                    case (nil, let id?): if accounts[id] == nil { fail("assignment to unknown account") } else { weights[id, default: 0] += a.weight }
                    default: fail("assignment must reference exactly one vehicle")
                    }
                }
            }
            for (id, weight) in weights where weight != 10_000 { fail("\(taxonomy.name): weights of \(id) sum to \(weight)") }
            if expectFullCoverage {
                for id in Array(securities.keys) + Array(accounts.keys) where weights[id] == nil {
                    fail("\(taxonomy.name): \(securities[id]?.name ?? accounts[id]?.name ?? "?") unassigned")
                }
            }
        }

        // Prices and rates.
        for security in file.securities {
            let days = security.prices.days
            for i in days.indices.dropFirst() where days[i] <= days[i - 1] { fail("\(security.name): prices not ascending"); break }
            if let last = security.prices.lastDay, last > today { fail("\(security.name): price after today") }
            if security.prices.values.contains(where: { $0 <= 0 }) { fail("\(security.name): non-positive price") }
            for event in security.events where event.day > today { fail("event after today") }
        }
        for series in file.exchangeRates {
            if series.days.count != series.rates.count { fail("rate columns differ") }
            for i in series.days.indices.dropFirst() where series.days[i] <= series.days[i - 1] { fail("rates not ascending"); break }
            if let last = series.days.last, last > today.rawValue { fail("rate after today") }
            if series.rates.contains(where: { !($0 > 0) }) { fail("non-positive rate") }
        }

        // Ledger replay in the model's canonical order.
        struct Position: Hashable { var depot: UUID; var security: UUID }
        var balance = [UUID: Int64]()
        var held = [Position: Int64]()
        var firstHeld = [UUID: Day](), lastMove = [UUID: Day]()
        for tx in file.transactions.sorted(by: Transaction.chronological) {
            let label = "\(tx.date) \(tx.kind.rawValue)"
            if tx.date > today { fail("\(label): after today") }
            if tx.amount.minor < 0 || tx.fees < 0 || tx.taxes < 0 || tx.shares.raw < 0 { fail("\(label): negative magnitude") }
            if let minute = tx.minuteOfDay, !(0..<1440).contains(minute) { fail("\(label): bad minute") }
            let account = tx.accountID.flatMap { accounts[$0] }
            if tx.kind.requiresAccount, account == nil { fail("\(label): missing account") }
            if tx.accountID != nil, account == nil { fail("\(label): unknown account") }
            if tx.kind.requiresDepot, tx.depotID.map(depots.contains) != true { fail("\(label): missing depot") }
            if let depot = tx.depotID, !depots.contains(depot) { fail("\(label): unknown depot") }
            let security = tx.securityID.flatMap { securities[$0] }
            if tx.kind.requiresSecurity, security == nil { fail("\(label): missing security") }
            if tx.securityID != nil, security == nil { fail("\(label): unknown security") }
            if let account, tx.amount.currency != account.currency { fail("\(label): amount not in account currency") }

            if tx.kind == .cashTransfer {
                guard let counter = tx.counterAccountID.flatMap({ accounts[$0] }), let account else {
                    fail("\(label): missing counter account")
                    continue
                }
                if counter.currency != account.currency {
                    if tx.counterAmount?.currency != counter.currency { fail("\(label): counterAmount currency") }
                    let expected = convert(tx.amount.minor, from: account.currency, to: counter.currency, on: tx.date)
                    if abs((tx.counterAmount?.minor ?? 0) - expected) > 1 { fail("\(label): counterAmount not at day's rate") }
                } else if tx.counterAmount != nil {
                    fail("\(label): unexpected counterAmount")
                }
            }
            if tx.kind == .securityTransfer, tx.counterDepotID.map(depots.contains) != true { fail("\(label): missing counter depot") }

            // Valuation at the day's price.
            if let security, [.buy, .sell, .deliveryIn, .securityTransfer].contains(tx.kind) {
                // Trades are valued at that very day's close — a stale quote would mean a booking on a closed day.
                guard let point = security.prices.point(onOrBefore: tx.date), point.day == tx.date else {
                    fail("\(label): no price for \(security.name) on that day")
                    continue
                }
                let price = point.price
                let value = price.value(of: tx.shares)
                let cross = security.currency != tx.amount.currency
                if cross != (tx.securityGross != nil) { fail("\(label): securityGross presence") }
                if let gross = tx.securityGross {
                    if gross.currency != security.currency { fail("\(label): securityGross currency") }
                    if gross.minor != value { fail("\(label): securityGross \(gross.minor) != value \(value)") }
                    let converted = convert(gross.minor, from: security.currency, to: tx.amount.currency, on: tx.date)
                    if abs(converted - tx.grossMinor) > 1 { fail("\(label): gross not converted at day's rate") }
                } else if abs(tx.grossMinor - value) > 1 {
                    fail("\(label): gross \(tx.grossMinor) != value \(value) for \(security.name)")
                }
                if tx.shares.raw <= 0 { fail("\(label): no shares") }
            }
            if tx.kind == .dividend, let security {
                if (security.currency != tx.amount.currency) != (tx.securityGross != nil) { fail("\(label): securityGross presence") }
                let position = held[Position(depot: tx.depotID ?? UUID(), security: security.id)] ?? 0
                if tx.shares.raw != position || position <= 0 { fail("\(label): dividend shares \(tx.shares) != held") }
            }

            // Effects.
            for id in [tx.accountID, tx.counterAccountID].compactMap({ $0 }) {
                balance[id, default: 0] += tx.cashEffect(on: id)
                if balance[id]! < 0 { fail("\(label): balance of \(accounts[id]?.name ?? "?") negative (\(balance[id]!))") }
            }
            if let securityID = tx.securityID, tx.kind.sharesSign != 0 {
                for depot in [tx.depotID, tx.counterDepotID].compactMap({ $0 }) {
                    let key = Position(depot: depot, security: securityID)
                    held[key, default: 0] += tx.sharesEffect(on: depot).raw
                    if held[key]! < 0 { fail("\(label): negative position") }
                }
                if firstHeld[securityID] == nil { firstHeld[securityID] = tx.date }
                lastMove[securityID] = tx.date
            }
        }

        // Price coverage of holding periods.
        var remaining = [UUID: Int64]()
        for (key, shares) in held { remaining[key.security, default: 0] += shares }
        for (id, first) in firstHeld {
            guard let security = securities[id], let from = security.prices.firstDay, let to = security.prices.lastDay else {
                fail("held security without prices")
                continue
            }
            if from > first { fail("\(security.name): prices start after first purchase") }
            // Held securities must be quoted up to the last trading day (reference calendar) on or before today.
            var lastTradingDay = today
            while !ReferenceCalendar.isTradingDay(lastTradingDay) { lastTradingDay = lastTradingDay.advanced(by: -1) }
            let needed = (remaining[id] ?? 0) > 0 ? lastTradingDay : (lastMove[id] ?? first)
            if to < needed { fail("\(security.name): prices end \(to), needed through \(needed)") }
        }
        return out
    }

    /// Final cash balances per account id.
    static func balances(_ file: PortfolioFile) -> [UUID: Int64] {
        var balance = [UUID: Int64]()
        for tx in file.transactions {
            for id in [tx.accountID, tx.counterAccountID].compactMap({ $0 }) { balance[id, default: 0] += tx.cashEffect(on: id) }
        }
        return balance
    }

    /// Final share totals per security id (over all depots).
    static func holdings(_ file: PortfolioFile) -> [UUID: Int64] {
        var held = [UUID: Int64]()
        for tx in file.transactions {
            guard let id = tx.securityID else { continue }
            for depot in [tx.depotID, tx.counterDepotID].compactMap({ $0 }) { held[id, default: 0] += tx.sharesEffect(on: depot).raw }
        }
        return held
    }
}
