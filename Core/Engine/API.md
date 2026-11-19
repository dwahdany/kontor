# KontorEngine — calculation core

Pure Swift (Foundation only), Swift 6, all public types `Sendable`. Depends on `KontorModel`.

```swift
.package(path: "../Engine")                       // from another Core package
.product(name: "KontorEngine", package: "Engine")
```

Everything starts with a `Ledger` — an immutable index of a `PortfolioFile`. Build it once per
document revision (≈ 1.5 ms for 5 000 transactions, off the main thread if you like), then call
any calculation from any thread.

```swift
import KontorEngine

let ledger = Ledger(file)                                  // reporting currency = settings.baseCurrency
let today = Day.today

let snapshot = ledger.snapshot(on: today)                  // statement of assets
let interval = ReportingPeriod.lastYears(1).interval(today: today, ledger: ledger)
let report   = ledger.performance(in: interval)            // everything for the performance screens

report.ttwror                     // 0.0834 = +8.34 %
report.ttwrorAnnualized           // Double?
report.irr                        // Double? (annual, money-weighted)
report.breakdown.realizedGains    // Int64 minor units of report.currency
report.securities                 // [SecurityPerformance]
report.risk.maxDrawdown?.depth    // 0.21 = −21 %
report.returns.cumulative         // [Double], one per day → chart
report.valuation.values           // [Int64], one per day → chart
```

Timings (release, M-series, 20 years × 60 securities × 4 750 transactions × 313 000 quotes):
ledger build 1.4 ms · daily valuation 6 ms · snapshot 0.3 ms · breakdown 0.3 ms · full report 9 ms ·
trades 0.5 ms · earnings 0.06 ms · allocation 0.4 ms · rebalancing 0.1 ms · consistency check 4 ms ·
everything through the `Analysis` facade 10 ms.

For a screen that shows several things about the same scope and period, use the **`Analysis`**
facade (last section but one) — it computes shared intermediate results once.

Contents: Conventions · Ledger · CurrencyConverter · Scope · Snapshot · Daily valuation · Returns ·
Performance · Risk · Reporting periods · Benchmarks and charts · Diagnostics · **Trades** ·
**Earnings & costs** · **Taxonomy allocation** · **Rebalancing** · **Investment plans** ·
**Consistency checks** · **Heatmap & rolling returns** · **Stock splits** · **Analysis facade** ·
Internals.

## Conventions

| Topic | Convention |
|---|---|
| Money | `Int64` minor units (1/100) of the **reporting currency** unless a `Money` says otherwise. |
| Rates / returns | `Double` fractions: `0.05` = 5 %. |
| Weights | basis points, `10_000` = 100 %. |
| Intervals | `DayInterval(start, end)`: the value at the **end of `start`** is the baseline; the period covers `start+1 … end`. Year 2024 = `2023-12-31 … 2024-12-31`. Transactions dated `start` belong to the baseline. |
| Daily series | index `i` ⇔ day `interval.start + i`; `count == interval.dayCount + 1`; index 0 is the baseline. |
| Prices | last known quote on or before the day; before the first quote the first quote is used. Securities without quotes are valued with prices derived from their own buys/sells (flagged). |
| FX | last known rate on or before the day (first rate before the series starts); transactions convert at their own day's rate. |
| Bad data | never traps. Unconvertible / unpriced values count as 0 and are reported in `diagnostics`. Invalid transactions are skipped and listed in `ledger.diagnostics`. |
| Same-day ordering | Transactions are processed in the order of `Transaction.chronological` (day, time of day, id). Bookings that share a day **and** time of day (typically untimed imports) have no natural order; there, a booking that would take more shares out of a holding than it holds is processed *after* same-moment bookings adding shares to it, so an untimed buy + sell of one day is never reported as a short sale. Nothing else is reordered; give transactions a `minuteOfDay` to force an order. |
| Bookings without a depot | A dividend, fee or tax that names a security but no depot (Portfolio Performance books these on the account only) is attributed to the depot holding the security at that time — after a complete sale, to the depot it was last moved in. Only while several depots hold the security at once does it stay unattributed; it then counts in full for every depot scope that ever held the security. |
| Rounding | half away from zero, everywhere. Values are rounded per (security, depot) holding and per account, so totals of partial scopes add up exactly to the portfolio. |

## Ledger

