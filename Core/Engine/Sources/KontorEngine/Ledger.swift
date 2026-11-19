import Foundation
import KontorModel

/// A compact, index-based form of one valid transaction, precomputed for the calculation passes.
/// All `…Rep` amounts are in the ledger's reporting currency, converted at the transaction day's rate.
struct Entry: Sendable {
    var day: Int32
    var kind: Transaction.Kind
    /// Index into `Ledger.transactions`.
    var transaction: Int32
    var security: Int32 = -1
    var account: Int32 = -1
    var counterAccount: Int32 = -1
    /// The (security, depot) pair this entry relates to. Bookings without a depot are attributed to
    /// the depot holding the security at that time; −1 if there is none or it is ambiguous.
    var holding: Int32 = -1
    /// Target holding of a `securityTransfer`.
    var counterHolding: Int32 = -1
    /// Currency index of `amount` (the account currency for cash-affecting kinds).
    var currency: Int32 = 0
    /// Unsigned share count of the transaction.
    var shares: Int64 = 0
    /// Signed change of `holding`'s share count (`counterHolding` receives `+shares`).
    var sharesDelta: Int64 = 0
    /// Signed change of `account`'s balance in its own currency.
    var cashDelta: Int64 = 0
    /// Amount credited to `counterAccount` in its own currency.
    var counterCashDelta: Int64 = 0
    var amountRep: Int64 = 0
    var feesRep: Int64 = 0
    var taxesRep: Int64 = 0
    /// `counterCashDelta` in the reporting currency.
    var counterAmountRep: Int64 = 0
    /// Gross value (before fees and taxes) in the security's currency, for share-moving kinds.
    var grossSec: Int64 = 0
    /// True if an amount of this entry could not be converted to the reporting currency.
    var rateMissing = false
}

/// An immutable, precomputed, thread-safe index of a `PortfolioFile`. Every calculation in the
/// engine takes a `Ledger` as input; build it once per document revision (a few milliseconds for
/// 10 000 transactions) and share it freely between threads.
///
/// The ledger provides
/// * transactions in chronological order (identical to `Transaction.chronological`),
/// * transactions grouped by security / account / depot,
/// * id → entity lookups,
/// * a `CurrencyConverter` and the reporting currency all results are expressed in,
/// * effective price lookups (quotes, or prices derived from transactions when a security has none).
public struct Ledger: Sendable {
    /// Name of the source file.
    public let name: String
    public let settings: Settings
    /// Currency all results are converted to (defaults to `settings.baseCurrency`).
    public let reportingCurrency: CurrencyCode
    public let securities: [Security]
    public let accounts: [Account]
    public let depots: [Depot]
    /// All transactions of the file in the order of `Transaction.chronological` (including ones
    /// flagged invalid). Calculations process them in this order, with one exception for bookings
    /// that share a day and time of day: one that would overdraw a holding is processed after the
    /// same-moment bookings that add shares to it (see `API.md`, "Same-day ordering").
    public let transactions: [Transaction]
    public let converter: CurrencyConverter
    /// Problems found while indexing (invalid transactions, derived prices, unconvertible currencies).
    public let diagnostics: [EngineDiagnostic]
    /// Date of the first / last valid transaction; nil for an empty ledger.
    public let firstTransactionDay: Day?
    public let lastTransactionDay: Day?

    // MARK: Internal index

    let entries: [Entry]
    /// Distinct (security, depot) pairs, addressed by `Entry.holding`.
    let holdingSecurity: [Int32]
    let holdingDepot: [Int32]
    /// Interned currencies; index 0 is the reporting currency.
    let currencies: [CurrencyCode]
    /// Conversion route of each interned currency into the reporting currency (nil = unavailable).
    let currencyPaths: [CurrencyConverter.Path?]
    let securityCurrency: [Int32]
    let accountCurrency: [Int32]
    /// Effective prices of all securities, flattened: security `s` owns `priceOffsets[s]..<priceOffsets[s+1]`.
    let priceOffsets: [Int]
    let priceDays: [Int32]
    let priceValues: [Int64]

