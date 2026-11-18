import Foundation
import KontorEngine
import KontorModel

/// Parses "YYYY-MM-DD".
func d(_ iso: String) -> Day { Day(iso: iso)! }

/// Minor units from a decimal amount (12.34 → 1234).
func minor(_ value: Double) -> Int64 { Int64((value * 100).rounded()) }

/// Builds small hand-written portfolios with deterministic ids (ids ascend in creation order, so
/// same-day transactions are processed in the order they were added).
struct Fixture {
    var file = PortfolioFile(name: "Fixture")
    private var counter = 0

    mutating func uuid() -> UUID {
        counter += 1
        let tail = String(counter)
        return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - tail.count) + tail)!
    }

    mutating func account(_ name: String, _ currency: String = "EUR") -> UUID {
        let id = uuid()
        file.accounts.append(Account(id: id, name: name, currency: currency))
        return id
    }

    mutating func depot(_ name: String) -> UUID {
        let id = uuid()
        file.depots.append(Depot(id: id, name: name))
        return id
    }

    mutating func security(_ name: String, _ currency: String = "EUR", prices: [(String, Double)] = []) -> UUID {
        let id = uuid()
        let series = PriceSeries(prices.map { PricePoint(day: d($0.0), price: Price($0.1)) })
        file.securities.append(Security(id: id, name: name, currency: currency, prices: series))
        return id
    }

    mutating func rates(_ base: String, _ quote: String, _ points: [(String, Double)]) {
        file.exchangeRates.append(ExchangeRateSeries(
            base: base, quote: quote, days: points.map { d($0.0).rawValue }, rates: points.map(\.1)))
    }

    @discardableResult
    mutating func add(
        _ kind: Transaction.Kind, _ date: String, account: UUID? = nil, depot: UUID? = nil, security: UUID? = nil,
        shares: Double = 0, amount: Double, fees: Double = 0, taxes: Double = 0, currency: String = "EUR",
        counterAccount: UUID? = nil, counterDepot: UUID? = nil, counterAmount: Money? = nil,
        securityGross: Money? = nil, minute: Int? = nil
    ) -> UUID {
        let id = uuid()
        file.transactions.append(Transaction(
            id: id, kind: kind, date: d(date), minuteOfDay: minute, accountID: account, depotID: depot,
            counterAccountID: counterAccount, counterDepotID: counterDepot, securityID: security,
            shares: Shares(shares), amount: Money(amount, currency), fees: minor(fees), taxes: minor(taxes),
            counterAmount: counterAmount, securityGross: securityGross))
        return id
    }

    var ledger: Ledger { Ledger(file) }
}

/// Deterministic pseudo-random generator (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

struct RandomPortfolioOptions {
    var seed: UInt64 = 1
    var securities = 8
    var days = 800
    var transactions = 400
    /// Adds a USD account, USD securities and a EUR/USD rate series.
    var multiCurrency = true
    /// Occasionally sells securities that are not held (short positions).
    var allowShort = false
    /// Fraction of the day range (from the start) that receives transactions.
    var activeFraction = 0.85
    var start = Day(year: 2015, month: 1, day: 1)
    var costMethod = CostMethod.fifo
}