```swift
public struct Ledger: Sendable {
    init(_ file: PortfolioFile, reportingCurrency: CurrencyCode? = nil)
    let name: String, settings: Settings, reportingCurrency: CurrencyCode
    let securities: [Security], accounts: [Account], depots: [Depot]
    let transactions: [Transaction]            // chronological (== sorted by Transaction.chronological);
                                               // processing order: see "Same-day ordering" above
    let converter: CurrencyConverter
    let diagnostics: [EngineDiagnostic]
    let firstTransactionDay: Day?, lastTransactionDay: Day?

    func security(_ id: UUID) -> Security?     // O(1); also account(_:), depot(_:)
    func securityIndex(_ id: UUID) -> Int?     // position in `securities`; also accountIndex, depotIndex
    func transactions(forSecurity: UUID) -> [Transaction]   // chronological; also forAccount:, forDepot:
    var transactionCountBySecurity: [Int]
    func price(of securityID: UUID, on: Day) -> PricePoint?  // effective quote (see conventions)
}
```

## CurrencyConverter

Built from `PortfolioFile.exchangeRates` (`ledger.converter`). Lookup order: identity → direct →
inverse → triangulated via the file's base currency, then EUR, then USD.

```swift
converter.rate(from: "USD", to: "EUR", on: day)                  // Double?  (nil = unavailable)
converter.convert(minor: 11_000, from: "USD", to: "EUR", on: day) // Int64?
converter.convert(Money(110, "USD"), to: "EUR", on: day)          // Money?
converter.canConvert(from: "JPY", to: "EUR")

// Hot loops: resolve once, evaluate often / densely
let path = converter.path(from: "GBP", to: "USD")!                // CurrencyConverter.Path
converter.rate(along: path, on: day)
converter.dailyRates(along: path, from: start, count: 365)        // [Double], one linear sweep
```

## Scope

```swift
public enum Scope: Hashable, Sendable, Codable {
    case portfolio
    case subset(depots: Set<UUID>, accounts: Set<UUID>)
    case security(UUID, depot: UUID? = nil)
    case weighted(securities: [UUID: Int], accounts: [UUID: Int])   // basis points, e.g. a classification
    static func depot(_ depot: UUID, account: UUID? = nil) -> Scope
    static func account(_ account: UUID) -> Scope
}
```

Every calculation takes `scope:` (default `.portfolio`). For partial scopes, value crossing the scope
boundary is an **external flow** (it is not performance):

* single security: a buy is an inflow, a sell an outflow, a dividend an outflow that still counts as
  return, a fee/tax booked on the security an inflow that buys nothing (reduces the return);
* single account: a deposit and a dividend arriving are inflows, a purchase is an outflow;
* depot subsets: `securityTransfer`s in/out are flows at market value;
* weights apply to both legs of a transaction (position leg and account leg) — see the table in
  `Scope`'s doc comment.

Money figures of weighted scopes are scaled by the weight; share counts are not.

## Snapshot

```swift
let s = ledger.snapshot(on: day, scope: .portfolio)
s.totalValue, s.securitiesValue, s.cashValue, s.costBasis     // Money in s.currency
for p in s.positions {            // non-zero positions, ledger order
    p.securityID, p.shares, p.price, p.priceDay
    p.value                       // Money, reporting currency
    p.valueInSecurityCurrency     // Money
    p.costBasis, p.unrealizedGain, p.unrealizedGainFraction, p.purchasePrice
    p.isValued                    // false → price or rate missing, value is 0
    p.holdings                    // per depot: depotID, shares, value, valueInSecurityCurrency, costBasis
}
for c in s.cash { c.accountID, c.balance /* own currency */, c.value /* reporting */, c.isValued }
s.position(securityID); s.cash(accountID); s.share(of: p)      // 0…1
```

Invariant: `totalValue == Σ positions.value + Σ cash.value`; `position.value == Σ holdings.value`.

## Daily valuation series (hot path)

```swift
let v = ledger.valuation(in: interval, scope: scope)   // ValuationSeries
v.values        // [Int64] total value at end of each day
v.cashValues    // [Int64] cash part;  v.securitiesValue(at: i)
v.inflows       // [Int64] ≥ 0, external value entering on that day
v.outflows      // [Int64] ≥ 0
v.day(at: i); v.index(of: day); v.count
v.initialValue; v.finalValue; v.totalInflows; v.totalOutflows; v.absolutePerformance
v.investedCapital()                 // [Int64] baseline + cumulative net flows (chart "invested" line)
v.returns()                         // ReturnSeries (TTWROR)
v.irr()                             // Double?
v.chartPoints(maxPoints: 400)       // [ChartPoint<Int64>]
```

