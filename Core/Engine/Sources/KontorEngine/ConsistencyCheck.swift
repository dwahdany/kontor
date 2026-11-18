import Foundation
import KontorModel

/// A problem found in a portfolio file by `ConsistencyChecker`.
public struct ConsistencyIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, Comparable, Codable, CaseIterable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A depot holds a negative number of shares of a security at the end of `day`.
        case negativeShares
        /// An account balance is negative at the end of `day`.
        case negativeCashBalance
        /// A field the transaction kind requires (account, depot, security, target, shares) is empty.
        case missingField
        /// A transaction points to an account, depot or security that does not exist.
        case unknownReference
        /// An amount is not in the currency of the account / security it belongs to.
        case currencyMismatch
        /// A negative magnitude, fees exceeding the amount, a transfer onto itself, …
        case invalidValue
        /// A security that is currently held has no quotes at all.
        case securityWithoutPrices
        /// A security that is currently held has no recent quote.
        case stalePrices
        /// A currency in use cannot be converted to the base currency.
        case missingExchangeRate
        /// Several transactions with identical kind, date, parties, shares and amount.
        case duplicateTransactions
    }

    public let kind: Kind
    public let severity: Severity
    /// Human-readable (English) description.
    public let message: String
    /// The field or currency pair concerned, e.g. "account", "counterAmount", "USD→EUR"; may be empty.
    public let detail: String
    /// Transactions involved (for navigation); empty for position- and security-level issues.
    public let transactionIDs: [UUID]
    public let securityID: UUID?
    public let accountID: UUID?
    public let depotID: UUID?
    /// The (first) day the problem occurs, where applicable.
    public let day: Day?

    /// Stable across runs as long as the problem persists.
    public var id: String {
        var parts = [kind.rawValue, detail]
        parts.append(contentsOf: transactionIDs.map(\.uuidString))
        for optional in [securityID, accountID, depotID] { parts.append(optional?.uuidString ?? "-") }
        return parts.joined(separator: "|")
    }
}

/// Validates a portfolio file. Checks never modify anything and never trap on bad data.
public enum ConsistencyChecker {
    public struct Options: Sendable, Hashable {
        /// The day "currently held" refers to.
        public var today: Day
        /// A held security is flagged as stale if its latest quote is older than this many days.
        public var staleAfterDays: Int

        public init(today: Day = .today, staleAfterDays: Int = 10) {
            self.today = today
            self.staleAfterDays = staleAfterDays
        }
    }

    /// Checks `file` and returns all issues, most severe first.
    public static func check(_ file: PortfolioFile, options: Options = Options()) -> [ConsistencyIssue] {
        Ledger(file).consistencyIssues(options: options)
    }
}

