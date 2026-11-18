import Foundation
import KontorModel

/// The state of a scope at the end of one day: positions, cash balances and totals.
///
/// Invariant: `totalValue == Σ positions.value + Σ cash.value`, and each position's value is the
/// sum of its depot holdings — exactly, in minor units. Values of positions whose price or exchange
/// rate is unavailable are excluded (zero) and flagged via `isValued` and `diagnostics`.
public struct Snapshot: Sendable {
    /// The shares of one security in one depot.
    public struct DepotHolding: Sendable, Hashable {
        public let depotID: UUID
        public let shares: Shares
        /// Market value in the security's currency (weighted by the scope).
        public let valueInSecurityCurrency: Money
        /// Market value in the reporting currency (weighted by the scope).
        public let value: Money
        /// Cost basis incl. fees in the reporting currency (weighted by the scope).
        public let costBasis: Money
    }

    /// One security held in the scope (all depots combined).
    public struct Position: Sendable, Hashable, Identifiable {
        public var id: UUID { securityID }
        public let securityID: UUID
        /// Total shares across the scope's depots (not scaled by the scope weight).
        public let shares: Shares
        /// The quote used for valuation; nil if the security has no price.
        public let price: Price?
        /// The date of that quote (may differ from the snapshot day: last known price).
        public let priceDay: Day?
        /// Market value in the security's currency.
        public let valueInSecurityCurrency: Money
        /// Market value in the reporting currency.
        public let value: Money
        /// Cost basis (purchase value incl. fees, per `Settings.costMethod`) in the reporting currency.
        public let costBasis: Money
        /// False if the price or the exchange rate is missing (the value is then 0).
        public let isValued: Bool
        /// Scope weight of the security in basis points (10 000 unless the scope is weighted).
        public let weight: Int
        /// Breakdown by depot; values and costs sum exactly to the position's.
        public let holdings: [DepotHolding]

        /// `value − costBasis`.
        public var unrealizedGain: Money { value - costBasis }
        /// Unrealized gain relative to the cost basis; nil without a positive cost basis.
        public var unrealizedGainFraction: Double? {
            costBasis.minor > 0 ? Double(value.minor - costBasis.minor) / Double(costBasis.minor) : nil
        }
        /// Average purchase price per share in the reporting currency (incl. fees).
        public var purchasePrice: Price? {
            weight == 0 ? nil : Price(minor: mulDiv(costBasis.minor, 10_000, Int64(weight)), per: shares)
        }
    }

    /// The balance of one cash account.
    public struct CashBalance: Sendable, Hashable, Identifiable {
        public var id: UUID { accountID }
        public let accountID: UUID
        /// Balance in the account's own currency (not scaled by the scope weight).
        public let balance: Money
        /// Value in the reporting currency (weighted by the scope).
        public let value: Money
        /// False if the exchange rate is missing (the value is then 0).
        public let isValued: Bool
    }

    public let day: Day
    public let currency: CurrencyCode
    /// Positions with non-zero shares, in the order of `Ledger.securities`.
    public let positions: [Position]
    /// All in-scope accounts (including empty ones), in the order of `Ledger.accounts`.
    public let cash: [CashBalance]
    public let securitiesValue: Money
    public let cashValue: Money
    public let totalValue: Money
    /// Σ cost basis of all positions.
    public let costBasis: Money
    public let diagnostics: [EngineDiagnostic]

    /// The position of a security, if held.
    public func position(_ securityID: UUID) -> Position? { positions.first { $0.securityID == securityID } }
    /// The balance of an account, if in scope.
    public func cash(_ accountID: UUID) -> CashBalance? { cash.first { $0.accountID == accountID } }
    /// Share of the total value held by `position` (0…1); nil if the total is not positive.
    public func share(of position: Position) -> Double? {
        totalValue.minor > 0 ? Double(position.value.minor) / Double(totalValue.minor) : nil
    }
}

