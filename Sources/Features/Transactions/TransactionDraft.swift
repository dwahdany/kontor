import Foundation
import KontorUI

// MARK: - Kind groups and form shapes

/// The five families of transaction kinds, used by the ledger's filter chips and the editor's kind picker.
enum KindGroup: String, CaseIterable, Identifiable, Sendable {
    case trades, income, cash, transfers, costs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trades: "Trades"
        case .income: "Income"
        case .cash: "Cash"
        case .transfers: "Transfers"
        case .costs: "Fees & Taxes"
        }
    }

    var kinds: [Transaction.Kind] {
        switch self {
        case .trades: [.buy, .sell, .deliveryIn, .deliveryOut]
        case .income: [.dividend, .interest]
        case .cash: [.deposit, .withdrawal]
        case .transfers: [.cashTransfer, .securityTransfer]
        case .costs: [.fee, .feeRefund, .tax, .taxRefund, .interestCharge]
        }
    }
}

extension Transaction.Kind {
    var group: KindGroup {
        switch self {
        case .buy, .sell, .deliveryIn, .deliveryOut: .trades
        case .dividend, .interest: .income
        case .deposit, .withdrawal: .cash
        case .cashTransfer, .securityTransfer: .transfers
        case .fee, .feeRefund, .tax, .taxRefund, .interestCharge: .costs
        }
    }

    /// Position in `menuOrder` — a stable sort key for the "Type" column.
    var rank: UInt8 { UInt8(Self.menuOrder.firstIndex(of: self) ?? 0) }

    /// Kinds whose amount is shares × price (the editor shows the full calculation).
    var usesPrice: Bool {
        switch self {
        case .buy, .sell, .deliveryIn, .deliveryOut, .securityTransfer: true
        default: false
        }
    }

    /// Kinds that carry a fee breakdown inside their amount.
    var hasFees: Bool {
        switch self {
        case .buy, .sell, .deliveryIn, .deliveryOut, .dividend, .interest: true
        default: false
        }
    }

    /// Kinds that carry a tax breakdown inside their amount.
    var hasTaxes: Bool { hasFees }

    /// +1: fees and taxes are added to the gross value (you pay them on top); −1: they are deducted
    /// from it (you receive less); 0: the kind has no breakdown.
    var chargeSign: Int64 {
        switch self {
        case .buy, .deliveryIn: 1
        case .sell, .deliveryOut, .dividend, .interest: -1
        default: 0
        }
    }

    /// A security may be named, but does not have to be.
    var allowsOptionalSecurity: Bool {
        switch self {
        case .fee, .feeRefund, .tax, .taxRefund: true
        default: false
        }
    }

    /// Kinds that move no shares but may name the depot they belong to (the depot that paid the
    /// dividend, the depot a fee or tax on a security was charged for). The engine attributes them
    /// to that depot; without one, a security held in several depots counts for each of them.
    var attributesToDepot: Bool {
        switch self {
        case .dividend, .fee, .feeRefund, .tax, .taxRefund: true
        default: false
        }
    }

    /// The kind this one converts to when the cash leg is dropped or added.
    var deliveryCounterpart: Transaction.Kind? {
        switch self {
        case .buy: .deliveryIn
        case .deliveryIn: .buy
        case .sell: .deliveryOut
        case .deliveryOut: .sell
        default: nil
        }
    }

    /// One plain sentence for the kind picker.
    var explanation: String {
        switch self {
        case .buy: "You pay cash and receive shares."
        case .sell: "You give up shares and receive cash."
        case .deliveryIn: "Shares arrive without a payment, e.g. a gift."
        case .deliveryOut: "Shares leave without a payment."
        case .deposit: "Money comes into an account from outside."
        case .withdrawal: "Money leaves an account."
        case .dividend: "A security pays you a distribution."
        case .interest: "An account earns interest."
        case .interestCharge: "An account is charged interest."
        case .fee: "A fee is charged to an account."
        case .feeRefund: "A fee is paid back."
        case .tax: "Tax is charged to an account."
        case .taxRefund: "Tax is paid back."
        case .cashTransfer: "Money moves between your accounts."
        case .securityTransfer: "Shares move between your depots."
        }
    }

    /// ⌃⌥-key that selects the kind while the editor is open.
    var shortcutKey: Character? {
        switch self {
        case .buy: "b"
        case .sell: "s"
        case .dividend: "d"
        case .deposit: "p"
        case .withdrawal: "w"
        case .interest: "i"
        case .fee: "f"
        case .tax: "x"
        case .cashTransfer: "c"
        case .securityTransfer: "t"
        case .deliveryIn: "l"
        case .deliveryOut: "o"
        default: nil
        }
    }
}

// MARK: - Position context

/// What the engine knows about the positions an entry touches, at the end of the entry's day and
/// **without** the entry itself. Feeds the warnings and the "after this you hold …" preview.
struct PositionContext: Equatable, Sendable {
    /// Shares of the security in the depot.
    var sharesHeld: Int64?
    /// Shares of the security in the target depot of a security transfer.
    var counterSharesHeld: Int64?
    /// Balance of the account, in its currency.
    var cashBalance: Int64?
    /// Balance of the target account of a cash transfer, in its currency.
    var counterCashBalance: Int64?
    /// Shares of the security per depot (every depot that holds any); nil without a security.
    var holdings: [UUID: Int64]?

