import Foundation
import KontorUI

/// One line of the ledger table: a small `Sendable` value with everything a cell shows, built off
/// the main actor. Names are resolved once here, so cells never look anything up.
struct LedgerRow: Identifiable, Sendable {
    let id: UUID
    /// Chronological position in the whole ledger — the sort key of the Date column.
    var order: Int32
    var date: Day
    /// Minutes after midnight, −1 when the entry has no time.
    var minute: Int16
    var kind: Transaction.Kind
    var kindRank: UInt8

    var securityID: UUID?
    var accountID: UUID?
    var depotID: UUID?
    var counterAccountID: UUID?
    var counterDepotID: UUID?

    var security: String
    var account: String
    var depot: String
    /// Target account or depot of a transfer.
    var counter: String
    var note: String
    var source: String
    /// Sort keys of the name columns (rank of the name in natural order; 0 = empty).
    var securityRank: Int32
    var accountRank: Int32
    var depotRank: Int32
    var counterRank: Int32

    /// Signed change of the share position (0 when the kind moves no shares). Seen from the source
    /// depot, or — when the list is filtered to a depot — from that depot.
    var shares: Int64
    /// The stored share count of an entry that moves shares (unsigned).
    var movedShares: Int64
    /// Share count that is only informative (dividends).
    var infoShares: Int64
    /// Gross price per share in `currency`, raw fixed-point; 0 when there is none.
    var price: Int64
    var currency: CurrencyCode
    /// Signed cash effect shown in the Amount column, in `cashCurrency`.
    var cash: Int64
    var cashCurrency: CurrencyCode
    /// False for bookings that move no cash (deliveries, transfers seen from the whole portfolio):
    /// the amount is then shown neutral, without a sign.
    var movesCash: Bool
    /// Fees and taxes of the entry in `currency`: the breakdown inside a trade's or a dividend's
    /// amount, and the whole amount of a Fee / Tax entry (negative for refunds) — so the columns and
    /// the footer cover every fee and tax that was paid.
    var fees: Int64
    var taxes: Int64

    /// The stored amount and, for cross-currency transfers, what arrived.
    var amount: Int64
    var counterAmount: Int64
    var counterCurrency: CurrencyCode

    /// Cash effect, fees and taxes in the reporting currency (for the footer sums).
    var baseCash: Int64
    var baseFees: Int64
    var baseTaxes: Int64
    /// A value of this entry could not be converted to the reporting currency (no exchange rate
    /// on file): the footer sums in that currency then lack it.
    var isUnconverted: Bool

    /// Balance of the filtered account after this entry (only with a single-account filter).
    var balance: Int64?
    /// Plain-language finding of the consistency check; empty when the entry is fine.
    var issue: String
    /// Lower-cased, diacritic-free text the search field matches against.
    var haystack: String

    /// Sort key of the Balance column.
    var balanceKey: Int64 { balance ?? .min }
    /// Sort key of the Shares column.
    var sharesKey: Int64 { shares != 0 ? shares : infoShares }

    /// Signed change of the share position in `depot` caused by this entry.
    func sharesEffect(on depot: UUID) -> Int64 {
        var effect: Int64 = 0
        if depotID == depot { effect += kind.sharesSign * movedShares }
        if kind == .securityTransfer, counterDepotID == depot { effect += movedShares }
        return effect
    }

    /// Signed change of the balance of `account` caused by this entry, in the account's currency.
    func cashEffect(on account: UUID) -> Int64 {
        var effect: Int64 = 0
        if accountID == account { effect += kind.cashSign * amount }
        if kind == .cashTransfer, counterAccountID == account { effect += counterAmount }
        return effect
    }
}

/// What the ledger shows — everything the rows depend on besides the document.
struct LedgerQuery: Hashable, Sendable {
    var text = ""
    /// Empty = all kinds.
    var groups: Set<KindGroup> = []
    var accountID: UUID?
    var depotID: UUID?
    var securityID: UUID?
    /// Only entries whose day lies in `firstDay … end` of this interval.
    var interval: DayInterval?
    var issuesOnly = false
    var sortOrder: [KeyPathComparator<LedgerRow>] = [KeyPathComparator(\LedgerRow.order, order: .reverse)]