    private let securityIndexByID: [UUID: Int32]
    private let accountIndexByID: [UUID: Int32]
    private let depotIndexByID: [UUID: Int32]
    private let transactionsBySecurity: [[Int32]]
    private let transactionsByAccount: [[Int32]]
    private let transactionsByDepot: [[Int32]]

    // MARK: Building

    private struct SortKey {
        var day: Int32
        var minute: Int32
        var hi: UInt64
        var lo: UInt64
        var index: Int32

        @inline(__always)
        static func < (a: SortKey, b: SortKey) -> Bool {
            if a.day != b.day { return a.day < b.day }
            if a.minute != b.minute { return a.minute < b.minute }
            if a.hi != b.hi { return a.hi < b.hi }
            return a.lo < b.lo
        }
    }

    /// Indexes `file`. `reportingCurrency` overrides the file's base currency for all results.
    public init(_ file: PortfolioFile, reportingCurrency: CurrencyCode? = nil) {
        let rep = reportingCurrency ?? file.settings.baseCurrency
        let converter = CurrencyConverter(series: file.exchangeRates, baseCurrency: file.settings.baseCurrency)
        var diagnostics = DiagnosticCollector()

        // Entities.
        var securityIndex = [UUID: Int32](minimumCapacity: file.securities.count)
        for (i, s) in file.securities.enumerated() where securityIndex[s.id] == nil { securityIndex[s.id] = Int32(i) }
        var accountIndex = [UUID: Int32](minimumCapacity: file.accounts.count)
        for (i, a) in file.accounts.enumerated() where accountIndex[a.id] == nil { accountIndex[a.id] = Int32(i) }
        var depotIndex = [UUID: Int32](minimumCapacity: file.depots.count)
        for (i, d) in file.depots.enumerated() where depotIndex[d.id] == nil { depotIndex[d.id] = Int32(i) }

        // Currencies.
        var currencies: [CurrencyCode] = [rep]
        var currencyPaths: [CurrencyConverter.Path?] = [.identity]
        var currencyIndex: [CurrencyCode: Int32] = [rep: 0]
        func intern(_ code: CurrencyCode) -> Int32 {
            if let i = currencyIndex[code] { return i }
            let i = Int32(currencies.count)
            currencies.append(code)
            let path = converter.path(from: code, to: rep)
            if path == nil { diagnostics.add(.missingExchangeRate(from: code, to: rep)) }
            currencyPaths.append(path)
            currencyIndex[code] = i
            return i
        }
        let securityCurrency = file.securities.map { intern($0.currency) }
        let accountCurrency = file.accounts.map { intern($0.currency) }

        // Chronological order. Comparing the big-endian UUID bytes is equivalent to comparing
        // `uuidString` (as `Transaction.chronological` does) but needs no string allocations.
        let source = file.transactions
        var keys = [SortKey]()
        keys.reserveCapacity(source.count)
        var sorted = true
        for (i, t) in source.enumerated() {
            let (hi, lo) = withUnsafeBytes(of: t.id.uuid) { raw in
                (
                    UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                    UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
                )
            }
            let key = SortKey(
                day: t.date.rawValue, minute: Int32(truncatingIfNeeded: t.minuteOfDay ?? -1), hi: hi, lo: lo,
                index: Int32(i)
            )
            if let last = keys.last, key < last { sorted = false }
            keys.append(key)
        }
        let transactions: [Transaction]
        if sorted {
            transactions = source
        } else {
            keys.sort(by: <)
            transactions = keys.map { source[Int($0.index)] }
        }

        // Entries.
        var entries = [Entry]()
        entries.reserveCapacity(transactions.count)
        var holdingIndex = [UInt64: Int32]()
        var holdingSecurity: [Int32] = []
        var holdingDepot: [Int32] = []
        // Running share counts, used to attribute depot-less bookings (see below).
        var runningShares: [Int64] = []
        var holdingsOfSecurity = [[Int32]](repeating: [], count: file.securities.count)
        var lastMovedHolding = [Int32](repeating: -1, count: file.securities.count)
        func holding(_ security: Int32, _ depot: Int32) -> Int32 {
            let key = UInt64(UInt32(bitPattern: security)) << 32 | UInt64(UInt32(bitPattern: depot))
            if let h = holdingIndex[key] { return h }
            let h = Int32(holdingSecurity.count)
            holdingIndex[key] = h
            holdingSecurity.append(security)
            holdingDepot.append(depot)
            runningShares.append(0)
            holdingsOfSecurity[Int(security)].append(h)
            return h
        }
        var bySecurity = [[Int32]](repeating: [], count: file.securities.count)
        var byAccount = [[Int32]](repeating: [], count: file.accounts.count)
        var byDepot = [[Int32]](repeating: [], count: file.depots.count)
        let needsDerivedPrices = file.securities.map { $0.prices.isEmpty }
        var derivedPoints = [Int: [PricePoint]]()

        @inline(__always) func rateToRep(_ currency: Int32, _ day: Day) -> Double {
            if currency == 0 { return 1 }
            guard let path = currencyPaths[Int(currency)] else { return .nan }
            return converter.rate(along: path, on: day)
        }

        for (ti, t) in transactions.enumerated() {
            let kind = t.kind
            var security: Int32 = -1
            if let id = t.securityID, let s = securityIndex[id] {
                security = s
            } else if kind.requiresSecurity {
                diagnostics.add(.invalidTransaction(
                    transactionID: t.id, reason: t.securityID == nil ? "missing security" : "unknown security"))
                continue
            }
            var account: Int32 = -1
            var counterAccount: Int32 = -1
            if kind.requiresAccount {
                guard let id = t.accountID, let a = accountIndex[id] else {
                    diagnostics.add(.invalidTransaction(
                        transactionID: t.id, reason: t.accountID == nil ? "missing account" : "unknown account"))
                    continue
                }
                account = a
                if kind == .cashTransfer {
                    guard let cid = t.counterAccountID, let b = accountIndex[cid] else {
                        diagnostics.add(.invalidTransaction(
                            transactionID: t.id,
                            reason: t.counterAccountID == nil ? "missing target account" : "unknown target account"))
                        continue
                    }
                    counterAccount = b
                }
            }
            var depot: Int32 = -1
            var counterDepot: Int32 = -1
            if kind.requiresDepot {
                guard let id = t.depotID, let d = depotIndex[id] else {
                    diagnostics.add(.invalidTransaction(
                        transactionID: t.id, reason: t.depotID == nil ? "missing depot" : "unknown depot"))
                    continue
                }
                depot = d
                if kind == .securityTransfer {
                    guard let cid = t.counterDepotID, let d2 = depotIndex[cid] else {
                        diagnostics.add(.invalidTransaction(
                            transactionID: t.id,
                            reason: t.counterDepotID == nil ? "missing target depot" : "unknown target depot"))
                        continue
                    }
                    counterDepot = d2
                }
            } else if let id = t.depotID, let d = depotIndex[id] {
                depot = d // informational depot of dividends, fees and taxes
            }

            var e = Entry(day: t.date.rawValue, kind: kind, transaction: Int32(ti))
            e.security = security
            e.account = account
            e.counterAccount = counterAccount
            if security >= 0, depot >= 0 { e.holding = holding(security, depot) }
            if security >= 0, counterDepot >= 0 { e.counterHolding = holding(security, counterDepot) }
            if security >= 0, e.holding < 0 {
                // A dividend, fee or tax of a security that names no depot (Portfolio Performance
                // books these on the account only) belongs to the depot holding the security at
                // that time — or, once it is sold, to the depot it was last moved in. Only if
                // several depots hold it at once does it stay unattributed (see `ResolvedScope`).
                var sole: Int32 = -1, holders = 0
                for h in holdingsOfSecurity[Int(security)] where runningShares[Int(h)] != 0 {
                    sole = h
                    holders += 1
                }
                if holders == 1 { e.holding = sole } else if holders == 0 { e.holding = lastMovedHolding[Int(security)] }
            }
            e.currency = account >= 0 ? accountCurrency[Int(account)] : intern(t.amount.currency)
            e.shares = t.shares.raw
            e.sharesDelta = kind.sharesSign * t.shares.raw
            if e.sharesDelta != 0, e.holding >= 0 {
                runningShares[Int(e.holding)] &+= e.sharesDelta
                lastMovedHolding[Int(security)] = e.holding
            }
            if e.counterHolding >= 0 {
                runningShares[Int(e.counterHolding)] &+= t.shares.raw
                lastMovedHolding[Int(security)] = e.counterHolding
            }
            e.cashDelta = kind.cashSign * t.amount.minor

            let rate = rateToRep(e.currency, t.date)
            if rate.isNaN {
                e.rateMissing = true
            } else if e.currency == 0 {
                e.amountRep = t.amount.minor
                e.feesRep = t.fees
                e.taxesRep = t.taxes
            } else {
                e.amountRep = FixedMath.convert(t.amount.minor, rate: rate)
                e.feesRep = FixedMath.convert(t.fees, rate: rate)
                e.taxesRep = FixedMath.convert(t.taxes, rate: rate)
            }
            if counterAccount >= 0 {
                let credited = (t.counterAmount ?? t.amount).minor
                e.counterCashDelta = credited
                let c = accountCurrency[Int(counterAccount)]
                let r = rateToRep(c, t.date)
                if r.isNaN { e.rateMissing = true } else { e.counterAmountRep = c == 0 ? credited : FixedMath.convert(credited, rate: r) }
            }
            if security >= 0, kind.sharesSign != 0, kind != .securityTransfer {
                let sc = securityCurrency[Int(security)]
                if let gross = t.securityGross, gross.currency == currencies[Int(sc)] {
                    e.grossSec = gross.minor
                } else if sc == e.currency {
                    e.grossSec = t.grossMinor
                } else if let r = converter.rate(from: currencies[Int(e.currency)], to: currencies[Int(sc)], on: t.date) {
                    e.grossSec = FixedMath.convert(t.grossMinor, rate: r)
                }
                if needsDerivedPrices[Int(security)], let price = Price(minor: e.grossSec, per: t.shares), price.raw > 0 {
                    derivedPoints[Int(security), default: []].append(PricePoint(day: t.date, price: price))
                }
            }
            entries.append(e)

            if security >= 0 { bySecurity[Int(security)].append(Int32(ti)) }
            if account >= 0 { byAccount[Int(account)].append(Int32(ti)) }
            if counterAccount >= 0, counterAccount != account { byAccount[Int(counterAccount)].append(Int32(ti)) }
            if depot >= 0 { byDepot[Int(depot)].append(Int32(ti)) }
            if counterDepot >= 0, counterDepot != depot { byDepot[Int(counterDepot)].append(Int32(ti)) }
        }

        Self.deferOverdraws(&entries, transactions: transactions, holdingCount: holdingSecurity.count)

        // Effective prices, flattened into two contiguous columns.
        var priceOffsets = [Int]()
        priceOffsets.reserveCapacity(file.securities.count + 1)
        var total = 0
        for s in file.securities { total += s.prices.count }
        var priceDays = [Int32]()
        var priceValues = [Int64]()
        priceDays.reserveCapacity(total)
        priceValues.reserveCapacity(total)
        for (i, s) in file.securities.enumerated() {
            priceOffsets.append(priceDays.count)
            if !needsDerivedPrices[i] {
                priceDays.append(contentsOf: s.prices.days)
                priceValues.append(contentsOf: s.prices.values)
            } else if let points = derivedPoints[i] {
                let derived = PriceSeries(points)
                priceDays.append(contentsOf: derived.days)
                priceValues.append(contentsOf: derived.values)
                diagnostics.add(.pricesDerivedFromTransactions(securityID: s.id))
            }
        }
        priceOffsets.append(priceDays.count)

        self.name = file.name
        self.settings = file.settings
        self.reportingCurrency = rep
        self.securities = file.securities
        self.accounts = file.accounts
        self.depots = file.depots
        self.transactions = transactions
        self.converter = converter
        self.diagnostics = diagnostics.items
        self.firstTransactionDay = entries.first.map { Day(rawValue: $0.day) }
        self.lastTransactionDay = entries.last.map { Day(rawValue: $0.day) }
        self.entries = entries
        self.holdingSecurity = holdingSecurity
        self.holdingDepot = holdingDepot
        self.currencies = currencies
        self.currencyPaths = currencyPaths
        self.securityCurrency = securityCurrency
        self.accountCurrency = accountCurrency
        self.priceOffsets = priceOffsets
        self.priceDays = priceDays
        self.priceValues = priceValues
        self.securityIndexByID = securityIndex
        self.accountIndexByID = accountIndex
        self.depotIndexByID = depotIndex
        self.transactionsBySecurity = bySecurity
        self.transactionsByAccount = byAccount
        self.transactionsByDepot = byDepot
    }