    init(sharesHeld: Int64? = nil, counterSharesHeld: Int64? = nil, cashBalance: Int64? = nil, counterCashBalance: Int64? = nil,
         holdings: [UUID: Int64]? = nil) {
        self.sharesHeld = sharesHeld
        self.counterSharesHeld = counterSharesHeld
        self.cashBalance = cashBalance
        self.counterCashBalance = counterCashBalance
        self.holdings = holdings
    }

    /// Depots that hold shares of the security, largest holding first (ties: by id, so the order is stable).
    var holdingDepots: [UUID] {
        (holdings ?? [:]).filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
            .map(\.key)
    }

    /// Reads the positions from the engine's snapshot of `day` and takes the effect of `original`
    /// (the entry being edited) out again, so the numbers describe the world without it.
    init(ledger: Ledger, day: Day, securityID: UUID?, depotID: UUID?, counterDepotID: UUID?, accountID: UUID?,
         counterAccountID: UUID?, excluding original: Transaction?) {
        let snapshot = ledger.snapshot(on: day)
        let original = original.flatMap { $0.date <= day ? $0 : nil }
        var perDepot: [UUID: Int64]?
        if let securityID, ledger.security(securityID) != nil {
            var held = [UUID: Int64]()
            for holding in snapshot.position(securityID)?.holdings ?? [] { held[holding.depotID, default: 0] += holding.shares.raw }
            if let original, original.securityID == securityID {
                for depot in [original.depotID, original.counterDepotID].compactMap({ $0 }) {
                    held[depot, default: 0] -= original.sharesEffect(on: depot).raw
                }
            }
            perDepot = held.filter { $0.value != 0 }
        }
        holdings = perDepot
        func shares(in depot: UUID?, orWholePosition: Bool) -> Int64? {
            guard let perDepot else { return nil }
            guard let depot else {
                // No depot (a dividend that is not attributed to one): the whole position across depots.
                return orWholePosition ? perDepot.values.reduce(0, +) : nil
            }
            guard ledger.depot(depot) != nil else { return nil }
            return perDepot[depot] ?? 0
        }
        func cash(in account: UUID?) -> Int64? {
            guard let account, ledger.account(account) != nil else { return nil }
            var balance = snapshot.cash(account)?.balance.minor ?? 0
            if let original { balance -= original.cashEffect(on: account) }
            return balance
        }
        sharesHeld = shares(in: depotID, orWholePosition: true)
        counterSharesHeld = shares(in: counterDepotID, orWholePosition: false)
        cashBalance = cash(in: accountID)
        counterCashBalance = cash(in: counterAccountID)
    }
}

// MARK: - Issues

/// One validation finding of the editor.
struct EditorIssue: Equatable, Sendable, Identifiable {
    enum Severity: Sendable { case error, warning }
    enum Field: Sendable { case date, security, depot, account, counterAccount, counterDepot, shares, price, amount, charges, counterAmount }

    var severity: Severity
    var field: Field
    var message: String

    var id: String { message }
}

// MARK: - Draft

/// The editor's calculation and validation model: a value type without any UI or store dependency.
///
/// The numbers form one equation,
///
///     shares × price = gross (security currency)  × rate =  gross  ± fees ± taxes = total
///
/// and the draft keeps it balanced while respecting whatever the user typed last:
///
/// * of **shares, price and amount** the one touched longest ago is the calculated one — except that
///   a share count the user typed is never recalculated (it is the one hard fact of a trade): then
///   the price follows a typed amount and the amount follows a typed price;
/// * **gross vs. total**: the one typed last is kept when fees or taxes change;
/// * with a **foreign-currency security**, typing an amount in the account's currency adjusts the
///   exchange rate (the bank's rate is implied by what was actually paid), typing a rate adjusts the
///   amounts; a typed (or stored) amount in the account's currency survives a change of the date —
///   the day's new rate then changes the value in the security's currency instead.
///
/// Fields that a kind does not use keep their values, so switching between related kinds
/// (buy ↔ inbound delivery, sell ↔ outbound delivery) loses nothing.
struct TransactionDraft: Equatable, Sendable {
    enum Field: Hashable, Sendable { case shares, price, securityGross, gross, fees, taxes, total, counterAmount }
    /// The three quantities of "shares × price = amount".
    enum Quantity: Hashable, Sendable { case shares, price, amount }
    enum Anchor: Hashable, Sendable { case gross, total }
    /// What changed outside the numbers — tells `resolve` which defaults to refresh.
    enum Input: Hashable, Sendable { case kind, date, security, account, counterAccount, depot }

    /// The entry being edited; nil for a new one.
    var original: Transaction?
    var kind: Transaction.Kind
    var date: Day
    var minuteOfDay: Int?
    var securityID: UUID?
    var accountID: UUID?
    var depotID: UUID?
    var counterAccountID: UUID?
    var counterDepotID: UUID?

