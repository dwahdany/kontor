import Foundation
import KontorModel

/// What a calculation covers.
///
/// For every scope other than `.portfolio`, value that crosses the scope boundary is an *external
/// flow* (it changes the invested capital, not the performance). Each transaction is viewed as a
/// movement between a *position leg* (the security in a depot) and an *account leg*:
///
/// | transaction                    | position leg        | account leg          |
/// |--------------------------------|---------------------|----------------------|
/// | buy                            | receives `amount`   | pays `amount`        |
/// | sell                           | pays `amount`       | receives `amount`    |
/// | deliveryIn / deliveryOut       | receives / pays     | — (outside world)    |
/// | deposit / withdrawal           | —                   | receives / pays      |
/// | dividend                       | pays `amount`       | receives `amount`    |
/// | fee / tax *with* a security    | receives `amount`   | pays `amount`        |
/// | fee / tax refund with security | pays `amount`       | receives `amount`    |
/// | cashTransfer                   | —                   | source pays, target receives |
/// | securityTransfer               | source pays market value, target receives it | — |
/// | interest, fees/taxes w/o security | —                | performance of the account, no flow |
///
/// A dividend, fee or tax that names a security but no depot is attributed to the depot holding
/// the security at that time (after a complete sale: the depot it was last moved in). While
/// several depots hold the security at once it cannot be attributed and counts in full for every
/// depot scope that ever held the security.
///
/// The external flow of a transaction is the sum of what the in-scope legs receive minus what they
/// pay (each multiplied by the leg's weight). With the whole portfolio in scope the legs cancel,
/// leaving only deposits, withdrawals and deliveries. For a single security a buy is an inflow,
/// a sell an outflow, and a dividend an outflow that still counts as return (the value leaves the
/// position but was earned by it); fees and taxes booked on the security reduce its return.
public enum Scope: Hashable, Sendable, Codable {
    /// Everything in the file.
    case portfolio
    /// The securities held in `depots` plus the cash in `accounts`.
    case subset(depots: Set<UUID>, accounts: Set<UUID>)
    /// One security, in all depots or only in `depot`. No cash.
    case security(UUID, depot: UUID? = nil)
    /// Arbitrary securities and accounts with weights in basis points (10 000 = 100 %), e.g. the
    /// assignments of a taxonomy classification. Entities not listed are out of scope.
    case weighted(securities: [UUID: Int], accounts: [UUID: Int])

    /// A single depot together with a single account (typically its reference account).
    public static func depot(_ depot: UUID, account: UUID? = nil) -> Scope {
        .subset(depots: [depot], accounts: account.map { [$0] } ?? [])
    }

    /// A single cash account.
    public static func account(_ account: UUID) -> Scope { .subset(depots: [], accounts: [account]) }
}

/// A `Scope` resolved against a ledger: per-holding and per-account weights in basis points.
public struct ResolvedScope: Sendable {
    /// Weight of each (security, depot) holding, parallel to the ledger's internal holding table.
    let holdingWeight: [Int32]
    /// Weight of each account, parallel to `Ledger.accounts`.
    let accountWeight: [Int32]
    /// Weight applied to security-related entries that could not be attributed to a depot
    /// (dividends, fees and taxes without a depot while several depots hold the security): the
    /// largest weight among the security's in-scope holdings.
    let securityLegWeight: [Int32]
    /// Weight of each security irrespective of depot, parallel to `Ledger.securities`.
    let securityWeight: [Int32]
    /// True if everything is in scope at 100 %.
    public let isWholePortfolio: Bool