/// Generates a deterministic random portfolio that exercises every transaction kind.
func makeRandomPortfolio(_ o: RandomPortfolioOptions) -> PortfolioFile {
    var rng = SplitMix64(seed: o.seed)
    var file = PortfolioFile(name: "Random \(o.seed)")
    file.settings.costMethod = o.costMethod
    file.settings.riskFreeRate = 0.01
    var idCounter: UInt64 = 0
    func nextID() -> UUID {
        idCounter += 1
        let a = rng.next(), b = idCounter
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: a >> 56), UInt8(truncatingIfNeeded: a >> 48), UInt8(truncatingIfNeeded: a >> 40),
            UInt8(truncatingIfNeeded: a >> 32), UInt8(truncatingIfNeeded: a >> 24), UInt8(truncatingIfNeeded: a >> 16),
            UInt8(truncatingIfNeeded: a >> 8), UInt8(truncatingIfNeeded: a),
            UInt8(truncatingIfNeeded: b >> 56), UInt8(truncatingIfNeeded: b >> 48), UInt8(truncatingIfNeeded: b >> 40),
            UInt8(truncatingIfNeeded: b >> 32), UInt8(truncatingIfNeeded: b >> 24), UInt8(truncatingIfNeeded: b >> 16),
            UInt8(truncatingIfNeeded: b >> 8), UInt8(truncatingIfNeeded: b)))
    }

    // Exchange rate EUR/USD as a random walk; `usdPerEur[i]` applies on day start + i.
    var usdPerEur = [Double](repeating: 1.1, count: o.days)
    if o.multiCurrency {
        var r = 1.1
        var days: [Int32] = [], rates: [Double] = []
        for i in 0..<o.days {
            let day = o.start.advanced(by: i)
            if !day.isWeekend {
                r = max(0.7, min(1.6, r * (1 + (rng.unit() - 0.5) * 0.012)))
                r = (r * 10_000).rounded() / 10_000
                days.append(day.rawValue)
                rates.append(r)
            }
            usdPerEur[i] = r
        }
        file.exchangeRates = [ExchangeRateSeries(base: "EUR", quote: "USD", days: days, rates: rates)]
    }

    // Accounts and depots.
    var accountCurrencies = ["EUR", "EUR"]
    if o.multiCurrency { accountCurrencies.append("USD") }
    for (i, c) in accountCurrencies.enumerated() { file.accounts.append(Account(id: nextID(), name: "Account \(i)", currency: c)) }
    file.depots = [Depot(id: nextID(), name: "Depot 0"), Depot(id: nextID(), name: "Depot 1")]

    // Securities with weekday prices; `price[s][i]` is the last known price on day start + i.
    var price = [[Double]]()
    for s in 0..<o.securities {
        let currency = o.multiCurrency && s % 3 == 2 ? "USD" : "EUR"
        var p = 20 + rng.unit() * 180
        var points: [PricePoint] = []
        var column = [Double](repeating: 0, count: o.days)
        for i in 0..<o.days {
            let day = o.start.advanced(by: i)
            if !day.isWeekend {
                p = max(1, p * (1 + (rng.unit() - 0.48) * 0.03))
                p = (p * 100).rounded() / 100
                points.append(PricePoint(day: day, price: Price(p)))
            }
            column[i] = p
        }
        price.append(column)
        file.securities.append(Security(id: nextID(), name: "Security \(s)", currency: currency, prices: PriceSeries(points)))
    }

    // Transactions, generated chronologically so that sells can respect current holdings.
    let lastActive = max(1, Int(Double(o.days) * o.activeFraction))
    var offsets = (0..<o.transactions).map { _ in rng.int(1...(lastActive - 1)) }
    offsets.sort()
    var held = [[Int64]](repeating: [0, 0], count: o.securities) // [security][depot] raw shares
    func toAccountCurrency(_ value: Double, from: String, account: Int, dayIndex: Int) -> Double {
        let to = accountCurrencies[account]
        if from == to { return value }
        return from == "EUR" ? value * usdPerEur[dayIndex] : value / usdPerEur[dayIndex]
    }
    func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    for (n, offset) in offsets.enumerated() {
        let day = o.start.advanced(by: offset)
        let account = rng.int(0...(accountCurrencies.count - 1))
        let accountID = file.accounts[account].id
        let currency = accountCurrencies[account]
        let depot = rng.int(0...1)
        let depotID = file.depots[depot].id
        let s = rng.int(0...(o.securities - 1))
        let security = file.securities[s]
        let roll = n < 3 ? 0.0 : rng.unit()
        var t: Transaction?

        func trade(_ kind: Transaction.Kind, shares: Int64) -> Transaction {
            let grossSec = round2(Double(shares) / 1e8 * price[s][offset])
            let gross = round2(toAccountCurrency(grossSec, from: security.currency, account: account, dayIndex: offset))
            let fees = rng.chance(0.7) ? round2(rng.unit() * 12) : 0
            let taxes = kind == .sell && rng.chance(0.4) ? round2(gross * 0.02) : 0
            let amount = kind == .buy || kind == .deliveryIn ? gross + fees + taxes : max(gross - fees - taxes, 0)
            var tx = Transaction(
                id: nextID(), kind: kind, date: day, accountID: kind == .buy || kind == .sell ? accountID : nil,
                depotID: depotID, securityID: security.id, shares: Shares(raw: shares),
                amount: Money(amount, currency), fees: minor(fees), taxes: minor(taxes))
            // For sells that were clamped at zero keep the fee/tax breakdown consistent.
            if kind == .sell || kind == .deliveryOut, gross - fees - taxes < 0 {
                tx.fees = 0
                tx.taxes = 0
                tx.amount = Money(gross, currency)
            }
            if security.currency != currency, rng.chance(0.5) { tx.securityGross = Money(grossSec, security.currency) }
            return tx
        }

        switch roll {
        case ..<0.12:
            t = Transaction(id: nextID(), kind: .deposit, date: day, accountID: accountID,
                            amount: Money(round2(500 + rng.unit() * 5000), currency))
        case ..<0.46:
            let shares = Int64(rng.int(1...80)) * (rng.chance(0.2) ? 12_345_678 : 100_000_000)
            held[s][depot] += shares
            t = trade(.buy, shares: shares)
        case ..<0.62:
            var shares = held[s][depot]
            if shares > 0 {
                if rng.chance(0.6) { shares = max(1, shares / Int64(rng.int(2...5))) }
            } else if o.allowShort, rng.chance(0.3) {
                shares = Int64(rng.int(1...5)) * 100_000_000
            } else {
                shares = 0
            }
            if shares != 0 {
                held[s][depot] -= shares
                t = trade(.sell, shares: shares)
            }
        case ..<0.74:
            let gross = round2(5 + rng.unit() * 200)
            let taxes = rng.chance(0.6) ? round2(gross * 0.26) : 0
            t = Transaction(
                id: nextID(), kind: .dividend, date: day, accountID: accountID, depotID: rng.chance(0.8) ? depotID : nil,
                securityID: security.id, shares: Shares(raw: max(held[s][depot], 0)),
                amount: Money(gross - taxes, currency), taxes: minor(taxes))
        case ..<0.77:
            let gross = round2(1 + rng.unit() * 40)
            let taxes = rng.chance(0.5) ? round2(gross * 0.25) : 0
            t = Transaction(id: nextID(), kind: .interest, date: day, accountID: accountID,
                            amount: Money(gross - taxes, currency), taxes: minor(taxes))
        case ..<0.78:
            t = Transaction(id: nextID(), kind: .interestCharge, date: day, accountID: accountID,
                            amount: Money(round2(1 + rng.unit() * 10), currency))
        case ..<0.81:
            t = Transaction(id: nextID(), kind: .fee, date: day, accountID: accountID,
                            securityID: rng.chance(0.5) ? security.id : nil, amount: Money(round2(1 + rng.unit() * 20), currency))
        case ..<0.82:
            t = Transaction(id: nextID(), kind: .feeRefund, date: day, accountID: accountID,
                            securityID: rng.chance(0.5) ? security.id : nil, amount: Money(round2(1 + rng.unit() * 5), currency))
        case ..<0.84:
            t = Transaction(id: nextID(), kind: .tax, date: day, accountID: accountID,
                            securityID: rng.chance(0.5) ? security.id : nil, amount: Money(round2(1 + rng.unit() * 30), currency))
        case ..<0.85:
            t = Transaction(id: nextID(), kind: .taxRefund, date: day, accountID: accountID,
                            securityID: rng.chance(0.5) ? security.id : nil, amount: Money(round2(1 + rng.unit() * 30), currency))
        case ..<0.89:
            let target = (account + 1 + rng.int(0...(accountCurrencies.count - 2))) % accountCurrencies.count
            let amount = round2(50 + rng.unit() * 1500)
            var tx = Transaction(id: nextID(), kind: .cashTransfer, date: day, accountID: accountID,
                                 counterAccountID: file.accounts[target].id, amount: Money(amount, currency))
            if accountCurrencies[target] != currency {
                let converted = currency == "EUR" ? amount * usdPerEur[offset] : amount / usdPerEur[offset]
                tx.counterAmount = Money(round2(converted * 0.995), accountCurrencies[target])
            }
            t = tx
        case ..<0.93:
            let available = held[s][depot]
            if available > 0 {
                let shares = rng.chance(0.5) ? available : max(1, available / 2)
                held[s][depot] -= shares
                held[s][1 - depot] += shares
                t = Transaction(
                    id: nextID(), kind: .securityTransfer, date: day, depotID: depotID,
                    counterDepotID: file.depots[1 - depot].id, securityID: security.id, shares: Shares(raw: shares),
                    amount: Money(round2(Double(shares) / 1e8 * price[s][offset]), security.currency))
            }
        case ..<0.95:
            let shares = Int64(rng.int(1...40)) * 100_000_000
            held[s][depot] += shares
            t = trade(.deliveryIn, shares: shares)
        case ..<0.97:
            let available = held[s][depot]
            if available > 0 {
                let shares = max(1, available / Int64(rng.int(1...3)))
                held[s][depot] -= shares
                t = trade(.deliveryOut, shares: shares)
            }
        default:
            t = Transaction(id: nextID(), kind: .withdrawal, date: day, accountID: accountID,
                            amount: Money(round2(50 + rng.unit() * 800), currency))
        }
        if var tx = t {
            if rng.chance(0.3) { tx.minuteOfDay = rng.int(0...1439) }
            file.transactions.append(tx)
        }
    }
    file.transactions.shuffle(using: &rng) // the ledger must restore chronological order
    return file
}

/// Wall-clock milliseconds of the fastest of `runs` executions.
func bestMilliseconds(runs: Int = 5, _ body: () -> Void) -> Double {
    var best = Double.infinity
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return best
}