`values[i]` is exactly `ledger.snapshot(on: v.day(at: i), scope:).totalValue.minor`.

## Returns

```swift
public struct ReturnSeries: Sendable {
    init(interval: DayInterval, daily: [Double])     // or init(interval:levels:) from index levels
    let interval: DayInterval
    let daily: [Double]         // daily[0] == 0
    let cumulative: [Double]    // ∏(1 + daily) − 1
    var total: Double; var annualized: Double?
    func monthlyReturns() -> [MonthReturn]; func yearlyReturns() -> [YearReturn]
    func drawdowns() -> [Double]                     // underwater curve, 0…1
    func chartPoints(maxPoints: Int) -> [ChartPoint<Double>]
}
```

**TTWROR convention** — inflows are invested at the *start* of the day, outflows leave at the *end*:

    r_t = (V_t + outflows_t) / (V_{t−1} + inflows_t) − 1

Well-defined for a first purchase (`V_{t−1} = 0`), full liquidation (`V_t = 0`) and same-day round
trips. If `V_{t−1} < 0` or the denominator is ≤ 0 the day's return is 0; losses are capped at −100 %.
A flow-free interval yields exactly `V_end / V_start − 1`.

```swift
Returns.dailyReturn(previous:value:inflow:outflow:)
Returns.annualize(total: 0.21, days: 730)                       // 0.10 — (1+total)^(365/days) − 1
Returns.irr([.init(day: 0, amount: -1_000), .init(day: 365, amount: 1_100)])   // 0.10; nil if undefined
```

IRR flows: negative = invested, positive = received; `day` = offset in days. Returns nil without a
sign change, without a time span, or without a root.

## Performance

```swift
let report = ledger.performance(in: interval, scope: scope)             // PerformanceReport
let report = ledger.performance(for: .ytd, today: today, scope: scope)
// cheaper partial calls
ledger.breakdown(in: interval, scope: scope)                             // PerformanceBreakdown only
ledger.securityPerformance(in: interval, scope: scope)                   // [SecurityPerformance]
```

`PerformanceReport`: `interval`, `currency`, `valuation`, `returns`, `ttwror`, `ttwrorAnnualized`, `irr`,
`absolutePerformance`, `breakdown`, `securities`, `security(_:)`, `risk`, `diagnostics`.

### PerformanceBreakdown (reconciles exactly)

    finalValue = initialValue
               + deposits + deliveriesIn + transfersIn − withdrawals − deliveriesOut − transfersOut
               + realizedGains + unrealizedGains + dividends + interest − fees − taxes
               + cashCurrencyGains + roundingResidue

* Capital gains use the **period basis**: positions held at the start are based at their market value
  on the start day, later purchases at gross cost. Gains are **before fees and taxes**; *all* fees and
  taxes of the period (also those inside buys, sells, dividends) are in `fees` / `taxes`.
* `dividends`, `interest` are gross. Interest charges are netted into `interest`.
* `realizedCurrencyGains` / `unrealizedCurrencyGains` are the FX part *contained in* the capital gains
  of foreign-currency securities; `cashCurrencyGains` is FX on foreign cash (plus conversion spreads).
* `transfersIn/Out` only occur for partial scopes.
* `roundingResidue` is 0 for single-currency, unweighted scopes; otherwise sub-cent dust per transaction.
* Helpers: `inflows`, `outflows`, `capitalGains`, `earnings`, `currencyGains`, `absolutePerformance`,
  `lines` (`[(Line, Int64)]`, signed, ready for a waterfall table).

### SecurityPerformance

`securityID`, `shares`, `initialValue`, `marketValue`, `portfolioWeight` (0…1),
`costBasis` (incl. fees), `purchasePrice`, `unrealizedGain`, `unrealizedGainFraction`,
`realizedGain` (interval, since-purchase basis, after fees, before taxes),
`periodRealizedGain`, `periodUnrealizedGain`, `periodCurrencyGain` (period basis, gross),
`dividends` (gross), `dividendCount`, `lastDividend`, `lastDividendDay`, `dividendYieldOnCost`,
`fees`, `taxes`, `inflows`, `outflows`, `absolutePerformance`, `ttwror`, `ttwrorAnnualized`, `irr`.