    public init(_ scope: Scope, ledger: Ledger) {
        let full = FixedMath.fullWeight
        var securityWeight = [Int32](repeating: 0, count: ledger.securities.count)
        var depotIncluded = [Bool](repeating: true, count: ledger.depots.count)
        var accountWeight = [Int32](repeating: 0, count: ledger.accounts.count)
        var allDepots = true
        var whole = false
        func clamp(_ w: Int) -> Int32 { Int32(min(max(w, 0), Int(full))) }

        switch scope {
        case .portfolio:
            securityWeight = [Int32](repeating: full, count: ledger.securities.count)
            accountWeight = [Int32](repeating: full, count: ledger.accounts.count)
            whole = true
        case .subset(let depots, let accounts):
            securityWeight = [Int32](repeating: full, count: ledger.securities.count)
            for (i, d) in ledger.depots.enumerated() { depotIncluded[i] = depots.contains(d.id) }
            for (i, a) in ledger.accounts.enumerated() where accounts.contains(a.id) { accountWeight[i] = full }
            allDepots = false
        case .security(let id, let depot):
            if let s = ledger.securityIndex(id) { securityWeight[s] = full }
            if let depot {
                for (i, d) in ledger.depots.enumerated() { depotIncluded[i] = d.id == depot }
                allDepots = false
            }
        case .weighted(let securities, let accounts):
            for (id, w) in securities { if let s = ledger.securityIndex(id) { securityWeight[s] = clamp(w) } }
            for (id, w) in accounts { if let a = ledger.accountIndex(id) { accountWeight[a] = clamp(w) } }
        }

        var holdingWeight = [Int32](repeating: 0, count: ledger.holdingSecurity.count)
        var legWeight = allDepots ? securityWeight : [Int32](repeating: 0, count: ledger.securities.count)
        for h in holdingWeight.indices {
            let s = Int(ledger.holdingSecurity[h])
            let w = depotIncluded[Int(ledger.holdingDepot[h])] ? securityWeight[s] : 0
            holdingWeight[h] = w
            if !allDepots, w > legWeight[s] { legWeight[s] = w }
        }
        self.holdingWeight = holdingWeight
        self.accountWeight = accountWeight
        self.securityLegWeight = legWeight
        self.securityWeight = securityWeight
        self.isWholePortfolio = whole
    }

    /// Weight of the position leg of an entry.
    @inline(__always)
    func positionWeight(_ e: Entry) -> Int32 {
        if e.holding >= 0 { return holdingWeight[Int(e.holding)] }
        return e.security >= 0 ? securityLegWeight[Int(e.security)] : 0
    }

    /// The external flow of an entry split into its position leg and its account leg, in minor
    /// units of the reporting currency. Positive = value entering the scope.
    @inline(__always)
    func flowLegs(_ e: Entry, _ ledger: Ledger) -> (position: Int64, account: Int64) {
        let amount = e.amountRep
        switch e.kind {
        case .buy:
            return (
                FixedMath.weighted(amount, positionWeight(e)),
                -FixedMath.weighted(amount, accountWeight[Int(e.account)])
            )
        case .sell, .dividend:
            return (
                -FixedMath.weighted(amount, positionWeight(e)),
                FixedMath.weighted(amount, accountWeight[Int(e.account)])
            )
        case .deliveryIn:
            return (FixedMath.weighted(amount, positionWeight(e)), 0)
        case .deliveryOut:
            return (-FixedMath.weighted(amount, positionWeight(e)), 0)
        case .deposit:
            return (0, FixedMath.weighted(amount, accountWeight[Int(e.account)]))
        case .withdrawal:
            return (0, -FixedMath.weighted(amount, accountWeight[Int(e.account)]))
        case .interest, .interestCharge:
            return (0, 0)
        case .fee, .tax:
            guard e.security >= 0 else { return (0, 0) }
            return (
                FixedMath.weighted(amount, positionWeight(e)),
                -FixedMath.weighted(amount, accountWeight[Int(e.account)])
            )
        case .feeRefund, .taxRefund:
            guard e.security >= 0 else { return (0, 0) }
            return (
                -FixedMath.weighted(amount, positionWeight(e)),
                FixedMath.weighted(amount, accountWeight[Int(e.account)])
            )
        case .cashTransfer:
            let from = accountWeight[Int(e.account)], to = accountWeight[Int(e.counterAccount)]
            if from == to { return (0, 0) }
            return (0, FixedMath.weighted(amount, to) - FixedMath.weighted(amount, from))
        case .securityTransfer:
            let from = holdingWeight[Int(e.holding)], to = holdingWeight[Int(e.counterHolding)]
            if from == to { return (0, 0) }
            let value = ledger.value(security: Int(e.security), shares: e.shares, on: e.day).rep
            return (FixedMath.weighted(value, to) - FixedMath.weighted(value, from), 0)
        }
    }
}

extension Ledger {
    /// Resolves a scope against this ledger (cheap; exposed for callers that run many calculations
    /// over the same scope).
    public func resolve(_ scope: Scope) -> ResolvedScope { ResolvedScope(scope, ledger: self) }
}