    /// Resolves the order of bookings whose sequence the data does not really tell:
    ///
    /// - bookings that share a day *and* a time of day (typically untimed imports), where only the
    ///   transaction id decides the sequence, and
    /// - **untimed** bookings against timed ones of the same day. "No time" sorts first, but it
    ///   means "some time that day": a transfer or sale entered by hand without a time on the day
    ///   of a purchase that carries one (a broker statement) happened after the purchase.
    ///
    /// If such a booking would take more shares out of a holding than it holds while a later
    /// booking it may float past adds shares to that holding, the adding booking is processed
    /// first. Otherwise a purchase and its sale (or transfer) on the same day would show up as a
    /// short sale with a wrong cost basis. Nothing else is reordered, timed bookings keep their
    /// order among themselves, and `transactions` keeps the order of `Transaction.chronological`.
    private static func deferOverdraws(_ entries: inout [Entry], transactions: [Transaction], holdingCount: Int) {
        guard entries.count > 1 else { return }
        var shares = [Int64](repeating: 0, count: holdingCount)
        @inline(__always) func book(_ e: Entry) {
            if e.holding >= 0 { shares[Int(e.holding)] &+= e.sharesDelta }
            if e.counterHolding >= 0 { shares[Int(e.counterHolding)] &+= e.shares }
        }
        @inline(__always) func moment(_ e: Entry) -> Int { transactions[Int(e.transaction)].minuteOfDay ?? -1 }
        /// Whether `e` adds shares to holding `h`.
        @inline(__always) func adds(_ e: Entry, to h: Int32) -> Bool {
            (e.holding == h && e.sharesDelta > 0) || (e.counterHolding == h && e.holding != h && e.shares > 0)
        }
        var i = 0
        while i < entries.count {
            // [i, dayEnd): one day.
            var dayEnd = i + 1
            let day = entries[i].day
            while dayEnd < entries.count, entries[dayEnd].day == day { dayEnd += 1 }
            if dayEnd - i > 1 {
                var k = i
                while k < dayEnd {
                    let e = entries[k]
                    if e.holding >= 0, e.sharesDelta < 0, e.counterHolding != e.holding {
                        let h = e.holding
                        // How far later additions may be pulled forward from: the whole day for an
                        // untimed removal, the same moment for a timed one.
                        let minute = moment(e)
                        var limit = dayEnd
                        if minute >= 0 {
                            limit = k + 1
                            while limit < dayEnd, moment(entries[limit]) == minute { limit += 1 }
                        }
                        // Pull later additions forward until the position covers the removal.
                        var held = shares[Int(h)]
                        var next = k + 1
                        while held >= 0, held &+ e.sharesDelta < 0, next < limit {
                            if adds(entries[next], to: h) {
                                let moved = entries.remove(at: next)
                                entries.insert(moved, at: k)
                                book(moved)
                                held = shares[Int(h)]
                                k += 1
                            }
                            next += 1
                        }
                    }
                    book(entries[k])
                    k += 1
                }
            } else {
                book(entries[i])
            }
            i = dayEnd
        }
    }