One record per security that was held or had transactions in the interval.

### Cost basis

`Settings.costMethod`: `.fifo` (lots, oldest first) or `.average` (one pooled lot per security and
depot). Fees are part of the cost basis on buys and reduce proceeds on sells; taxes never enter the
cost basis or realized gains. Foreign purchases are converted at the purchase day's rate.
`securityTransfer` moves lots with cost and acquisition day; in the target depot they queue up by
acquisition day, so FIFO there keeps selling the oldest shares first. Overselling opens a short lot
(`.shortPosition` diagnostic) that a later purchase closes.

```swift
ledger.openLots(on: day, scope: scope)       // [OpenLot]: securityID, depotID, shares, acquired, cost, fees, taxes
ledger.closedLots(in: interval, scope: scope) // [ClosedLot]: shares, opened, closed, cost, proceeds, fees, taxes,
ledger.closedLots()                           //   gain, holdingDays, isShort, transactionID  (raw lots; see Trades)
```

## Risk

```swift
let risk = RiskMetrics(returns: series, riskFreeRate: ledger.settings.riskFreeRate)   // or report.risk
risk.maxDrawdown      // Drawdown?: depth, peak, trough, recovery?, declineDays, durationDays?
risk.volatility       // annualized: sample σ of weekday returns × √252
risk.semiVolatility   // downside part (returns below the mean)
risk.sharpeRatio      // (annualized return − riskFreeRate) / volatility, nil if undefined
risk.bestDay, risk.worstDay       // DayReturn?(day, value)
risk.bestMonth, risk.worstMonth   // MonthReturn?(year, month, value)
```

Works on any `ReturnSeries`, including benchmarks.

## Reporting periods

```swift
public enum ReportingPeriod: Hashable, Sendable, Codable {
    case ytd, monthToDate, quarterToDate, lastDays(Int), lastMonths(Int), lastYears(Int), year(Int), allTime
    case custom(from: Day, to: Day)
    static let presets: [ReportingPeriod]
    func interval(today: Day = .today, ledger: Ledger) -> DayInterval
    func interval(today: Day, firstTransactionDay: Day?) -> DayInterval
    var title: String        // "Year to date", "Last 3 months", "2023", "All time"
    var shortTitle: String   // "YTD", "3M", "2023", "Max"
}
public struct DayInterval { var start, end: Day; var dayCount: Int; var years: Double; var firstDay: Day; func contains(Day) -> Bool }
```

`.allTime` starts the day before the first transaction; `.year(y)` ends today while the year is running.

## Benchmarks and charts

```swift
// Same day axis as valuation/returns of the same interval → plot together.
let bench = ledger.benchmark(securityID: id, in: interval)                          // ReturnSeries?
let own   = ledger.benchmark(securityID: id, in: interval, basis: .securityCurrency)
ledger.priceLevels(securityID: id, in: interval)                                    // [Double]?

Downsampler.indices(values, maxPoints: 400)   // [Int] — keeps first, last and per-bucket min/max
Downsampler.downsample(values, maxPoints: 400)
```

## Diagnostics

```swift
public enum EngineDiagnostic: Hashable, Sendable, CustomStringConvertible {
    case missingExchangeRate(from: CurrencyCode, to: CurrencyCode)   // amounts excluded
    case missingPrice(securityID: UUID)                              // position valued at 0
    case pricesDerivedFromTransactions(securityID: UUID)
    case invalidTransaction(transactionID: UUID, reason: String)     // skipped
    case shortPosition(securityID: UUID, depotID: UUID, day: Day)
}
```

`ledger.diagnostics` (indexing), plus `diagnostics` on `Snapshot`, `ValuationSeries`, `PerformanceReport`.

## Identifiable rows