    /// True if anything narrows the list.
    var isFiltering: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !groups.isEmpty || accountID != nil || depotID != nil
            || securityID != nil || interval != nil || issuesOnly
    }
}

/// All rows of a document revision in chronological order — computed once per revision.
struct LedgerBase: Sendable {
    var rows: [LedgerRow]
    var currency: CurrencyCode
    var issueCount: Int
    var accountCurrencies: [UUID: CurrencyCode]

    init(_ ledger: Ledger, today: Day, formatter: KontorFormatter = Fmt.current) {
        currency = ledger.reportingCurrency
        accountCurrencies = Dictionary(ledger.accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { a, _ in a })

        // Natural-order ranks, so that sorting by a name column compares integers.
        func ranks(_ names: [(UUID, String)]) -> [UUID: (name: String, rank: Int32)] {
            let sorted = names.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            var result = [UUID: (name: String, rank: Int32)](minimumCapacity: sorted.count)
            for (index, entry) in sorted.enumerated() { result[entry.0] = (entry.1, Int32(index + 1)) }
            return result
        }
        let securities = ranks(ledger.securities.map { ($0.id, $0.name) })
        let accounts = ranks(ledger.accounts.map { ($0.id, $0.name) })
        let depots = ranks(ledger.depots.map { ($0.id, $0.name) })
        var securitySearch = [UUID: String](minimumCapacity: ledger.securities.count)
        for security in ledger.securities {
            securitySearch[security.id] = [security.name, security.isin, security.ticker, security.wkn].filter { !$0.isEmpty }.joined(separator: " ")
        }

        // Findings of the engine's consistency check, most severe first — the first one per entry wins.
        var issues = [UUID: String]()
        for issue in ledger.consistencyIssues(options: .init(today: today)) {
            for id in issue.transactionIDs where issues[id] == nil { issues[id] = issue.message }
        }
        for diagnostic in ledger.diagnostics {
            if case .invalidTransaction(let id, let reason) = diagnostic, issues[id] == nil { issues[id] = reason }
        }
        issueCount = 0

        let converter = ledger.converter
        let reporting = ledger.reportingCurrency
        var rows = [LedgerRow]()
        rows.reserveCapacity(ledger.transactions.count)
        for (index, t) in ledger.transactions.enumerated() {
            let security = t.securityID.flatMap { securities[$0] }
            let account = t.accountID.flatMap { accounts[$0] }
            let depot = t.depotID.flatMap { depots[$0] }
            let counter = t.kind == .cashTransfer ? t.counterAccountID.flatMap { accounts[$0] } : t.counterDepotID.flatMap { depots[$0] }
            let currency = t.amount.currency
            let cashSign = t.kind == .cashTransfer ? 0 : t.kind.cashSign
            // An amount without an exchange rate is left out of the sums — and reported, not hidden.
            var isUnconverted = false
            func toBase(_ minor: Int64) -> Int64 {
                if minor == 0 || currency == reporting { return minor }
                guard let converted = converter.convert(minor: minor, from: currency, to: reporting, on: t.date) else {
                    isUnconverted = true
                    return 0
                }
                return converted
            }
            // Fee and Tax entries are fees and taxes in full; refunds give them back.
            var fees = t.fees, taxes = t.taxes
            switch t.kind {
            case .fee: fees = t.amount.minor
            case .feeRefund: fees = -t.amount.minor
            case .tax: taxes = t.amount.minor
            case .taxRefund: taxes = -t.amount.minor
            default: break
            }
            let baseCash = cashSign == 0 ? 0 : toBase(cashSign * t.amount.minor)
            let baseFees = toBase(fees), baseTaxes = toBase(taxes)
            let issue = issues[t.id] ?? ""
            if !issue.isEmpty { issueCount += 1 }
            var haystack = t.kind.title
            // Dates and amounts the way they are shown and the way people type them:
            // "05.06.2026", "2026-06-05", "1.471,47", "1471,47", "1471.47".
            let whole = String(t.amount.minor / Scale.amount), cents = t.amount.minor % Scale.amount
            let fraction = (cents < 10 ? "0" : "") + String(cents)
            let amounts = t.amount.minor == 0 ? "" : "\(formatter.money(minor: t.amount.minor)) \(whole),\(fraction) \(whole).\(fraction)"
            for part in [t.securityID.flatMap { securitySearch[$0] } ?? "", account?.name ?? "", depot?.name ?? "", counter?.name ?? "", t.note, t.source ?? "",
                         t.date.iso, formatter.day(t.date), amounts] where !part.isEmpty {
                haystack.append(" ")
                haystack.append(part)
            }
            rows.append(LedgerRow(
                id: t.id, order: Int32(index), date: t.date, minute: Int16(clamping: t.minuteOfDay ?? -1), kind: t.kind, kindRank: t.kind.rank,
                securityID: t.securityID, accountID: t.accountID, depotID: t.depotID, counterAccountID: t.counterAccountID,
                counterDepotID: t.counterDepotID,
                security: security?.name ?? "", account: account?.name ?? "", depot: depot?.name ?? "", counter: counter?.name ?? "",
                note: t.note, source: t.source ?? "",
                securityRank: security?.rank ?? 0, accountRank: account?.rank ?? 0, depotRank: depot?.rank ?? 0, counterRank: counter?.rank ?? 0,
                shares: t.kind.sharesSign * t.shares.raw, movedShares: t.kind.sharesSign == 0 ? 0 : t.shares.raw,
                infoShares: t.kind.sharesSign == 0 ? t.shares.raw : 0,
                price: t.grossPrice?.raw ?? 0, currency: currency,
                cash: cashSign == 0 ? t.amount.minor : cashSign * t.amount.minor, cashCurrency: currency, movesCash: cashSign != 0,
                fees: fees, taxes: taxes, amount: t.amount.minor,
                counterAmount: (t.counterAmount ?? t.amount).minor, counterCurrency: (t.counterAmount ?? t.amount).currency,
                baseCash: baseCash, baseFees: baseFees, baseTaxes: baseTaxes, isUnconverted: isUnconverted,
                balance: nil, issue: issue, haystack: LedgerBase.fold(haystack)))
        }
        self.rows = rows
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The filtered, sorted rows and the sums shown in the footer.
struct LedgerContent: Sendable {
    struct Totals: Sendable, Equatable {
        var inflows: Int64 = 0
        var outflows: Int64 = 0
        /// Fees and taxes paid: inside trades and income, plus Fee / Tax entries, less refunds.
        var fees: Int64 = 0
        var taxes: Int64 = 0
        var currency: CurrencyCode
        /// Entries missing from the sums because no exchange rate to `currency` is on file.
        var unconverted = 0

        /// Adds one row. `inAccountCurrency`: the list is filtered to one account, whose currency
        /// the row's cash effect is already in.
        mutating func add(_ row: LedgerRow, inAccountCurrency: Bool) {
            let cash = inAccountCurrency ? row.cash : row.baseCash
            if cash > 0 { inflows += cash } else { outflows += cash }
            if inAccountCurrency {
                // Fees and taxes of the account's own bookings (a transfer's target has none).
                if row.currency == currency {
                    fees += row.fees
                    taxes += row.taxes
                }
            } else {
                fees += row.baseFees
                taxes += row.baseTaxes
                if row.isUnconverted { unconverted += 1 }
            }
        }

        /// The sums of `rows` (e.g. the selection) under the same rules as the footer.
        static func sum(_ rows: some Sequence<LedgerRow>, currency: CurrencyCode, inAccountCurrency: Bool) -> Totals {
            var totals = Totals(currency: currency)
            for row in rows { totals.add(row, inAccountCurrency: inAccountCurrency) }
            return totals
        }
    }

    var rows: [LedgerRow]
    var totals: Totals
    /// Number of entries in the document.
    var totalCount: Int
    /// Entries the consistency check complains about (whole document).
    var issueCount: Int
    /// The account whose running balance the rows carry, if the list is filtered to one account.
    var balanceAccount: UUID?
    var balanceCurrency: CurrencyCode?

    init(base: LedgerBase, query: LedgerQuery) {
        totalCount = base.rows.count
        issueCount = base.issueCount
        balanceAccount = query.accountID
        balanceCurrency = query.accountID.flatMap { base.accountCurrencies[$0] }
        let account = query.accountID
        var totals = Totals(currency: balanceCurrency ?? base.currency)

        let terms = query.text.split(whereSeparator: \.isWhitespace).map { LedgerBase.fold(String($0)) }
        var kinds = Set<Transaction.Kind>()
        for group in query.groups { kinds.formUnion(group.kinds) }
        let first = query.interval?.firstDay, last = query.interval?.end

        var result = [LedgerRow]()
        var running: Int64 = 0
        for var row in base.rows {
            if let account {
                guard row.accountID == account || row.counterAccountID == account else { continue }
                // The balance runs over every entry of the account, whatever else is filtered.
                let effect = row.cashEffect(on: account)
                running += effect
                row.balance = running
                row.cash = effect
                row.cashCurrency = totals.currency
                row.movesCash = true
            }
            if !kinds.isEmpty, !kinds.contains(row.kind) { continue }
            if let depot = query.depotID {
                guard row.depotID == depot || row.counterDepotID == depot else { continue }
                // Seen from that depot: a transfer into it adds shares.
                if row.movedShares != 0 { row.shares = row.sharesEffect(on: depot) }
            }
            if let security = query.securityID, row.securityID != security { continue }
            if let first, let last, row.date < first || row.date > last { continue }
            if query.issuesOnly, row.issue.isEmpty { continue }
            if !terms.isEmpty, !terms.allSatisfy({ row.haystack.contains($0) }) { continue }

            totals.add(row, inAccountCurrency: account != nil)
            result.append(row)
        }

        // Rows are chronological already: sorting by date is free (or a reversal).
        if let primary = query.sortOrder.first, primary.keyPath == \LedgerRow.order {
            if primary.order == .reverse { result.reverse() }
        } else {
            result.sort(using: query.sortOrder + [KeyPathComparator(\LedgerRow.order, order: .reverse)])
        }
        rows = result
        self.totals = totals
    }

    /// Sums of the rows with these ids (the selection), in the footer's currency.
    func totals(of ids: Set<UUID>) -> Totals {
        Totals.sum(rows.lazy.filter { ids.contains($0.id) }, currency: totals.currency, inAccountCurrency: balanceAccount != nil)
    }

    /// Runs the filter and sort off the main actor.
    @concurrent
    static func make(base: LedgerBase, query: LedgerQuery) async -> LedgerContent {
        LedgerContent(base: base, query: query)
    }
}

/// Tab-separated text of ledger rows, for ⌘C.
enum LedgerExport {
    static let header = ["Date", "Time", "Type", "Security", "Shares", "Price", "Amount", "Currency", "Fees", "Taxes", "Account", "Depot", "To", "Note", "Source"]

    static func tsv(_ rows: [LedgerRow]) -> String {
        TSV.string(header: header, rows: rows.map { row in
            let shares = row.sharesKey
            return [
                row.date.iso,
                row.minute >= 0 ? LedgerExport.time(Int(row.minute)) : "",
                row.kind.title,
                row.security,
                shares == 0 ? "" : TSV.number(Shares(raw: shares).decimalValue),
                row.price == 0 ? "" : TSV.number(Price(raw: row.price).decimalValue),
                TSV.number(Money(minor: row.cash, currency: row.cashCurrency).decimalValue),
                row.cashCurrency,
                row.fees == 0 ? "" : TSV.number(Money(minor: row.fees, currency: row.currency).decimalValue),
                row.taxes == 0 ? "" : TSV.number(Money(minor: row.taxes, currency: row.currency).decimalValue),
                row.account, row.depot, row.counter, row.note, row.source,
            ]
        })
    }

    @concurrent
    static func tsvOffMain(_ rows: [LedgerRow]) async -> String { tsv(rows) }

    /// "09:05"
    static func time(_ minute: Int) -> String {
        let hours = minute / 60, minutes = minute % 60
        return (hours < 10 ? "0" : "") + String(hours) + ":" + (minutes < 10 ? "0" : "") + String(minutes)
    }
}