    // MARK: Entity lookup

    public func security(_ id: UUID) -> Security? { securityIndexByID[id].map { securities[Int($0)] } }
    public func account(_ id: UUID) -> Account? { accountIndexByID[id].map { accounts[Int($0)] } }
    public func depot(_ id: UUID) -> Depot? { depotIndexByID[id].map { depots[Int($0)] } }

    /// Position of the entity in `securities` / `accounts` / `depots`.
    public func securityIndex(_ id: UUID) -> Int? { securityIndexByID[id].map(Int.init) }
    public func accountIndex(_ id: UUID) -> Int? { accountIndexByID[id].map(Int.init) }
    public func depotIndex(_ id: UUID) -> Int? { depotIndexByID[id].map(Int.init) }

    // MARK: Grouped transactions (chronological)

    /// Valid transactions that reference the security.
    public func transactions(forSecurity id: UUID) -> [Transaction] {
        guard let i = securityIndexByID[id] else { return [] }
        return transactionsBySecurity[Int(i)].map { transactions[Int($0)] }
    }

    /// Valid transactions that debit or credit the account (including incoming cash transfers).
    public func transactions(forAccount id: UUID) -> [Transaction] {
        guard let i = accountIndexByID[id] else { return [] }
        return transactionsByAccount[Int(i)].map { transactions[Int($0)] }
    }