    /// Shares, raw fixed-point (1e-8).
    var shares: Int64 = 0
    /// Price per share in the **security's** currency, raw fixed-point (1e-8).
    var price: Int64 = 0
    /// shares × price in the security's currency (minor units). Equals `gross` unless `isForeign`.
    var securityGross: Int64 = 0
    /// One unit of the security's currency in units of `currency`.
    var rate: Double = 1
    /// Value before fees and taxes, in `currency`.
    var gross: Int64 = 0
    var fees: Int64 = 0
    var taxes: Int64 = 0
    /// The stored `Transaction.amount`, in `currency`.
    var total: Int64 = 0
    /// Cash transfers between currencies: what arrives, in `counterCurrency`.
    var counterAmount: Int64 = 0
    /// One unit of `currency` in units of `counterCurrency`.
    var counterRate: Double = 1
    var note = ""
    var exDate: Day?
    var source: String?

    /// Currency of the amount: the account's, or the security's for bookings without an account.
    var currency: CurrencyCode
    var securityCurrency: CurrencyCode?
    var counterCurrency: CurrencyCode?

    /// Most recently touched first; the last one is the calculated quantity.
    var order: [Quantity] = [.price, .shares, .amount]
    var anchor = Anchor.gross
    /// Fields the user typed into (or that came from the stored entry / a prefill).
    var pinned: Set<Field> = []
    /// The amount in `currency` (gross / total) is what the user typed, what the stored entry says or
    /// what a prefill asked for — not the product of shares × price × rate. Such an amount is what
    /// really moved on the account, so a new exchange rate must not rewrite it.
    var amountTyped = false
    /// The depot a new entry falls back to when its kind starts to need one.
    var defaultDepotID: UUID?
    /// The user typed an exchange rate (or it is implied by stored amounts).
    var ratePinned = false
    var counterRatePinned = false
    /// The latest quote on or before `date`, in the security's currency.
    var quote: Int64?
    var quoteDay: Day?
    /// The price field currently shows that quote.
    var priceIsQuote = false
    /// An edited entry that had no stored security-currency value: the value derived on loading.
    /// As long as it is untouched nothing is written back, so saving without changes changes nothing.
    var derivedSecurityGross: Int64?
    /// No exchange rate is known for the pair on that date.
    var rateMissing = false
    var counterRateMissing = false

    var isNew: Bool { original == nil }

    // MARK: Shape

    var needsSecurity: Bool { kind.requiresSecurity }
    var showsSecurity: Bool { kind.requiresSecurity || kind.allowsOptionalSecurity }
    var showsFees: Bool { kind.hasFees }
    var showsTaxes: Bool { kind.hasTaxes }
    /// The entry moves no shares but can say which depot it belongs to (dividends; fees and taxes on a security).
    var showsOptionalDepot: Bool { kind.attributesToDepot && securityID != nil }
    /// The security is quoted in another currency than the amount is booked in.
    var isForeign: Bool {
        guard kind.usesPrice || kind == .dividend, let securityCurrency else { return false }
        return securityCurrency != currency
    }
    /// A cash transfer between accounts of different currencies.
    var isCrossCurrencyTransfer: Bool {
        guard kind == .cashTransfer, let counterCurrency else { return false }
        return counterCurrency != currency
    }
    /// The quantity that is currently calculated from the other two (nil when the kind has no price).
    var calculated: Quantity? { kind.usesPrice ? order.last : nil }

    private var charges: Int64 { (showsFees ? fees : 0) + (showsTaxes ? taxes : 0) }
    /// The amount of "shares × price = amount", in the security's currency.
    private var quantityAmount: Int64 { isForeign ? securityGross : gross }

    // MARK: Editing numbers

    /// The user typed `value` into `field`.
    mutating func edit(_ field: Field, _ value: Int64) {
        let value = max(0, value)
        pinned.insert(field)
        switch field {
        case .shares:
            shares = value
            // An emptied field is no longer a typed share count: it may be calculated again.
            if value == 0 { pinned.remove(.shares) }
            if kind.usesPrice {
                touch(.shares)
                solve(edited: .shares)
            }
        case .price:
            price = value
            priceIsQuote = false
            touch(.price)
            solve(edited: .price)
        case .securityGross:
            securityGross = value
            if kind.usesPrice {
                touch(.amount)
                solve(edited: .amount)
            }
            if rate > 0, value != 0 || gross != 0 {
                gross = FixedMath.convert(value, rate: rate)
                anchor = .gross
                amountTyped = false
            }
            syncTotals()
        case .gross:
            gross = value
            anchor = .gross
            amountTyped = value != 0
            amountChanged(byUser: true)
        case .total:
            total = value
            anchor = .total
            gross = total - kind.chargeSign * charges
            amountTyped = value != 0
            amountChanged(byUser: true)
        case .fees, .taxes:
            if field == .fees { fees = value } else { taxes = value }
            if anchor == .total, pinned.contains(.total) {
                gross = total - kind.chargeSign * charges
                amountChanged(byUser: false)
            } else {
                syncTotals()
            }
        case .counterAmount:
            counterAmount = value
            if total != 0, value != 0 {
                counterRate = Double(value) / Double(total)
                counterRatePinned = true
            }
        }
        syncCounterAmount(after: field)
    }