extension Ledger {
    /// The statement of assets of `scope` at the end of `day`.
    public func snapshot(on day: Day, scope: Scope = .portfolio) -> Snapshot {
        let resolved = ResolvedScope(scope, ledger: self)
        var replay = LotReplay(ledger: self, scope: resolved)
        replay.advance(through: day)
        return snapshot(from: replay, on: day)
    }

    /// Builds a snapshot from a replay that was advanced through `day`.
    func snapshot(from replay: LotReplay, on day: Day) -> Snapshot {
        let scope = replay.scope
        let rep = reportingCurrency
        var diagnostics = replay.diagnostics
        var bySecurity = [[Int]](repeating: [], count: securities.count)
        for h in holdingSecurity.indices where scope.holdingWeight[h] != 0 && replay.shares[h] != 0 {
            bySecurity[Int(holdingSecurity[h])].append(h)
        }
        var positions: [Snapshot.Position] = []
        var securitiesTotal: Int64 = 0, costTotal: Int64 = 0
        for s in securities.indices where !bySecurity[s].isEmpty {
            let security = securities[s]
            var holdings: [Snapshot.DepotHolding] = []
            var shares: Int64 = 0, valueSec: Int64 = 0, value: Int64 = 0, cost: Int64 = 0
            var priceIndex = -1
            var valued = true
            for h in bySecurity[s] {
                let w = scope.holdingWeight[h]
                let state = replay.holdingState(h, on: day.rawValue)
                let hSec = FixedMath.weighted(state.valueSec, w)
                let hValue = FixedMath.weighted(state.value, w)
                let hCost = FixedMath.weighted(state.cost, w)
                holdings.append(Snapshot.DepotHolding(
                    depotID: depots[Int(holdingDepot[h])].id, shares: Shares(raw: state.shares),
                    valueInSecurityCurrency: Money(minor: hSec, currency: security.currency),
                    value: Money(minor: hValue, currency: rep), costBasis: Money(minor: hCost, currency: rep)))
                shares += state.shares
                valueSec += hSec
                value += hValue
                cost += hCost
                priceIndex = state.priceIndex
                valued = valued && state.valued
            }
            guard shares != 0 || value != 0 || cost != 0 else { continue }
            if !valued {
                if priceIndex < 0 {
                    diagnostics.add(.missingPrice(securityID: security.id))
                } else {
                    diagnostics.add(.missingExchangeRate(from: security.currency, to: rep))
                }
            }
            positions.append(Snapshot.Position(
                securityID: security.id, shares: Shares(raw: shares),
                price: priceIndex >= 0 ? Price(raw: priceValues[priceIndex]) : nil,
                priceDay: priceIndex >= 0 ? Day(rawValue: priceDays[priceIndex]) : nil,
                valueInSecurityCurrency: Money(minor: valueSec, currency: security.currency),
                value: Money(minor: value, currency: rep), costBasis: Money(minor: cost, currency: rep),
                isValued: valued, weight: Int(scope.securityWeight[s]), holdings: holdings))
            securitiesTotal += value
            costTotal += cost
        }

        var cash: [Snapshot.CashBalance] = []
        var cashTotal: Int64 = 0
        for a in accounts.indices where scope.accountWeight[a] != 0 {
            let account = accounts[a]
            let converted = cashValue(account: a, balance: replay.balances[a], on: day.rawValue)
            if !converted.valued, replay.balances[a] != 0 {
                diagnostics.add(.missingExchangeRate(from: account.currency, to: rep))
            }
            let value = FixedMath.weighted(converted.rep, scope.accountWeight[a])
            cash.append(Snapshot.CashBalance(
                accountID: account.id, balance: Money(minor: replay.balances[a], currency: account.currency),
                value: Money(minor: value, currency: rep), isValued: converted.valued))
            cashTotal += value
        }
        return Snapshot(
            day: day, currency: rep, positions: positions, cash: cash,
            securitiesValue: Money(minor: securitiesTotal, currency: rep),
            cashValue: Money(minor: cashTotal, currency: rep),
            totalValue: Money(minor: securitiesTotal + cashTotal, currency: rep),
            costBasis: Money(minor: costTotal, currency: rep), diagnostics: diagnostics.items)
    }
}