Everything meant for a `List` / `ForEach` / chart is `Identifiable`: `Snapshot.Position`,
`Snapshot.CashBalance`, `SecurityPerformance`, `Trade`, `DividendPayment`, `SecurityEarnings`,
`AccountEarnings`, `EarningsMonth` / `Quarter` / `Year`, `TrailingEarnings`, `EarningsGrowth`,
`MonthReturn`, `YearReturn`, `ReturnHeatmap.Row`, `ChartPoint` (by day), `AllocationNode`,
`AllocationItem`, `RebalancingProposal.Node` / `Item` / `Order`, `ClassificationPerformance`,
`PlanStatus`, `PlanStatus.Execution`, `PlanProposal`, `PlanProposal.Skipped`, `ConsistencyIssue`.
`OpenLot`, `ClosedLot` and `Trade.Lot` have no natural identity (use `enumerated()`); an
`AllocationItem` id repeats if a taxonomy assigns the same vehicle twice to one classification.

## Low-level helpers

`FixedMath.marketValue(price:shares:)`, `FixedMath.convert(_:rate:)`, `FixedMath.weighted(_:_:)` — the
exact rounding primitives every calculation uses. `FixedMath.saturatingInt64(_:)` rounds a `Double`
into the `Int64` range without trapping (use it when turning chart / form input into fixed-point). `ledger.resolve(scope)` returns a `ResolvedScope`.

## Trades

Round trips per security and depot, derived from the tax lots of `Settings.costMethod`.

```swift
let t = ledger.trades(on: today)                               // closed ever + open today
let t = ledger.trades(on: end, closedAfter: start, scope: s)   // closed in (start, end], open at end
                                                               // (start >= end: no closed trades)
t.closed        // [Trade], chronological by closing transaction
t.open          // [Trade], one per (security, depot) still held, valued at `day`
t.statistics    // TradeStatistics of the closed trades
t.trades(for: securityID)

trade.securityID, trade.depotID, trade.closingTransactionID   // nil while open
trade.isOpen, trade.isShort, trade.shares                      // shares always > 0, never weighted
trade.opened, trade.end, trade.holdingDays                     // end = close day, or the report day
trade.entryValue   // purchase cost incl. fees (short: net proceeds of the short sale)
trade.exitValue    // sale proceeds after fees (short: cost of covering; open: market value)
trade.fees, trade.taxes                                        // taxes are NOT part of gain
trade.gain, trade.gainAfterTaxes, trade.returnFraction         // gain / entryValue
trade.irr, trade.annualizedReturn                              // Double?, nil for same-day trades
trade.lots         // [Trade.Lot(opened, shares, entryValue)] — the acquisitions behind the trade

TradeStatistics(trades.closed.filter { … })   // recompute for any subset
// count, winners, losers, winRate, totalGain, grossProfit, grossLoss, averageGain, averageLoss,
// averageReturn, averageHoldingDays, profitFactor (grossProfit / grossLoss), totalFees, totalTaxes
```

* One closed trade per closing transaction (sell, outbound delivery, or the buy covering a short):
  FIFO consumes the oldest lots, the average method the pooled position.
* Lots moved with `securityTransfer` keep their acquisition day and cost; the trade is reported in
  the depot it was closed in.
* `Σ closed.gain` equals `Σ SecurityPerformance.realizedGain` over the same span;
  `Σ (gain + fees)` equals `PerformanceBreakdown.realizedGains` for an interval that starts before
  the first transaction (whole portfolio / single security).
* `irr` uses each lot's own date; `annualizedReturn` annualizes `returnFraction` over `holdingDays`.

## Earnings & costs

```swift
let e = ledger.earnings(in: interval, scope: scope)     // EarningsReport, one pass
e.total                       // EarningsAmounts
e.months                      // [EarningsMonth(year, month, amounts)] — every month of the interval
e.quarters                    // [EarningsQuarter(year, quarter, amounts)]
e.years                       // [EarningsYear(year, months: [EarningsAmounts] × 12, total)] — the matrix
e.years[0].values(.dividends) // [Int64] × 12 for one metric
e.bySecurity                  // [SecurityEarnings(securityID, amounts, dividendCount)]
e.withoutSecurity             // interest, general fees/taxes
e.byAccount                   // [AccountEarnings(accountID, amounts)] — the account it was booked on
e.trailingTwelveMonths(.dividends)   // [TrailingEarnings(year, month, value, isComplete)]
e.yearOverYear(.dividends)           // [EarningsGrowth(year, value, growth: Double?)]
e.payments                           // [DividendPayment], all securities, chronological
e.dividendHistory(for: securityID)   // [DividendPayment]

amounts.dividends, .interest, .interestCharges, .fees, .taxes      // Int64, reporting currency
amounts.earnings, .costs, .net                                     // derived
amounts[.dividends]   // EarningsMetric: dividends, interest, interestCharges, fees, taxes, earnings, costs, net

payment.day, .transactionID, .securityID, .accountID, .shares
payment.gross, .fees, .taxes, .net
payment.perShare      // Price? in the reporting currency (gross / shares)
payment.yield         // Double? gross / market value of those shares on the payment day
```