    /// The user typed an exchange rate (security currency → amount currency).
    mutating func editRate(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        rate = value
        ratePinned = true
        rateMissing = false
        guard isForeign, value > 0 else { return }
        if securityGross != 0 {
            gross = FixedMath.convert(securityGross, rate: value)
            anchor = .gross
            amountTyped = false
            syncTotals()
        } else if gross != 0, kind.usesPrice {
            securityGross = FixedMath.saturatingInt64(Double(gross) / value)
            touch(.amount)
            solve(edited: .amount)
        }
        syncCounterAmount(after: .gross)
    }

    /// The user typed the rate of a cross-currency cash transfer (source → target currency).
    mutating func editCounterRate(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        counterRate = value
        counterRatePinned = true
        counterRateMissing = false
        counterAmount = FixedMath.convert(total, rate: value)
    }

    private mutating func touch(_ quantity: Quantity) {
        order.removeAll { $0 == quantity }
        order.insert(quantity, at: 0)
        // Shares the user typed are never the calculated quantity: the other untouched one is.
        if order.count == 3, order[2] == .shares, pinned.contains(.shares), shares != 0 { order.swapAt(1, 2) }
    }

    /// The amount in `currency` changed (typed, or implied by a pinned total and new charges).
    private mutating func amountChanged(byUser: Bool) {
        if isForeign {
            if securityGross != 0 {
                // What was really paid implies the bank's exchange rate.
                if gross > 0 {
                    rate = Double(gross) / Double(securityGross)
                    ratePinned = true
                    rateMissing = false
                }
            } else if kind.usesPrice, rate > 0 {
                securityGross = FixedMath.saturatingInt64(Double(gross) / rate)
                touch(.amount)
                solve(edited: .amount)
            }
        } else {
            securityGross = gross
            if kind.usesPrice {
                if byUser { touch(.amount) }
                solve(edited: .amount)
            }
        }
        syncTotals()
    }

    /// Re-balances "shares × price = amount": the calculated quantity follows the other two; if that
    /// is impossible because one of them is still empty, the single empty one is filled in instead.
    private mutating func solve(edited: Quantity?) {
        guard kind.usesPrice else { return }
        let amount = quantityAmount
        func isSet(_ quantity: Quantity) -> Bool {
            switch quantity {
            case .shares: shares != 0
            case .price: price != 0
            case .amount: amount != 0
            }
        }
        guard let last = order.last else { return }
        let sources = order.dropLast()
        var target: Quantity?
        if sources.allSatisfy(isSet) {
            target = last
        } else {
            let empty = order.filter { !isSet($0) }
            if empty.count == 1, empty[0] != edited {
                // The filled-in quantity is the calculated one from now on.
                target = empty[0]
                order.removeAll { $0 == empty[0] }
                order.append(empty[0])
                if empty[0] == .shares { pinned.remove(.shares) }
            }
        }
        switch target {
        case .amount:
            setQuantityAmount(Price(raw: price).value(of: Shares(raw: shares)))
        case .price:
            if let derived = Price(minor: amount, per: Shares(raw: shares)) {
                price = derived.raw
                priceIsQuote = false
            }
        case .shares:
            shares = mulDiv(amount, Scale.price * Scale.shares / Scale.amount, price)
        case nil:
            break
        }
    }

    private mutating func setQuantityAmount(_ value: Int64) {
        amountTyped = false
        if isForeign {
            securityGross = value
            gross = rate > 0 ? FixedMath.convert(value, rate: rate) : 0
        } else {
            gross = value
            securityGross = value
        }
        anchor = .gross
        syncTotals()
    }

    /// Keeps gross and total apart by exactly the charges, holding on to the anchored one.
    private mutating func syncTotals() {
        if anchor == .total, kind.chargeSign != 0 {
            gross = total - kind.chargeSign * charges
        } else {
            total = gross + kind.chargeSign * charges
        }
        if !isForeign { securityGross = gross }
    }

    private mutating func syncCounterAmount(after field: Field) {
        guard kind == .cashTransfer, field != .counterAmount else { return }
        counterAmount = isCrossCurrencyTransfer ? FixedMath.convert(total, rate: counterRate) : total
    }

    // MARK: Kind

    /// Switches the kind. All entered values survive; the totals are re-balanced for the new kind's
    /// sign (fees are added to a purchase but deducted from a sale).
    mutating func setKind(_ newKind: Transaction.Kind) {
        guard newKind != kind else { return }
        kind = newKind
        if newKind.requiresDepot, depotID == nil, isNew { depotID = defaultDepotID }
        anchor = .gross
        syncTotals()
    }

    // MARK: Context from the document