    /// Valid transactions that reference the depot (including incoming security transfers).
    public func transactions(forDepot id: UUID) -> [Transaction] {
        guard let i = depotIndexByID[id] else { return [] }
        return transactionsByDepot[Int(i)].map { transactions[Int($0)] }
    }

    /// Number of valid transactions per security, parallel to `securities`.
    public var transactionCountBySecurity: [Int] { transactionsBySecurity.map(\.count) }

    // MARK: Prices and rates

    /// The effective quote of a security on `day`: the most recent price on or before `day`, or the
    /// first known price if `day` precedes the series. For securities without quotes, prices derived
    /// from their transactions are used. Nil if no price is known at all.
    public func price(of securityID: UUID, on day: Day) -> PricePoint? {
        guard let s = securityIndexByID[securityID] else { return nil }
        let i = priceIndex(Int(s), on: day.rawValue)
        return i < 0 ? nil : PricePoint(day: Day(rawValue: priceDays[i]), price: Price(raw: priceValues[i]))
    }

    /// Absolute index into the flattened price columns of the effective price on `day`; −1 if none.
    @inline(__always)
    func priceIndex(_ security: Int, on day: Int32) -> Int {
        let start = priceOffsets[security], end = priceOffsets[security + 1]
        guard start < end else { return -1 }
        var lo = start, hi = end
        while lo < hi {
            let mid = (lo &+ hi) >> 1
            if priceDays[mid] <= day { lo = mid &+ 1 } else { hi = mid }
        }
        return lo == start ? start : lo - 1
    }