* Dividends and interest are **gross**; fees and taxes include those embedded in buys, sells,
  deliveries, dividends and interest, net of refunds. Converted at each transaction day's rate.
* Exactly consistent with `PerformanceBreakdown` over the same interval and scope:
  `total.dividends == dividends`, `total.interest − total.interestCharges == interest`,
  `total.fees == fees`, `total.taxes == taxes`.
* A dividend without a share count uses the position held before the payment.

## Taxonomy allocation

```swift
let a = ledger.allocation(for: taxonomy, on: day, scope: .portfolio, includeUnassignedInTargets: false)
let a = ledger.allocation(for: taxonomy, snapshot: snapshot)   // reuse an existing snapshot
a.totalValue, a.classifiedValue, a.unassignedValue, a.unassignedShare, a.targetBase
a.roots            // [AllocationNode], mirrors taxonomy.root
a.unassigned       // [AllocationItem] — the not (fully) assigned remainder of each security / account
a.overAssigned     // vehicles assigned > 100 % (weights were scaled down to 100 %)
a.flattened; a.node(classificationID)

node.id, node.name, node.color, node.depth
node.value, node.ownValue                 // incl. descendants / assigned directly
node.share, node.shareOfParent            // Double? 0…1
node.targetWeight                         // bp relative to the parent (as stored)
node.targetShare, node.targetValue        // absolute: product of weights along the path × targetBase
node.deltaValue, node.deltaShare          // actual − target (positive = overweight)
node.items         // [AllocationItem(vehicle, name, weight, value, shares, pricePerShare)]
node.children

item.vehicle       // AllocationVehicle: .security(UUID) | .account(UUID)
item.weight        // effective bp of the vehicle counted here
item.pricePerShare // Double?, minor units of the reporting currency per share
```

* Exact: `node.value == Σ items + Σ children`, `Σ roots + unassignedValue == snapshot.totalValue`,
  and every vehicle's parts (all assignments + unassigned) sum to its value to the cent.
* A vehicle may be assigned to several classifications with partial weights.
* Targets refer to the classified value (default) or to the total incl. unassigned.
* Assigned vehicles that are not held are listed with value 0 (rebalancing can buy them).

Performance per classification (weighted scope, one daily pass each):

```swift
taxonomy.scope(forClassification: id)                              // Scope? (.weighted), incl. descendants
ledger.classificationPerformance(id, of: taxonomy, in: interval)   // ClassificationPerformance?
ledger.classificationPerformance(of: taxonomy, in: interval)       // all nodes, depth first
// classificationID, initialValue, finalValue, inflows, outflows, absolutePerformance, ttwror,
// ttwrorAnnualized, irr
```

## Rebalancing

```swift
let p = allocation.rebalancing(RebalancingOptions(cash: 500_000, mode: .noSales, wholeShares: true))
let p = ledger.rebalancing(for: taxonomy, on: day, options: options)       // allocation + proposal

p.orders          // [Order(vehicle, name, amount, shares: Shares?, pricePerShare)], signed (+ buy)
p.totalBuys, p.totalSells, p.residualCash       // residual = cash − (buys − sells)
p.nodes           // [Node] tree: value, targetShare, amount (ideal), resultingValue, resultingShare, items, children
p.valueBefore, p.valueAfter, p.warnings, p.node(id), p.flattened
```

* `cash > 0` invests fresh money, `cash < 0` takes money out, `0` rebalances in place.
* `.buyAndSell`: every targeted classification ends on target. `.noSales`: water filling — new
  cash raises the most underweight classes to a common level, never selling (with negative cash:
  only sales, from the most overweight classes first).
* Targets are relative to the parent; sibling targets that do not sum to 100 % are normalized.
  Siblings without a target, vehicles assigned directly to a parent node and the unassigned bucket
  are left untouched; a level without any targets receives money in proportion to current values.
* Within a classification the amount is split over its vehicles in proportion to their current
  value — equally if the classification is empty.