    /// Re-reads everything that depends on the document: currencies, the quote for the date and the
    /// exchange rates. Values the user typed are never overwritten.
    ///
    /// - Parameter changed: what the user just changed; an empty set only resolves the currencies
    ///   (used when an existing entry is loaded).
    mutating func resolve(_ ledger: Ledger, changed: Set<Input>) {
        let wasForeign = isForeign
        let previousAmount = quantityAmount
        let previousCurrency = currency
        let previousRate = rate
        let previousSecurityCurrency = securityCurrency
        let previousPrice = price

        // A new booking in a depot settles against the depot's reference account.
        if changed.contains(.depot), isNew, kind.requiresAccount, kind.requiresDepot,
           let reference = depotID.flatMap({ ledger.depot($0)?.referenceAccountID }), ledger.account(reference) != nil {
            accountID = reference
        }

        let security = securityID.flatMap { ledger.security($0) }
        securityCurrency = showsSecurity ? security?.currency : nil
        let accountCurrency = accountID.flatMap { ledger.account($0)?.currency }
        if kind.requiresAccount {
            currency = accountCurrency ?? currency
        } else if let original, original.kind == kind, original.securityID == securityID {
            currency = original.amount.currency
        } else {
            currency = security?.currency ?? accountCurrency ?? currency
        }
        counterCurrency = kind == .cashTransfer ? counterAccountID.flatMap { ledger.account($0)?.currency } : nil

        // Quote for the day.
        if kind.usesPrice || kind == .dividend {
            let point = security?.prices.point(onOrBefore: date)
            quote = point?.price.raw
            quoteDay = point?.day
        } else {
            quote = nil
            quoteDay = nil
        }
        let refreshesQuote = !changed.isDisjoint(with: [.date, .security, .kind])
        if kind.usesPrice, refreshesQuote, !pinned.contains(.price) {
            let priceIsCalculated = order.last == .price && shares != 0 && previousAmount != 0
            if !priceIsCalculated, let quote {
                price = quote
                priceIsQuote = true
            } else if !priceIsCalculated, changed.contains(.security) {
                price = 0
                priceIsQuote = false
            }
        }

        // Exchange rate security currency → amount currency.
        let pairChanged = isForeign != wasForeign || currency != previousCurrency || securityCurrency != previousSecurityCurrency
        if isForeign, let securityCurrency {
            let dateChanged = !changed.isDisjoint(with: [.date, .kind])
            if pairChanged || (dateChanged && !ratePinned) {
                let known = ledger.converter.rate(from: securityCurrency, to: currency, on: date)
                rateMissing = known == nil
                rate = known ?? 0
                ratePinned = false
            }
        } else {
            rate = 1
            ratePinned = false
            rateMissing = false
        }

        // Amounts follow the value in the security's currency.
        if !changed.isEmpty, kind.usesPrice || kind == .dividend {
            if isForeign {
                if pairChanged {
                    // Another currency pair: the value in the security's currency is what stays.
                    securityGross = previousAmount
                    amountTyped = false
                }
                if rate > 0, rate != previousRate || pairChanged {
                    if amountTyped, gross != 0 {
                        // The amount on the account is a fact (typed, stored or prefilled); the new
                        // day's rate changes what it was worth in the security's currency.
                        let wasDerived = derivedSecurityGross != nil && derivedSecurityGross == securityGross
                        securityGross = FixedMath.saturatingInt64(Double(gross) / rate)
                        if wasDerived { derivedSecurityGross = securityGross }
                        if kind.usesPrice { solve(edited: .amount) }
                    } else if securityGross != 0 {
                        gross = FixedMath.convert(securityGross, rate: rate)
                        anchor = .gross
                    }
                }
            } else if wasForeign {
                if previousAmount != 0 { gross = previousAmount }
                anchor = .gross
                amountTyped = false
            }
            if kind.usesPrice, price != previousPrice { solve(edited: .price) }
        }
        syncTotals()

        // Cash transfer between currencies.
        if isCrossCurrencyTransfer, let counterCurrency {
            let refreshes = changed.isEmpty || !changed.isDisjoint(with: [.date, .account, .counterAccount, .kind])
            if refreshes, !counterRatePinned {
                let known = ledger.converter.rate(from: currency, to: counterCurrency, on: date)
                counterRateMissing = known == nil
                counterRate = known ?? 0
            }
            counterAmount = FixedMath.convert(total, rate: counterRate)
        } else {
            counterRate = 1
            counterRatePinned = false
            counterRateMissing = false
            counterAmount = total
        }
    }

    // MARK: Construction