extension Ledger {
    /// Consistency issues of the indexed file, most severe first (then by kind and day). Linear in
    /// the number of transactions.
    ///
    /// * **error** — negative share positions (end of day), missing required fields, unknown
    ///   references, amounts in the wrong currency, invalid values, unconvertible currencies;
    /// * **warning** — negative cash balances, held securities without or with stale quotes,
    ///   probable duplicates, implausible fee / tax breakdowns.
    public func consistencyIssues(
        options: ConsistencyChecker.Options = ConsistencyChecker.Options()
    ) -> [ConsistencyIssue] {
        var issues: [ConsistencyIssue] = []
        func add(
            _ kind: ConsistencyIssue.Kind, _ severity: ConsistencyIssue.Severity, _ message: String, detail: String = "",
            transactions: [UUID] = [], security: UUID? = nil, account: UUID? = nil, depot: UUID? = nil, day: Day? = nil
        ) {
            issues.append(ConsistencyIssue(
                kind: kind, severity: severity, message: message, detail: detail, transactionIDs: transactions,
                securityID: security, accountID: account, depotID: depot, day: day))
        }
        func label(_ t: Transaction) -> String { "\(t.kind.rawValue) on \(t.date.iso)" }

        // 1. Every transaction on its own.
        struct DuplicateKey: Hashable {
            var kind: Transaction.Kind
            var date: Day
            var account: UUID?
            var depot: UUID?
            var security: UUID?
            var counterAccount: UUID?
            var counterDepot: UUID?
            var shares: Int64
            var amount: Money
        }
        var groups: [DuplicateKey: [UUID]] = [:]
        var groupOrder: [DuplicateKey] = []

        for t in transactions {
            let kind = t.kind
            func reference(_ id: UUID?, required: Bool, field: String, exists: (UUID) -> Bool) {
                if let id {
                    if !exists(id) {
                        add(.unknownReference, .error, "The \(label(t)) refers to a \(field) that does not exist.",
                            detail: field, transactions: [t.id], security: t.securityID, account: t.accountID,
                            depot: t.depotID, day: t.date)
                    }
                } else if required {
                    add(.missingField, .error, "The \(label(t)) has no \(field).", detail: field,
                        transactions: [t.id], security: t.securityID, account: t.accountID, depot: t.depotID, day: t.date)
                }
            }
            reference(t.securityID, required: kind.requiresSecurity, field: "security") { self.security($0) != nil }
            reference(t.accountID, required: kind.requiresAccount, field: "account") { self.account($0) != nil }
            reference(t.depotID, required: kind.requiresDepot, field: "depot") { self.depot($0) != nil }
            if kind == .cashTransfer {
                reference(t.counterAccountID, required: true, field: "target account") { self.account($0) != nil }
            }
            if kind == .securityTransfer {
                reference(t.counterDepotID, required: true, field: "target depot") { self.depot($0) != nil }
            }

            func invalid(_ severity: ConsistencyIssue.Severity, _ message: String, _ detail: String) {
                add(.invalidValue, severity, message, detail: detail, transactions: [t.id], security: t.securityID,
                    account: t.accountID, depot: t.depotID, day: t.date)
            }
            if kind.sharesSign != 0, t.shares.raw == 0 {
                add(.missingField, .error, "The \(label(t)) has no share count.", detail: "shares",
                    transactions: [t.id], security: t.securityID, account: t.accountID, depot: t.depotID, day: t.date)
            }
            if t.shares.raw < 0 { invalid(.error, "The \(label(t)) has a negative share count.", "shares") }
            if t.amount.minor < 0 { invalid(.error, "The \(label(t)) has a negative amount.", "amount") }
            if t.fees < 0 { invalid(.error, "The \(label(t)) has negative fees.", "fees") }
            if t.taxes < 0 { invalid(.error, "The \(label(t)) has negative taxes.", "taxes") }
            if kind == .buy || kind == .deliveryIn, t.fees >= 0, t.taxes >= 0, t.amount.minor >= 0,
               t.fees + t.taxes > t.amount.minor {
                invalid(.warning, "Fees and taxes of the \(label(t)) exceed its amount.", "fees")
            }
            if kind == .cashTransfer, let a = t.accountID, a == t.counterAccountID {
                invalid(.error, "The \(label(t)) transfers between the same account.", "target account")
            }
            if kind == .securityTransfer, let d = t.depotID, d == t.counterDepotID {
                invalid(.error, "The \(label(t)) transfers between the same depot.", "target depot")
            }

            func mismatch(_ severity: ConsistencyIssue.Severity, found: CurrencyCode, expected: CurrencyCode, _ field: String, _ owner: String) {
                add(.currencyMismatch, severity,
                    "The \(field) of the \(label(t)) is in \(found), but \(owner) uses \(expected).", detail: field,
                    transactions: [t.id], security: t.securityID, account: t.accountID, depot: t.depotID, day: t.date)
            }
            if kind.requiresAccount, let account = t.accountID.flatMap({ self.account($0) }) {
                if t.amount.currency != account.currency {
                    mismatch(.error, found: t.amount.currency, expected: account.currency, "amount", "account “\(account.name)”")
                }
                if kind == .cashTransfer, let target = t.counterAccountID.flatMap({ self.account($0) }) {
                    if let credited = t.counterAmount {
                        if credited.currency != target.currency {
                            mismatch(.error, found: credited.currency, expected: target.currency, "counterAmount",
                                     "account “\(target.name)”")
                        }
                        if credited.minor < 0 { invalid(.error, "The \(label(t)) credits a negative amount.", "counterAmount") }
                    } else if target.currency != account.currency {
                        add(.missingField, .error,
                            "The \(label(t)) moves money from \(account.currency) to \(target.currency) without the credited amount.",
                            detail: "counterAmount", transactions: [t.id], account: t.accountID, day: t.date)
                    }
                }
            }
            if let gross = t.securityGross, let security = t.securityID.flatMap({ self.security($0) }),
               gross.currency != security.currency {
                mismatch(.warning, found: gross.currency, expected: security.currency, "securityGross",
                         "security “\(security.name)”")
            }

            let key = DuplicateKey(
                kind: kind, date: t.date, account: t.accountID, depot: t.depotID, security: t.securityID,
                counterAccount: t.counterAccountID, counterDepot: t.counterDepotID, shares: t.shares.raw, amount: t.amount)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(t.id)
        }
        for key in groupOrder {
            guard let ids = groups[key], ids.count > 1 else { continue }
            add(.duplicateTransactions, .warning,
                "\(ids.count) identical \(key.kind.rawValue) transactions on \(key.date.iso) (\(key.amount)).",
                transactions: ids, security: key.security, account: key.account, depot: key.depot, day: key.date)
        }

        // 2. Positions and balances at the end of every day (valid transactions only).
        var shares = [Int64](repeating: 0, count: holdingSecurity.count)
        var balances = [Int64](repeating: 0, count: accounts.count)
        var holdingFlagged = [Bool](repeating: false, count: shares.count)
        var accountFlagged = [Bool](repeating: false, count: balances.count)
        var sharesToday = shares
        var touchedHoldings: [Int] = [], touchedAccounts: [Int] = []
        var i = 0
        let todayRaw = options.today.rawValue
        var capturedToday = false
        while i < entries.count {
            let dayRaw = entries[i].day
            if !capturedToday, dayRaw > todayRaw {
                sharesToday = shares
                capturedToday = true
            }
            touchedHoldings.removeAll(keepingCapacity: true)
            touchedAccounts.removeAll(keepingCapacity: true)
            while i < entries.count, entries[i].day == dayRaw {
                let e = entries[i]
                i += 1
                if e.holding >= 0, e.sharesDelta != 0 {
                    shares[Int(e.holding)] += e.sharesDelta
                    touchedHoldings.append(Int(e.holding))
                }
                if e.counterHolding >= 0 {
                    shares[Int(e.counterHolding)] += e.shares
                    touchedHoldings.append(Int(e.counterHolding))
                }
                if e.account >= 0 {
                    balances[Int(e.account)] += e.cashDelta
                    touchedAccounts.append(Int(e.account))
                }
                if e.counterAccount >= 0 {
                    balances[Int(e.counterAccount)] += e.counterCashDelta
                    touchedAccounts.append(Int(e.counterAccount))
                }
            }
            let day = Day(rawValue: dayRaw)
            for h in touchedHoldings where shares[h] < 0 && !holdingFlagged[h] {
                holdingFlagged[h] = true
                let security = securities[Int(holdingSecurity[h])], depot = depots[Int(holdingDepot[h])]
                add(.negativeShares, .error,
                    "Depot “\(depot.name)” holds \(Shares(raw: shares[h])) shares of “\(security.name)” from \(day.iso).",
                    security: security.id, depot: depot.id, day: day)
            }
            for a in touchedAccounts where balances[a] < 0 && !accountFlagged[a] {
                accountFlagged[a] = true
                let account = accounts[a]
                add(.negativeCashBalance, .warning,
                    "Account “\(account.name)” is overdrawn from \(day.iso) (\(Money(minor: balances[a], currency: account.currency))).",
                    account: account.id, day: day)
            }
        }
        if !capturedToday { sharesToday = shares }

        // 3. Quotes of the securities held today.
        var heldToday = [Bool](repeating: false, count: securities.count)
        for h in sharesToday.indices where sharesToday[h] != 0 { heldToday[Int(holdingSecurity[h])] = true }
        for s in securities.indices where heldToday[s] {
            let security = securities[s]
            guard let last = security.prices.lastDay else {
                add(.securityWithoutPrices, .warning,
                    "“\(security.name)” is held but has no quotes; it is valued from its own transactions.",
                    security: security.id)
                continue
            }
            if !security.isRetired, last.distance(to: options.today) > options.staleAfterDays {
                add(.stalePrices, .warning, "The latest quote of “\(security.name)” is from \(last.iso).",
                    security: security.id, day: last)
            }
        }

        // 4. Currencies that cannot be converted to the base currency.
        let base = settings.baseCurrency
        var checked: Set<CurrencyCode> = [base]
        func rates(_ currency: CurrencyCode, account: UUID? = nil, security: UUID? = nil, user: String) {
            guard checked.insert(currency).inserted, !converter.canConvert(from: currency, to: base) else { return }
            add(.missingExchangeRate, .error,
                "No exchange rate \(currency)→\(base) (needed for \(user)); such amounts are excluded from all totals.",
                detail: "\(currency)→\(base)", security: security, account: account)
        }
        for a in accounts { rates(a.currency, account: a.id, user: "account “\(a.name)”") }
        let used = transactionCountBySecurity
        for (s, security) in securities.enumerated() where used[s] > 0 {
            rates(security.currency, security: security.id, user: "security “\(security.name)”")
        }

        // Most severe first; the sort is stable within equal keys because of the index tie-break.
        let kindOrder = Dictionary(uniqueKeysWithValues: ConsistencyIssue.Kind.allCases.enumerated().map { ($1, $0) })
        return issues.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
            let ka = kindOrder[a.element.kind] ?? 0, kb = kindOrder[b.element.kind] ?? 0
            if ka != kb { return ka < kb }
            return a.offset < b.offset
        }.map(\.element)
    }
}