* `wholeShares` rounds each security order towards zero at the latest price; what is left is in
  `residualCash`. Always: `Σ orders.amount + residualCash == cash`.
* `resultingValue` / `resultingShare` show what the orders really do — including rounding and the
  spill-over of vehicles that are split across classifications (`.sharedVehicle` warning).
* Warnings: `.noTargets`, `.targetsNormalized`, `.noVehicles`, `.sharedVehicle`, `.missingPrice`,
  `.insufficientHoldings`.
* Accounts can be vehicles too (a "Cash" class): their orders mean "keep this much more / less cash".

## Investment plans

```swift
plan.dueDates(through: today)            // [Day]; start + k × intervalMonths, day clamped to month length,
plan.dueDates(through: today, moveToWeekday: false)   // weekends → next Monday unless disabled
plan.dueDates(through: today, includingSkipped: true) // the full schedule
plan.skippedDueDates(through: today)     // [Day] scheduled days listed in plan.skippedDates
plan.isSkipped(due)                      // Bool
plan.nextDueDate(after: today)           // Day? — the first execution day that is not skipped
plan.sourceTag                           // "plan:<uuid>" — marks executions in Transaction.source

let status = ledger.planStatus(plan, through: today)
status.dueDates, status.executions /* (due, transactionID, date) */, status.missing, status.nextDue
status.skipped                           // [Day] — scheduled, but skipped by the user
status.problem                           // PlanProblem? — configuration error, nothing can be generated

let proposal = ledger.planTransactions(plan, through: today)       // or an array of plans
proposal.transactions                    // [Transaction] to append to file.transactions
proposal.skipped                         // [(due, reason)] e.g. .noPrice, .noExchangeRate
```

* Pure: nothing is modified. Generated ids are deterministic (`InvestmentPlan.executionID`), so
  generating twice never duplicates.
* purchase → `buy` of `amount` (incl. `fees`), shares = (amount − fees) / price on that day (last
  quote on or before it); without an account a `deliveryIn`. Foreign securities: gross converted
  at the day's rate and stored in `securityGross`. deposit / withdrawal → plain bookings.
* `InvestmentPlan.skippedDates` (execution day, or the nominal day when a weekend moved it) removes
  a date from `dueDates`, `missing`, `nextDue` and from the generated transactions; it is reported in
  `status.skipped`. To skip an open execution: `plan.skippedDates = (plan.skippedDates ?? []) + [due]`.
* An execution is recognised by `source == plan.sourceTag` (case-insensitive) and a date equal to
  the due date or within `toleranceDays` (default 7) of it.

## Consistency checks

```swift
let issues = ConsistencyChecker.check(file, options: .init(today: .today, staleAfterDays: 10))
let issues = ledger.consistencyIssues()            // same, on an existing ledger
for i in issues {                                  // most severe first
    i.severity      // .error | .warning | .info
    i.kind          // see below
    i.message       // English sentence, ready to display
    i.detail        // field name ("account", "shares", "counterAmount", …) or pair ("JPY→EUR")
    i.transactionIDs, i.securityID, i.accountID, i.depotID, i.day   // for navigation
    i.id            // stable String
}
```

| kind | severity | meaning |
|---|---|---|
| `negativeShares` | error | a depot holds < 0 shares at the end of a day (`day` = first such day) |
| `negativeCashBalance` | warning | account overdrawn at the end of a day (first day) |
| `missingField` | error | required account / depot / security / target / shares / counterAmount missing |
| `unknownReference` | error | id that does not exist in the file |
| `currencyMismatch` | error / warning | amount ≠ account currency (error); `securityGross` ≠ security currency (warning) |
| `invalidValue` | error / warning | negative magnitudes, transfer onto itself (error); fees + taxes > amount (warning) |
| `securityWithoutPrices` | warning | held today, no quotes |
| `stalePrices` | warning | held today, latest quote older than `staleAfterDays` (not for retired securities) |
| `missingExchangeRate` | error | a currency in use cannot be converted to the base currency |
| `duplicateTransactions` | warning | same kind, date, parties, shares and amount |

## Heatmap & rolling returns