    /// A draft for a new entry: the request's prefill first, then sensible defaults (today, the
    /// depot and account used last, the depot's reference account, the quote of the day).
    init(prefill: TransactionPrefill, ledger: Ledger, today: Day, lastUsedDepot: UUID? = nil, lastUsedAccount: UUID? = nil) {
        let kind = prefill.kind ?? .buy
        self.kind = kind
        date = prefill.date ?? today
        securityID = prefill.securityID.flatMap { ledger.security($0)?.id }
        note = prefill.note ?? ""
        source = prefill.source

        func firstActive<E>(_ items: [E], retired: (E) -> Bool, id: (E) -> UUID) -> UUID? {
            (items.first { !retired($0) } ?? items.first).map(id)
        }
        let depot = prefill.depotID.flatMap { ledger.depot($0)?.id }
            ?? lastUsedDepot.flatMap { ledger.depot($0).flatMap { $0.isRetired ? nil : $0.id } }
            ?? firstActive(ledger.depots, retired: \.isRetired, id: \.id)
        defaultDepotID = depot
        // Trades need a depot, so they start with the usual one. A dividend, fee or tax only names
        // a depot when the request does (the editor then proposes the depot that holds the security).
        depotID = kind.attributesToDepot ? prefill.depotID.flatMap { ledger.depot($0)?.id } : depot
        var account = prefill.accountID.flatMap { ledger.account($0)?.id }
        if account == nil, kind.requiresDepot || prefill.depotID != nil {
            account = depot.flatMap { ledger.depot($0)?.referenceAccountID }.flatMap { ledger.account($0)?.id }
        }
        if account == nil, let wanted = prefill.amount?.currency {
            account = ledger.accounts.first { $0.currency == wanted && !$0.isRetired }?.id
        }
        account = account
            ?? lastUsedAccount.flatMap { ledger.account($0).flatMap { $0.isRetired ? nil : $0.id } }
            ?? depot.flatMap { ledger.depot($0)?.referenceAccountID }.flatMap { ledger.account($0)?.id }
            ?? firstActive(ledger.accounts, retired: \.isRetired, id: \.id)
        accountID = account
        counterAccountID = prefill.counterAccountID.flatMap { ledger.account($0)?.id }
        counterDepotID = prefill.counterDepotID.flatMap { ledger.depot($0)?.id }
        currency = account.flatMap { ledger.account($0)?.currency } ?? prefill.amount?.currency ?? ledger.reportingCurrency

        if let value = prefill.fees, value > 0 {
            fees = value
            pinned.insert(.fees)
        }
        if let value = prefill.taxes, value > 0 {
            taxes = value
            pinned.insert(.taxes)
        }
        if let value = prefill.shares, value.raw > 0 {
            shares = value.raw
            pinned.insert(.shares)
        }
        resolve(ledger, changed: [.kind, .date, .security, .account, .counterAccount])
        if shares != 0 {
            if kind.usesPrice {
                touch(.shares)
                solve(edited: .shares)
            }
        }
        if let amount = prefill.amount, amount.minor > 0 {
            if shares != 0, kind.usesPrice {
                // A known total and share count imply the price (not today's quote).
                price = 0
                priceIsQuote = false
                securityGross = 0
                gross = 0
                order = [.shares, .amount, .price]
            }
            edit(.total, amount.minor)
            if shares != 0, kind.usesPrice {
                order = [.shares, .amount, .price]
                pinned.insert(.price)
            }
        }
        // A copied booking brings what it fixed itself: the value in the security's currency (and
        // with it the exchange rate), and the amount that arrived from a cross-currency transfer.
        if isForeign, let stored = prefill.securityGross, stored.minor > 0, stored.currency == securityCurrency, gross > 0 {
            securityGross = stored.minor
            derivedSecurityGross = nil
            rate = Double(gross) / Double(stored.minor)
            ratePinned = true
            rateMissing = false
            pinned.insert(.securityGross)
            if kind.usesPrice, let derived = Price(minor: stored.minor, per: Shares(raw: shares)) { price = derived.raw }
        }
        if kind == .cashTransfer, let arrived = prefill.counterAmount, arrived.minor > 0, arrived.currency == counterCurrency, total != 0 {
            counterAmount = arrived.minor
            pinned.insert(.counterAmount)
            counterRate = Double(arrived.minor) / Double(total)
            counterRatePinned = true
            counterRateMissing = false
        }
        if let minute = prefill.minuteOfDay { minuteOfDay = minute }
        if kind == .dividend, let day = prefill.exDate { exDate = day }
    }

    /// A draft that edits an existing entry.
    init(editing transaction: Transaction, ledger: Ledger) {
        original = transaction
        kind = transaction.kind
        date = transaction.date
        minuteOfDay = transaction.minuteOfDay
        securityID = transaction.securityID
        accountID = transaction.accountID
        depotID = transaction.depotID
        counterAccountID = transaction.counterAccountID
        counterDepotID = transaction.counterDepotID
        note = transaction.note
        exDate = transaction.exDate
        source = transaction.source
        currency = transaction.amount.currency
        shares = max(0, transaction.shares.raw)
        fees = max(0, transaction.fees)
        taxes = max(0, transaction.taxes)
        total = max(0, transaction.amount.minor)
        anchor = .total
        amountTyped = true
        gross = total - kind.chargeSign * ((kind.hasFees ? fees : 0) + (kind.hasTaxes ? taxes : 0))
        securityGross = gross
        pinned = [.shares, .total, .fees, .taxes, .price]
        order = [.shares, .amount, .price]
        resolve(ledger, changed: [])

        if isForeign {
            if let stored = transaction.securityGross, stored.minor > 0 {
                securityGross = stored.minor
                if gross > 0 { rate = Double(gross) / Double(stored.minor) }
                ratePinned = true
                rateMissing = false
            } else {
                securityGross = rate > 0 ? FixedMath.saturatingInt64(Double(gross) / rate) : 0
                derivedSecurityGross = securityGross
            }
        }
        if kind.usesPrice, let derived = Price(minor: quantityAmount, per: Shares(raw: shares)) {
            price = derived.raw
        }
        if kind == .cashTransfer {
            if let arrived = transaction.counterAmount {
                counterAmount = arrived.minor
                pinned.insert(.counterAmount)
                if total != 0 {
                    counterRate = Double(arrived.minor) / Double(total)
                    counterRatePinned = true
                    counterRateMissing = false
                }
            } else {
                counterAmount = isCrossCurrencyTransfer ? FixedMath.convert(total, rate: counterRate) : total
            }
        }
    }