    /// Rate from the interned currency into the reporting currency on `day`; NaN if unavailable.
    @inline(__always)
    func rateToReporting(_ currency: Int32, on day: Int32) -> Double {
        if currency == 0 { return 1 }
        guard let path = currencyPaths[Int(currency)] else { return .nan }
        return converter.rate(along: path, on: Day(rawValue: day))
    }

    /// Unweighted market value of `shares` of a security on `day`: in the security's currency and in
    /// the reporting currency. `valued` is false if the price or the exchange rate is missing.
    func value(security: Int, shares: Int64, on day: Int32) -> (sec: Int64, rep: Int64, priceIndex: Int, valued: Bool) {
        let pi = priceIndex(security, on: day)
        guard pi >= 0 else { return (0, 0, -1, false) }
        let v = FixedMath.marketValue(priceRaw: priceValues[pi], sharesRaw: shares)
        let c = securityCurrency[security]
        if c == 0 { return (v, v, pi, true) }
        let r = rateToReporting(c, on: day)
        if r.isNaN { return (v, 0, pi, false) }
        return (v, FixedMath.convert(v, rate: r), pi, true)
    }

    /// Unweighted value of an account balance in the reporting currency on `day`.
    func cashValue(account: Int, balance: Int64, on day: Int32) -> (rep: Int64, valued: Bool) {
        let c = accountCurrency[account]
        if c == 0 { return (balance, true) }
        let r = rateToReporting(c, on: day)
        if r.isNaN { return (0, false) }
        return (FixedMath.convert(balance, rate: r), true)
    }

    /// Number of entries with `day <= day` (entries are sorted by day).
    func entryCount(through day: Int32) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo &+ hi) >> 1
            if entries[mid].day <= day { lo = mid &+ 1 } else { hi = mid }
        }
        return lo
    }
}