```swift
let map = ledger.returnHeatmap(in: interval, scope: scope)   // or anyReturnSeries.heatmap()
map.rows            // [Row(year, months: [Double?] × 12, total)] — nil outside the interval
map.monthlyRange    // ClosedRange<Double>? for the colour scale
map.value(year: 2024, month: 3)

let r = ledger.rollingReturns(in: interval, windowDays: 365, annualized: false, scope: scope)
r.values            // [Double?] on the day axis; nil for the first `windowDays` days
r.best, r.worst, r.average, r.positiveShare
r.chartPoints(maxPoints: 400)
```

Both also exist on `ReturnSeries` (`heatmap()`, `rollingReturns(windowDays:annualized:)`), so they
work for benchmarks as well.

## Stock splits

The engine expects split-adjusted data. `StockSplit` rewrites history for a split that the data
does not reflect yet: quotes before the effective day × old/new, share counts of the security's
transactions before that day × new/old, plus a `.split` `SecurityEvent` ("2:1").

```swift
let split = StockSplit(securityID: id, day: exDay, ratio: "4:1")!        // or newShares:oldShares:
split.isRecorded(in: security)                 // guard against applying it twice
let newFile = file.applying(split)             // PortfolioFile? (nil: unknown security) — pure

let r = split.apply(to: security, transactions: file.transactions)       // lower level
r.security, r.transactions, r.adjustedTransactionIDs, r.adjustedPriceCount, r.event
```

## Analysis facade

One object per (ledger, scope, interval). Everything is lazy, cached and thread-safe; shared
intermediates (the lot replay, the daily pass) run at most once.

```swift
let a = Analysis(ledger: ledger, scope: .portfolio, interval: interval)
let a = Analysis(ledger: ledger, period: .ytd, today: .today)
let a = Analysis(file: file, interval: interval, reportingCurrency: "USD")   // builds its own Ledger

a.snapshot, a.initialSnapshot                        // Snapshot at interval.end / interval.start
a.valuation, a.returns, a.ttwror, a.ttwrorAnnualized, a.irr, a.absolutePerformance
a.breakdown, a.securities, a.security(id), a.risk, a.report      // report == ledger.performance(in:scope:)
a.drawdowns, a.investedCapital, a.heatmap, a.rollingReturns(windowDays: 365)
a.trades                                             // closed in the interval, open at its end
a.earnings
a.benchmark(securityID: id)                          // cached per security
a.allocation(for: taxonomy), a.rebalancing(for: taxonomy, options: options)
a.diagnostics                                        // of everything computed so far
```

| first access to … | work | ≈ time (20 y × 60 securities × 4 750 tx, release) |
|---|---|---|
| `snapshot`, `initialSnapshot`, `breakdown` | one lot replay | 0.3 ms |
| `valuation`, `returns`, `ttwror`, `irr`, `risk`, `heatmap`, `drawdowns`, … | one daily pass | 6–8 ms |
| `securities`, `report` | both of the above, shared | — |
| `trades`, `earnings` | one extra transaction pass each | 0.5 / 0.06 ms |
| `allocation`, `rebalancing` | reuse `snapshot` | 0.4 ms |

Later accesses are free. Results are immutable; create a new `Analysis` when the ledger, scope or
interval changes. A snapshot-only screen never pays for the daily pass.

## Internals (for engine contributors)

* `Entry` (`Ledger.entries`): compact, index-based transactions in processing order (chronological,
  see "Same-day ordering"; depot-less bookings already attributed to a holding) with amounts
  pre-converted to the reporting currency; `Ledger.holdingSecurity/holdingDepot` enumerate the
  (security, depot) pairs; `Ledger.value(security:shares:on:)`, `cashValue(account:balance:on:)`.
* `ResolvedScope`: per-holding / per-account weights and `flowLegs(_:_:)` (the external-flow rule).
* `LotReplay` (CostBasis.swift): event-driven replay maintaining shares, balances and tax lots;
  `advance(through:)`, `beginPeriod(at:)`, `holdingState(_:on:)`, `openLots()`, `closedLots`.
  Snapshots, breakdowns and trades are all views of it.
* `Ledger.dailyPass(_:_:perSecurity:)` (Valuation.swift): the single days × positions loop.
* `Ledger.analyze(_:replay:accumulators:)` (Performance.swift): breakdown and security records from
  a finished replay — shared by `performance(in:)` and `Analysis`.
* `Apportion` (Rebalancing.swift): exact largest-remainder split, water filling (`fill`) and its
  mirror (`drain`).