    // MARK: Context from the engine

    /// Takes over what the engine knows about the position for a **new** dividend, fee or tax on a
    /// security: the depot it belongs to (unless one was chosen deliberately: `choosesDepot` false)
    /// and, for dividends, the share count held there (unless one was typed).
    ///
    /// The depot is the current one if it holds the security (the habit: where the last dividend
    /// was booked), else the depot with the largest holding, else none.
    mutating func adopt(_ context: PositionContext, choosesDepot: Bool) {
        guard isNew, showsOptionalDepot, let holdings = context.holdings else { return }
        if choosesDepot {
            let holders = context.holdingDepots
            if depotID.map({ !holders.contains($0) }) ?? true { depotID = holders.first }
        }
        if kind == .dividend, !pinned.contains(.shares) {
            shares = max(0, depotID.map { holdings[$0] ?? 0 } ?? holdings.values.reduce(0, +))
        }
    }

    // MARK: Result

    /// The entry to store. Only the fields the kind uses are written.
    func makeTransaction(id: UUID = UUID()) -> Transaction {
        let usesShares = kind.sharesSign != 0 || kind == .dividend
        var depot: UUID?
        if kind.requiresDepot || showsOptionalDepot {
            // Dividends, fees and taxes on a security say which depot they belong to.
            depot = depotID
        } else if let original, original.kind == kind, original.securityID == securityID {
            // No security, so the form has no depot field: keep whatever an import stored.
            depot = original.depotID
        }
        var stored: Money?
        if isForeign, securityGross > 0, securityGross != derivedSecurityGross, let securityCurrency {
            stored = Money(minor: securityGross, currency: securityCurrency)
        }
        return Transaction(
            id: original?.id ?? id, kind: kind, date: date, minuteOfDay: minuteOfDay,
            accountID: kind.requiresAccount ? accountID : nil,
            depotID: depot,
            counterAccountID: kind == .cashTransfer ? counterAccountID : nil,
            counterDepotID: kind == .securityTransfer ? counterDepotID : nil,
            securityID: showsSecurity ? securityID : nil,
            shares: usesShares ? Shares(raw: shares) : .zero,
            amount: Money(minor: total, currency: currency),
            fees: showsFees ? fees : 0, taxes: showsTaxes ? taxes : 0,
            counterAmount: isCrossCurrencyTransfer ? counterCurrency.map { Money(minor: counterAmount, currency: $0) } : nil,
            securityGross: stored,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines), source: source,
            exDate: kind == .dividend ? exDate : nil)
    }

    /// A draft for the next entry after "Save & New": same kind, day, depot and accounts; numbers,
    /// security and note start over.
    func next(ledger: Ledger) -> TransactionDraft {
        var prefill = TransactionPrefill(kind: kind, date: date, accountID: accountID, depotID: depotID)
        prefill.counterAccountID = counterAccountID
        prefill.counterDepotID = counterDepotID
        var draft = TransactionDraft(prefill: prefill, ledger: ledger, today: date)
        draft.minuteOfDay = nil
        return draft
    }

    // MARK: Effects and validation

    /// Signed change of the share position in `depotID`.
    var sharesDelta: Int64 { kind.sharesSign * shares }
    /// Signed change of the balance of `accountID`.
    var cashDelta: Int64 { kind.cashSign * total }

    /// Everything that is wrong (errors block saving) or merely suspicious (warnings do not).
    func issues(context: PositionContext, today: Day, names: Names = Names()) -> [EditorIssue] {
        var result = [EditorIssue]()
        func error(_ field: EditorIssue.Field, _ message: String) { result.append(EditorIssue(severity: .error, field: field, message: message)) }
        func warning(_ field: EditorIssue.Field, _ message: String) { result.append(EditorIssue(severity: .warning, field: field, message: message)) }

        if needsSecurity, securityID == nil { error(.security, "Choose a security.") }
        if kind.requiresDepot, depotID == nil { error(.depot, kind == .securityTransfer ? "Choose the depot the shares leave." : "Choose a depot.") }
        if kind.requiresAccount, accountID == nil { error(.account, kind == .cashTransfer ? "Choose the account the money leaves." : "Choose an account.") }
        if kind == .cashTransfer {
            if counterAccountID == nil {
                error(.counterAccount, "Choose the account the money goes to.")
            } else if counterAccountID == accountID {
                error(.counterAccount, "The money cannot go to the account it comes from.")
            }
        }
        if kind == .securityTransfer {
            if counterDepotID == nil {
                error(.counterDepot, "Choose the depot the shares go to.")
            } else if counterDepotID == depotID {
                error(.counterDepot, "The shares cannot go to the depot they come from.")
            }
        }
        if kind.sharesSign != 0, shares == 0 { error(.shares, "Enter the number of shares.") }
        if gross < 0 || total < 0 {
            error(.charges, kind.chargeSign < 0 ? "Fees and taxes are higher than the gross amount." : "Fees and taxes are higher than the total.")
        } else if kind.usesPrice ? gross == 0 : total == 0 {
            // For trades the value itself must be known: a total that consists of fees only is no trade.
            if kind.requiresAccount {
                if rateIsUnknown, securityGross != 0 {
                    error(.amount, "No exchange rate from \(securityCurrency ?? "") to \(currency) is known for this date — enter the rate or the amount in \(currency).")
                } else {
                    error(.amount, kind.usesPrice ? "Enter a price or the total amount." : "Enter an amount.")
                }
            } else if shares != 0 {
                warning(.price, "Without a price these shares are booked with a value of zero.")
            }
        }
        if isCrossCurrencyTransfer, total != 0, counterAmount == 0 {
            error(.counterAmount, "Enter the amount that arrives in \(counterCurrency ?? "the target currency").")
        }

        if date > today { warning(.date, "This date is in the future.") }
        if rateIsUnknown, !result.contains(where: { $0.severity == .error && $0.field == .amount }) {
            warning(.amount, "No exchange rate from \(securityCurrency ?? "") to \(currency) is known for this date — enter the rate or the amount in \(currency).")
        }
        if isCrossCurrencyTransfer, counterRateMissing, !counterRatePinned, counterAmount == 0, total == 0 {
            warning(.counterAmount, "No exchange rate from \(currency) to \(counterCurrency ?? "") is known for this date.")
        }
        if kind.sharesSign < 0, shares > 0, let held = context.sharesHeld, shares > held {
            let depot = names.depot.map { " in \($0)" } ?? ""
            if held <= 0 {
                warning(.shares, "You hold no shares of this security\(depot) on this date.")
            } else {
                warning(.shares, "You hold only \(Fmt.shares(Shares(raw: held))) shares\(depot) on this date — \(Fmt.shares(Shares(raw: shares - held))) fewer than entered.")
            }
        }
        if kind == .dividend, securityID != nil, let held = context.sharesHeld, held <= 0 {
            let depot = depotID == nil ? "" : (names.depot.map { " in \($0)" } ?? " in this depot")
            warning(depotID == nil ? .security : .depot, "You hold no shares of this security\(depot) on this date.")
        }
        if showsOptionalDepot, depotID == nil, context.holdingDepots.count > 1 {
            warning(.depot, "This security is held in \(context.holdingDepots.count) depots — choose the depot this \(kind == .dividend ? "dividend" : "entry") belongs to, otherwise it counts in full for each of them.")
        }
        if kind.cashSign < 0, total > 0, let balance = context.cashBalance, balance + cashDelta < 0 {
            let account = names.account ?? "The account"
            warning(.amount, "\(account) holds only \(Fmt.money(minor: balance, currency: currency)) on this date — this leaves it overdrawn by \(Fmt.money(minor: -(balance + cashDelta), currency: currency)).")
        }
        if kind.usesPrice, let quote, quote > 0, price > 0, !priceIsQuote, shares != 0 {
            let deviation = Double(price) / Double(quote) - 1
            if abs(deviation) >= 0.25, let quoteDay {
                let direction = deviation > 0 ? "above" : "below"
                warning(.price, "The price is \(Fmt.percent(abs(deviation), decimals: 0)) \(direction) the quote of \(Fmt.day(quoteDay, style: .medium)) (\(Fmt.price(Price(raw: quote), currency: securityCurrency))).")
            }
        }
        return result
    }

    /// No exchange rate is on file for the day and none was typed or implied by the amounts.
    private var rateIsUnknown: Bool { isForeign && rateMissing && !ratePinned }

    /// Display names used in messages (optional — tests leave them out).
    struct Names: Equatable, Sendable {
        var account: String?
        var depot: String?
        init(account: String? = nil, depot: String? = nil) {
            self.account = account
            self.depot = depot
        }
    }

    /// The positions after this entry, for the preview line.
    struct Outcome: Equatable, Sendable {
        var shares: Int64?
        var counterShares: Int64?
        var cash: Int64?
        var counterCash: Int64?
    }

    func outcome(context: PositionContext) -> Outcome {
        var outcome = Outcome()
        if kind.sharesSign != 0, securityID != nil {
            outcome.shares = context.sharesHeld.map { $0 + sharesDelta }
            if kind == .securityTransfer { outcome.counterShares = context.counterSharesHeld.map { $0 + shares } }
        }
        if kind.cashSign != 0 {
            outcome.cash = context.cashBalance.map { $0 + cashDelta }
            if kind == .cashTransfer { outcome.counterCash = context.counterCashBalance.map { $0 + counterAmount } }
        }
        return outcome
    }
}
